import type { Env } from "../env";
import { accountSecret, getAccount, markAccountError, updateAccountSecret, upsertAccount, type AccountRow } from "../accounts";
import { HttpError } from "../http";
import { htmlToText } from "../untrusted";
import { fromB64, now, randomToken, toB64Url } from "../util";
import { buildMime, validateRecipients, type MailMessage, type MailSummary, type OutgoingMail } from "./mail";

/**
 * Google: Gmail (read/search, drafts, send-after-approval) and Drive (read/search).
 * gmail.compose covers drafts and sending; sending is still gated by policy.ts.
 */
export const GOOGLE_SCOPES = [
  "openid",
  "email",
  "https://www.googleapis.com/auth/gmail.readonly",
  "https://www.googleapis.com/auth/gmail.compose",
  "https://www.googleapis.com/auth/drive.readonly",
];

interface GoogleSecret {
  refresh_token: string;
  access_token?: string;
  expires_at?: number;
}

function redirectUri(env: Env) {
  if (!env.PUBLIC_BASE_URL) throw new HttpError(500, "PUBLIC_BASE_URL is not configured", "config");
  return `${env.PUBLIC_BASE_URL.replace(/\/$/, "")}/oauth/google/callback`;
}

export async function googleAuthUrl(env: Env, label: string): Promise<string> {
  if (!env.GOOGLE_CLIENT_ID) throw new HttpError(500, "GOOGLE_CLIENT_ID is not configured", "config");
  const state = randomToken(24);
  await env.DB.prepare("INSERT INTO oauth_states (state, provider, label, expires_at) VALUES (?, 'google', ?, ?)")
    .bind(state, label, now() + 15 * 60_000)
    .run();
  const p = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    redirect_uri: redirectUri(env),
    response_type: "code",
    scope: GOOGLE_SCOPES.join(" "),
    access_type: "offline",
    prompt: "consent", // always return a refresh token, also when adding another account
    include_granted_scopes: "true",
    state,
  });
  return `https://accounts.google.com/o/oauth2/v2/auth?${p}`;
}

export async function googleCallback(env: Env, url: URL): Promise<{ accountId: string; email: string }> {
  const state = url.searchParams.get("state") ?? "";
  const code = url.searchParams.get("code");
  if (url.searchParams.get("error")) throw new HttpError(400, `Google returned: ${url.searchParams.get("error")}`, "oauth");
  const st = await env.DB.prepare("DELETE FROM oauth_states WHERE state = ? AND provider = 'google' AND expires_at > ? RETURNING label")
    .bind(state, now())
    .first<{ label: string }>();
  if (!st || !code) throw new HttpError(400, "OAuth state is invalid or expired; start again", "oauth");
  const tok = await tokenRequest(env, { grant_type: "authorization_code", code, redirect_uri: redirectUri(env) });
  if (!tok.refresh_token) throw new HttpError(400, "Google did not return a refresh token", "oauth");
  const info = (await (
    await fetch("https://openidconnect.googleapis.com/v1/userinfo", { headers: { authorization: `Bearer ${tok.access_token}` } })
  ).json()) as { email?: string };
  if (!info.email) throw new HttpError(400, "Could not read the Google account e-mail", "oauth");
  const accountId = await upsertAccount(env, {
    provider: "google",
    label: st.label || info.email,
    identity: info.email,
    scopes: tok.scope,
    secret: { refresh_token: tok.refresh_token, access_token: tok.access_token, expires_at: now() + tok.expires_in * 1000 } satisfies GoogleSecret,
  });
  return { accountId, email: info.email };
}

async function tokenRequest(env: Env, body: Record<string, string>) {
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: env.GOOGLE_CLIENT_ID ?? "", client_secret: env.GOOGLE_CLIENT_SECRET ?? "", ...body }),
  });
  const j = (await r.json()) as { access_token: string; expires_in: number; refresh_token?: string; scope?: string; error?: string; error_description?: string };
  if (!r.ok) {
    const err = new Error(`Google token error: ${j.error ?? r.status}${j.error_description ? ` (${j.error_description})` : ""}`);
    (err as Error & { oauthError?: string }).oauthError = j.error;
    throw err;
  }
  return j;
}

