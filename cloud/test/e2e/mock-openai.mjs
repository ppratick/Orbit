// Test double for OpenAI's Sign in with ChatGPT issuer + Responses API, used ONLY by the local e2e suite.
// It enforces the documented ChatGPT-plan-usage request rules (stream=true, store=false, no
// max_output_tokens, namespaced tools), signs RS256 ID tokens, rotates refresh tokens, and streams SSE.
import http from "node:http";
import { generateKeyPairSync, createSign, randomUUID } from "node:crypto";

const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: "jwk" }), kid: "test-key-1", alg: "RS256", use: "sig" };
const b64u = (o) => Buffer.from(typeof o === "string" ? o : JSON.stringify(o)).toString("base64url");

export const modelControl = { holdAfter: null, release: null };

export const siwc = { issuer: "", validAccess: new Set(), refresh: new Map(), issued: 0, rejectNext: 0, quota: false, revoked: [] };

export function signIdToken(claims) {
  const h = b64u({ alg: "RS256", kid: jwk.kid, typ: "JWT" });
  const p = b64u({ iss: siwc.issuer, iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 3600, ...claims });
  const sig = createSign("RSA-SHA256").update(`${h}.${p}`).sign(privateKey).toString("base64url");
  return `${h}.${p}.${sig}`;
}

/** Simulates what a device gets back from the real token endpoint after local sign-in. */
export function issueTokens(clientId, { sub = "user-123", email = "me@example.com", nonce, scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct" } = {}) {
  const n = ++siwc.issued;
  const access = `siwc-access-${n}`;
  siwc.validAccess.add(access);
  siwc.refresh.set(`siwc-refresh-${n}`, { clientId, sub });
  return { access_token: access, refresh_token: `siwc-refresh-${n}`, id_token: signIdToken({ aud: clientId, sub, email, nonce }), expires_in: 3600, scope, token_type: "Bearer" };
}

export function startMockOpenAI(port) {
  siwc.issuer = `http://127.0.0.1:${port}`;
  const requests = [];
  const server = http.createServer(async (req, res) => {
    let body = "";
    for await (const c of req) body += c;
    const url = new URL(req.url, "http://x");
    const sendJson = (status, obj) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(obj));
    };
    if (url.pathname === "/.well-known/openid-configuration")
      return sendJson(200, { issuer: siwc.issuer, jwks_uri: `${siwc.issuer}/jwks`, revocation_endpoint: `${siwc.issuer}/api/accounts/oauth/revoke` });
    if (url.pathname === "/jwks") return sendJson(200, { keys: [jwk] });
    if (url.pathname === "/api/accounts/oauth/revoke") {
      siwc.revoked.push(Object.fromEntries(new URLSearchParams(body)));
      res.writeHead(200);
      return res.end();
    }
    if (url.pathname === "/api/accounts/oauth/token") {
      const f = new URLSearchParams(body);
      const entry = siwc.refresh.get(f.get("refresh_token"));
      if (f.get("grant_type") !== "refresh_token" || f.get("resource") !== "https://api.openai.com/v1" || !entry || entry.clientId !== f.get("client_id"))
        return sendJson(400, { error: entry ? "invalid_client" : "invalid_grant" });
      siwc.refresh.delete(f.get("refresh_token")); // rotation: old refresh token is single-use
      const t = issueTokens(entry.clientId, { sub: entry.sub });
      return sendJson(200, t);
    }
    const auth = (req.headers.authorization ?? "").replace("Bearer ", "");
    if (url.pathname === "/v1/models") {
      if (!siwc.validAccess.has(auth)) return sendJson(401, { detail: "bad token" });
      return sendJson(200, { models: [{ slug: "gpt-6.1-sol", display_name: "GPT-6.1 Sol", visibility: "list" }, { slug: "gpt-6-luna", display_name: "GPT-6 Luna", visibility: "list" }, { slug: "hidden", visibility: "hide" }] });
    }
    // ── Responses API ──
    const j = JSON.parse(body || "{}");
    j._auth = auth;
    requests.push(j);
    if (j.instructions?.includes("Classify follow-ups") && j.text?.format?.type === "json_object" && !/json/i.test(JSON.stringify(j.input))) {
      return sendJson(400, { error: { code: "invalid_request", message: "JSON mode requires json in input messages" } });
    }
    if (modelControl.holdAfter === 0) {
      modelControl.holdAfter = null;
      await new Promise((resolve) => { modelControl.release = () => { modelControl.release = null; resolve(); }; });
    } else if (typeof modelControl.holdAfter === "number") modelControl.holdAfter--;
    if (siwc.rejectNext > 0 || !siwc.validAccess.has(auth)) {
      siwc.rejectNext = Math.max(0, siwc.rejectNext - 1);
      siwc.validAccess.delete(auth);
      return sendJson(401, { detail: "The required signed identity was not accepted." });
    }
    const unsupported = ["max_output_tokens", "temperature", "previous_response_id", "metadata", "user"].find((k) => k in j);
    const badTools = (j.tools ?? []).some((t) => t.type !== "namespace");
    if (j.stream !== true || j.store !== false || unsupported || badTools || (j.input ?? []).some((i) => i.role === "system"))
      return sendJson(400, { error: { code: "subscription_sharing_unsupported_capability", param: unsupported ?? (badTools ? "tools" : "stream/store"), message: "unsupported" } });
    if (siwc.quota) return sendJson(429, { error: { code: "subscription_sharing_usage_limit_exceeded", message: "limit" } });

    const out = respond(j);
    res.writeHead(200, { "content-type": "text/event-stream" });
    const ev = (o) => res.write(`event: ${o.type}\ndata: ${JSON.stringify(o)}\n\n`);
    ev({ type: "response.created", response: { id: "resp_mock" } });
    for (const item of out) {
      if (item.type === "message") {
        const text = item.content[0].text;
        // Stream in small chunks to exercise delta handling.
        for (let i = 0; i < text.length; i += 7) ev({ type: "response.output_text.delta", delta: text.slice(i, i + 7) });
      }
      ev({ type: "response.output_item.done", item });
    }
    if (j._failMidStream) ev({ type: "response.failed", response: { error: { code: "subscription_sharing_usage_limit_exceeded" } } });
    else ev({ type: "response.completed", response: { id: "resp_mock", output: out, usage: { input_tokens: 1, output_tokens: 1 } } });
    res.end();
  });
  return new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve({ server, requests })));
}

