import type { Env } from "./env";
import { HttpError, json } from "./http";
import { handleAuthed, redeem } from "./routes";
import { googleCallback } from "./connectors/google";
import { chatgptComplete } from "./agent/llmauth";
import { heartbeat, phaseFor } from "./heartbeat";

const VERSION = "0.1.0";

function page(title: string, body: string, status = 200) {
  const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
  return new Response(
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${esc(title)}</title><body style="font:16px -apple-system,system-ui;max-width:32rem;margin:4rem auto;padding:0 1rem"><h2>${esc(title)}</h2><p>${esc(body)}</p></body>`,
    { status, headers: { "content-type": "text/html; charset=utf-8" } },
  );
}

export default {
  async fetch(req: Request, env: Env, exec: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);
    try {
      if (url.pathname === "/" || url.pathname === "/health") return json({ name: "orbit", version: VERSION, ok: true });
      if (url.pathname === "/oauth/google/callback" && req.method === "GET") {
        try {
          const r = await googleCallback(env, url);
          return page("Connected", `${r.email} is now connected to Orbit. You can close this tab.`);
        } catch (e) {
          return page("Could not connect", e instanceof Error ? e.message : String(e), 400);
        }
      }
      // Used when the ChatGPT OAuth client's registered redirect URI points at this Worker.
      if (url.pathname === "/oauth/chatgpt/callback" && req.method === "GET") {
        try {
          const r = await chatgptComplete(env, { callback_url: url.toString() });
          return page("Signed in", `${r.identity} is now linked for Orbit's model access. You can close this tab.`);
        } catch (e) {
          return page("Could not sign in", e instanceof Error ? e.message : String(e), 400);
        }
      }
      if (url.pathname === "/v1/devices/redeem" && req.method === "POST") return await redeem(req, env);
      if (url.pathname.startsWith("/v1/")) return await handleAuthed(req, env, exec, url.pathname);
      throw new HttpError(404, "Not found", "not_found");
    } catch (e) {
      if (e instanceof HttpError) return json({ error: { code: e.code, message: e.message } }, e.status);
      console.error("unhandled", e);
      return json({ error: { code: "internal", message: e instanceof Error ? e.message : "Internal error" } }, 500);
    }
  },

  async scheduled(event: ScheduledController, env: Env, exec: ExecutionContext): Promise<void> {
    exec.waitUntil(
      heartbeat(env, phaseFor(event.scheduledTime)).then((s) => console.log("heartbeat", JSON.stringify(s))),
    );
  },
} satisfies ExportedHandler<Env>;
