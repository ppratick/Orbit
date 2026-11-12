/**
 * Permission policy, enforced in code — never by the model.
 *
 * Every side-effecting capability is an "action". The model can only *request*
 * actions through tools; this module decides whether an action runs right away
 * or waits for an explicit approval from an authenticated device. The approval is
 * bound to a hash of the exact parameters, and executors re-check it before running.
 */
export type Target = "cloud" | "mac" | "iphone" | "apple";

export interface ActionContext {
  /** Name of the dedicated calendar Orbit may write to without asking. */
  orbitCalendar: string;
}

export interface ActionSpec {
  target: Target;
  /** Why approval is needed, or null if the action is auto-allowed for these params. */
  approval: (p: Record<string, unknown>, ctx: ActionContext) => string | null;
  /** Can the executor safely run it again after an unknown outcome? */
  retrySafe: boolean;
  summarize: (p: Record<string, unknown>) => string;
}

const always = (reason: string) => () => reason;
const never = () => null;
const s = (v: unknown) => (typeof v === "string" ? v : v == null ? "" : JSON.stringify(v));

export const ACTIONS: Record<string, ActionSpec> = {
  // ── Email ───────────────────────────────────────────────────────────────
  "email.create_draft": {
    target: "cloud",
    approval: never,
    retrySafe: false,
    summarize: (p) => `Draft email to ${s(p.to)}: "${s(p.subject)}"`,
  },
  "email.send": {
    target: "cloud",
    approval: always("Sending a message"),
    retrySafe: false,
    summarize: (p) => `Send email to ${s(p.to)}: "${s(p.subject)}"`,
  },
  "email.send_draft": {
    target: "cloud",
    approval: always("Sending a message"),
    retrySafe: false,
    summarize: (p) => `Send draft ${s(p.draft_id)} (${s(p.subject) || "no subject"})`,
  },
  // ── Apple Calendar / Reminders (EventKit on a Mac or iPhone) ────────────
  "calendar.create_event": {
    target: "apple",
    approval: (p, ctx) =>
      !p.calendar || p.calendar === ctx.orbitCalendar ? null : `Adding an event to "${s(p.calendar)}" instead of the dedicated ${ctx.orbitCalendar} calendar`,
    retrySafe: true, // device de-duplicates by task id stored in the event
    summarize: (p) => `Add "${s(p.title)}" at ${s(p.start)} to ${s(p.calendar) || "Orbit"} calendar`,
  },
  "calendar.update_event": {
    target: "apple",
    approval: always("Changing an existing event"),
    retrySafe: true,
    summarize: (p) => `Change event ${s(p.event_id)}: ${s(p.changes)}`,
  },
  "calendar.delete_event": {
    target: "apple",
    approval: always("Deleting an event"),
    retrySafe: true,
    summarize: (p) => `Delete event ${s(p.event_id)}`,
  },
  "reminders.create": {
    target: "apple",
    approval: never,
    retrySafe: true,
    summarize: (p) => `Create reminder "${s(p.title)}"${p.due ? ` due ${s(p.due)}` : ""}`,
  },
  "reminders.complete": {
    target: "apple",
    approval: always("Changing an existing reminder"),
    retrySafe: true,
    summarize: (p) => `Mark reminder ${s(p.reminder_id)} complete`,
  },
  // ── Messaging / code / coursework ────────────────────────────────────────
  "github.comment": {
    target: "cloud",
    approval: always("Posting on GitHub"),
    retrySafe: false,
    summarize: (p) => `Comment on ${s(p.repo)}#${s(p.number)}`,
  },
  "github.create_issue": {
    target: "cloud",
    approval: always("Posting on GitHub"),
    retrySafe: false,
    summarize: (p) => `Open issue in ${s(p.repo)}: "${s(p.title)}"`,
  },
  "github.merge_pr": {
    target: "cloud",
    approval: always("Merging code"),
    retrySafe: false,
    summarize: (p) => `Merge ${s(p.repo)}#${s(p.number)}`,
  },
  "canvas.submit": {
    target: "cloud",
    approval: always("Submitting coursework"),
    retrySafe: false,
    summarize: (p) => `Submit to Canvas course ${s(p.course_id)} assignment ${s(p.assignment_id)}`,
  },
  // ── Memory ────────────────────────────────────────────────────────────────
  "memory.delete": {
    target: "cloud",
    approval: always("Deleting saved memory"),
    retrySafe: true,
    summarize: (p) => `Forget memory ${s(p.memory_id)}`,
  },
  // ── Mac companion ─────────────────────────────────────────────────────────
  "mac.search_files": {
    target: "mac",
    approval: never,
    retrySafe: true,
    summarize: (p) => `Search Mac files for "${s(p.query)}"`,
  },
  "mac.read_file": {
    target: "mac",
    approval: never,
    retrySafe: true,
    summarize: (p) => `Read ${s(p.path)} on Mac`,
  },
  "mac.write_file": {
    target: "mac",
    // New files inside the Orbit workspace are fine; anything that may overwrite needs approval.
    approval: (p) => (p.overwrite ? "Overwriting a file" : null),
    retrySafe: true,
    summarize: (p) => `${p.overwrite ? "Overwrite" : "Create"} ${s(p.path)} on Mac`,
  },
  "mac.run_script": {
    target: "mac",
    // Scripts the user placed in the Mac's allow-listed scripts folder run freely.
    approval: (p) => (p.script && !p.command ? null : "Running an arbitrary command"),
    retrySafe: false,
    summarize: (p) => (p.script ? `Run Mac script "${s(p.script)}"` : `Run on Mac: ${s(p.command).slice(0, 80)}`),
  },
  "mac.open_url": {
    target: "mac",
    approval: never,
    retrySafe: true,
    summarize: (p) => `Open ${s(p.url)} on Mac`,
  },
  "shortcuts.run": {
    target: "apple",
    approval: always("Running a Shortcut can change data or send messages"),
    retrySafe: false,
    summarize: (p) => `Run Shortcut "${s(p.name)}"`,
  },
};

export function getAction(name: string): ActionSpec {
  const a = ACTIONS[name];
  if (!a) throw new Error(`Unknown action: ${name}`);
  return a;
}

/** Device kinds that may execute an action target. */
export function targetMatchesDevice(target: Target, kind: string): boolean {
  if (target === "apple") return kind === "mac" || kind === "iphone";
  return target === kind;
}
