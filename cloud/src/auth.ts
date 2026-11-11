import type { Env } from "./env";
import { HttpError } from "./http";
import { newId, now, randomToken, sha256Hex, timingSafeEqual } from "./util";

export interface Device {
  id: string;
  name: string;
  kind: "mac" | "iphone" | "cli";
  capabilities: string[];
}

export type Principal = { type: "admin" } | { type: "device"; device: Device };

function bearer(req: Request): string | null {
  const h = req.headers.get("authorization") ?? "";
  return h.startsWith("Bearer ") ? h.slice(7).trim() : null;
}

export async function authenticate(env: Env, req: Request): Promise<Principal> {
  const token = bearer(req);
  if (!token) throw new HttpError(401, "Missing bearer token", "unauthorized");
  if (env.ADMIN_TOKEN && timingSafeEqual(token, env.ADMIN_TOKEN)) return { type: "admin" };
  const hash = await sha256Hex(token);
  const row = await env.DB.prepare(
    "SELECT id, name, kind, capabilities, last_seen_at FROM devices WHERE token_hash = ? AND revoked_at IS NULL",
  )
    .bind(hash)
    .first<{ id: string; name: string; kind: Device["kind"]; capabilities: string; last_seen_at: number | null }>();
  if (!row) throw new HttpError(401, "Invalid or revoked token", "unauthorized");
  // Throttle last_seen writes to save D1 row writes (free tier quota).
  if (!row.last_seen_at || now() - row.last_seen_at > 60_000) {
    await env.DB.prepare("UPDATE devices SET last_seen_at = ? WHERE id = ?").bind(now(), row.id).run();
  }
  return {
    type: "device",
    device: { id: row.id, name: row.name, kind: row.kind, capabilities: JSON.parse(row.capabilities) },
  };
}

/** Pairing: an already-trusted principal mints a short-lived one-time code; a new device redeems it for a token. */
export async function createPairingCode(env: Env): Promise<{ code: string; expires_at: number }> {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  const code = [...bytes].map((b) => alphabet[b % alphabet.length]).join("");
  const expires_at = now() + 10 * 60_000;
  await env.DB.prepare("INSERT INTO pairing_codes (code_hash, expires_at, created_at) VALUES (?, ?, ?)")
    .bind(await sha256Hex(code), expires_at, now())
    .run();
  return { code, expires_at };
}

export async function redeemPairingCode(
  env: Env,
  code: string,
  name: string,
  kind: Device["kind"],
  capabilities: string[],
): Promise<{ device_id: string; token: string }> {
  const hash = await sha256Hex(code.trim().toUpperCase());
  // Atomic single-use: only one redeemer can flip used_at.
  const res = await env.DB.prepare(
    "UPDATE pairing_codes SET used_at = ? WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?",
  )
    .bind(now(), hash, now())
    .run();
  if (!res.meta.changes) throw new HttpError(400, "Pairing code is invalid, expired or already used", "bad_code");
  return registerDevice(env, name, kind, capabilities);
}

export async function registerDevice(env: Env, name: string, kind: Device["kind"], capabilities: string[]) {
  if (!["mac", "iphone", "cli"].includes(kind)) throw new HttpError(400, "kind must be mac, iphone or cli", "validation");
  const token = randomToken(32);
  const id = newId("dev");
  await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO devices (id, name, kind, token_hash, capabilities, created_at) VALUES (?, ?, ?, ?, ?, ?)",
    ).bind(id, name.slice(0, 80), kind, await sha256Hex(token), JSON.stringify(capabilities.slice(0, 50)), now()),
  ]);
  return { device_id: id, token };
}
