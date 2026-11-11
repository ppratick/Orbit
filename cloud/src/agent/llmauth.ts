import type { Env } from "../env";
import { listAccounts, accountSecret, updateAccountSecret, markAccountError, upsertAccount, type AccountRow } from "../accounts";
import { HttpError } from "../http";
import { now, randomToken, sha256Hex, toB64Url, parseJson, fromB64 } from "../util";
import { logActivity } from "../db";

/**
 * Model credentials, kept entirely outside model context.
 *
 * ChatGPT sign-in: the user's own OAuth client (Authorization Code + PKCE) yields an access token
 * that the public Responses API accepts and bills against the ChatGPT plan allowance. The Worker
 * generates the PKCE pair, performs the code exchange and refreshes tokens; devices only open the
 * authorize URL and hand back the redirect. Whether the plan allowance may be used from
 * Cloudflare (a remotely hosted, unattended caller) is NOT verified — see docs/STATUS.md.
 */
interface ChatgptSecret {
  access_token: string;
  refresh_token?: string;
  expires_at?: number;
}

export interface LlmAuth {
  mode: "chatgpt" | "api_key";
  baseUrl: string;
  bearer: string;
  accountId?: string;
}

export type AuthMode = "chatgpt" | "api_key" | "chatgpt_then_api_key";

export function authMode(env: Env): AuthMode {
  const m = env.OPENAI_AUTH_MODE as AuthMode | undefined;
  if (m === "chatgpt" || m === "api_key" || m === "chatgpt_then_api_key") return m;
  return "chatgpt_then_api_key";
}

function cfg(env: Env) {
  const missing = ["CHATGPT_OAUTH_CLIENT_ID", "CHATGPT_OAUTH_AUTHORIZE_URL", "CHATGPT_OAUTH_TOKEN_URL", "CHATGPT_OAUTH_REDIRECT_URI"].filter((k) => !env[k as keyof Env]);
  if (missing.length) throw new HttpError(500, `ChatGPT sign-in is not configured: ${missing.join(", ")}`, "config");
  return {
    clientId: env.CHATGPT_OAUTH_CLIENT_ID!,
    authorizeUrl: env.CHATGPT_OAUTH_AUTHORIZE_URL!,
    tokenUrl: env.CHATGPT_OAUTH_TOKEN_URL!,
    redirectUri: env.CHATGPT_OAUTH_REDIRECT_URI!,
    scopes: env.CHATGPT_OAUTH_SCOPES ?? "",
    extra: parseJson<Record<string, string>>(env.CHATGPT_OAUTH_EXTRA_PARAMS, {}),
  };
}

export async function chatgptAuthUrl(env: Env): Promise<{ url: string; state: string; redirect_uri: string }> {
  const c = cfg(env);
  const state = randomToken(24);
  const verifier = randomToken(48); // 64 chars of base64url → valid PKCE verifier (43–128)
  const challenge = toB64Url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
  await env.DB.prepare("INSERT INTO oauth_states (state, provider, label, expires_at, code_verifier, redirect_uri) VALUES (?, 'chatgpt', NULL, ?, ?, ?)")
    .bind(state, now() + 15 * 60_000, verifier, c.redirectUri)
    .run();
  const u = new URL(c.authorizeUrl);
  const params: Record<string, string> = {
    response_type: "code",
    client_id: c.clientId,
    redirect_uri: c.redirectUri,
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
    ...(c.scopes ? { scope: c.scopes } : {}),
    ...c.extra,
  };
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  return { url: u.toString(), state, redirect_uri: c.redirectUri };
}

/** Accepts either the full redirect URL the device captured, or code + state. */
export async function chatgptComplete(env: Env, input: { callback_url?: string; code?: string; state?: string }): Promise<{ accountId: string; identity: string }> {
  const c = cfg(env);
  let code = input.code,
    state = input.state;
  if (input.callback_url) {
    const u = new URL(input.callback_url);
    if (u.searchParams.get("error")) throw new HttpError(400, `Sign-in failed: ${u.searchParams.get("error")}`, "oauth");
    code = u.searchParams.get("code") ?? undefined;
    state = u.searchParams.get("state") ?? undefined;
  }
  if (!code || !state) throw new HttpError(400, "code and state are required", "validation");
  const st = await env.DB.prepare("DELETE FROM oauth_states WHERE state = ? AND provider = 'chatgpt' AND expires_at > ? RETURNING code_verifier, redirect_uri")
    .bind(state, now())
    .first<{ code_verifier: string; redirect_uri: string }>();
  if (!st) throw new HttpError(400, "Sign-in state is invalid or expired; start again", "oauth");
  const tok = await tokenRequest(c.tokenUrl, {
    grant_type: "authorization_code",
    code,
    redirect_uri: st.redirect_uri,
    client_id: c.clientId,
    code_verifier: st.code_verifier,
  });
  const identity = jwtEmail(tok.id_token) ?? jwtEmail(tok.access_token) ?? "ChatGPT account";
  const accountId = await upsertAccount(env, {
    provider: "chatgpt",
    label: `ChatGPT (${identity})`,
    identity,
    scopes: tok.scope ?? c.scopes,
    secret: { access_token: tok.access_token, refresh_token: tok.refresh_token, expires_at: tok.expires_in ? now() + tok.expires_in * 1000 : undefined } satisfies ChatgptSecret,
  });
  await logActivity(env, "account.linked", `Linked ${identity} for model access`, { provider: "chatgpt" });
  return { accountId, identity };
}

