import { publicPage } from "./public-pages";
import type { Env } from "./env";
import { HttpError, json } from "./http";
import { handleAuthed, redeem } from "./routes";
import { googleCallback } from "./connectors/google";
import { resumeConversations } from "./agent/agent";
import { dispatchHeartbeat } from "./heartbeat";
import { queueGoalChecks } from "./proactive";
import { runDueSchedules } from "./schedules";

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
      if (req.method === "GET" || req.method === "HEAD") {
        const info = publicPage(url.pathname, env.CONTACT_EMAIL);
        if (info) return req.method === "HEAD" ? new Response(null, { headers: info.headers }) : info;
      }
      if (url.pathname === "/" || url.pathname === "/health") return json({ name: "orbit", version: VERSION, ok: true });
      if (url.pathname === "/oauth/google/callback" && req.method === "GET") {
        try {
          const r = await googleCallback(env, url);
          return page("Connected", `${r.email} is now connected to Orbit. You can close this tab.`);
        } catch (e) {
          return page("Could not connect", e instanceof Error ? e.message : String(e), 400);
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
    if (event.cron === "* * * * *") {
      // Every minute: start due scheduled tasks; their runs drain through the chat inbox.
      exec.waitUntil(
        runDueSchedules(env)
          .then(async (r) => {
            if (r.queued) console.log("schedules", JSON.stringify(r));
            const goals = await queueGoalChecks(env);
            if (r.queued || goals) await resumeConversations(env);
          })
          .catch((e) => console.error("schedules", String(e))),
      );
      return;
    }
    exec.waitUntil(resumeConversations(env).catch((e) => console.error("chat recovery", String(e))));
    exec.waitUntil(
      Promise.all([dispatchHeartbeat(env, "email"), dispatchHeartbeat(env, "responsibilities"), dispatchHeartbeat(env, "changes")]),
    );
  },
} satisfies ExportedHandler<Env>;
