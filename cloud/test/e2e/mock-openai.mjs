// Test double for the OpenAI Responses API, used ONLY by the local e2e suite.
// It scripts tool calls from keywords so the Worker's real agent loop, policy engine,
// task queue and storage can be exercised without network access or an API key.
import http from "node:http";
import { createHash } from "node:crypto";

// Fake OAuth state (authorization code + PKCE) standing in for the user's ChatGPT OAuth client.
export const oauth = { codes: new Map(), validAccess: new Set(), refresh: new Map(), issued: 0, rejectNext: 0, quotaBlocked: false };

export function startMockOpenAI(port) {
  const requests = [];
  const server = http.createServer(async (req, res) => {
    let body = "";
    for await (const c of req) body += c;
    const url = new URL(req.url, "http://x");
    if (url.pathname === "/oauth/authorize") {
      const code = "code_" + Math.random().toString(36).slice(2);
      oauth.codes.set(code, { challenge: url.searchParams.get("code_challenge"), method: url.searchParams.get("code_challenge_method"), client: url.searchParams.get("client_id"), redirect: url.searchParams.get("redirect_uri") });
      res.writeHead(302, { location: `${url.searchParams.get("redirect_uri")}?code=${code}&state=${url.searchParams.get("state")}` });
      return res.end();
    }
    if (url.pathname === "/oauth/token") {
      const f = new URLSearchParams(body);
      const issue = () => {
        const n = ++oauth.issued;
        oauth.validAccess.add(`chatgpt-access-${n}`);
        oauth.refresh.set(`chatgpt-refresh-${n}`, true);
        const idPayload = Buffer.from(JSON.stringify({ email: "me@example.com" })).toString("base64url");
        return { access_token: `chatgpt-access-${n}`, refresh_token: `chatgpt-refresh-${n}`, expires_in: 3600, id_token: `x.${idPayload}.y` };
      };
      res.writeHead(200, { "content-type": "application/json" });
      if (f.get("grant_type") === "authorization_code") {
        const c = oauth.codes.get(f.get("code"));
        oauth.codes.delete(f.get("code"));
        const ok = c && c.method === "S256" && createHash("sha256").update(f.get("code_verifier") ?? "").digest("base64url") === c.challenge && c.redirect === f.get("redirect_uri") && c.client === f.get("client_id");
        if (!ok) { res.statusCode = 400; return res.end(JSON.stringify({ error: "invalid_grant" })); }
        return res.end(JSON.stringify(issue()));
      }
      if (f.get("grant_type") === "refresh_token" && oauth.refresh.get(f.get("refresh_token"))) {
        oauth.refresh.delete(f.get("refresh_token")); // rotation
        return res.end(JSON.stringify(issue()));
      }
      res.statusCode = 400;
      return res.end(JSON.stringify({ error: "invalid_grant" }));
    }
    const j = JSON.parse(body || "{}");
    const auth = (req.headers.authorization ?? "").replace("Bearer ", "");
    j._auth = auth;
    requests.push(j);
    if (auth.startsWith("chatgpt-access-")) {
      if (oauth.quotaBlocked) { res.writeHead(429, { "content-type": "application/json" }); return res.end('{"error":{"message":"usage limit"}}'); }
      if (oauth.rejectNext > 0 || !oauth.validAccess.has(auth)) {
        oauth.rejectNext = Math.max(0, oauth.rejectNext - 1);
        oauth.validAccess.delete(auth);
        res.writeHead(401, { "content-type": "application/json" });
        return res.end('{"error":{"message":"invalid token"}}');
      }
    } else if (auth !== "test-key") {
      res.writeHead(401, { "content-type": "application/json" });
      return res.end('{"error":{"message":"bad key"}}');
    }
    const out = respond(j);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ id: "resp_mock", output: out, usage: { input_tokens: 1, output_tokens: 1 } }));
  });
  return new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve({ server, requests })));
}

let n = 0;
const call = (name, args) => ({ type: "function_call", call_id: `call_${++n}`, name, arguments: JSON.stringify(args) });
const text = (t) => ({ type: "message", role: "assistant", content: [{ type: "output_text", text: t }] });

function respond(j) {
  const instr = j.instructions ?? "";
  if (instr.includes("triage")) {
    const payload = j.input[0].content;
    const ids = [...payload.matchAll(/"id":"([^"]+)"/g)].map((m) => m[1]);
    return [text(JSON.stringify({ items: ids.map((id) => ({ id, category: "delivery", important: true, summary: "Package arriving", due_at: null, track_title: "Package delivery" })) }))];
  }
  if (instr.includes("morning briefing")) return [text("- Today: nothing scheduled\n- Due soon: dentist")];
  const input = j.input ?? [];
  const last = input[input.length - 1];
  if (last?.type === "function_call_output") return [text(`Tool said: ${String(last.output).slice(0, 160)}`)];
  const msg = String(last?.content ?? "");
  const tools = new Set((j.tools ?? []).map((t) => t.name));
  if (/remember/i.test(msg)) return [call("remember", { kind: "preference", content: "Prefers short replies" })];
  if (/work calendar/i.test(msg)) return [call("add_calendar_event", { title: "Team sync", start: "2026-11-12T15:00:00-05:00", calendar: "Work" })];
  if (/dentist/i.test(msg)) return [call("add_calendar_event", { title: "Dentist", start: "2026-11-13T09:00:00-05:00" })];
  if (/track/i.test(msg)) return [call("track_responsibility", { title: "Return headphones", kind: "return", due_at: "2026-11-20T17:00:00-05:00" })];
  if (/forget/i.test(msg)) return [call("forget_memory", { memory_id: msg.match(/mem_[\w-]+/)?.[0] ?? "x" })];
  if (/read file/i.test(msg)) return [call("mac_read_file", { path: "~/notes.txt" })];
  if (/both/i.test(msg)) return [call("search_memory", { query: "" }), call("list_responsibilities", {})];
  if (/tools\?/i.test(msg)) return [text(`tools: ${[...tools].sort().join(",")}`)];
  return [text(`Echo: ${msg.slice(0, 100)}`)];
}
