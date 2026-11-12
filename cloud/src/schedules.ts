import type { Env } from "./env";
import { HttpError } from "./http";
import { MAIN_CONVERSATION_ID, mainConversation } from "./conversation";
import { newId, now, truncate } from "./util";

/**
 * Scheduled tasks. A due task becomes a hidden instruction message in the main conversation's
 * inbox, so the normal assistant turn carries it out: replies land in the chat and every
 * consequential action goes through the same approval policy as a typed request.
 */
export type Repeat = "once" | "daily" | "weekdays" | "weekly" | "interval";
export const REPEATS: Repeat[] = ["once", "daily", "weekdays", "weekly", "interval"];

export interface ScheduleRow {
  id: string;
  title: string;
  instructions: string;
  repeat: Repeat;
  time_of_day: string | null;
  days: string | null;
  interval_hours: number | null;
  run_at: number | null;
  timezone: string;
  respect_quiet_hours: number;
  status: "active" | "paused" | "done";
  next_run_at: number | null;
  last_run_at: number | null;
  last_finished_at: number | null;
  last_status: string | null;
  last_result: string | null;
  last_message_id: string | null;
  run_count: number;
  source: string;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
}

export interface ScheduleInput {
  title?: string;
  instructions?: string;
  repeat?: string;
  time_of_day?: string | null;
  days?: number[] | string | null;
  interval_hours?: number | null;
  run_at?: number | string | null;
  timezone?: string;
  respect_quiet_hours?: boolean;
  status?: string;
}

// ── Time-zone math (Intl only; no libraries in Workers) ──────────────────────
const MIN = 60_000, HOUR = 3_600_000, DAY = 86_400_000;
const dtf = new Map<string, Intl.DateTimeFormat>();
function fmt(tz: string) {
  let f = dtf.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", weekday: "short" });
    dtf.set(tz, f);
  }
  return f;
}
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
/** Wall-clock parts of instant `t` in `tz`. */
export function partsIn(tz: string, t: number) {
  const p = Object.fromEntries(fmt(tz).formatToParts(new Date(t)).map((x) => [x.type, x.value]));
  return { y: +p.year, m: +p.month, d: +p.day, h: +p.hour % 24, mi: +p.minute, wd: WEEKDAYS.indexOf(p.weekday) };
}
/** The instant when the wall clock in `tz` reads y-m-d h:mi (DST-safe; a skipped hour moves forward). */
export function zonedToUtc(tz: string, y: number, m: number, d: number, h: number, mi: number): number {
  const want = Date.UTC(y, m - 1, d, h, mi);
  let t = want;
  for (let i = 0; i < 3; i++) {
    const p = partsIn(tz, t);
    const diff = Date.UTC(p.y, p.m - 1, p.d, p.h, p.mi) - want;
    if (!diff) return t;
    t -= diff;
  }
  return t;
}
export function validTimezone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}
const parseHM = (v: string | null | undefined) => {
  const m = /^([01]?\d|2[0-3]):([0-5]\d)$/.exec(v ?? "");
  return m ? { h: +m[1], mi: +m[2] } : null;
};

/** Quiet hours like "22:00-07:00" (may wrap past midnight). */
export function parseQuiet(v: string | null | undefined): { start: number; end: number } | null {
  const [a, b] = (v ?? "").split("-");
  const s = parseHM(a), e = parseHM(b);
  if (!s || !e) return null;
  const start = s.h * 60 + s.mi, end = e.h * 60 + e.mi;
  return start === end ? null : { start, end };
}
export function inQuiet(quiet: { start: number; end: number }, tz: string, t: number): boolean {
  const p = partsIn(tz, t);
  const m = p.h * 60 + p.mi;
  return quiet.start < quiet.end ? m >= quiet.start && m < quiet.end : m >= quiet.start || m < quiet.end;
}
/** First moment after `t` when quiet hours end. */
export function quietEnd(quiet: { start: number; end: number }, tz: string, t: number): number {
  const p = partsIn(tz, t);
  let at = zonedToUtc(tz, p.y, p.m, p.d, Math.floor(quiet.end / 60), quiet.end % 60);
  if (at <= t) {
    const next = partsIn(tz, at + DAY);
    at = zonedToUtc(tz, next.y, next.m, next.d, Math.floor(quiet.end / 60), quiet.end % 60);
  }
  return at;
}

