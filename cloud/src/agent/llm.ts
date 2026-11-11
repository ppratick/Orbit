import type { Env } from "../env";
import { authMode, LlmAuthError, noteFallback, resolveAuth, type LlmAuth } from "./llmauth";

/**
 * OpenAI Responses API client, streaming.
 *
 * ChatGPT plan usage (Sign in with ChatGPT) requires: stream=true, store=false, history sent in `input`,
 * no max_output_tokens/temperature/etc., function tools grouped in a namespace, and success only on
 * `response.completed`. We follow those rules for every request so both auth modes behave the same.
 * https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
 */
export type InputItem =
  | { role: "user" | "assistant" | "developer"; content: string }
  | { type: "function_call"; call_id: string; name: string; arguments: string; namespace?: string }
  | { type: "function_call_output"; call_id: string; output: string }
  | { type: "reasoning"; [k: string]: unknown };

export interface ToolDef {
  type: "function";
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  strict?: boolean;
}

export const TOOL_NAMESPACE = "orbit";

export interface LlmCall {
  call_id: string;
  name: string;
  arguments: string;
  namespace?: string;
}

export interface LlmResult {
  text: string;
  calls: LlmCall[];
  reasoning: Record<string, unknown>[];
  usage?: { input_tokens?: number; output_tokens?: number };
  via: "chatgpt" | "api_key";
  model: string;
}

export interface Req {
  model: string;
  instructions: string;
  input: InputItem[];
  tools?: ToolDef[];
  json?: boolean;
  /** Called with each visible text delta as it streams. */
  onDelta?: (text: string) => void | Promise<void>;
}

/** Errors with the API's machine-readable code preserved (e.g. subscription_sharing_usage_limit_exceeded). */
export class LlmError extends Error {
  constructor(public status: number, public code: string, message: string, public requestId?: string | null) {
    super(message);
  }
}

const FRIENDLY: Record<string, string> = {
  subscription_sharing_usage_limit_exceeded: "Your ChatGPT plan usage limit for apps has been reached. Check ChatGPT Settings → Usage; Orbit will work again once usage is available.",
  subscription_sharing_usage_unavailable: "ChatGPT couldn't confirm plan usage right now. Try again shortly.",
  subscription_sharing_user_not_eligible: "ChatGPT plan usage isn't available for this account or workspace.",
  subscription_sharing_unsupported_capability: "This request used a capability ChatGPT plan usage doesn't support.",
  subscription_sharing_route_not_supported: "ChatGPT plan usage doesn't support this API route.",
  subscription_sharing_invalid_user: "ChatGPT couldn't validate your account; sign in again.",
  subscription_sharing_user_unavailable: "ChatGPT account information is temporarily unavailable. Try again shortly.",
};

export function friendlyError(e: unknown): string {
  if (e instanceof LlmError) return FRIENDLY[e.code] ?? e.message;
  return e instanceof Error ? e.message : String(e);
}

export function buildBody(req: Req, stream = true): Record<string, unknown> {
  const body: Record<string, unknown> = {
    model: req.model,
    instructions: req.instructions,
    input: req.input,
    store: false,
    stream,
    include: ["reasoning.encrypted_content"],
  };
  if (req.tools?.length) {
    body.tools = [{ type: "namespace", name: TOOL_NAMESPACE, description: "Orbit assistant tools: memory, email, calendar, tasks, accounts, devices.", tools: req.tools }];
    body.parallel_tool_calls = true;
  }
  if (req.json) body.text = { format: { type: "json_object" } };
  return body;
}

