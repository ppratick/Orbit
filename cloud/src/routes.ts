import type { Env } from "./env";
import { HttpError, json, readJson, Router, str } from "./http";
import { authenticate, createPairingCode, redeemPairingCode, registerDevice, type Principal } from "./auth";
import { runTurn } from "./agent/agent";
import { addMemory, deleteMemory, exportMarkdown, listMemories, listResponsibilities, searchConversations, updateMemory, updateResponsibility, upsertResponsibility } from "./memory";
import { cancelTask, claimDeviceTasks, completeTask, createTask, decideApproval, extendLease, recoverExpired, type TaskRow } from "./tasks";
import { ACTIONS } from "./policy";
import { sync } from "./sync";
import { heartbeat, PHASES, type Phase } from "./heartbeat";
import { listAccounts, publicAccount, upsertAccount } from "./accounts";
import { googleAuthUrl } from "./connectors/google";
import { authMode, chatgptAuthUrl, chatgptComplete } from "./agent/llmauth";
import { icloudMail } from "./connectors/icloud";
import { github } from "./connectors/github";
import { slackApi } from "./connectors/slack";
import { canvasApi } from "./connectors/canvas";
import { untrusted } from "./untrusted";
import { newId, now, parseJson, truncate } from "./util";

export interface Ctx {
  env: Env;
  exec: ExecutionContext;
  principal: Principal;
}

const deviceId = (c: Ctx) => (c.principal.type === "device" ? c.principal.device.id : null);
const requireDevice = (c: Ctx) => {
  if (c.principal.type !== "device") throw new HttpError(403, "Device token required", "forbidden");
  return c.principal.device;
};
const requireAdmin = (c: Ctx) => {
  if (c.principal.type !== "admin") throw new HttpError(403, "Admin token required", "forbidden");
};
const num = (v: string | null, d: number) => (v && !Number.isNaN(Number(v)) ? Number(v) : d);
const isoOrNull = (v: unknown, name: string) => {
  if (v === undefined) return undefined;
  if (v === null || v === "") return null;
  const t = typeof v === "number" ? v : Date.parse(String(v));
  if (Number.isNaN(t)) throw new HttpError(400, `${name} must be an ISO date`, "validation");
  return t;
};

export const router = new Router<Ctx>();

// ── Devices & pairing ─────────────────────────────────────────────────────────
router.on("GET", "/v1/me", async (_r, _p, c) => json({ principal: c.principal.type === "admin" ? { type: "admin" } : { type: "device", ...c.principal.device } }));
router.on("POST", "/v1/devices/register", async (r, _p, c) => {
  requireAdmin(c); // first device is registered with the admin token; later ones via pairing codes
  const b = await readJson<{ name: string; kind: "mac" | "iphone" | "cli"; capabilities?: string[] }>(r);
  return json(await registerDevice(c.env, str(b.name, "name", { max: 80 }), b.kind, b.capabilities ?? []), 201);
});
router.on("POST", "/v1/pairing-codes", async (_r, _p, c) => json(await createPairingCode(c.env), 201));
router.on("GET", "/v1/devices", async (_r, _p, c) => {
  const d = await c.env.DB.prepare("SELECT id, name, kind, capabilities, last_seen_at, created_at, revoked_at, push_token IS NOT NULL AS has_push FROM devices ORDER BY created_at").all();
  return json({ devices: d.results.map((x) => ({ ...x, capabilities: parseJson(x.capabilities as string, []) })) });
});
router.on("PUT", "/v1/devices/me", async (r, _p, c) => {
  const dev = requireDevice(c);
  const b = await readJson<{ name?: string; capabilities?: string[]; push_token?: string | null; push_env?: string }>(r);
  const caps = b.capabilities?.filter((x) => typeof x === "string" && (ACTIONS[x] || x.startsWith("script:"))).slice(0, 60);
  await c.env.DB.prepare(
    "UPDATE devices SET name = COALESCE(?, name), capabilities = COALESCE(?, capabilities), push_token = CASE WHEN ? THEN ? ELSE push_token END, push_env = COALESCE(?, push_env) WHERE id = ?",
  )
    .bind(b.name ?? null, caps ? JSON.stringify(caps) : null, b.push_token !== undefined ? 1 : 0, b.push_token ?? null, b.push_env ?? null, dev.id)
    .run();
  return json({ ok: true, capabilities: caps ?? dev.capabilities });
});
router.on("DELETE", "/v1/devices/:id", async (_r, p, c) => {
  await c.env.DB.prepare("UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL").bind(now(), p.id).run();
  return json({ ok: true });
});

