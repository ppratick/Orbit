import type { Env } from "../env";
import type { ToolDef } from "./llm";
import { createTask } from "../tasks";
import { addMemory, listMemories, listResponsibilities, searchConversations, updateResponsibility, upsertResponsibility } from "../memory";
import { firstAccount, mailAccount, MAIL_PROVIDERS } from "../connectors";
import { listAccounts } from "../accounts";
import { drive } from "../connectors/google";
import { github } from "../connectors/github";
import { canvasApi } from "../connectors/canvas";
import { readWebPage } from "../connectors/browser";
import { untrusted } from "../untrusted";
import { parseJson, truncate } from "../util";
import { localTime } from "../localtime";

export interface ToolCtx {
  env: Env;
  conversationId: string;
  callId: string;
  providers: Set<string>;
  deviceKinds: Set<string>;
}

type Args = Record<string, unknown>;
interface Tool {
  name: string;
  description: string;
  properties: Record<string, unknown>;
  required?: string[];
  /** Tool is offered only if this returns true (keeps prompts small and honest about what is connected). */
  available?: (t: ToolCtx) => boolean;
  run: (t: ToolCtx, a: Args) => Promise<string>;
}

const S = (description: string) => ({ type: "string", description });
const N = (description: string) => ({ type: "number", description });
const B = (description: string) => ({ type: "boolean", description });
const str = (a: Args, k: string) => (typeof a[k] === "string" ? (a[k] as string).trim() : "");
const has = (p: string) => (t: ToolCtx) => t.providers.has(p);
const hasMail = (t: ToolCtx) => [...t.providers].some((p) => MAIL_PROVIDERS[p]);
const hasDevice = (...kinds: string[]) => (t: ToolCtx) => kinds.some((k) => t.deviceKinds.has(k));
const out = (v: unknown) => truncate(JSON.stringify(v, null, 1), 14000);

export { localTime };

function parseTime(v: string, field: string): number | null {
  if (!v) return null;
  const t = Date.parse(v);
  if (Number.isNaN(t)) throw new Error(`${field} must be an ISO-8601 date-time with a UTC offset`);
  return t;
}

interface Snapshot {
  device_id: string;
  device_name: string;
  kind: string;
  captured_at: number;
  items: Record<string, unknown>[];
}

/** Latest calendar/reminders snapshot from each active device, newest first. */
export async function deviceSnapshots(env: Env, kind?: string): Promise<Snapshot[]> {
  const r = await env.DB.prepare(
    `SELECT c.device_id, d.name AS device_name, c.kind, c.payload, c.captured_at FROM device_context c
     JOIN devices d ON d.id = c.device_id WHERE d.revoked_at IS NULL ${kind ? "AND c.kind = ?" : ""} ORDER BY c.captured_at DESC`,
  )
    .bind(...(kind ? [kind] : []))
    .all<{ device_id: string; device_name: string; kind: string; payload: string; captured_at: number }>();
  return r.results.map((x) => ({ ...x, items: parseJson<Record<string, unknown>[]>(x.payload, []) }));
}

/** Find which device reported an EventKit id (ids are device-local), so the edit is routed to that device. */
export async function locateItem(env: Env, kind: "calendar" | "reminders", id: string): Promise<{ id: string; device_id: string; title: string } | null> {
  if (!id) return null;
  for (const snap of await deviceSnapshots(env, kind)) {
    const hit = snap.items.find((i) => i.id === id);
    if (hit) return { id, device_id: snap.device_id, title: typeof hit.title === "string" ? hit.title : "" };
  }
  return null;
}

const unknownId = (what: string) =>
  `That ${what} id isn't in the latest synced snapshot. Call apple_calendar_and_reminders again and use an id from there (new items appear once the device that created them syncs).`;

