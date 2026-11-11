import type { Env } from "./env";
import { fromB64, toB64 } from "./util";

/**
 * Account credentials are encrypted at rest with AES-256-GCM using ENCRYPTION_KEY
 * (a Worker secret). Decrypted values only live inside connector code paths and
 * are never placed in model prompts, tool results, API responses or logs.
 */
async function key(env: Env): Promise<CryptoKey> {
  if (!env.ENCRYPTION_KEY) throw new Error("ENCRYPTION_KEY secret is not configured");
  const raw = fromB64(env.ENCRYPTION_KEY);
  if (raw.length !== 32) throw new Error("ENCRYPTION_KEY must be 32 bytes, base64-encoded");
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export async function encryptSecret(env: Env, value: unknown): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const pt = new TextEncoder().encode(JSON.stringify(value));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await key(env), pt));
  return `v1.${toB64(iv)}.${toB64(ct)}`;
}

export async function decryptSecret<T>(env: Env, blob: string): Promise<T> {
  const [v, ivB64, ctB64] = blob.split(".");
  if (v !== "v1" || !ivB64 || !ctB64) throw new Error("Unrecognised secret format");
  const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromB64(ivB64) }, await key(env), fromB64(ctB64));
  return JSON.parse(new TextDecoder().decode(pt)) as T;
}
