import type { Env } from "../env";
import { listAccounts, accountSecret, updateAccountSecret, markAccountError, upsertAccount, type AccountRow } from "../accounts";
import { HttpError } from "../http";
import { logActivity, getSetting, setSetting } from "../db";
import { fromB64, now, parseJson } from "../util";

/**
 * Model credentials via OpenAI's official "Sign in with ChatGPT" dynamic client registration
 * (ChatGPT plan usage for open-source / self-hosted apps):
 *   https://developers.openai.com/siwc/token-sharing-open-source
 *
 * Flow: a Mac/iPhone runs the browser sign-in locally (loopback 127.0.0.1 callback,
 * client_id=dynamic_agent_client on first registration, PKCE + nonce, its own ext_agent_host_id),
 * exchanges the code, then transfers the credential record to this Worker over TLS — the documented
 * "self-hosted VM" pattern. From then on the Worker alone owns refreshes (refresh tokens rotate) and
 * uses the access token for Responses API calls. Tokens never enter model context or API responses.
 *
 * Whether OpenAI treats a user's own Cloudflare Worker as a permitted self-hosted host (vs. a
 * "remotely hosted app" needing their interest form) is NOT verified — see docs/STATUS.md.
 */
export const RESOURCE = "https://api.openai.com/v1";
export const PLAN_SCOPE = "chatgpt.tokens.use.direct";
export const SIWC_SCOPES = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
export const AGENT_NAME = "Orbit";

export const issuer = (env: Env) => (env.SIWC_ISSUER || "https://auth.openai.com").replace(/\/$/, "");
export const responsesBase = (env: Env) => (env.CHATGPT_RESPONSES_BASE_URL || RESOURCE).replace(/\/$/, "");
const tokenEndpoint = (env: Env) => `${issuer(env)}/api/accounts/oauth/token`;

export interface ChatgptSecret {
  client_id: string;
  subject: string;
  email: string | null;
  access_token?: string;
  refresh_token?: string;
  id_token?: string;
  scopes: string[];
  expires_at?: number;
}

export type AuthMode = "chatgpt" | "api_key" | "chatgpt_then_api_key";
export function authMode(env: Env): AuthMode {
  const m = env.OPENAI_AUTH_MODE as AuthMode | undefined;
  return m === "api_key" || m === "chatgpt_then_api_key" ? m : "chatgpt";
}

export class LlmAuthError extends Error {
  constructor(message: string, public code = "auth") {
    super(message);
  }
}

/** Public sign-in parameters for devices (nothing secret). */
export async function signInConfig(env: Env) {
  const acct = await chatgptAccount(env);
  const sec = acct ? await accountSecret<ChatgptSecret>(env, acct) : null;
  return {
    authorize_url: `${issuer(env)}/api/accounts/authorize`,
    token_url: tokenEndpoint(env),
    scopes: SIWC_SCOPES,
    resource: RESOURCE,
    agent_name_hint: AGENT_NAME,
    registration: sec ? { client_id: sec.client_id, email: sec.email, plan_usage: sec.scopes.includes(PLAN_SCOPE), status: acct!.status } : null,
  };
}

// ── ID token validation (RS256 against OpenAI's published JWKS) ───────────────
let jwksCache: { at: number; issuer: string; keys: JsonWebKey[]; revocation?: string } | null = null;

async function discovery(env: Env) {
  if (jwksCache && jwksCache.issuer === issuer(env) && now() - jwksCache.at < 3600_000) return jwksCache;
  const conf = (await (await fetch(`${issuer(env)}/.well-known/openid-configuration`)).json()) as { jwks_uri: string; revocation_endpoint?: string };
  const jwks = (await (await fetch(conf.jwks_uri)).json()) as { keys: JsonWebKey[] };
  jwksCache = { at: now(), issuer: issuer(env), keys: jwks.keys, revocation: conf.revocation_endpoint };
  return jwksCache;
}

function decodePart<T>(part: string): T {
  return JSON.parse(new TextDecoder().decode(fromB64(part))) as T;
}

export interface IdClaims {
  iss: string;
  aud: string | string[];
  sub: string;
  exp: number;
  nonce?: string;
  email?: string;
}

