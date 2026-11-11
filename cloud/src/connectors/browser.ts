import type { Env } from "../env";
import { htmlToText } from "../untrusted";

/**
 * Web reading for research.
 *  - Cloudflare Browser Run (headless Chrome, REST "markdown" quick action) when CF_ACCOUNT_ID + CF_BROWSER_TOKEN are set.
 *    Workers Free includes ~10 browser-minutes/day, so it is used only when `render` is requested.
 *  - Otherwise a plain fetch + HTML-to-text, which costs nothing.
 * Interactive browser control (logins, forms, clicks) runs on the Mac companion instead.
 */
export function assertPublicUrl(raw: string): URL {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    throw new Error("Invalid URL");
  }
  if (!["http:", "https:"].includes(u.protocol)) throw new Error("Only http(s) URLs are allowed");
  const h = u.hostname.toLowerCase();
  if (h === "localhost" || h.endsWith(".local") || h.endsWith(".internal") || /^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|0\.|\[?::1\]?$)/.test(h)) {
    throw new Error("Private network addresses are not allowed");
  }
  return u;
}

export async function readWebPage(env: Env, url: string, render = false): Promise<{ url: string; text: string; via: string }> {
  const u = assertPublicUrl(url);
  if (render && env.CF_ACCOUNT_ID && env.CF_BROWSER_TOKEN) {
    const r = await fetch(`https://api.cloudflare.com/client/v4/accounts/${env.CF_ACCOUNT_ID}/browser-rendering/markdown`, {
      method: "POST",
      headers: { authorization: `Bearer ${env.CF_BROWSER_TOKEN}`, "content-type": "application/json" },
      body: JSON.stringify({ url: u.toString() }),
    });
    const j = (await r.json()) as { success: boolean; result?: string; errors?: { message: string }[] };
    if (!r.ok || !j.success) throw new Error(`Browser Run: ${j.errors?.[0]?.message ?? r.status}`);
    return { url: u.toString(), text: (j.result ?? "").slice(0, 20000), via: "browser-run" };
  }
  const r = await fetch(u.toString(), { headers: { "user-agent": "Mozilla/5.0 (compatible; OrbitAssistant/0.1)", accept: "text/html,text/plain,*/*" }, redirect: "follow" });
  if (!r.ok) throw new Error(`Fetch ${r.status}`);
  const ct = r.headers.get("content-type") ?? "";
  const body = (await r.text()).slice(0, 400_000);
  return { url: r.url, text: (ct.includes("html") ? htmlToText(body) : body).slice(0, 20000), via: "fetch" };
}