/** Route a side-effecting action through the policy engine. The model never decides approval. */
async function act(t: ToolCtx, action: string, params: Args): Promise<string> {
  const clean: Args = {};
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== "" && v !== null) clean[k] = v;
  const r = await createTask(t.env, null, {
    action,
    params: clean,
    idempotencyKey: `call:${t.conversationId}:${t.callId}`,
    conversationId: t.conversationId,
  });
  const task = (await t.env.DB.prepare("SELECT status, result, error, target FROM tasks WHERE id = ?").bind(r.task.id).first<{
    status: string;
    result: string | null;
    error: string | null;
    target: string;
  }>())!;
  switch (task.status) {
    case "awaiting_approval":
      return `NOT DONE YET — approval requested from the user (task ${r.task.id}, reason: ${r.approvalReason ?? "requires approval"}). Tell the user it is waiting in Approvals; once approved, the result is posted in this chat. Do not claim it happened.`;
    case "succeeded":
      return `Done (task ${r.task.id}). Result: ${truncate(task.result ?? "", 2000)}`;
    case "failed":
      return `Failed (task ${r.task.id}): ${task.error}`;
    case "queued":
    case "leased":
      return task.target === "cloud"
        ? `Queued (task ${r.task.id}); it will retry shortly. Last error: ${task.error ?? "none"}`
        : `Queued for ${typeof params.device_id === "string" ? "the device that has this item" : task.target === "apple" ? "your Mac or iPhone" : `your ${task.target}`} (task ${r.task.id}). It runs when that device is online and the result is posted in this chat automatically, so just say it's on its way. Do not claim it is done.`;
    default:
      return `Task ${r.task.id} is ${task.status}.`;
  }
}