export async function verifyIdToken(env: Env, idToken: string, clientId: string, nonce: string | null): Promise<IdClaims> {
  const parts = idToken.split(".");
  if (parts.length !== 3) throw new HttpError(400, "Malformed ID token", "id_token");
  const header = decodePart<{ alg: string; kid?: string }>(parts[0]);
  if (header.alg !== "RS256") throw new HttpError(400, `Unsupported ID token algorithm ${header.alg}`, "id_token");
  const verifyWith = async (keys: JsonWebKey[]) => {
    const jwk = keys.find((k) => (k as { kid?: string }).kid === header.kid) ?? (keys.length === 1 ? keys[0] : undefined);
    if (!jwk) return null;
    const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
    return crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, fromB64(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  };
  let ok = await verifyWith((await discovery(env)).keys);
  if (ok === null) {
    jwksCache = null; // key rotation: refetch once
    ok = await verifyWith((await discovery(env)).keys);
  }
  if (!ok) throw new HttpError(400, "ID token signature is invalid", "id_token");
  const c = decodePart<IdClaims>(parts[1]);
  const aud = Array.isArray(c.aud) ? c.aud : [c.aud];
  if (c.iss !== issuer(env)) throw new HttpError(400, "ID token issuer mismatch", "id_token");
  if (!aud.includes(clientId)) throw new HttpError(400, "ID token audience does not match the issued client ID", "id_token");
  if (c.exp * 1000 < now() - 60_000) throw new HttpError(400, "ID token expired", "id_token");
  if (nonce !== null && c.nonce !== nonce) throw new HttpError(400, "ID token nonce mismatch", "id_token");
  if (!c.sub) throw new HttpError(400, "ID token has no subject", "id_token");
  return c;
}

/**
 * Import a credential record produced by a device's local sign-in. The Worker re-validates the ID token
 * (signature, issuer, audience = issued client_id, expiry, nonce) and checks the plan-usage scope.
 */
export async function importCredentials(
  env: Env,
  b: { client_id: string; nonce: string; access_token: string; refresh_token?: string; id_token: string; expires_in?: number; scope?: string },
) {
  if (!b.client_id || b.client_id === "dynamic_agent_client") throw new HttpError(400, "client_id must be the issued client ID (oaiapp_…), not dynamic_agent_client", "validation");
  if (!b.access_token || !b.id_token) throw new HttpError(400, "access_token and id_token are required", "validation");
  const claims = await verifyIdToken(env, b.id_token, b.client_id, b.nonce ?? null);
  const scopes = (b.scope ?? "").split(/\s+/).filter(Boolean);
  const existing = await chatgptAccount(env, true);
  if (existing) {
    const prev = await accountSecret<ChatgptSecret>(env, existing);
    // Never mix one registration's client ID with another identity's tokens.
    if (prev.client_id === b.client_id && prev.subject !== claims.sub) throw new HttpError(409, "This registration belongs to a different ChatGPT account", "identity_mismatch");
  }
  const secret: ChatgptSecret = {
    client_id: b.client_id,
    subject: claims.sub,
    email: claims.email ?? null,
    access_token: b.access_token,
    refresh_token: b.refresh_token,
    id_token: b.id_token,
    scopes,
    expires_at: now() + (b.expires_in ?? 3600) * 1000,
  };
  // Single active ChatGPT registration: disable any other one so only one set of tokens is refreshed.
  await env.DB.prepare("UPDATE accounts SET status = 'disabled', updated_at = ? WHERE provider = 'chatgpt' AND identity != ?").bind(now(), `${b.client_id}:${claims.sub}`).run();
  const accountId = await upsertAccount(env, {
    provider: "chatgpt",
    label: claims.email ? `ChatGPT (${claims.email})` : "ChatGPT",
    identity: `${b.client_id}:${claims.sub}`,
    scopes: scopes.join(" "),
    secret,
  });
  const planUsage = scopes.includes(PLAN_SCOPE);
  if (!planUsage) await markAccountError(env, accountId, "ChatGPT plan usage was not granted. Sign in again and allow it.");
  await logActivity(env, "account.linked", `Signed in with ChatGPT${claims.email ? ` (${claims.email})` : ""}${planUsage ? "" : " — plan usage not granted"}`, { provider: "chatgpt" });
  return { account_id: accountId, email: claims.email ?? null, plan_usage: planUsage, worker_host_id: await workerHostId(env) };
}

/** Stable, opaque host ID for this Worker as an agent host (kept for attribution/reference). */
export async function workerHostId(env: Env): Promise<string> {
  const cur = await getSetting(env, "siwc_host_id");
  if (cur) return cur;
  const id = `urn:uuid:${crypto.randomUUID()}`;
  await setSetting(env, "siwc_host_id", id);
  return id;
}

async function chatgptAccount(env: Env, includeError = true): Promise<AccountRow | null> {
  const all = await listAccounts(env, "chatgpt");
  return all.find((a) => a.status === "active") ?? (includeError ? (all.find((a) => a.status !== "disabled") ?? null) : null);
}

const UNUSABLE_REFRESH = new Set(["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]);

async function refresh(env: Env, acct: AccountRow, sec: ChatgptSecret): Promise<ChatgptSecret> {
  // Serialise refreshes of this rotating token across concurrent invocations.
  const t = now();
  const lock = await env.DB.prepare("UPDATE accounts SET lock_until = ? WHERE id = ? AND (lock_until IS NULL OR lock_until < ?)").bind(t + 30_000, acct.id, t).run();
  if (!lock.meta.changes) {
    for (let i = 0; i < 8; i++) {
      await new Promise((r) => setTimeout(r, 500));
      const fresh = await env.DB.prepare("SELECT * FROM accounts WHERE id = ?").bind(acct.id).first<AccountRow>();
      const s2 = fresh ? await accountSecret<ChatgptSecret>(env, fresh) : null;
      if (s2?.access_token && (s2.expires_at ?? 0) - now() > 60_000) return s2;
    }
    throw new LlmAuthError("Another request is refreshing the ChatGPT session; try again shortly", "refresh_busy");
  }
  try {
    // Re-read inside the lock in case another invocation just rotated the token.
    const latest = await env.DB.prepare("SELECT * FROM accounts WHERE id = ?").bind(acct.id).first<AccountRow>();
    const cur = latest ? await accountSecret<ChatgptSecret>(env, latest) : sec;
    if (cur.access_token && (cur.expires_at ?? 0) - now() > 120_000 && cur.access_token !== sec.access_token) return cur;
    if (!cur.refresh_token) throw new LlmAuthError("ChatGPT session expired; sign in again", "signin_required");
    const r = await fetch(tokenEndpoint(env), {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: new URLSearchParams({ grant_type: "refresh_token", client_id: cur.client_id, refresh_token: cur.refresh_token, resource: RESOURCE }),
    });
    const j = parseJson<{ access_token?: string; refresh_token?: string; id_token?: string; expires_in?: number; scope?: string; error?: string; error_description?: string }>(await r.text(), {});
    if (!r.ok || !j.access_token) {
      const code = j.error ?? `http_${r.status}`;
      if (UNUSABLE_REFRESH.has(code)) {
        await updateAccountSecret(env, acct.id, { ...cur, access_token: undefined, refresh_token: undefined } satisfies ChatgptSecret);
        await markAccountError(env, acct.id, "ChatGPT sign-in expired or was disconnected — sign in again in Settings.");
        throw new LlmAuthError("ChatGPT session ended; sign in again", "signin_required");
      }
      if (code === "invalid_client") await markAccountError(env, acct.id, "ChatGPT client registration is invalid — sign in again.");
      throw new LlmAuthError(`ChatGPT token refresh failed: ${code}`, code);
    }
    // Replace access token, expiry, scopes and the rotating refresh token together.
    const next: ChatgptSecret = {
      ...cur,
      access_token: j.access_token,
      refresh_token: j.refresh_token ?? cur.refresh_token,
      id_token: j.id_token ?? cur.id_token,
      scopes: j.scope ? j.scope.split(/\s+/).filter(Boolean) : cur.scopes,
      expires_at: now() + (j.expires_in ?? 3600) * 1000,
    };
    await updateAccountSecret(env, acct.id, next);
    if (acct.status === "error") await markAccountError(env, acct.id, null);
    return next;
  } finally {
    await env.DB.prepare("UPDATE accounts SET lock_until = NULL WHERE id = ?").bind(acct.id).run();
  }
}

export interface LlmAuth {
  mode: "chatgpt" | "api_key";
  baseUrl: string;
  bearer: string;
  accountId?: string;
}

export async function resolveAuth(env: Env, preferred: "chatgpt" | "api_key", forceRefresh = false): Promise<LlmAuth> {
  if (preferred === "api_key") {
    if (!env.OPENAI_API_KEY) throw new LlmAuthError("OPENAI_API_KEY is not configured", "no_api_key");
    return { mode: "api_key", baseUrl: env.OPENAI_BASE_URL, bearer: env.OPENAI_API_KEY };
  }
  const acct = await chatgptAccount(env);
  if (!acct) throw new LlmAuthError("Sign in with ChatGPT in Orbit's Settings to enable the assistant", "signin_required");
  if (acct.status === "signed_out") throw new LlmAuthError("Signed out of ChatGPT; sign in again in Orbit's Settings", "signin_required");
  let sec = await accountSecret<ChatgptSecret>(env, acct);
  if (!sec.scopes.includes(PLAN_SCOPE)) throw new LlmAuthError("ChatGPT plan usage was not granted; sign in again and allow it", "plan_usage_disabled");
  if (forceRefresh || !sec.access_token || (sec.expires_at ?? 0) - now() < 120_000) sec = await refresh(env, acct, sec);
  return { mode: "chatgpt", baseUrl: responsesBase(env), bearer: sec.access_token!, accountId: acct.id };
}

export async function llmConfigured(env: Env): Promise<boolean> {
  const mode = authMode(env);
  if (mode !== "chatgpt" && env.OPENAI_API_KEY) return true;
  if (mode === "api_key") return false;
  return !!(await chatgptAccount(env, false));
}

/** Sign out: revoke the renewable session, clear tokens, keep the client/account mapping. */
export async function signOut(env: Env): Promise<{ revoked: boolean }> {
  const acct = await chatgptAccount(env);
  if (!acct) return { revoked: false };
  const sec = await accountSecret<ChatgptSecret>(env, acct);
  let revoked = false;
  if (sec.refresh_token) {
    try {
      const d = await discovery(env);
      const endpoint = d.revocation ?? `${issuer(env)}/api/accounts/oauth/revoke`;
      const r = await fetch(endpoint, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ token: sec.refresh_token, token_type_hint: "refresh_token", client_id: sec.client_id }),
      });
      revoked = r.status === 200;
    } catch {
      revoked = false;
    }
  }
  await updateAccountSecret(env, acct.id, { client_id: sec.client_id, subject: sec.subject, email: sec.email, scopes: [] } satisfies ChatgptSecret);
  await env.DB.prepare("UPDATE accounts SET status = 'signed_out', last_error = ?, updated_at = ? WHERE id = ?")
    .bind(revoked ? null : "Remote revocation not confirmed; you can disconnect Orbit in ChatGPT Settings.", now(), acct.id)
    .run();
  await logActivity(env, "account.signed_out", `Signed out of ChatGPT${revoked ? "" : " (remote revocation not confirmed)"}`);
  return { revoked };
}

/** The signed-in account's model catalog (verifies which model IDs this account can use). */
export async function modelCatalog(env: Env): Promise<{ slug: string; display_name?: string }[]> {
  const auth = await resolveAuth(env, authMode(env) === "api_key" ? "api_key" : "chatgpt");
  const r = await fetch(`${auth.baseUrl}/models`, { headers: { authorization: `Bearer ${auth.bearer}` } });
  if (!r.ok) throw new Error(`Model list failed: HTTP ${r.status} ${(await r.text()).slice(0, 200)}`);
  const j = (await r.json()) as { models?: { slug: string; display_name?: string; visibility?: string }[]; data?: { id: string }[] };
  if (j.models) return j.models.filter((m) => !m.visibility || m.visibility === "list").map((m) => ({ slug: m.slug, display_name: m.display_name }));
  return (j.data ?? []).map((m) => ({ slug: m.id }));
}

export async function noteFallback(env: Env, reason: string) {
  console.warn("llm fallback to API key:", reason);
  await logActivity(env, "llm.fallback", `ChatGPT plan usage unavailable; used the paid API key instead (${reason.slice(0, 160)})`);
}
