import type { Env } from "./env";
import { HttpError } from "./http";
import { newId, now, parseJson } from "./util";
import { getProfile, PROFILE_SECTIONS } from "./profile";

export interface MemoryRow {
  id: string;
  kind: "preference" | "fact";
  content: string;
  source: string;
  source_ref: string | null;
  created_at: number;
  updated_at: number;
}

export async function addMemory(env: Env, kind: string, content: string, source: string, sourceRef: string | null = null): Promise<string> {
  if (kind !== "preference" && kind !== "fact") throw new HttpError(400, "kind must be preference or fact", "validation");
  if (!content.trim()) throw new HttpError(400, "content is required", "validation");
  const id = newId("mem");
  const t = now();
  await env.DB.batch([
    env.DB.prepare("INSERT INTO memories (id, kind, content, source, source_ref, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)").bind(
      id,
      kind,
      content.trim().slice(0, 2000),
      source,
      sourceRef,
      t,
      t,
    ),
  ]);
  return id;
}

export async function updateMemory(env: Env, id: string, patch: { content?: string; kind?: string }) {
  const r = await env.DB.prepare(
    "UPDATE memories SET content = COALESCE(?, content), kind = COALESCE(?, kind), source = 'user', updated_at = ? WHERE id = ? AND deleted_at IS NULL",
  )
    .bind(patch.content ?? null, patch.kind ?? null, now(), id)
    .run();
  if (!r.meta.changes) throw new HttpError(404, "Memory not found", "not_found");
}

/** Direct user deletion from the app (the model has to go through the approval-gated memory.delete action). */
export async function deleteMemory(env: Env, id: string) {
  await env.DB.batch([
    env.DB.prepare("UPDATE memories SET deleted_at = ?, updated_at = ? WHERE id = ?").bind(now(), now(), id),
  ]);
}

export async function listMemories(env: Env, query?: string, limit = 100): Promise<MemoryRow[]> {
  if (query) {
    const terms = query.toLowerCase().split(/\s+/).filter((w) => w.length > 2).slice(0, 6);
    if (terms.length) {
      const where = terms.map(() => "LOWER(content) LIKE ?").join(" OR ");
      const r = await env.DB.prepare(`SELECT * FROM memories WHERE deleted_at IS NULL AND (${where}) ORDER BY updated_at DESC LIMIT ?`)
        .bind(...terms.map((t) => `%${t}%`), limit)
        .all<MemoryRow>();
      return r.results;
    }
  }
  const r = await env.DB.prepare("SELECT * FROM memories WHERE deleted_at IS NULL ORDER BY kind, updated_at DESC LIMIT ?").bind(limit).all<MemoryRow>();
  return r.results;
}

// ── Responsibilities ──────────────────────────────────────────────────────────
export interface ResponsibilityRow {
  id: string;
  title: string;
  kind: string;
  status: string;
  notes: string;
  due_at: number | null;
  next_check_at: number | null;
  check_interval_min: number | null;
  data: string;
  source: string;
  source_ref: string | null;
  dedupe_key: string | null;
  created_at: number;
  updated_at: number;
}

const KINDS = ["deadline", "followup", "delivery", "return", "refund", "renewal", "research", "custom"];