const daySet = (s: Pick<ScheduleRow, "repeat" | "days">): number[] =>
  s.repeat === "daily" ? [0, 1, 2, 3, 4, 5, 6]
    : s.repeat === "weekdays" ? [1, 2, 3, 4, 5]
      : (s.days ?? "").split(",").map((x) => +x).filter((x) => x >= 0 && x <= 6);

/** Next time the rule fires strictly after `after`, before quiet hours are applied. */
export function nextOccurrence(s: Pick<ScheduleRow, "repeat" | "time_of_day" | "days" | "interval_hours" | "run_at" | "timezone">, after: number, prev?: number | null): number | null {
  if (s.repeat === "once") return s.run_at && s.run_at > after ? s.run_at : null;
  if (s.repeat === "interval") {
    const step = Math.max(1, s.interval_hours ?? 1) * HOUR;
    let t = prev ?? after;
    while (t <= after) t += step;
    return t;
  }
  const hm = parseHM(s.time_of_day);
  const days = daySet(s);
  if (!hm || !days.length) return null;
  const base = partsIn(s.timezone, after);
  for (let i = 0; i <= 8; i++) {
    const day = partsIn(s.timezone, zonedToUtc(s.timezone, base.y, base.m, base.d, 12, 0) + i * DAY);
    const at = zonedToUtc(s.timezone, day.y, day.m, day.d, hm.h, hm.mi);
    if (at > after && days.includes(partsIn(s.timezone, at).wd)) return at;
  }
  return null;
}

/** Next run including quiet-hours deferral. */
export function computeNextRun(s: Parameters<typeof nextOccurrence>[0] & { respect_quiet_hours: number }, quiet: string | null, after: number, prev?: number | null): number | null {
  const t = nextOccurrence(s, after, prev);
  if (t == null) return null;
  const q = parseQuiet(quiet);
  return q && s.respect_quiet_hours && inQuiet(q, s.timezone, t) ? quietEnd(q, s.timezone, t) : t;
}

/** "Every weekday at 8:00 AM (Eastern Time)" — for chat and tool results. */
export function describeRule(s: Pick<ScheduleRow, "repeat" | "time_of_day" | "days" | "interval_hours" | "run_at" | "timezone">): string {
  const hm = parseHM(s.time_of_day);
  const time = hm ? new Date(Date.UTC(2000, 0, 1, hm.h, hm.mi)).toLocaleTimeString("en-US", { timeZone: "UTC", hour: "numeric", minute: "2-digit" }) : "";
  const zone = new Intl.DateTimeFormat("en-US", { timeZone: s.timezone, timeZoneName: "long" }).formatToParts(new Date()).find((p) => p.type === "timeZoneName")?.value ?? s.timezone;
  switch (s.repeat) {
    case "once":
      return s.run_at ? `Once, ${new Intl.DateTimeFormat("en-US", { timeZone: s.timezone, weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(s.run_at)} (${zone})` : "Once";
    case "interval":
      return `Every ${s.interval_hours ?? 1} hour${(s.interval_hours ?? 1) === 1 ? "" : "s"}`;
    case "daily":
      return `Every day at ${time} (${zone})`;
    case "weekdays":
      return `Every weekday at ${time} (${zone})`;
    default: {
      const names = daySet(s).map((d) => ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d]).join(", ");
      return `Every ${names} at ${time} (${zone})`;
    }
  }
}