/** Email claim, used only as a display label (the token is not trusted for anything else here). */
function jwtEmail(jwt?: string): string | null {
  if (!jwt || jwt.split(".").length !== 3) return null;
  try {
    const p = JSON.parse(new TextDecoder().decode(fromB64(jwt.split(".")[1]))) as Record<string, unknown>;
    const nested = p["https://api.openai.com/profile"] as { email?: string } | undefined;
    return (p.email as string) ?? nested?.email ?? null;
  } catch {
    return null;
  }
}

interface TokenResponse {
  access_token: string;
  refresh_token?: string;
  id_token?: string;
  expires_in?: number;
  scope?: string;
}

async function tokenRequest(url: string, body: Record<string, string>): Promise<TokenResponse> {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" }, body: new URLSearchParams(body) });
  const text = await r.text();
  const j = parseJson<TokenResponse & { error?: string; error_description?: string }>(text, {} as TokenResponse);
  if (!r.ok || !j.access_token) {
    const e = new Error(`ChatGPT token endpoint: ${j.error ?? r.status}${j.error_description ? ` (${j.error_description})` : ""}`);
    (e as Error & { oauthError?: string }).oauthError = j.error;
    throw e;
  }
  return j;
}

async function chatgptAccount(env: Env): Promise<AccountRow | null> {
  return (await listAccounts(env, "chatgpt")).find((a) => a.status !== "disabled") ?? null;
}

async function chatgptToken(env: Env, acct: AccountRow, force: boolean): Promise<string> {
  const sec = await accountSecret<ChatgptSecret>(env, acct);
  if (!force && (!sec.expires_at || sec.expires_at - now() > 120_000)) return sec.access_token;
  if (!sec.refresh_token) throw new Error("ChatGPT access token expired and no refresh token is stored; sign in again");
  const c = cfg(env);
  try {
    const tok = await tokenRequest(c.tokenUrl, { grant_type: "refresh_token", refresh_token: sec.refresh_token, client_id: c.clientId });
    await updateAccountSecret(env, acct.id, {
      access_token: tok.access_token,
      refresh_token: tok.refresh_token ?? sec.refresh_token, // keep the old one unless rotated
      expires_at: tok.expires_in ? now() + tok.expires_in * 1000 : undefined,
    } satisfies ChatgptSecret);
    if (acct.status === "error") await markAccountError(env, acct.id, null);
    return tok.access_token;
  } catch (e) {
    // A concurrent invocation may have rotated the refresh token first; use its result if fresh.
    const latest = await env.DB.prepare("SELECT * FROM accounts WHERE id = ?").bind(acct.id).first<AccountRow>();
    if (latest && latest.secret_ct !== acct.secret_ct) {
      const s2 = await accountSecret<ChatgptSecret>(env, latest);
      if (!s2.expires_at || s2.expires_at - now() > 60_000) return s2.access_token;
    }
    if ((e as { oauthError?: string }).oauthError === "invalid_grant") await markAccountError(env, acct.id, "ChatGPT sign-in expired or was revoked — sign in again in Settings.");
    throw e;
  }
}

export async function resolveAuth(env: Env, preferred: "chatgpt" | "api_key", forceRefresh = false): Promise<LlmAuth> {
  if (preferred === "chatgpt") {
    const acct = await chatgptAccount(env);
    if (!acct) throw new LlmAuthError("No ChatGPT account is linked");
    return { mode: "chatgpt", baseUrl: env.CHATGPT_RESPONSES_BASE_URL || env.OPENAI_BASE_URL, bearer: await chatgptToken(env, acct, forceRefresh), accountId: acct.id };
  }
  if (!env.OPENAI_API_KEY) throw new LlmAuthError("OPENAI_API_KEY is not configured");
  return { mode: "api_key", baseUrl: env.OPENAI_BASE_URL, bearer: env.OPENAI_API_KEY };
}

export class LlmAuthError extends Error {}

/** Is a model backend configured at all? (Cheap check used to skip background LLM work.) */
export async function llmConfigured(env: Env): Promise<boolean> {
  const mode = authMode(env);
  if (mode !== "chatgpt" && env.OPENAI_API_KEY) return true;
  if (mode === "api_key") return false;
  return !!(await chatgptAccount(env));
}

export async function noteFallback(env: Env, reason: string) {
  console.warn("llm fallback to API key:", reason);
  await logActivity(env, "llm.fallback", `ChatGPT sign-in unavailable; used API key instead (${reason.slice(0, 160)})`);
}

export const _test = { sha256Hex };