async function accessToken(env: Env, acct: AccountRow): Promise<string> {
  const sec = await accountSecret<GoogleSecret>(env, acct);
  if (sec.access_token && sec.expires_at && sec.expires_at - now() > 120_000) return sec.access_token;
  try {
    const tok = await tokenRequest(env, { grant_type: "refresh_token", refresh_token: sec.refresh_token });
    await updateAccountSecret(env, acct.id, { ...sec, access_token: tok.access_token, expires_at: now() + tok.expires_in * 1000 });
    if (acct.status === "error") await markAccountError(env, acct.id, null);
    return tok.access_token;
  } catch (e) {
    if ((e as { oauthError?: string }).oauthError === "invalid_grant") {
      // Revoked access, a password change, or (for OAuth apps left in "Testing") the 7-day refresh-token expiry.
      await markAccountError(env, acct.id, "Google authorization expired or was revoked — reconnect this account.");
    }
    throw e;
  }
}

async function gapi<T>(env: Env, acct: AccountRow, path: string, init: RequestInit = {}): Promise<T> {
  const token = await accessToken(env, acct);
  const r = await fetch(path.startsWith("http") ? path : `https://gmail.googleapis.com/gmail/v1/users/me/${path}`, {
    ...init,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", ...(init.headers ?? {}) },
  });
  if (!r.ok) throw new Error(`Google API ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return (await r.json()) as T;
}

interface GmailPart {
  mimeType: string;
  filename?: string;
  headers?: { name: string; value: string }[];
  body?: { data?: string; size?: number };
  parts?: GmailPart[];
}
interface GmailMsg {
  id: string;
  threadId: string;
  snippet: string;
  labelIds?: string[];
  internalDate: string;
  payload: GmailPart;
}

const header = (p: GmailPart, name: string) => p.headers?.find((h) => h.name.toLowerCase() === name.toLowerCase())?.value ?? "";
const decodeBody = (d?: string) => (d ? new TextDecoder().decode(fromB64(d)) : "");

export function extractGmailText(p: GmailPart): string {
  if (p.mimeType === "text/plain" && p.body?.data) return decodeBody(p.body.data);
  if (p.parts) {
    const plain = p.parts.map(extractGmailText).find((t) => t.trim());
    if (plain) return plain;
  }
  if (p.mimeType === "text/html" && p.body?.data) return htmlToText(decodeBody(p.body.data));
  return "";
}

function toSummary(m: GmailMsg): MailSummary {
  return {
    id: m.id,
    thread_id: m.threadId,
    from: header(m.payload, "From"),
    to: header(m.payload, "To"),
    subject: header(m.payload, "Subject"),
    date: Number(m.internalDate) || null,
    snippet: m.snippet,
    unread: m.labelIds?.includes("UNREAD"),
  };
}

export const gmail = {
  async search(env: Env, acct: AccountRow, q: string, max = 10): Promise<MailSummary[]> {
    const list = await gapi<{ messages?: { id: string }[] }>(env, acct, `messages?${new URLSearchParams({ q, maxResults: String(Math.min(max, 25)) })}`);
    const ids = (list.messages ?? []).map((m) => m.id);
    const out: MailSummary[] = [];
    for (const id of ids) {
      const m = await gapi<GmailMsg>(env, acct, `messages/${id}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject`);
      out.push(toSummary(m));
    }
    return out;
  },

  async read(env: Env, acct: AccountRow, id: string): Promise<MailMessage> {
    const m = await gapi<GmailMsg>(env, acct, `messages/${encodeURIComponent(id)}?format=full`);
    return {
      ...toSummary(m),
      cc: header(m.payload, "Cc"),
      message_id_header: header(m.payload, "Message-ID") || header(m.payload, "Message-Id"),
      references: header(m.payload, "References"),
      body: extractGmailText(m.payload),
    };
  },

  async raw(env: Env, acct: AccountRow, mail: OutgoingMail): Promise<{ raw: string; threadId?: string }> {
    let inReplyToHeader: string | undefined, referencesHeader: string | undefined, threadId: string | undefined;
    if (mail.in_reply_to) {
      const orig = await gmail.read(env, acct, mail.in_reply_to);
      inReplyToHeader = orig.message_id_header;
      referencesHeader = orig.references;
      threadId = orig.thread_id;
    }
    const mime = buildMime({ ...mail, to: validateRecipients(mail.to), cc: mail.cc ? validateRecipients(mail.cc) : undefined, inReplyToHeader, referencesHeader });
    return { raw: toB64Url(new TextEncoder().encode(mime)), threadId };
  },

  async createDraft(env: Env, acct: AccountRow, mail: OutgoingMail): Promise<{ draft_id: string; message_id: string }> {
    const { raw, threadId } = await gmail.raw(env, acct, mail);
    const d = await gapi<{ id: string; message: { id: string } }>(env, acct, "drafts", {
      method: "POST",
      body: JSON.stringify({ message: { raw, threadId } }),
    });
    return { draft_id: d.id, message_id: d.message.id };
  },

  async send(env: Env, acct: AccountRow, mail: OutgoingMail): Promise<{ message_id: string }> {
    const { raw, threadId } = await gmail.raw(env, acct, mail);
    const m = await gapi<{ id: string }>(env, acct, "messages/send", { method: "POST", body: JSON.stringify({ raw, threadId }) });
    return { message_id: m.id };
  },

  async sendDraft(env: Env, acct: AccountRow, draftId: string): Promise<{ message_id: string }> {
    const m = await gapi<{ id: string }>(env, acct, "drafts/send", { method: "POST", body: JSON.stringify({ id: draftId }) });
    return { message_id: m.id };
  },

  /** New inbox mail since the last heartbeat, for triage. Uses message ids as the de-duplication key. */
  async recent(env: Env, acct: AccountRow, max = 15): Promise<MailSummary[]> {
    return gmail.search(env, acct, "in:inbox newer_than:2d -category:promotions -category:social", max);
  },
};

export const drive = {
  /**
   * Full-text search (ranked by relevance), or, with an empty query, the most recently modified files.
   * Drive doesn't allow orderBy together with fullText terms, so recency only applies to the empty query.
   */
  async search(env: Env, acct: AccountRow, query: string, max = 10) {
    const text = query.trim();
    const q = text ? `fullText contains '${text.replace(/\\/g, "\\\\").replace(/'/g, "\\'")}' and trashed = false` : "trashed = false";
    const r = await gapi<{ files: { id: string; name: string; mimeType: string; modifiedTime: string; webViewLink: string }[] }>(
      env,
      acct,
      `https://www.googleapis.com/drive/v3/files?${new URLSearchParams({
        q,
        pageSize: String(Math.min(max, 25)),
        fields: "files(id,name,mimeType,modifiedTime,webViewLink)",
        includeItemsFromAllDrives: "true",
        supportsAllDrives: "true",
        corpora: "allDrives",
        ...(text ? {} : { orderBy: "modifiedTime desc" }),
      })}`,
    );
    return r.files;
  },

  async read(env: Env, acct: AccountRow, fileId: string, maxChars = 15000): Promise<{ name: string; mimeType: string; text: string }> {
    const meta = await gapi<{ name: string; mimeType: string; size?: string }>(
      env,
      acct,
      `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?fields=name,mimeType,size&supportsAllDrives=true`,
    );
    const token = await accessToken(env, acct);
    const exportMime: Record<string, string> = {
      "application/vnd.google-apps.document": "text/plain",
      "application/vnd.google-apps.spreadsheet": "text/csv",
      "application/vnd.google-apps.presentation": "text/plain",
    };
    let url: string;
    if (exportMime[meta.mimeType]) {
      url = `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}/export?mimeType=${encodeURIComponent(exportMime[meta.mimeType])}`;
    } else if (meta.mimeType.startsWith("text/") || meta.mimeType === "application/json") {
      url = `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?alt=media&supportsAllDrives=true`;
    } else {
      return { name: meta.name, mimeType: meta.mimeType, text: `[Binary file (${meta.mimeType}); text extraction is not supported in the cloud. Ask the Mac companion to open it.]` };
    }
    const r = await fetch(url, { headers: { authorization: `Bearer ${token}` } });
    if (!r.ok) throw new Error(`Drive ${r.status}`);
    return { name: meta.name, mimeType: meta.mimeType, text: (await r.text()).slice(0, maxChars) };
  },
};

export async function googleAccount(env: Env, id: string) {
  const a = await getAccount(env, id);
  if (a.provider !== "google") throw new Error(`Account ${id} is not a Google account`);
  return a;
}
