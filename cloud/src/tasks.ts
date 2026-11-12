import type { Env } from "./env";
import { HttpError } from "./http";
import { logActivity } from "./db";
import { deviceMayRun, getAction, type Target } from "./policy";
import { notify } from "./notify";
import { canonicalJson, newId, now, parseJson, randomToken, sha256Hex, truncate } from "./util";
import { runCloudAction } from "./executors";
import { localTime } from "./localtime";
import { toPlainText } from "./plaintext";

export interface TaskRow {
  id: string;
  action: string;
  target: Target;
  status: string;
  summary: string;
  params: string;
  params_hash: string;
  result: string | null;
  error: string | null;
  idempotency_key: string;
  approval_id: string | null;
  conversation_id: string | null;
  responsibility_id: string | null;
  lease_device_id: string | null;
  lease_token: string | null;
  lease_expires_at: number | null;
  attempts: number;
  max_attempts: number;
  not_before: number;
  created_at: number;
  updated_at: number;
  completed_at: number | null;
}

export const LEASE_MS = 5 * 60_000;
const APPROVAL_TTL_MS = 7 * 24 * 3600_000;

export interface CreateTaskInput {
  action: string;
  params: Record<string, unknown>;
  idempotencyKey?: string;
  conversationId?: string | null;
  responsibilityId?: string | null;
  /** Set only when an authenticated device explicitly confirmed this exact action in the UI. */
  confirmedByDevice?: string | null;
}

export interface CreateTaskResult {
  task: TaskRow;
  created: boolean;
  needsApproval: boolean;
  approvalReason: string | null;
}

