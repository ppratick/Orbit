import type { Env } from "./env";
import { newId, now } from "./util";

export type Entity =
  | "conversation"
  | "message"
  | "task"
  | "approval"
  | "memory"
  | "schedule"
  | "profile"
  | "profile_suggestion"
  | "responsibility"
  | "notification"
  | "activity"
  | "account"
  | "device";

export async function logActivity(
  env: Env,
  type: string,
  summary: string,
  data: Record<string, unknown> = {},
  taskId: string | null = null,
): Promise<string> {
  const id = newId("act");
  await env.DB.batch([
    env.DB.prepare("INSERT INTO activity (id, type, summary, data, task_id, created_at) VALUES (?, ?, ?, ?, ?, ?)").bind(
      id,
      type,
      summary,
      JSON.stringify(data),
      taskId,
      now(),
    ),
  ]);
  return id;
}

export async function getSetting(env: Env, key: string): Promise<string | null> {
  const r = await env.DB.prepare("SELECT value FROM settings WHERE key = ?").bind(key).first<{ value: string }>();
  return r?.value ?? null;
}

export async function setSetting(env: Env, key: string, value: string) {
  await env.DB.prepare("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
    .bind(key, value)
    .run();
}
