import type { Env } from "./env";
import { fromB64, newId, now, toB64Url, truncate } from "./util";

export interface NotifyInput {
  title: string;
  body: string;
  category: "approval" | "task_done" | "task_failed" | "briefing" | "deadline" | "email" | "system";
  refType?: string | null;
  refId?: string | null;
  dedupeKey?: string | null;
}

/**
 * Persist a notification (devices always see it on their next sync) and try to push it.
 * Push is best-effort; the database row is the source of truth.
 */
export async function notify(env: Env, n: NotifyInput): Promise<string | null> {
  const id = newId("ntf");
  const res = await env.DB.prepare(
    `INSERT INTO notifications (id, title, body, category, ref_type, ref_id, dedupe_key, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(dedupe_key) DO NOTHING`,
  )
    .bind(id, truncate(n.title, 120), truncate(n.body, 1000), n.category, n.refType ?? null, n.refId ?? null, n.dedupeKey ?? null, now())
    .run();
  if (!res.meta.changes) return null; // already notified
  const { status, error } = await push(env, n, id);
  await env.DB.prepare("UPDATE notifications SET push_status = ?, push_error = ? WHERE id = ?").bind(status, error, id).run();
  return id;
}

async function push(env: Env, n: NotifyInput, id: string): Promise<{ status: string; error: string | null }> {
  const errors: string[] = [];
  let sent = false;
  if (env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_TOPIC) {
    const devices = await env.DB.prepare(
      "SELECT id, push_token, push_env FROM devices WHERE push_token IS NOT NULL AND revoked_at IS NULL",
    ).all<{ id: string; push_token: string; push_env: string | null }>();
    for (const d of devices.results) {
      try {
        await sendApns(env, d.push_token, d.push_env === "production", n, id);
        sent = true;
      } catch (e) {
        errors.push(`apns:${d.id}:${e instanceof Error ? e.message : e}`);
      }
    }
  }
  if (env.NTFY_TOPIC_URL) {
    // ntfy fallback: send only a generic line so message content never leaves Orbit.
    try {
      const r = await fetch(env.NTFY_TOPIC_URL, {
        method: "POST",
        headers: { Title: "Orbit", Tags: n.category },
        body: n.category === "approval" ? "An action is waiting for your approval." : "Orbit has an update for you.",
      });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      sent = true;
    } catch (e) {
      errors.push(`ntfy:${e instanceof Error ? e.message : e}`);
    }
  }
  if (sent) return { status: "sent", error: errors.length ? errors.join("; ") : null };
  return errors.length ? { status: "failed", error: errors.join("; ") } : { status: "skipped", error: null };
}

let cachedJwt: { token: string; at: number } | null = null;

async function apnsJwt(env: Env): Promise<string> {
  // APNs provider tokens are valid up to 1 hour; refresh well before that.
  if (cachedJwt && now() - cachedJwt.at < 40 * 60_000) return cachedJwt.token;
  const pem = env.APNS_KEY_P8!.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const key = await crypto.subtle.importKey("pkcs8", fromB64(pem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const enc = new TextEncoder();
  const header = toB64Url(enc.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = toB64Url(enc.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(now() / 1000) })));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${header}.${claims}`)));
  const token = `${header}.${claims}.${toB64Url(sig)}`;
  cachedJwt = { token, at: now() };
  return token;
}

async function sendApns(env: Env, deviceToken: string, production: boolean, n: NotifyInput, id: string) {
  const host = production ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";
  const r = await fetch(`${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await apnsJwt(env)}`,
      "apns-topic": env.APNS_TOPIC!,
      "apns-push-type": "alert",
      "apns-priority": n.category === "approval" ? "10" : "5",
      "apns-collapse-id": id.slice(0, 64),
    },
    body: JSON.stringify({
      aps: { alert: { title: n.title, body: n.body }, sound: "default", category: n.category === "approval" ? "ORBIT_APPROVAL" : undefined },
      orbit: { notification_id: id, ref_type: n.refType, ref_id: n.refId },
    }),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status} ${truncate(await r.text(), 200)}`);
}