// ── Validation & storage ─────────────────────────────────────────────────────
async function quietHours(env: Env): Promise<string | null> {
  return (await env.DB.prepare("SELECT content FROM profile_sections WHERE id = 'quiet_hours'").first<{ content: string }>())?.content || null;
}

function normalize(input: ScheduleInput, base: Partial<ScheduleRow>, defaultTz: string): Omit<ScheduleRow, "id" | "status" | "next_run_at" | "last_run_at" | "last_finished_at" | "last_status" | "last_result" | "last_message_id" | "run_count" | "source" | "created_at" | "updated_at" | "deleted_at"> {
  const title = (input.title ?? base.title ?? "").trim().slice(0, 120);
  const instructions = (input.instructions ?? base.instructions ?? "").trim().slice(0, 4000);
  if (!title) throw new HttpError(400, "A scheduled task needs a title", "validation");
  if (!instructions) throw new HttpError(400, "A scheduled task needs instructions", "validation");
  const repeat = (input.repeat ?? base.repeat ?? "") as Repeat;
  if (!REPEATS.includes(repeat)) throw new HttpError(400, "repeat must be once, daily, weekdays, weekly or interval", "validation");
  const timezone = input.timezone ?? base.timezone ?? defaultTz;
  if (!validTimezone(timezone)) throw new HttpError(400, `Unknown time zone ${timezone}`, "validation");
  const time_of_day = input.time_of_day !== undefined ? input.time_of_day : base.time_of_day ?? null;
  const daysIn = input.days !== undefined ? input.days : base.days ?? null;
  const days = Array.isArray(daysIn) ? daysIn.filter((d) => Number.isInteger(d) && d >= 0 && d <= 6).join(",") : (daysIn ?? null);
  const interval_hours = input.interval_hours !== undefined ? input.interval_hours : base.interval_hours ?? null;
  const runAtIn = input.run_at !== undefined ? input.run_at : base.run_at ?? null;
  const run_at = runAtIn == null || runAtIn === "" ? null : typeof runAtIn === "number" ? runAtIn : Date.parse(runAtIn);
  if (run_at != null && Number.isNaN(run_at)) throw new HttpError(400, "run_at must be an ISO date-time", "validation");
  if (repeat === "once" && run_at == null) throw new HttpError(400, "A one-time task needs run_at", "validation");
  if (["daily", "weekdays", "weekly"].includes(repeat) && !parseHM(time_of_day)) throw new HttpError(400, "time_of_day must be HH:MM", "validation");
  if (repeat === "weekly" && !days) throw new HttpError(400, "A weekly task needs days (0 = Sunday … 6 = Saturday)", "validation");
  if (repeat === "interval" && !(interval_hours && interval_hours >= 1 && interval_hours <= 168)) throw new HttpError(400, "interval_hours must be 1–168", "validation");
  const respect = input.respect_quiet_hours !== undefined ? (input.respect_quiet_hours ? 1 : 0) : base.respect_quiet_hours ?? 1;
  return { title, instructions, repeat, time_of_day, days, interval_hours, run_at, timezone, respect_quiet_hours: respect };
}

export async function listSchedules(env: Env, includeDeleted = false): Promise<ScheduleRow[]> {
  const r = await env.DB.prepare(`SELECT * FROM schedules ${includeDeleted ? "" : "WHERE deleted_at IS NULL"} ORDER BY COALESCE(next_run_at, 9e15), created_at`).all<ScheduleRow>();
  return r.results;
}

export async function getSchedule(env: Env, id: string): Promise<ScheduleRow> {
  const s = await env.DB.prepare("SELECT * FROM schedules WHERE id = ? AND deleted_at IS NULL").bind(id).first<ScheduleRow>();
  if (!s) throw new HttpError(404, "Scheduled task not found", "not_found");
  return s;
}