const TOOLS: Tool[] = [
  // ── Memory & responsibilities ───────────────────────────────────────────
  {
    name: "remember",
    description: "Save a durable preference or fact about the user (only things they said or clearly confirmed). Not for secrets.",
    properties: { kind: { type: "string", enum: ["preference", "fact"] }, content: S("One self-contained sentence.") },
    required: ["kind", "content"],
    run: async (t, a) => `Saved memory ${await addMemory(t.env, str(a, "kind"), str(a, "content"), "conversation", t.conversationId)}`,
  },
  {
    name: "search_memory",
    description: "Search saved preferences and facts.",
    properties: { query: S("Keywords; empty lists everything.") },
    run: async (t, a) => out((await listMemories(t.env, str(a, "query"), 40)).map((m) => ({ id: m.id, kind: m.kind, content: m.content, source: m.source, updated: new Date(m.updated_at).toISOString() }))),
  },
  {
    name: "forget_memory",
    description: "Delete a saved memory. Requires the user's approval.",
    properties: { memory_id: S("Memory id") },
    required: ["memory_id"],
    run: (t, a) => act(t, "memory.delete", { memory_id: str(a, "memory_id") }),
  },
  {
    name: "list_responsibilities",
    description: "List ongoing responsibilities Orbit is tracking (deadlines, follow-ups, deliveries, returns, refunds, renewals, research).",
    properties: { include_closed: B("Include done/cancelled items") },
    run: async (t, a) =>
      out((await listResponsibilities(t.env, !!a.include_closed)).map((r) => ({ id: r.id, title: r.title, kind: r.kind, status: r.status, due_at: r.due_at && new Date(r.due_at).toISOString(), next_check_at: r.next_check_at && new Date(r.next_check_at).toISOString(), notes: truncate(r.notes, 400) }))),
  },
  {
    name: "track_responsibility",
    description: "Start tracking something ongoing. The heartbeat re-checks it at next_check_at and notifies the user when it is due.",
    properties: {
      title: S("Short title"),
      kind: { type: "string", enum: ["deadline", "followup", "delivery", "return", "refund", "renewal", "research", "custom"] },
      due_at: S("ISO-8601 with offset, optional"),
      next_check_at: S("ISO-8601 with offset, optional"),
      check_every_hours: N("Re-check interval in hours, optional"),
      notes: S("Details: order numbers, who to follow up with, what 'done' means"),
    },
    required: ["title", "kind"],
    run: async (t, a) => {
      const r = await upsertResponsibility(t.env, {
        title: str(a, "title"),
        kind: str(a, "kind"),
        notes: str(a, "notes"),
        due_at: parseTime(str(a, "due_at"), "due_at"),
        next_check_at: parseTime(str(a, "next_check_at"), "next_check_at"),
        check_interval_min: a.check_every_hours ? Math.round(Number(a.check_every_hours) * 60) : null,
        source: "conversation",
        source_ref: t.conversationId,
      });
      return `Tracking as ${r.id}`;
    },
  },
  {
    name: "update_responsibility",
    description: "Update status/notes/dates of a tracked responsibility (e.g. mark a delivery done).",
    properties: { id: S("Responsibility id"), status: { type: "string", enum: ["active", "waiting", "done", "cancelled"] }, notes: S("Replacement notes"), due_at: S("ISO-8601"), next_check_at: S("ISO-8601") },
    required: ["id"],
    run: async (t, a) => {
      await updateResponsibility(t.env, str(a, "id"), {
        status: str(a, "status") || undefined,
        notes: str(a, "notes") || undefined,
        due_at: str(a, "due_at") ? parseTime(str(a, "due_at"), "due_at") : undefined,
        next_check_at: str(a, "next_check_at") ? parseTime(str(a, "next_check_at"), "next_check_at") : undefined,
      });
      return "Updated";
    },
  },
  {
    name: "search_conversations",
    description: "Full-text search across all past conversations.",
    properties: { query: S("Keywords") },
    required: ["query"],
    run: async (t, a) => out(await searchConversations(t.env, str(a, "query"), 15)),
  },
  {
    name: "task_status",
    description: "Check the status/result of a task Orbit queued earlier.",
    properties: { task_id: S("Task id") },
    required: ["task_id"],
    run: async (t, a) => {
      const r = await t.env.DB.prepare("SELECT id, summary, status, target, result, error, updated_at FROM tasks WHERE id = ?").bind(str(a, "task_id")).first();
      return r ? untrusted("task-result", out(r)) : "No such task";
    },
  },
  // ── Email ─────────────────────────────────────────────────────────────────
  {
    name: "list_accounts",
    description: "List connected accounts (email, Google Drive, GitHub, Canvas) with ids and status.",
    properties: {},
    run: async (t) => out((await listAccounts(t.env)).map((a) => ({ id: a.id, provider: a.provider, label: a.label, identity: a.identity, status: a.status, error: a.last_error }))),
  },
  {
    name: "search_email",
    description: "Search an email account. Gmail accounts accept Gmail search syntax; iCloud matches subject/sender. Omit account_id for the first mail account.",
    properties: { query: S("Search query"), account_id: S("Account id, optional"), max: N("Max results (≤25)") },
    required: ["query"],
    available: hasMail,
    run: async (t, a) => {
      const { acct, mail } = await mailAccount(t.env, str(a, "account_id") || null);
      const r = await mail.search(t.env, acct, str(a, "query"), Number(a.max) || 10);
      return untrusted(`email-search:${acct.identity}`, out(r.map((m) => ({ ...m, date_local: localTime(t.env, m.date) }))));
    },
  },
  {
    name: "read_email",
    description: "Read one email in full.",
    properties: { id: S("Message id from search_email"), account_id: S("Account id, optional") },
    required: ["id"],
    available: hasMail,
    run: async (t, a) => {
      const { acct, mail } = await mailAccount(t.env, str(a, "account_id") || null);
      const m = await mail.read(t.env, acct, str(a, "id"));
      return untrusted(`email:${acct.identity}`, out({ ...m, date_local: localTime(t.env, m.date), body: truncate(m.body, 10000) }));
    },
  },
  {
    name: "draft_email",
    description: "Create a draft in the user's mailbox (not sent). Use in_reply_to to reply in-thread.",
    properties: { to: S("Recipients, comma-separated"), cc: S("Optional"), subject: S("Subject"), body: S("Plain-text body"), in_reply_to: S("Message id being replied to, optional"), account_id: S("Account id, optional") },
    required: ["to", "subject", "body"],
    available: hasMail,
    run: (t, a) => act(t, "email.create_draft", { to: str(a, "to"), cc: str(a, "cc"), subject: str(a, "subject"), body: str(a, "body"), in_reply_to: str(a, "in_reply_to"), account_id: str(a, "account_id") }),
  },
  {
    name: "send_email",
    description: "Send an email. Always requires the user's approval; prefer draft_email unless the user asked to send.",
    properties: { to: S("Recipients"), cc: S("Optional"), subject: S("Subject"), body: S("Body"), in_reply_to: S("Optional"), account_id: S("Optional") },
    required: ["to", "subject", "body"],
    available: has("google"),
    run: (t, a) => act(t, "email.send", { to: str(a, "to"), cc: str(a, "cc"), subject: str(a, "subject"), body: str(a, "body"), in_reply_to: str(a, "in_reply_to"), account_id: str(a, "account_id") }),
  },
  {
    name: "send_draft",
    description: "Send an existing Gmail draft. Requires approval.",
    properties: { draft_id: S("Draft id"), subject: S("Draft subject (for the approval summary)"), account_id: S("Optional") },
    required: ["draft_id"],
    available: has("google"),
    run: (t, a) => act(t, "email.send_draft", { draft_id: str(a, "draft_id"), subject: str(a, "subject"), account_id: str(a, "account_id") }),
  },
  // ── Apple Calendar & Reminders (via Mac/iPhone EventKit) ─────────────────
  {
    name: "apple_calendar_and_reminders",
    description:
      "Read Apple Calendar events (next 14 days) and incomplete Reminders, as last synced by each of the user's devices. Use the ids from here for updates; they belong to the device that reported them.",
    properties: {},
    available: hasDevice("mac", "iphone"),
    run: async (t) => {
      const snaps = await deviceSnapshots(t.env);
      if (!snaps.length) return "No calendar/reminder snapshot has been synced yet; open Orbit on the Mac or iPhone and grant Calendar/Reminders access.";
      return untrusted(
        "apple-pim",
        out(
          snaps.map((p) => ({
            device: p.device_name,
            kind: p.kind,
            synced_local: localTime(t.env, p.captured_at),
            items: p.items.map((i) => ({ ...i, start_local: localTime(t.env, i.start as string), due_local: localTime(t.env, i.due as string) })),
          })),
        ),
      );
    },
  },
  {
    name: "add_calendar_event",
    description: "Add an appointment or deadline to Apple Calendar. Goes to the dedicated Orbit calendar automatically; any other calendar needs approval.",
    properties: { title: S("Title"), start: S("ISO-8601 with offset"), end: S("ISO-8601 with offset (optional; default 1h)"), all_day: B("All-day event"), location: S("Optional"), notes: S("Optional"), calendar: S("Leave empty for the Orbit calendar") },
    required: ["title", "start"],
    available: hasDevice("mac", "iphone"),
    run: (t, a) => {
      parseTime(str(a, "start"), "start");
      if (str(a, "end")) parseTime(str(a, "end"), "end");
      return act(t, "calendar.create_event", { title: str(a, "title"), start: str(a, "start"), end: str(a, "end"), all_day: a.all_day ? true : undefined, location: str(a, "location"), notes: str(a, "notes"), calendar: str(a, "calendar") });
    },
  },
  {
    name: "update_calendar_event",
    description: "Change or move an existing calendar event (requires approval). Only pass the fields that change.",
    properties: { event_id: S("Event id from apple_calendar_and_reminders"), title: S("New title"), start: S("ISO-8601"), end: S("ISO-8601"), location: S(""), notes: S("") },
    required: ["event_id"],
    available: hasDevice("mac", "iphone"),
    run: async (t, a) => {
      for (const k of ["start", "end"]) parseTime(str(a, k), k);
      const item = await locateItem(t.env, "calendar", str(a, "event_id"));
      if (!item) return unknownId("event");
      const changes = { title: str(a, "title") || undefined, start: str(a, "start") || undefined, end: str(a, "end") || undefined, location: str(a, "location") || undefined, notes: str(a, "notes") || undefined };
      return act(t, "calendar.update_event", { event_id: item.id, device_id: item.device_id, title: item.title, changes });
    },
  },
  {
    name: "delete_calendar_event",
    description: "Delete an existing calendar event (requires approval).",
    properties: { event_id: S("Event id from apple_calendar_and_reminders") },
    required: ["event_id"],
    available: hasDevice("mac", "iphone"),
    run: async (t, a) => {
      const item = await locateItem(t.env, "calendar", str(a, "event_id"));
      if (!item) return unknownId("event");
      return act(t, "calendar.delete_event", { event_id: item.id, device_id: item.device_id, title: item.title });
    },
  },
  {
    name: "create_reminder",
    description: "Create an Apple Reminder.",
    properties: { title: S("Title"), due: S("ISO-8601 with offset, optional"), notes: S("Optional"), list: S("Reminders list name, optional") },
    required: ["title"],
    available: hasDevice("mac", "iphone"),
    run: (t, a) => {
      parseTime(str(a, "due"), "due");
      return act(t, "reminders.create", { title: str(a, "title"), due: str(a, "due"), notes: str(a, "notes"), list: str(a, "list") });
    },
  },
  {
    name: "update_reminder",
    description: "Change an existing reminder's title, due date or notes (requires approval). Only pass the fields that change.",
    properties: { reminder_id: S("Reminder id from apple_calendar_and_reminders"), title: S("New title"), due: S("ISO-8601 with offset"), notes: S("") },
    required: ["reminder_id"],
    available: hasDevice("mac", "iphone"),
    run: async (t, a) => {
      parseTime(str(a, "due"), "due");
      const item = await locateItem(t.env, "reminders", str(a, "reminder_id"));
      if (!item) return unknownId("reminder");
      const changes = { title: str(a, "title") || undefined, due: str(a, "due") || undefined, notes: str(a, "notes") || undefined };
      return act(t, "reminders.update", { reminder_id: item.id, device_id: item.device_id, title: item.title, changes });
    },
  },
  {
    name: "complete_reminder",
    description: "Mark an existing reminder as done (requires approval).",
    properties: { reminder_id: S("Reminder id from apple_calendar_and_reminders") },
    required: ["reminder_id"],
    available: hasDevice("mac", "iphone"),
    run: async (t, a) => {
      const item = await locateItem(t.env, "reminders", str(a, "reminder_id"));
      if (!item) return unknownId("reminder");
      return act(t, "reminders.complete", { reminder_id: item.id, device_id: item.device_id, title: item.title });
    },
  },
  {
    name: "delete_reminder",
    description: "Delete an existing reminder (requires approval).",
    properties: { reminder_id: S("Reminder id from apple_calendar_and_reminders") },
    required: ["reminder_id"],
    available: hasDevice("mac", "iphone"),
    run: async (t, a) => {
      const item = await locateItem(t.env, "reminders", str(a, "reminder_id"));
      if (!item) return unknownId("reminder");
      return act(t, "reminders.delete", { reminder_id: item.id, device_id: item.device_id, title: item.title });
    },
  },
  {
    name: "run_shortcut",
    description: "Run an Apple Shortcut by name on the Mac/iPhone (requires approval).",
    properties: { name: S("Shortcut name"), input: S("Optional text input") },
    required: ["name"],
    available: hasDevice("mac", "iphone"),
    run: (t, a) => act(t, "shortcuts.run", { name: str(a, "name"), input: str(a, "input") }),
  },
  // ── Google Drive ─────────────────────────────────────────────────────────
  {
    name: "drive_search",
    description: "Search Google Drive (including shared drives) by text, ranked by relevance. Use an empty query to list the most recently modified files.",
    properties: { query: S("Text to find; empty for most recently modified"), account_id: S("Optional") },
    required: [],
    available: has("google"),
    run: async (t, a) => {
      const acct = await firstAccount(t.env, "google", str(a, "account_id") || null);
      const files = await drive.search(t.env, acct, str(a, "query"));
      return untrusted("drive-search", out(files.map((f) => ({ ...f, modified_local: localTime(t.env, f.modifiedTime) }))));
    },
  },
  {
    name: "drive_read",
    description: "Read the text of a Google Drive file (Docs, Sheets as CSV, Slides, text files).",
    properties: { file_id: S("File id"), account_id: S("Optional") },
    required: ["file_id"],
    available: has("google"),
    run: async (t, a) => {
      const acct = await firstAccount(t.env, "google", str(a, "account_id") || null);
      const f = await drive.read(t.env, acct, str(a, "file_id"));
      return untrusted(`drive:${f.name}`, f.text);
    },
  },
  // ── GitHub ───────────────────────────────────────────────────────────────
  {
    name: "github_notifications",
    description: "Recent GitHub activity: unread notifications, or (if the token can't read notifications) open issues and PRs that involve the user or request their review.",
    properties: {},
    available: has("github"),
    run: async (t) => untrusted("github", out(await github.activity(t.env, await firstAccount(t.env, "github")))),
  },
  {
    name: "github_search",
    description: "Search GitHub issues and pull requests (GitHub search syntax, e.g. 'is:pull-request is:open review-requested:@me'). Searches both kinds when the query names neither.",
    properties: { query: S("Query") },
    required: ["query"],
    available: has("github"),
    run: async (t, a) => untrusted("github", out(await github.searchIssues(t.env, await firstAccount(t.env, "github"), str(a, "query")))),
  },
  {
    name: "github_read_issue",
    description: "Read an issue or PR with comments.",
    properties: { repo: S("owner/name"), number: N("Number") },
    required: ["repo", "number"],
    available: has("github"),
    run: async (t, a) => untrusted("github", out(await github.readIssue(t.env, await firstAccount(t.env, "github"), str(a, "repo"), Number(a.number)))),
  },
  {
    name: "github_read_file",
    description: "Read a file from a repository.",
    properties: { repo: S("owner/name"), path: S("Path"), ref: S("Branch/sha, optional") },
    required: ["repo", "path"],
    available: has("github"),
    run: async (t, a) => untrusted("github", truncate(await github.readFile(t.env, await firstAccount(t.env, "github"), str(a, "repo"), str(a, "path"), str(a, "ref") || undefined), 12000)),
  },
  {
    name: "github_comment",
    description: "Comment on an issue/PR (requires approval).",
    properties: { repo: S("owner/name"), number: N("Number"), body: S("Markdown") },
    required: ["repo", "number", "body"],
    available: has("github"),
    run: (t, a) => act(t, "github.comment", { repo: str(a, "repo"), number: Number(a.number), body: str(a, "body") }),
  },
  {
    name: "github_create_issue",
    description: "Open an issue (requires approval).",
    properties: { repo: S("owner/name"), title: S("Title"), body: S("Markdown") },
    required: ["repo", "title"],
    available: has("github"),
    run: (t, a) => act(t, "github.create_issue", { repo: str(a, "repo"), title: str(a, "title"), body: str(a, "body") }),
  },
  {
    name: "github_merge_pr",
    description: "Merge a pull request (requires approval).",
    properties: { repo: S("owner/name"), number: N("PR number"), method: { type: "string", enum: ["merge", "squash", "rebase"] } },
    required: ["repo", "number"],
    available: has("github"),
    run: (t, a) => act(t, "github.merge_pr", { repo: str(a, "repo"), number: Number(a.number), method: str(a, "method") || "squash" }),
  },
  // ── Canvas ───────────────────────────────────────────────────────────────
  {
    name: "canvas_upcoming",
    description: "Upcoming Canvas assignments and to-dos with due dates.",
    properties: {},
    available: has("canvas"),
    run: async (t) => untrusted("canvas", out((await canvasApi.upcoming(t.env, await firstAccount(t.env, "canvas"))).map((x) => ({ ...x, due_local: localTime(t.env, x.due_at) })))),
  },
  {
    name: "canvas_courses",
    description: "List active Canvas courses.",
    properties: {},
    available: has("canvas"),
    run: async (t) => untrusted("canvas", out(await canvasApi.courses(t.env, await firstAccount(t.env, "canvas")))),
  },
  {
    name: "canvas_assignments",
    description: "List future assignments in a course with descriptions.",
    properties: { course_id: N("Course id") },
    required: ["course_id"],
    available: has("canvas"),
    run: async (t, a) => untrusted("canvas", out((await canvasApi.assignments(t.env, await firstAccount(t.env, "canvas"), Number(a.course_id))).map((x) => ({ ...x, due_local: localTime(t.env, x.due_at) })))),
  },
  {
    name: "canvas_submit",
    description: "Submit coursework (text or URL). Always requires approval.",
    properties: { course_id: N("Course id"), assignment_id: N("Assignment id"), submission_type: { type: "string", enum: ["online_text_entry", "online_url"] }, body: S("HTML/text body"), url: S("URL") },
    required: ["course_id", "assignment_id", "submission_type"],
    available: has("canvas"),
    run: (t, a) => act(t, "canvas.submit", { course_id: Number(a.course_id), assignment_id: Number(a.assignment_id), submission_type: str(a, "submission_type"), body: str(a, "body"), url: str(a, "url") }),
  },
  // ── Web research ─────────────────────────────────────────────────────────
  {
    name: "read_web_page",
    description: "Fetch a public web page as text. Set render=true only for JavaScript-heavy pages (uses the limited headless-browser quota).",
    properties: { url: S("http(s) URL"), render: B("Use headless Chrome (Browser Run)") },
    required: ["url"],
    run: async (t, a) => {
      const r = await readWebPage(t.env, str(a, "url"), !!a.render);
      return untrusted(`web:${new URL(r.url).hostname}`, r.text);
    },
  },
  // ── Mac companion ────────────────────────────────────────────────────────
  {
    name: "mac_search_files",
    description: "Search files on the user's Mac (Spotlight). Result arrives asynchronously.",
    properties: { query: S("Spotlight query"), folder: S("Optional folder") },
    required: ["query"],
    available: hasDevice("mac"),
    run: (t, a) => act(t, "mac.search_files", { query: str(a, "query"), folder: str(a, "folder") }),
  },
  {
    name: "mac_read_file",
    description: "Read a text file (or extract text from PDF/DOCX) on the Mac. Result arrives asynchronously.",
    properties: { path: S("Absolute path or ~/…") },
    required: ["path"],
    available: hasDevice("mac"),
    run: (t, a) => act(t, "mac.read_file", { path: str(a, "path") }),
  },
  {
    name: "mac_write_file",
    description: "Create a file on the Mac (in ~/Orbit by default). Overwriting an existing file requires approval.",
    properties: { path: S("Path"), content: S("Text content"), overwrite: B("Replace if it exists") },
    required: ["path", "content"],
    available: hasDevice("mac"),
    run: (t, a) => act(t, "mac.write_file", { path: str(a, "path"), content: String(a.content ?? ""), overwrite: a.overwrite ? true : undefined }),
  },
  {
    name: "mac_run_script",
    description: "Run a script from the Mac's allow-listed ~/Orbit/Scripts folder (by file name), or an arbitrary shell command (requires approval).",
    properties: { script: S("Script file name in ~/Orbit/Scripts"), args: { type: "array", items: { type: "string" } }, command: S("Arbitrary zsh command (approval required)") },
    available: hasDevice("mac"),
    run: (t, a) => act(t, "mac.run_script", { script: str(a, "script"), args: Array.isArray(a.args) ? a.args.map(String) : undefined, command: str(a, "command") }),
  },
  {
    name: "mac_open_url",
    description: "Open a URL in the Mac's default browser (for the user to continue, e.g. a checkout or form).",
    properties: { url: S("URL") },
    required: ["url"],
    available: hasDevice("mac"),
    run: (t, a) => act(t, "mac.open_url", { url: str(a, "url") }),
  },
];

export function toolsFor(t: ToolCtx): { defs: ToolDef[]; byName: Map<string, Tool> } {
  const list = TOOLS.filter((x) => !x.available || x.available(t));
  return {
    defs: list.map((x) => ({ type: "function", name: x.name, description: x.description, parameters: { type: "object", properties: x.properties, required: x.required ?? [], additionalProperties: false } })),
    byName: new Map(list.map((x) => [x.name, x])),
  };
}

export const ALL_TOOL_NAMES = TOOLS.map((t) => t.name);