// ── Conversations ────────────────────────────────────────────────────────────
router.on("GET", "/v1/conversations", async (r, _p, c) => {
  const archived = new URL(r.url).searchParams.get("archived") === "1" ? 1 : 0;
  const rows = await c.env.DB.prepare("SELECT * FROM conversations WHERE archived = ? ORDER BY updated_at DESC LIMIT 200").bind(archived).all();
  return json({ conversations: rows.results });
});
router.on("POST", "/v1/conversations", async (r, _p, c) => {
  const b = await readJson<{ id?: string; title?: string }>(r).catch(() => ({}) as { id?: string; title?: string });
  // Clients may generate the id (offline-first); creation is idempotent on it.
  const id = b.id && /^conv_[\w-]{8,40}$/.test(b.id) ? b.id : newId("conv");
  await c.env.DB.prepare("INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO NOTHING")
    .bind(id, truncate(b.title || "New conversation", 120), now(), now())
    .run();
  return json(await c.env.DB.prepare("SELECT * FROM conversations WHERE id = ?").bind(id).first(), 201);
});
router.on("PATCH", "/v1/conversations/:id", async (r, p, c) => {
  const b = await readJson<{ title?: string; archived?: boolean }>(r);
  await c.env.DB.prepare("UPDATE conversations SET title = COALESCE(?, title), archived = COALESCE(?, archived), updated_at = ? WHERE id = ?")
    .bind(b.title ? truncate(b.title, 120) : null, b.archived === undefined ? null : b.archived ? 1 : 0, now(), p.id)
    .run();
  return json(await c.env.DB.prepare("SELECT * FROM conversations WHERE id = ?").bind(p.id).first());
});
router.on("DELETE", "/v1/conversations/:id", async (_r, p, c) => {
  // Direct user action from an authenticated device (not reachable by the model).
  await c.env.DB.batch([c.env.DB.prepare("DELETE FROM messages WHERE conversation_id = ?").bind(p.id), c.env.DB.prepare("DELETE FROM conversations WHERE id = ?").bind(p.id)]);
  return json({ ok: true });
});
router.on("GET", "/v1/conversations/:id/messages", async (r, p, c) => {
  const u = new URL(r.url);
  const before = num(u.searchParams.get("before"), 9e15);
  const rows = await c.env.DB.prepare(
    "SELECT * FROM (SELECT rowid AS rid, * FROM messages WHERE conversation_id = ? AND created_at < ? ORDER BY created_at DESC, rowid DESC LIMIT ?) ORDER BY created_at, rid",
  )
    .bind(p.id, before, Math.min(num(u.searchParams.get("limit"), 100), 500))
    .all<Record<string, unknown>>();
  return json({ messages: rows.results.map(({ rid: _r, ...m }) => ({ ...m, meta: parseJson(m.meta as string, null) })) });
});
router.on("POST", "/v1/conversations/:id/messages", async (r, p, c) => {
  const b = await readJson<{ content: string; client_msg_id?: string }>(r);
  const content = str(b.content, "content", { max: 20000 });
  const res = await runTurn(c.env, p.id, content, b.client_msg_id ? String(b.client_msg_id).slice(0, 80) : null, deviceId(c));
  return json(res, res.replayed ? 200 : 201);
});
router.on("GET", "/v1/search", async (r, _p, c) => {
  const q = new URL(r.url).searchParams.get("q") ?? "";
  return json({ results: await searchConversations(c.env, q, 30) });
});