export async function createSchedule(env: Env, input: ScheduleInput, source: "user" | "conversation"): Promise<ScheduleRow> {
  const v = normalize(input, {}, env.ORBIT_TIMEZONE);
  const t = now();
  const next = computeNextRun(v, await quietHours(env), t);
  if (next == null) throw new HttpError(400, "That schedule never runs (is the time in the past?)", "validation");
  const id = newId("sch");
  await env.DB.prepare(
    `INSERT INTO schedules (id, title, instructions, repeat, time_of_day, days, interval_hours, run_at, timezone, respect_quiet_hours, status, next_run_at, source, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?)`,
  ).bind(id, v.title, v.instructions, v.repeat, v.time_of_day, v.days, v.interval_hours, v.run_at, v.timezone, v.respect_quiet_hours, next, source, t, t).run();
  return getSchedule(env, id);
}

/** Edit fields and/or pause, resume. Recomputes the next run from now. */
export async function updateSchedule(env: Env, id: string, input: ScheduleInput): Promise<ScheduleRow> {
  const cur = await getSchedule(env, id);
  const v = normalize(input, cur, env.ORBIT_TIMEZONE);
  let status = (input.status ?? cur.status) as ScheduleRow["status"];
  if (!["active", "paused", "done"].includes(status)) throw new HttpError(400, "status must be active or paused", "validation");
  const t = now();
  let next: number | null = null;
  if (status !== "paused") {
    next = computeNextRun(v, await quietHours(env), t);
    // Editing or resuming a finished one-time task with a new future time brings it back.
    status = next == null ? "done" : "active";
    if (next == null && input.status === "active") throw new HttpError(400, "That schedule has no future run", "validation");
  }
  await env.DB.prepare(
    `UPDATE schedules SET title = ?, instructions = ?, repeat = ?, time_of_day = ?, days = ?, interval_hours = ?, run_at = ?, timezone = ?,
       respect_quiet_hours = ?, status = ?, next_run_at = ?, updated_at = ? WHERE id = ?`,
  ).bind(v.title, v.instructions, v.repeat, v.time_of_day, v.days, v.interval_hours, v.run_at, v.timezone, v.respect_quiet_hours, status, next, t, id).run();
  return getSchedule(env, id);
}

export async function deleteSchedule(env: Env, id: string) {
  await getSchedule(env, id);
  await env.DB.prepare("UPDATE schedules SET deleted_at = ?, status = 'paused', next_run_at = NULL, updated_at = ? WHERE id = ?").bind(now(), now(), id).run();
  return { deleted: id };
}

/** Quiet hours changed: re-plan every active schedule against the new window. */
export async function replanAll(env: Env) {
  const quiet = await quietHours(env);
  const t = now();
  const rows = (await listSchedules(env)).filter((s) => s.status === "active");
  if (!rows.length) return;
  await env.DB.batch(rows.map((s) => env.DB.prepare("UPDATE schedules SET next_run_at = ?, updated_at = ? WHERE id = ?")
    .bind(computeNextRun(s, quiet, t), t, s.id)));
}

// ── Running ──────────────────────────────────────────────────────────────────
export function scheduleInstruction(s: ScheduleRow, manual: boolean): string {
  return `Scheduled task “${s.title}” is running now${manual ? " (started manually by the user)" : ""} — ${describeRule(s)}.
Carry out the user's instructions below and reply in this chat with the result, briefly. The normal rules apply: anything that needs approval waits for it, so say it is waiting rather than claiming it happened. If there is nothing worth reporting, say so in one short line.

Instructions from the user: ${s.instructions}`;
}

/** Queue one run of `s` in the main conversation. Idempotent per (schedule, slot). */
async function enqueue(env: Env, s: ScheduleRow, slot: string, manual: boolean): Promise<string | null> {
  await mainConversation(env);
  const id = newId("msg"), t = now();
  const meta = JSON.stringify({ kind: "schedule", schedule_id: s.id, title: s.title, manual });
  const res = await env.DB.batch([
    env.DB.prepare(`INSERT INTO messages (id, conversation_id, role, content, meta, client_msg_id, created_at) VALUES (?, ?, 'system', ?, ?, ?, ?)
      ON CONFLICT(client_msg_id) DO NOTHING`).bind(id, MAIN_CONVERSATION_ID, scheduleInstruction(s, manual), meta, `sched:${s.id}:${slot}`, t),
    env.DB.prepare("INSERT INTO chat_inbox (message_id, conversation_id, created_at) SELECT id, conversation_id, created_at FROM messages WHERE id = ?").bind(id),
  ]);
  return res[0].meta.changes ? id : null;
}