export async function createTask(env: Env, ctx: ExecutionContext | null, input: CreateTaskInput): Promise<CreateTaskResult> {
  const spec = getAction(input.action);
  const paramsJson = canonicalJson(input.params);
  const paramsHash = await sha256Hex(`${input.action}|${paramsJson}`);
  const key = input.idempotencyKey ?? `auto:${paramsHash}:${input.conversationId ?? ""}`;

  const existing = await env.DB.prepare("SELECT * FROM tasks WHERE idempotency_key = ?").bind(key).first<TaskRow>();
  if (existing) {
    return { task: existing, created: false, needsApproval: existing.status === "awaiting_approval", approvalReason: null };
  }

  const reason = spec.approval(input.params, { orbitCalendar: env.ORBIT_CALENDAR_NAME });
  const needsApproval = reason !== null && !input.confirmedByDevice;
  const id = newId("task");
  const t = now();
  // Approval cards and notifications show times in the user's zone, not raw ISO strings.
  const summary = truncate(
    spec.summarize(input.params).replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2})/g, (m) => localTime(env, m) ?? m),
    300,
  );
  const stmts: D1PreparedStatement[] = [];
  let approvalId: string | null = null;

  if (reason !== null) {
    approvalId = newId("apr");
    stmts.push(
      env.DB.prepare(
        `INSERT INTO approvals (id, task_id, action, summary, params_hash, status, decided_by_device, decided_at, expires_at, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        approvalId,
        id,
        input.action,
        `${reason}: ${summary}`,
        paramsHash,
        needsApproval ? "pending" : "approved",
        input.confirmedByDevice ?? null,
        needsApproval ? null : t,
        t + APPROVAL_TTL_MS,
        t,
      ),
    );
  }
  stmts.unshift(
    env.DB.prepare(
      `INSERT INTO tasks (id, action, target, status, summary, params, params_hash, idempotency_key, approval_id,
        conversation_id, responsibility_id, max_attempts, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(idempotency_key) DO NOTHING`,
    ).bind(
      id,
      input.action,
      spec.target,
      needsApproval ? "awaiting_approval" : "queued",
      summary,
      paramsJson,
      paramsHash,
      key,
      approvalId,
      input.conversationId ?? null,
      input.responsibilityId ?? null,
      spec.retrySafe ? 3 : 1,
      t,
      t,
    ),
  );
  const res = await env.DB.batch(stmts);
  if (!res[0].meta.changes) {
    // Lost a race with an identical request; return the winner. (The orphan approval insert is harmless:
    // task_id is unique and points to a task that does not exist, so it can never authorise anything.)
    const winner = await env.DB.prepare("SELECT * FROM tasks WHERE idempotency_key = ?").bind(key).first<TaskRow>();
    return { task: winner!, created: false, needsApproval: winner!.status === "awaiting_approval", approvalReason: null };
  }
  const task = (await env.DB.prepare("SELECT * FROM tasks WHERE id = ?").bind(id).first<TaskRow>())!;

  if (needsApproval) {
    await notify(env, {
      title: "Approval needed",
      body: `${reason}: ${summary}`,
      category: "approval",
      refType: "approval",
      refId: approvalId,
      dedupeKey: `approval:${approvalId}`,
    });
  } else if (spec.target === "cloud") {
    const run = runCloudTask(env, id);
    if (ctx) ctx.waitUntil(run);
    else await run;
  }
  return { task, created: true, needsApproval, approvalReason: reason };
}

/** Approve or deny. Only reachable from authenticated device/admin HTTP routes — never from model tools. */
export async function decideApproval(
  env: Env,
  ctx: ExecutionContext | null,
  approvalId: string,
  decision: "approve" | "deny",
  deviceId: string | null,
) {
  const appr = await env.DB.prepare("SELECT * FROM approvals WHERE id = ?").bind(approvalId).first<{
    id: string;
    task_id: string;
    status: string;
    expires_at: number;
  }>();
  if (!appr) throw new HttpError(404, "Approval not found", "not_found");
  if (appr.status !== "pending") throw new HttpError(409, `Approval is already ${appr.status}`, "conflict");
  if (appr.expires_at < now()) {
    await expireApproval(env, appr.id, appr.task_id);
    throw new HttpError(409, "Approval has expired", "expired");
  }
  const t = now();
  const newStatus = decision === "approve" ? "approved" : "denied";
  const upd = await env.DB.prepare(
    "UPDATE approvals SET status = ?, decided_by_device = ?, decided_at = ? WHERE id = ? AND status = 'pending'",
  )
    .bind(newStatus, deviceId, t, appr.id)
    .run();
  if (!upd.meta.changes) throw new HttpError(409, "Approval was decided concurrently", "conflict");
  await env.DB.batch([
    env.DB.prepare("UPDATE tasks SET status = ?, updated_at = ? WHERE id = ? AND status = 'awaiting_approval'").bind(
      decision === "approve" ? "queued" : "denied",
      t,
      appr.task_id,
    ),
  ]);
  const task = (await env.DB.prepare("SELECT * FROM tasks WHERE id = ?").bind(appr.task_id).first<TaskRow>())!;
  await logActivity(env, decision === "approve" ? "approval.approved" : "approval.denied", task.summary, { approval_id: appr.id }, task.id);
  if (decision === "approve" && task.target === "cloud") {
    const run = runCloudTask(env, task.id);
    if (ctx) ctx.waitUntil(run);
    else await run;
  }
  return task;
}

async function expireApproval(env: Env, approvalId: string, taskId: string) {
  await env.DB.batch([
    env.DB.prepare("UPDATE approvals SET status = 'expired' WHERE id = ? AND status = 'pending'").bind(approvalId),
    env.DB.prepare("UPDATE tasks SET status = 'cancelled', error = 'Approval expired', updated_at = ? WHERE id = ? AND status = 'awaiting_approval'").bind(now(), taskId),
  ]);
}

/**
 * Final gate before any side effect: the action must either need no approval for
 * these exact params, or carry an approved approval whose hash matches.
 */
export async function assertAuthorized(env: Env, task: TaskRow): Promise<void> {
  const spec = getAction(task.action);
  const params = parseJson<Record<string, unknown>>(task.params, {});
  const recomputed = await sha256Hex(`${task.action}|${canonicalJson(params)}`);
  if (recomputed !== task.params_hash) throw new Error("Task parameters do not match their hash");
  const reason = spec.approval(params, { orbitCalendar: env.ORBIT_CALENDAR_NAME });
  if (reason === null) return;
  if (!task.approval_id) throw new Error("Approval required but missing");
  const appr = await env.DB.prepare("SELECT status, params_hash, task_id FROM approvals WHERE id = ?")
    .bind(task.approval_id)
    .first<{ status: string; params_hash: string; task_id: string }>();
  if (!appr || appr.status !== "approved" || appr.params_hash !== task.params_hash || appr.task_id !== task.id) {
    throw new Error("Approval required but not granted for these parameters");
  }
}

/** Atomically lease and execute one queued cloud task. Safe to call concurrently: only one caller wins the lease. */
export async function runCloudTask(env: Env, taskId: string): Promise<void> {
  const leaseToken = randomToken(16);
  const t = now();
  const claim = await env.DB.prepare(
    `UPDATE tasks SET status = 'leased', lease_token = ?, lease_device_id = 'cloud', lease_expires_at = ?, attempts = attempts + 1, updated_at = ?
     WHERE id = ? AND status = 'queued' AND target = 'cloud' AND not_before <= ?`,
  )
    .bind(leaseToken, t + LEASE_MS, t, taskId, t)
    .run();
  if (!claim.meta.changes) return;
  const task = (await env.DB.prepare("SELECT * FROM tasks WHERE id = ?").bind(taskId).first<TaskRow>())!;
  try {
    await assertAuthorized(env, task);
    const result = await runCloudAction(env, task.action, parseJson(task.params, {}), task);
    await completeTask(env, task.id, leaseToken, { ok: true, result });
  } catch (e) {
    await completeTask(env, task.id, leaseToken, { ok: false, error: e instanceof Error ? e.message : String(e) });
  }
}

export async function completeTask(
  env: Env,
  taskId: string,
  leaseToken: string,
  outcome: { ok: true; result: unknown } | { ok: false; error: string; retryable?: boolean },
): Promise<TaskRow> {
  const task = await env.DB.prepare("SELECT * FROM tasks WHERE id = ?").bind(taskId).first<TaskRow>();
  if (!task) throw new HttpError(404, "Task not found", "not_found");
  // Completion is only accepted from the current lease holder; a stale holder after a handoff is rejected.
  if (task.status !== "leased" || task.lease_token !== leaseToken) {
    throw new HttpError(409, "Lease is not held (expired or handed off)", "lease_lost");
  }
  const t = now();
  if (outcome.ok) {
    await env.DB.batch([
      env.DB.prepare(
        "UPDATE tasks SET status = 'succeeded', result = ?, error = NULL, lease_token = NULL, completed_at = ?, updated_at = ? WHERE id = ? AND lease_token = ?",
      ).bind(truncate(JSON.stringify(outcome.result ?? null), 20000), t, t, taskId, leaseToken),
    ]);
    await logActivity(env, `task.succeeded`, task.summary, { action: task.action }, taskId);
    await postOutcomeToChat(env, task, { ok: true, result: outcome.result });
    await notify(env, {
      title: "Done",
      body: task.summary,
      category: "task_done",
      refType: "task",
      refId: taskId,
      dedupeKey: `task_done:${taskId}`,
    });
  } else {
    const canRetry = (outcome.retryable ?? true) && task.attempts < task.max_attempts;
    const backoff = Math.min(60 * 60_000, 2 ** task.attempts * 60_000);
    await env.DB.batch([
      env.DB.prepare(
        `UPDATE tasks SET status = ?, error = ?, lease_token = NULL, lease_device_id = NULL, lease_expires_at = NULL,
         not_before = ?, completed_at = ?, updated_at = ? WHERE id = ? AND lease_token = ?`,
      ).bind(canRetry ? "queued" : "failed", truncate(outcome.error, 2000), canRetry ? t + backoff : 0, canRetry ? null : t, t, taskId, leaseToken),
    ]);
    if (!canRetry) {
      await logActivity(env, "task.failed", task.summary, { action: task.action, error: outcome.error }, taskId);
      await postOutcomeToChat(env, task, { ok: false, error: outcome.error });
      await notify(env, {
        title: "Task failed",
        body: `${task.summary} — ${truncate(outcome.error, 200)}`,
        category: "task_failed",
        refType: "task",
        refId: taskId,
        dedupeKey: `task_failed:${taskId}`,
      });
    }
  }
  return (await env.DB.prepare("SELECT * FROM tasks WHERE id = ?").bind(taskId).first<TaskRow>())!;
}

/** Device pulls work it can execute. Each task is leased to exactly one device at a time. */
export async function claimDeviceTasks(
  env: Env,
  device: { id: string; kind: string; capabilities: string[] },
  limit = 5,
): Promise<(TaskRow & { lease_token: string })[]> {
  const t = now();
  const candidates = await env.DB.prepare(
    `SELECT * FROM tasks WHERE status = 'queued' AND target != 'cloud' AND not_before <= ? ORDER BY created_at LIMIT 20`,
  )
    .bind(t)
    .all<TaskRow>();
  const out: (TaskRow & { lease_token: string })[] = [];
  for (const task of candidates.results) {
    if (out.length >= limit) break;
    if (!deviceMayRun(task.target, device.kind, device.id, parseJson(task.params, {}))) continue;
    // Device must advertise the capability (e.g. "calendar.create_event") to receive the task.
    if (!device.capabilities.includes(task.action)) continue;
    try {
      await assertAuthorized(env, task);
    } catch (e) {
      // Never hand an unauthorised task to a device; fail it visibly instead.
      await env.DB.prepare("UPDATE tasks SET status = 'failed', error = ?, completed_at = ?, updated_at = ? WHERE id = ? AND status = 'queued'")
        .bind(`Policy re-check failed: ${e instanceof Error ? e.message : e}`, t, t, task.id)
        .run();
      continue;
    }
    const token = randomToken(16);
    const r = await env.DB.prepare(
      `UPDATE tasks SET status = 'leased', lease_device_id = ?, lease_token = ?, lease_expires_at = ?, attempts = attempts + 1, updated_at = ?
       WHERE id = ? AND status = 'queued'`,
    )
      .bind(device.id, token, t + LEASE_MS, t, task.id)
      .run();
    if (!r.meta.changes) continue; // another device got it first
    out.push({ ...task, status: "leased", lease_token: token, lease_device_id: device.id, attempts: task.attempts + 1 });
  }
  return out;
}

export async function extendLease(env: Env, taskId: string, deviceId: string, leaseToken: string) {
  const r = await env.DB.prepare(
    "UPDATE tasks SET lease_expires_at = ?, updated_at = ? WHERE id = ? AND status = 'leased' AND lease_device_id = ? AND lease_token = ?",
  )
    .bind(now() + LEASE_MS, now(), taskId, deviceId, leaseToken)
    .run();
  if (!r.meta.changes) throw new HttpError(409, "Lease is not held", "lease_lost");
}

/** Housekeeping: recover expired leases and expire stale approvals. Called by the heartbeat and on device polls. */
export async function recoverExpired(env: Env): Promise<{ requeued: number; failed: number; expiredApprovals: number }> {
  const t = now();
  const expired = await env.DB.prepare(
    "SELECT * FROM tasks WHERE status = 'leased' AND lease_expires_at < ? LIMIT 50",
  )
    .bind(t)
    .all<TaskRow>();
  let requeued = 0,
    failed = 0;
  for (const task of expired.results) {
    const spec = getAction(task.action);
    const retry = spec.retrySafe && task.attempts < task.max_attempts;
    const r = await env.DB.prepare(
      `UPDATE tasks SET status = ?, lease_token = NULL, lease_device_id = NULL, lease_expires_at = NULL, error = ?, updated_at = ?,
       completed_at = ? WHERE id = ? AND status = 'leased' AND lease_token = ?`,
    )
      .bind(
        retry ? "queued" : "failed",
        retry ? "Lease expired; re-queued" : "Lease expired; outcome unknown (not retried to avoid duplicate side effects)",
        t,
        retry ? null : t,
        task.id,
        task.lease_token,
      )
      .run();
    if (!r.meta.changes) continue;
    if (retry) requeued++;
    else {
      failed++;
      await notify(env, {
        title: "Check this task",
        body: `${task.summary} — the device stopped responding; it may or may not have completed.`,
        category: "task_failed",
        refType: "task",
        refId: task.id,
        dedupeKey: `task_failed:${task.id}`,
      });
    }
  }
  const stale = await env.DB.prepare("SELECT id, task_id FROM approvals WHERE status = 'pending' AND expires_at < ? LIMIT 50")
    .bind(t)
    .all<{ id: string; task_id: string }>();
  for (const a of stale.results) await expireApproval(env, a.id, a.task_id);
  return { requeued, failed, expiredApprovals: stale.results.length };
}

export async function runQueuedCloudTasks(env: Env, limit = 10): Promise<number> {
  const rows = await env.DB.prepare(
    "SELECT id FROM tasks WHERE status = 'queued' AND target = 'cloud' AND not_before <= ? ORDER BY created_at LIMIT ?",
  )
    .bind(now(), limit)
    .all<{ id: string }>();
  for (const r of rows.results) await runCloudTask(env, r.id);
  return rows.results.length;
}

export async function cancelTask(env: Env, taskId: string) {
  const r = await env.DB.prepare(
    "UPDATE tasks SET status = 'cancelled', updated_at = ? WHERE id = ? AND status IN ('queued','awaiting_approval')",
  )
    .bind(now(), taskId)
    .run();
  if (!r.meta.changes) throw new HttpError(409, "Only queued or awaiting tasks can be cancelled", "conflict");
  await env.DB.batch([
    env.DB.prepare("UPDATE approvals SET status = 'denied', decided_at = ? WHERE task_id = ? AND status = 'pending'").bind(now(), taskId),
  ]);
}

/** Device actions whose results start a follow-up model turn instead (see routes.ts). */
export const FOLLOW_UP_ACTIONS = ["mac.search_files", "mac.read_file", "mac.run_script"];

/** One plain sentence describing what a finished device task did, in the user's time zone. */
export function outcomeText(env: Env, task: Pick<TaskRow, "action" | "params" | "summary">, deviceName: string, outcome: { ok: true } | { ok: false; error: string }): string {
  const p = parseJson<Record<string, unknown>>(task.params, {});
  const c = (p.changes ?? {}) as Record<string, unknown>;
  const q = (v: unknown) => `\u201c${typeof v === "string" ? v : ""}\u201d`;
  const when = (v: unknown) => localTime(env, typeof v === "string" ? v : null);
  const on = deviceName ? ` on ${deviceName}` : "";
  if (!outcome.ok) return toPlainText(`I couldn\u2019t finish this${on}: ${task.summary}. ${truncate(outcome.error, 300)}`);
  const changed = () =>
    [c.title ? `renamed it ${q(c.title)}` : "", c.start ? `moved it to ${when(c.start)}` : "", c.due ? `set it due ${when(c.due)}` : "", c.end && !c.start ? `set it to end ${when(c.end)}` : "", c.location ? `set the location to ${c.location}` : "", c.notes ? "updated the notes" : ""]
      .filter(Boolean)
      .join(", ") || "saved your changes";
  switch (task.action) {
    case "calendar.create_event":
      return `Added ${q(p.title)} to your ${typeof p.calendar === "string" && p.calendar ? p.calendar : "Orbit"} calendar for ${when(p.start) ?? p.start}${on}.`;
    case "calendar.update_event":
      return `Updated ${q(p.title)}${on}: ${changed()}.`;
    case "calendar.delete_event":
      return `Deleted the event ${q(p.title)}${on}.`;
    case "reminders.create":
      return `Added the reminder ${q(p.title)}${p.due ? `, due ${when(p.due)}` : ""}${on}.`;
    case "reminders.update":
      return `Updated the reminder ${q(p.title)}${on}: ${changed()}.`;
    case "reminders.complete":
      return `Marked ${q(p.title)} complete${on}.`;
    case "reminders.delete":
      return `Deleted the reminder ${q(p.title)}${on}.`;
    default:
      return toPlainText(`Done${on}: ${task.summary}.`);
  }
}

/** Device results land in the conversation that asked for them, so every synced device sees the outcome. */
async function postOutcomeToChat(env: Env, task: TaskRow, outcome: { ok: true; result: unknown } | { ok: false; error: string }) {
  if (!task.conversation_id || task.target === "cloud" || FOLLOW_UP_ACTIONS.includes(task.action)) return;
  const dev = task.lease_device_id
    ? await env.DB.prepare("SELECT name, kind FROM devices WHERE id = ?").bind(task.lease_device_id).first<{ name: string; kind: string }>()
    : null;
  const deviceName = dev ? (dev.kind === "mac" ? "your Mac" : dev.kind === "iphone" ? "your iPhone" : dev.name) : "";
  const text = outcomeText(env, task, deviceName, outcome);
  const t = now();
  await env.DB.batch([
    env.DB.prepare("INSERT INTO messages (id, conversation_id, role, content, meta, created_at) VALUES (?, ?, 'assistant', ?, ?, ?)").bind(
      newId("msg"),
      task.conversation_id,
      text,
      // Posted by the device itself: no AI model call was involved.
      JSON.stringify({ kind: "task_result", task_id: task.id, ok: outcome.ok, device_id: task.lease_device_id,
        usage: { calls: 0, models: [], breakdown: {}, finished_at: t } }),
      t,
    ),
    env.DB.prepare("UPDATE conversations SET updated_at = ? WHERE id = ?").bind(t, task.conversation_id),
  ]);
}