// ── Memory ───────────────────────────────────────────────────────────────────
router.on("GET", "/v1/memories", async (r, _p, c) => json({ memories: await listMemories(c.env, new URL(r.url).searchParams.get("q") ?? undefined, 500) }));
router.on("POST", "/v1/memories", async (r, _p, c) => {
  const b = await readJson<{ kind: string; content: string; source?: string }>(r);
  return json({ id: await addMemory(c.env, b.kind, str(b.content, "content", { max: 2000 }), "user", deviceId(c)) }, 201);
});
router.on("PATCH", "/v1/memories/:id", async (r, p, c) => {
  const b = await readJson<{ kind?: string; content?: string }>(r);
  await updateMemory(c.env, p.id, b);
  return json({ ok: true });
});
router.on("DELETE", "/v1/memories/:id", async (_r, p, c) => {
  await deleteMemory(c.env, p.id);
  return json({ ok: true });
});

// ── Responsibilities ─────────────────────────────────────────────────────────
router.on("GET", "/v1/responsibilities", async (r, _p, c) => json({ responsibilities: await listResponsibilities(c.env, new URL(r.url).searchParams.get("all") === "1") }));
router.on("POST", "/v1/responsibilities", async (r, _p, c) => {
  const b = await readJson<Record<string, unknown>>(r);
  const res = await upsertResponsibility(c.env, {
    title: str(b.title, "title", { max: 300 }),
    kind: b.kind as string,
    notes: (b.notes as string) ?? "",
    due_at: isoOrNull(b.due_at, "due_at") ?? null,
    next_check_at: isoOrNull(b.next_check_at, "next_check_at") ?? null,
    check_interval_min: b.check_interval_min ? Number(b.check_interval_min) : null,
    source: "user",
  });
  return json(res, 201);
});
router.on("PATCH", "/v1/responsibilities/:id", async (r, p, c) => {
  const b = await readJson<Record<string, unknown>>(r);
  await updateResponsibility(c.env, p.id, {
    title: b.title as string | undefined,
    status: b.status as string | undefined,
    notes: b.notes as string | undefined,
    due_at: isoOrNull(b.due_at, "due_at"),
    next_check_at: isoOrNull(b.next_check_at, "next_check_at"),
  });
  return json({ ok: true });
});

// ── Approvals & tasks ────────────────────────────────────────────────────────
router.on("GET", "/v1/approvals", async (r, _p, c) => {
  const status = new URL(r.url).searchParams.get("status") ?? "pending";
  const rows = await c.env.DB.prepare(
    "SELECT a.id, a.task_id, a.action, a.summary, a.status, a.created_at, a.expires_at, a.decided_at, t.params FROM approvals a JOIN tasks t ON t.id = a.task_id WHERE a.status = ? ORDER BY a.created_at DESC LIMIT 100",
  )
    .bind(status)
    .all<Record<string, unknown>>();
  // Params are shown so the user approves exactly what will run.
  return json({ approvals: rows.results.map((a) => ({ ...a, params: parseJson(a.params as string, {}) })) });
});
router.on("POST", "/v1/approvals/:id/:decision", async (_r, p, c) => {
  if (p.decision !== "approve" && p.decision !== "deny") throw new HttpError(404, "Not found");
  const task = await decideApproval(c.env, c.exec, p.id, p.decision, deviceId(c) ?? "admin");
  return json({ task: publicTask(task) });
});
router.on("GET", "/v1/tasks", async (r, _p, c) => {
  const u = new URL(r.url);
  const status = u.searchParams.get("status");
  const rows = status
    ? await c.env.DB.prepare("SELECT * FROM tasks WHERE status = ? ORDER BY updated_at DESC LIMIT 100").bind(status).all<TaskRow>()
    : await c.env.DB.prepare("SELECT * FROM tasks ORDER BY updated_at DESC LIMIT 100").all<TaskRow>();
  return json({ tasks: rows.results.map(publicTask) });
});
router.on("GET", "/v1/tasks/:id", async (_r, p, c) => {
  const t = await c.env.DB.prepare("SELECT * FROM tasks WHERE id = ?").bind(p.id).first<TaskRow>();
  if (!t) throw new HttpError(404, "Task not found", "not_found");
  return json(publicTask(t));
});
router.on("POST", "/v1/tasks", async (r, _p, c) => {
  // User-initiated action from the app UI (e.g. tapping "Send" on a draft). `confirm: true` records the
  // user's explicit consent for these exact params; otherwise it goes through the normal approval flow.
  const b = await readJson<{ action: string; params: Record<string, unknown>; idempotency_key?: string; confirm?: boolean }>(r);
  if (!ACTIONS[b.action]) throw new HttpError(400, "Unknown action", "validation");
  const dev = c.principal.type === "device" ? c.principal.device.id : null;
  const res = await createTask(c.env, c.exec, {
    action: b.action,
    params: b.params ?? {},
    idempotencyKey: b.idempotency_key ? `client:${b.idempotency_key}` : undefined,
    confirmedByDevice: b.confirm ? (dev ?? "admin") : null,
  });
  return json({ task: publicTask(res.task), created: res.created, needs_approval: res.needsApproval }, res.created ? 201 : 200);
});
router.on("POST", "/v1/tasks/:id/cancel", async (_r, p, c) => {
  await cancelTask(c.env, p.id);
  return json({ ok: true });
});

