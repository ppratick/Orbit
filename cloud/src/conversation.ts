import type { Env } from "./env";
import { now } from "./util";

// Stable across devices, reinstalls and concurrent first launches.
export const MAIN_CONVERSATION_ID = "conv_orbit_primary";
export async function mainConversation(env: Env) {
  await env.DB.prepare("INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, 'Orbit', ?, ?) ON CONFLICT(id) DO NOTHING")
    .bind(MAIN_CONVERSATION_ID, now(), now()).run();
  return env.DB.prepare("SELECT * FROM conversations WHERE id = ?").bind(MAIN_CONVERSATION_ID).first();
}