/** Start a run now from the app, without changing the schedule's next run. */
export async function runScheduleNow(env: Env, id: string): Promise<ScheduleRow> {
  const s = await getSchedule(env, id);
  const msg = await enqueue(env, s, `manual-${now()}`, true);
  await env.DB.prepare("UPDATE schedules SET last_run_at = ?, last_status = 'running', last_result = NULL, last_message_id = ?, run_count = run_count + 1, updated_at = ? WHERE id = ?")
    .bind(now(), msg, now(), id).run();
  return getSchedule(env, id);
}

/**
 * Cron tick: queue every due schedule, then advance it. Quiet hours defer a run to their end.
 * Returns how many runs were queued (the caller then drains the conversation inbox).
 */
export async function runDueSchedules(env: Env): Promise<{ queued: number; deferred: number }> {
  const t = now();
  const due = await env.DB.prepare("SELECT * FROM schedules WHERE status = 'active' AND deleted_at IS NULL AND next_run_at <= ? ORDER BY next_run_at LIMIT 5")
    .bind(t).all<ScheduleRow>();
  // A run whose Worker died never reports back; don't leave it "running" forever.
  await env.DB.prepare("UPDATE schedules SET last_status = 'failed', last_result = 'The run was interrupted before it finished.' WHERE last_status = 'running' AND last_run_at < ?")
    .bind(t - 30 * MIN).run();
  if (!due.results.length) return { queued: 0, deferred: 0 };
  const quiet = await quietHours(env);
  const q = parseQuiet(quiet);
  let queued = 0, deferred = 0;
  for (const s of due.results) {
    if (q && s.respect_quiet_hours && inQuiet(q, s.timezone, t)) {
      await env.DB.prepare("UPDATE schedules SET next_run_at = ?, last_status = 'deferred', updated_at = ? WHERE id = ?").bind(quietEnd(q, s.timezone, t), t, s.id).run();
      deferred++;
      continue;
    }
    const msg = await enqueue(env, s, String(s.next_run_at), false);
    const next = computeNextRun(s, quiet, t, s.next_run_at);
    await env.DB.prepare(`UPDATE schedules SET next_run_at = ?, status = ?, last_run_at = ?, last_status = 'running', last_result = NULL,
        last_message_id = COALESCE(?, last_message_id), run_count = run_count + 1, updated_at = ? WHERE id = ?`)
      .bind(next, next == null ? "done" : "active", t, msg, t, s.id).run();
    if (msg) queued++;
  }
  return { queued, deferred };
}

/** After the turn for a scheduled run finishes: record its outcome on the schedule. */
export function outcomeFor(reply: string, toolResults: string[]): { status: string; result: string } {
  const status = reply.startsWith("Sorry — I couldn't") ? "failed" : toolResults.some((r) => r.startsWith("NOT DONE YET")) ? "needs_approval" : "ok";
  return { status, result: truncate(reply.replace(/\s+/g, " ").trim(), 280) };
}

/** Compact form for tool results. */
export function scheduleForModel(s: ScheduleRow) {
  return {
    id: s.id, title: s.title, instructions: s.instructions, status: s.status, rule: describeRule(s), timezone: s.timezone,
    respects_quiet_hours: !!s.respect_quiet_hours,
    next_run: s.next_run_at ? new Intl.DateTimeFormat("en-US", { timeZone: s.timezone, weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short" }).format(s.next_run_at) : null,
    last_status: s.last_status, last_result: s.last_result,
  };
}