// Device execution protocol (Mac companion / iPhone).
router.on("POST", "/v1/device/tasks/claim", async (r, _p, c) => {
  const dev = requireDevice(c);
  const b = await readJson<{ limit?: number }>(r).catch(() => ({}) as { limit?: number });
  await recoverExpired(c.env);
  const tasks = await claimDeviceTasks(c.env, dev, Math.min(b.limit ?? 5, 10));
  return json({ tasks: tasks.map((t) => ({ ...publicTask(t), lease_token: t.lease_token })) });
});
router.on("POST", "/v1/device/tasks/:id/extend", async (r, p, c) => {
  const dev = requireDevice(c);
  const b = await readJson<{ lease_token: string }>(r);
  await extendLease(c.env, p.id, dev.id, str(b.lease_token, "lease_token"));
  return json({ ok: true });
});
router.on("POST", "/v1/device/tasks/:id/complete", async (r, p, c) => {
  const dev = requireDevice(c);
  const b = await readJson<{ lease_token: string; ok: boolean; result?: unknown; error?: string; retryable?: boolean }>(r);
  const cur = await c.env.DB.prepare("SELECT lease_device_id FROM tasks WHERE id = ?").bind(p.id).first<{ lease_device_id: string }>();
  if (cur && cur.lease_device_id !== dev.id) throw new HttpError(409, "Task is leased by another device", "lease_lost");
  const task = await completeTask(
    c.env,
    p.id,
    str(b.lease_token, "lease_token"),
    b.ok ? { ok: true, result: b.result ?? null } : { ok: false, error: str(b.error, "error", { optional: true }) || "Device reported failure", retryable: b.retryable },
  );
  // Results of read-type device work go back into the conversation so Orbit can continue.
  if (b.ok && task.conversation_id && ["mac.search_files", "mac.read_file", "mac.run_script"].includes(task.action)) {
    const followUp = runTurn(
      c.env,
      task.conversation_id,
      `Device task ${task.id} (${task.summary}) finished. Result:\n${untrusted(`device:${dev.name}`, truncate(JSON.stringify(b.result ?? null), 12000))}\nContinue helping the user with this result.`,
      `task-result:${task.id}`,
      dev.id,
      "system",
    ).catch(() => undefined);
    c.exec.waitUntil(followUp);
  }
  return json({ task: publicTask(task) });
});
router.on("PUT", "/v1/device/context", async (r, _p, c) => {
  const dev = requireDevice(c);
  const b = await readJson<{ kind: "calendar" | "reminders"; items: unknown[] }>(r);
  if (b.kind !== "calendar" && b.kind !== "reminders") throw new HttpError(400, "kind must be calendar or reminders", "validation");
  const payload = JSON.stringify((b.items ?? []).slice(0, 300));
  if (payload.length > 200_000) throw new HttpError(413, "Snapshot too large", "too_large");
  await c.env.DB.prepare(
    "INSERT INTO device_context (device_id, kind, payload, captured_at) VALUES (?, ?, ?, ?) ON CONFLICT(device_id, kind) DO UPDATE SET payload = excluded.payload, captured_at = excluded.captured_at",
  )
    .bind(dev.id, b.kind, payload, now())
    .run();
  return json({ ok: true });
});

