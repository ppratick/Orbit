import type { Env } from "./env";
import { publicAccount, type AccountRow } from "./accounts";
import { parseJson } from "./util";

const TABLES: Record<string, { table: string; map?: (r: Record<string, unknown>) => unknown }> = {
  conversation: { table: "conversations" },
  message: { table: "messages", map: (r) => ({ ...r, meta: parseJson(r.meta as string, null) }) },
  task: { table: "tasks", map: ({ lease_token: _l, params_hash: _h, ...r }) => ({ ...r, params: parseJson(r.params as string, {}), result: parseJson(r.result as string, r.result) }) },
  approval: { table: "approvals", map: ({ params_hash: _h, ...r }) => r },
  memory: { table: "memories" },
  profile: { table: "profile_sections" },
  profile_suggestion: { table: "profile_suggestions", map: ({ norm: _n, ...r }) => r },
  responsibility: { table: "responsibilities", map: (r) => ({ ...r, data: parseJson(r.data as string, {}) }) },
  notification: { table: "notifications" },
  activity: { table: "activity", map: (r) => ({ ...r, data: parseJson(r.data as string, {}) }) },
  account: { table: "accounts", map: (r) => publicAccount(r as unknown as AccountRow) },
  device: { table: "devices", map: ({ token_hash: _t, push_token, ...r }) => ({ ...r, has_push: !!push_token, capabilities: parseJson(r.capabilities as string, []) }) },
};

/**
 * Incremental sync: every device keeps a cursor (change_log.seq) and pulls rows changed since then.
 * Rows are returned in their current state (last-writer-wins on the server), deletions as ids.
 */
export async function sync(env: Env, since: number, limit = 500) {
  const minRow = await env.DB.prepare("SELECT MIN(seq) AS min, MAX(seq) AS max FROM change_log").first<{ min: number | null; max: number | null }>();
  const reset = since > 0 && minRow?.min != null && since < minRow.min - 1;
  const from = reset ? 0 : since;
  const changes = await env.DB.prepare("SELECT entity, entity_id, MAX(seq) AS seq FROM change_log WHERE seq > ? GROUP BY entity, entity_id ORDER BY seq LIMIT ?")
    .bind(from, limit)
    .all<{ entity: string; entity_id: string; seq: number }>();
  const grouped = new Map<string, string[]>();
  for (const c of changes.results) {
    if (!TABLES[c.entity]) continue;
    grouped.set(c.entity, [...(grouped.get(c.entity) ?? []), c.entity_id]);
  }
  const out: Record<string, unknown[]> = {};
  const deleted: Record<string, string[]> = {};
  for (const [entity, ids] of grouped) {
    const spec = TABLES[entity];
    const rows: Record<string, unknown>[] = [];
    for (let i = 0; i < ids.length; i += 90) {
      const chunk = ids.slice(i, i + 90);
      const r = await env.DB.prepare(`SELECT * FROM ${spec.table} WHERE id IN (${chunk.map(() => "?").join(",")})`).bind(...chunk).all<Record<string, unknown>>();
      rows.push(...r.results);
    }
    out[entity] = rows.map((r) => (spec.map ? spec.map(r) : r));
    const found = new Set(rows.map((r) => r.id as string));
    const gone = ids.filter((id) => !found.has(id));
    if (gone.length) deleted[entity] = gone;
  }
  const last = changes.results.length ? changes.results[changes.results.length - 1].seq : from;
  // If the page was truncated, the cursor is the highest seq we actually covered.
  const cursor = changes.results.length === limit ? last : Math.max(last, minRow?.max ?? 0, from);
  return { cursor, reset, has_more: changes.results.length === limit, changes: out, deleted };
}