let n = 0;
const call = (name, args) => ({ type: "function_call", call_id: `call_${++n}`, name, namespace: "orbit", arguments: JSON.stringify(args) });
const text = (t) => ({ type: "message", role: "assistant", content: [{ type: "output_text", text: t }] });

function respond(j) {
  const instr = j.instructions ?? "";
  if (instr.includes("Classify follow-ups")) {
    const payload = JSON.parse(j.input[0].content);
    return [text(JSON.stringify({ steer_ids: payload.followups.filter((m) => /^(Actually|Stop|Also)/i.test(m.content)).map((m) => m.id) }))];
  }
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
  if (/^Actually just say/i.test(msg)) return [text("Corrected without saving anything else.")];
  if (/^Stop/i.test(msg)) return [text("Stopped. No further actions taken.")];
  const tools = new Set((j.tools ?? []).flatMap((t) => (t.tools ?? []).map((x) => x.name)));
  if (/remember/i.test(msg)) return [call("remember", { kind: "preference", content: "Prefers short replies" })];
  if (/work calendar/i.test(msg)) return [call("add_calendar_event", { title: "Team sync", start: "2026-11-12T15:00:00-05:00", calendar: "Work" })];
  if (/dentist/i.test(msg)) return [call("add_calendar_event", { title: "Dentist", start: "2026-11-13T09:00:00-05:00" })];
  if (/mark (R\w+) done/i.test(msg)) return [call("complete_reminder", { reminder_id: msg.match(/mark (R\w+) done/i)[1] })];
  if (/track/i.test(msg)) return [call("track_responsibility", { title: "Return headphones", kind: "return", due_at: "2026-11-20T17:00:00-05:00" })];
  if (/forget/i.test(msg)) return [call("forget_memory", { memory_id: msg.match(/mem_[\w-]+/)?.[0] ?? "x" })];
  if (/read file/i.test(msg)) return [call("mac_read_file", { path: "~/notes.txt" })];
  if (/both/i.test(msg)) return [call("search_memory", { query: "" }), call("list_responsibilities", {})];
  if (/tools\?/i.test(msg)) return [text(`tools: ${[...tools].sort().join(",")}`)];
  return [text(`Echo: ${msg.slice(0, 100)}`)];
}
export { randomUUID };