// ── Activity, notifications, sync, export ────────────────────────────────────
router.on("GET", "/v1/activity", async (_r, _p, c) => {
  const rows = await c.env.DB.prepare("SELECT * FROM activity ORDER BY created_at DESC LIMIT 200").all<Record<string, unknown>>();
  return json({ activity: rows.results.map((a) => ({ ...a, data: parseJson(a.data as string, {}) })) });
});
router.on("GET", "/v1/notifications", async (_r, _p, c) => {
  const rows = await c.env.DB.prepare("SELECT * FROM notifications ORDER BY created_at DESC LIMIT 200").all();
  return json({ notifications: rows.results });
});
router.on("POST", "/v1/notifications/:id/read", async (_r, p, c) => {
  await c.env.DB.prepare("UPDATE notifications SET read_at = ? WHERE id = ? AND read_at IS NULL").bind(now(), p.id).run();
  return json({ ok: true });
});
router.on("GET", "/v1/sync", async (r, _p, c) => json(await sync(c.env, num(new URL(r.url).searchParams.get("since"), 0))));
router.on("GET", "/v1/export.md", async (r, _p, c) => {
  const md = await exportMarkdown(c.env, { conversations: new URL(r.url).searchParams.get("conversations") !== "0" });
  return new Response(md, { headers: { "content-type": "text/markdown; charset=utf-8", "content-disposition": `attachment; filename="orbit-export-${new Date().toISOString().slice(0, 10)}.md"` } });
});
router.on("POST", "/v1/heartbeat/run", async (r, _p, c) => {
  const b = await readJson<{ phase?: Phase }>(r).catch(() => ({}) as { phase?: Phase });
  const phase = PHASES.includes(b.phase as Phase) ? (b.phase as Phase) : "email";
  return json(await heartbeat(c.env, phase));
});
router.on("GET", "/v1/heartbeat/runs", async (_r, _p, c) => {
  const rows = await c.env.DB.prepare("SELECT * FROM heartbeat_runs ORDER BY started_at DESC LIMIT 30").all<Record<string, unknown>>();
  return json({ runs: rows.results.map((x) => ({ ...x, summary: parseJson(x.summary as string, null) })) });
});

