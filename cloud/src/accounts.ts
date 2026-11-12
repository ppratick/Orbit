import type { Env } from "./env";
import { decryptSecret, encryptSecret } from "./crypto";
import { HttpError } from "./http";
import { newId, now, parseJson } from "./util";

export interface AccountRow {
  id: string;
  provider: string;
  label: string;
  identity: string | null;
  scopes: string | null;
  secret_ct: string;
  config: string;
  status: string;
  last_error: string | null;
  sync_state: string;
  last_sync_at: number | null;
}

/** Public shape — never includes secret material. */
export function publicAccount(a: AccountRow) {
  return {
    id: a.id,
    provider: a.provider,
    label: a.label,
    identity: a.identity,
    scopes: a.scopes,
    config: parseJson(a.config, {}),
    status: a.status,
    last_error: a.last_error,
    last_sync_at: a.last_sync_at,
  };
}

export async function upsertAccount(
  env: Env,
  a: { provider: string; label: string; identity: string; scopes?: string; secret: unknown; config?: Record<string, unknown> },
): Promise<string> {
  const ct = await encryptSecret(env, a.secret);
  const existing = await env.DB.prepare("SELECT id FROM accounts WHERE provider = ? AND identity = ?")
    .bind(a.provider, a.identity)
    .first<{ id: string }>();
  const id = existing?.id ?? newId("acct");
  const t = now();
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO accounts (id, provider, label, identity, scopes, secret_ct, config, status, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
       ON CONFLICT(provider, identity) DO UPDATE SET label = excluded.label, scopes = excluded.scopes,
         secret_ct = excluded.secret_ct, config = excluded.config, status = 'active', last_error = NULL, updated_at = excluded.updated_at`,
    ).bind(id, a.provider, a.label, a.identity, a.scopes ?? null, ct, JSON.stringify(a.config ?? {}), t, t),
  ]);
  return id;
}

export async function getAccount(env: Env, id: string): Promise<AccountRow> {
  const a = await env.DB.prepare("SELECT * FROM accounts WHERE id = ?").bind(id).first<AccountRow>();
  if (!a) throw new HttpError(404, `Account ${id} not found`, "not_found");
  return a;
}

export async function listAccounts(env: Env, provider?: string): Promise<AccountRow[]> {
  const r = provider
    ? await env.DB.prepare("SELECT * FROM accounts WHERE provider = ? AND status != 'disabled' ORDER BY created_at").bind(provider).all<AccountRow>()
    : await env.DB.prepare("SELECT * FROM accounts WHERE status != 'disabled' ORDER BY created_at").all<AccountRow>();
  return r.results;
}

export async function accountSecret<T>(env: Env, a: AccountRow): Promise<T> {
  return decryptSecret<T>(env, a.secret_ct);
}

export async function updateAccountSecret(env: Env, id: string, secret: unknown) {
  await env.DB.prepare("UPDATE accounts SET secret_ct = ?, updated_at = ? WHERE id = ?").bind(await encryptSecret(env, secret), now(), id).run();
}

export async function markAccountError(env: Env, id: string, error: string | null) {
  await env.DB.batch([
    env.DB.prepare("UPDATE accounts SET status = ?, last_error = ?, updated_at = ? WHERE id = ?").bind(error ? "error" : "active", error, now(), id),
  ]);
}

export async function setSyncState(env: Env, id: string, state: Record<string, unknown>) {
  await env.DB.prepare("UPDATE accounts SET sync_state = json_patch(COALESCE(sync_state, '{}'), ?), last_sync_at = ? WHERE id = ?").bind(JSON.stringify(state), now(), id).run();
}