/** Parse a Responses SSE stream until a terminal event. */
export async function readStream(body: ReadableStream<Uint8Array>, onDelta?: Req["onDelta"]): Promise<Omit<LlmResult, "via" | "model">> {
  const reader = body.pipeThrough(new TextDecoderStream()).getReader();
  const out: Omit<LlmResult, "via" | "model"> = { text: "", calls: [], reasoning: [] };
  const items: Record<string, unknown>[] = [];
  let buf = "";
  let terminal: "completed" | null = null;
  const handle = async (data: string) => {
    if (!data || data === "[DONE]") return;
    const ev = JSON.parse(data) as { type: string; delta?: string; item?: Record<string, unknown>; response?: { output?: Record<string, unknown>[]; usage?: LlmResult["usage"]; error?: { code?: string; message?: string }; incomplete_details?: { reason?: string } }; error?: { code?: string; message?: string }; code?: string; message?: string };
    switch (ev.type) {
      case "response.output_text.delta":
        if (ev.delta) {
          out.text += ev.delta;
          await onDelta?.(ev.delta);
        }
        break;
      case "response.output_item.done":
        if (ev.item) items.push(ev.item);
        break;
      case "response.completed":
        terminal = "completed";
        out.usage = ev.response?.usage;
        if (ev.response?.output?.length) items.splice(0, items.length, ...ev.response.output);
        break;
      case "response.failed": {
        const err = ev.response?.error;
        throw new LlmError(200, err?.code ?? "response_failed", err?.message ?? "The model response failed");
      }
      case "response.incomplete":
        throw new LlmError(200, "response_incomplete", `Response incomplete: ${ev.response?.incomplete_details?.reason ?? "unknown"}`);
      case "error":
        throw new LlmError(200, ev.error?.code ?? ev.code ?? "stream_error", ev.error?.message ?? ev.message ?? "Stream error");
    }
  };
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += value;
    let i: number;
    while ((i = buf.indexOf("\n\n")) !== -1) {
      const block = buf.slice(0, i);
      buf = buf.slice(i + 2);
      const data = block
        .split("\n")
        .filter((l) => l.startsWith("data:"))
        .map((l) => l.slice(5).trimStart())
        .join("\n");
      await handle(data);
    }
  }
  if (buf.trim()) await handle(buf.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trimStart()).join("\n"));
  if (terminal !== "completed") throw new LlmError(0, "stream_interrupted", "The model stream ended before completion");
  // Authoritative output items: text from message items (covers deltas we may have missed), calls, reasoning.
  let text = "";
  for (const item of items) {
    if (item.type === "message") {
      for (const c of (item.content as { type: string; text?: string }[]) ?? []) if (c.type === "output_text" && c.text) text += c.text;
    } else if (item.type === "function_call") {
      out.calls.push({ call_id: String(item.call_id), name: String(item.name), arguments: String(item.arguments ?? "{}"), namespace: item.namespace ? String(item.namespace) : undefined });
    } else if (item.type === "reasoning") {
      out.reasoning.push(item);
    }
  }
  if (text) out.text = text;
  return out;
}

async function call(env: Env, auth: LlmAuth, req: Req): Promise<LlmResult> {
  const r = await fetch(`${auth.baseUrl.replace(/\/$/, "")}/responses`, {
    method: "POST",
    headers: { authorization: `Bearer ${auth.bearer}`, "content-type": "application/json", accept: "text/event-stream" },
    body: JSON.stringify(buildBody(req)),
  });
  if (!r.ok || !r.body) {
    const text = await r.text();
    const j = (() => {
      try {
        return JSON.parse(text) as { error?: { code?: string; message?: string }; detail?: string };
      } catch {
        return {} as { error?: { code?: string; message?: string }; detail?: string };
      }
    })();
    throw new LlmError(r.status, j.error?.code ?? `http_${r.status}`, `OpenAI ${r.status} (${auth.mode}): ${j.error?.message ?? j.detail ?? text.slice(0, 300)}`, r.headers.get("x-request-id"));
  }
  const res = await readStream(r.body, req.onDelta);
  return { ...res, via: auth.mode, model: req.model };
}

async function viaChatgpt(env: Env, req: Req): Promise<LlmResult> {
  const auth = await resolveAuth(env, "chatgpt");
  try {
    return await call(env, auth, req);
  } catch (e) {
    // Access token may have been revoked/expired early: refresh once and retry (only before any text streamed).
    if (e instanceof LlmError && e.status === 401) return call(env, await resolveAuth(env, "chatgpt", true), req);
    throw e;
  }
}

export async function respond(env: Env, req: Req): Promise<LlmResult> {
  const mode = authMode(env);
  if (mode === "api_key") return call(env, await resolveAuth(env, "api_key"), req);
  if (mode === "chatgpt") return viaChatgpt(env, req);
  // chatgpt_then_api_key — the paid fallback; never the default, always logged.
  try {
    return await viaChatgpt(env, req);
  } catch (e) {
    const fallbackable = e instanceof LlmAuthError || (e instanceof LlmError && ([401, 403, 429].includes(e.status) || e.code.startsWith("subscription_sharing_")));
    if (!fallbackable || !env.OPENAI_API_KEY) throw e;
    await noteFallback(env, e instanceof Error ? e.message : String(e));
    return call(env, await resolveAuth(env, "api_key"), req);
  }
}