// ── Accounts (credentials are accepted here, encrypted, and never returned) ──
router.on("GET", "/v1/accounts", async (_r, _p, c) => json({ accounts: (await listAccounts(c.env)).map(publicAccount) }));
router.on("POST", "/v1/accounts/google/link", async (r, _p, c) => {
  const b = await readJson<{ label?: string }>(r).catch(() => ({}) as { label?: string });
  return json({ url: await googleAuthUrl(c.env, truncate(b.label ?? "", 80)) });
});
// ChatGPT sign-in: the device opens `url` (ASWebAuthenticationSession) and posts back the redirect it captured.
router.on("POST", "/v1/accounts/chatgpt/link", async (_r, _p, c) => json({ ...(await chatgptAuthUrl(c.env)), auth_mode: authMode(c.env) }));
router.on("POST", "/v1/accounts/chatgpt/complete", async (r, _p, c) => {
  const b = await readJson<{ callback_url?: string; code?: string; state?: string }>(r);
  return json(await chatgptComplete(c.env, b), 201);
});
router.on("GET", "/v1/model", async (_r, _p, c) => {
  const linked = (await listAccounts(c.env, "chatgpt")).map(publicAccount);
  return json({ model: c.env.OPENAI_MODEL, auth_mode: authMode(c.env), chatgpt_accounts: linked, api_key_configured: !!c.env.OPENAI_API_KEY });
});
router.on("POST", "/v1/accounts/icloud", async (r, _p, c) => {
  const b = await readJson<{ username: string; app_password: string; label?: string }>(r);
  const username = str(b.username, "username", { max: 200 });
  const pw = str(b.app_password, "app_password", { max: 100 }).replace(/\s+/g, "");
  await icloudMail.verify(username, pw).catch((e) => {
    throw new HttpError(400, `iCloud login failed: ${e instanceof Error ? e.message : e}`, "auth_failed");
  });
  const id = await upsertAccount(c.env, { provider: "icloud_mail", label: b.label || username, identity: username, secret: { username, app_password: pw } });
  return json({ id }, 201);
});
async function tokenAccount(c: Ctx, provider: string, r: Request, verify: (acct: { secret_ct: string } & Record<string, unknown>) => Promise<string>, config: Record<string, unknown> = {}) {
  const b = await readJson<{ token: string; label?: string; base_url?: string }>(r);
  const token = str(b.token, "token", { max: 500 }).trim();
  const { encryptSecret } = await import("./crypto");
  const temp = { id: "tmp", provider, label: "", identity: null, scopes: null, secret_ct: await encryptSecret(c.env, { token }), config: JSON.stringify(config), status: "active", last_error: null, sync_state: "{}", last_sync_at: null };
  let identity: string;
  try {
    identity = await verify(temp);
  } catch (e) {
    throw new HttpError(400, `Could not verify ${provider} token: ${e instanceof Error ? e.message : e}`, "auth_failed");
  }
  const id = await upsertAccount(c.env, { provider, label: b.label || identity, identity, secret: { token }, config });
  return json({ id, identity }, 201);
}
router.on("POST", "/v1/accounts/github", async (r, _p, c) => tokenAccount(c, "github", r, async (a) => (await github.verify(c.env, a as never)).login));
router.on("POST", "/v1/accounts/slack", async (r, _p, c) => tokenAccount(c, "slack", r, async (a) => {
  const v = await slackApi.verify(c.env, a as never);
  return `${v.user}@${v.team}`;
}));
router.on("POST", "/v1/accounts/canvas", async (r, _p, c) => {
  const b = (await r.clone().json().catch(() => ({}))) as { base_url?: string };
  const base = str(b.base_url, "base_url", { max: 200 });
  if (!/^https:\/\/[\w.-]+(\/.*)?$/.test(base)) throw new HttpError(400, "base_url must be https://your-school.instructure.com", "validation");
  return tokenAccount(c, "canvas", r, async (a) => `${(await canvasApi.verify(c.env, a as never)).name}@${new URL(base).hostname}`, { base_url: base });
});
router.on("DELETE", "/v1/accounts/:id", async (_r, p, c) => {
  await c.env.DB.prepare("UPDATE accounts SET status = 'disabled', secret_ct = '', updated_at = ? WHERE id = ?").bind(now(), p.id).run();
  return json({ ok: true });
});

export function publicTask(t: TaskRow) {
  const { lease_token: _l, params_hash: _h, ...rest } = t;
  return { ...rest, params: parseJson(t.params, {}), result: parseJson(t.result, t.result) };
}

export async function handleAuthed(req: Request, env: Env, exec: ExecutionContext, pathname: string): Promise<Response> {
  const m = router.match(req.method, pathname);
  if (!m) throw new HttpError(404, "Not found", "not_found");
  const principal = await authenticate(env, req);
  return m.h(req, m.params, { env, exec, principal });
}

export async function redeem(req: Request, env: Env): Promise<Response> {
  const b = await readJson<{ code: string; name: string; kind: "mac" | "iphone" | "cli"; capabilities?: string[] }>(req);
  return json(await redeemPairingCode(env, str(b.code, "code", { max: 20 }), str(b.name, "name", { max: 80 }), b.kind, b.capabilities ?? []), 201);
}