export async function upsertResponsibility(
  env: Env,
  r: {
    title: string;
    kind?: string;
    notes?: string;
    due_at?: number | null;
    next_check_at?: number | null;
    check_interval_min?: number | null;
    data?: Record<string, unknown>;
    source: string;
    source_ref?: string | null;
    dedupe_key?: string | null;
  },
): Promise<{ id: string; created: boolean }> {
  const kind = KINDS.includes(r.kind ?? "") ? r.kind! : "custom";
  if (r.dedupe_key) {
    const ex = await env.DB.prepare("SELECT id FROM responsibilities WHERE dedupe_key = ?").bind(r.dedupe_key).first<{ id: string }>();
    if (ex) return { id: ex.id, created: false };
  }
  const id = newId("resp");
  const t = now();
  const res = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO responsibilities (id, title, kind, notes, due_at, next_check_at, check_interval_min, data, source, source_ref, dedupe_key, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(dedupe_key) DO NOTHING`,
    ).bind(
      id,
      r.title.slice(0, 300),
      kind,
      (r.notes ?? "").slice(0, 4000),
      r.due_at ?? null,
      r.next_check_at ?? (r.due_at ? Math.max(t, r.due_at - 24 * 3600_000) : null),
      r.check_interval_min ?? null,
      JSON.stringify(r.data ?? {}),
      r.source,
      r.source_ref ?? null,
      r.dedupe_key ?? null,
      t,
      t,
    ),
  ]);
  return { id, created: !!res[0].meta.changes };
}

export async function updateResponsibility(
  env: Env,
  id: string,
  patch: { title?: string; status?: string; notes?: string; due_at?: number | null; next_check_at?: number | null; data?: Record<string, unknown> },
) {
  const cur = await env.DB.prepare("SELECT * FROM responsibilities WHERE id = ?").bind(id).first<ResponsibilityRow>();
  if (!cur) throw new HttpError(404, "Responsibility not found", "not_found");
  if (patch.status && !["active", "waiting", "done", "cancelled"].includes(patch.status)) throw new HttpError(400, "invalid status", "validation");
  const data = patch.data ? { ...parseJson(cur.data, {}), ...patch.data } : parseJson(cur.data, {});
  await env.DB.batch([
    env.DB.prepare(
      `UPDATE responsibilities SET title = ?, status = ?, notes = ?, due_at = ?, next_check_at = ?, data = ?, updated_at = ? WHERE id = ?`,
    ).bind(
      patch.title ?? cur.title,
      patch.status ?? cur.status,
      patch.notes ?? cur.notes,
      patch.due_at !== undefined ? patch.due_at : cur.due_at,
      patch.next_check_at !== undefined ? patch.next_check_at : cur.next_check_at,
      JSON.stringify(data),
      now(),
      id,
    ),
  ]);
}

export async function listResponsibilities(env: Env, includeClosed = false): Promise<ResponsibilityRow[]> {
  const r = await env.DB.prepare(
    `SELECT * FROM responsibilities ${includeClosed ? "" : "WHERE status IN ('active','waiting')"} ORDER BY COALESCE(due_at, 9e15), created_at LIMIT 200`,
  ).all<ResponsibilityRow>();
  return r.results;
}

// ── Conversation search ───────────────────────────────────────────────────────
export async function searchConversations(env: Env, query: string, limit = 20) {
  const fts = query
    .replace(/["*^():]/g, " ")
    .split(/\s+/)
    .filter(Boolean)
    .map((t) => `"${t}"`)
    .join(" ");
  if (!fts) return [];
  const r = await env.DB.prepare(
    `SELECT m.id, m.conversation_id, m.role, m.created_at, c.title, snippet(messages_fts, 0, '[', ']', '…', 12) AS snippet
     FROM messages_fts JOIN messages m ON m.rowid = messages_fts.rowid JOIN conversations c ON c.id = m.conversation_id
     WHERE messages_fts MATCH ? ORDER BY rank LIMIT ?`,
  )
    .bind(fts, limit)
    .all();
  return r.results;
}

// ── Markdown export ───────────────────────────────────────────────────────────
const iso = (t: number | null) => (t ? new Date(t).toISOString().replace(".000Z", "Z") : "—");

export async function exportMarkdown(env: Env, opts: { conversations?: boolean } = {}): Promise<string> {
  const out: string[] = [`# Orbit export`, ``, `Exported ${iso(now())}`, ``];
  const mems = await listMemories(env, undefined, 1000);
  const profile = await getProfile(env);
  out.push("## About you", "");
  for (const s of PROFILE_SECTIONS) {
    const text = profile.sections.find((x) => x.id === s.id)?.content.trim();
    if (text) out.push(`### ${s.title}`, "", text, "");
  }
  if (profile.suggestions.length) {
    out.push("### Suggestions awaiting review", "");
    for (const x of profile.suggestions) out.push(`- ${x.content} _(${x.section}; suggested ${iso(x.created_at)})_`);
    out.push("");
  }
  for (const kind of ["preference", "fact"] as const) {
    const rows = mems.filter((x) => x.kind === kind);
    if (kind === "fact" && !rows.length) continue;
    out.push(`## ${kind === "preference" ? "Preferences" : "Facts"}`, "");
    for (const m of rows) out.push(`- ${m.content} _(source: ${m.source}${m.source_ref ? ` ${m.source_ref}` : ""}; updated ${iso(m.updated_at)})_`);
    out.push("");
  }
  out.push("## Ongoing responsibilities", "");
  for (const r of await listResponsibilities(env, true)) {
    out.push(`- **${r.title}** — ${r.kind}, ${r.status}; due ${iso(r.due_at)}; next check ${iso(r.next_check_at)}${r.notes ? `\n  ${r.notes.replace(/\n/g, "\n  ")}` : ""}`);
  }
  out.push("", "## Pending approvals", "");
  const appr = await env.DB.prepare("SELECT * FROM approvals WHERE status = 'pending' ORDER BY created_at").all<{ summary: string; created_at: number }>();
  for (const a of appr.results) out.push(`- ${a.summary} _(requested ${iso(a.created_at)})_`);
  out.push("", "## Recent activity", "");
  const act = await env.DB.prepare("SELECT * FROM activity ORDER BY created_at DESC LIMIT 200").all<{ type: string; summary: string; created_at: number }>();
  for (const a of act.results) out.push(`- ${iso(a.created_at)} · ${a.type} · ${a.summary}`);
  out.push("", "## Notifications", "");
  const ntf = await env.DB.prepare("SELECT * FROM notifications ORDER BY created_at DESC LIMIT 200").all<{ title: string; body: string; created_at: number }>();
  for (const x of ntf.results) out.push(`- ${iso(x.created_at)} · **${x.title}** ${x.body}`);
  if (opts.conversations !== false) {
    out.push("", "## Conversations", "");
    // One query for all messages: D1 Free allows only 50 queries per invocation.
    const convs = await env.DB.prepare("SELECT * FROM conversations ORDER BY updated_at DESC LIMIT 100").all<{ id: string; title: string; created_at: number }>();
    const msgs = await env.DB.prepare(
      `SELECT conversation_id, role, content, created_at FROM messages WHERE role IN ('user','assistant')
       AND conversation_id IN (SELECT id FROM conversations ORDER BY updated_at DESC LIMIT 100) ORDER BY created_at`,
    ).all<{ conversation_id: string; role: string; content: string; created_at: number }>();
    for (const c of convs.results) {
      out.push(`### ${c.title}`, `_${iso(c.created_at)} · ${c.id}_`, "");
      for (const m of msgs.results.filter((x) => x.conversation_id === c.id)) {
        out.push(`**${m.role === "user" ? "You" : "Orbit"}** (${iso(m.created_at)}): ${m.content}`, "");
      }
    }
  }
  return out.join("\n");
}
