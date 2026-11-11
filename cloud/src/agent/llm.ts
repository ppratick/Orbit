import type { Env } from "../env";
import { authMode, LlmAuthError, noteFallback, resolveAuth, type LlmAuth } from "./llmauth";

/**
 * OpenAI Responses API client (stateless: store=false; reasoning items are passed back encrypted).
 * Credentials come from llmauth.ts (ChatGPT sign-in or API key) and never enter model context.
 */
export type InputItem =
  | { role: "user" | "assistant" | "developer"; content: string }
  | { type: "function_call"; call_id: string; name: string; arguments: string }
  | { type: "function_call_output"; call_id: string; output: string }
  | { type: "reasoning"; [k: string]: unknown };

export interface ToolDef {
  type: "function";
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  strict?: boolean;
}

export interface LlmResult {
  text: string;
  calls: { call_id: string; name: string; arguments: string }[];
  reasoning: Record<string, unknown>[];
  usage?: { input_tokens?: number; output_tokens?: number };
  via?: "chatgpt" | "api_key";
}

interface Req {
  instructions: string;
  input: InputItem[];
  tools?: ToolDef[];
  maxOutputTokens?: number;
  json?: boolean;
}

class HttpStatusError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

async function call(env: Env, auth: LlmAuth, req: Req): Promise<LlmResult> {
  const body: Record<string, unknown> = {
    model: env.OPENAI_MODEL,
    instructions: req.instructions,
    input: req.input,
    store: false,
    include: ["reasoning.encrypted_content"],
    max_output_tokens: req.maxOutputTokens ?? 4000,
  };
  if (req.tools?.length) {
    body.tools = req.tools;
    body.parallel_tool_calls = true;
  }
  if (req.json) body.text = { format: { type: "json_object" } };
  const r = await fetch(`${auth.baseUrl.replace(/\/$/, "")}/responses`, {
    method: "POST",
    headers: { authorization: `Bearer ${auth.bearer}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new HttpStatusError(r.status, `OpenAI ${r.status} (${auth.mode}): ${(await r.text()).slice(0, 500)}`);
  const j = (await r.json()) as { output: Record<string, unknown>[]; usage?: LlmResult["usage"] };
  const out: LlmResult = { text: "", calls: [], reasoning: [], usage: j.usage, via: auth.mode };
  for (const item of j.output ?? []) {
    if (item.type === "message") {
      for (const c of (item.content as { type: string; text?: string }[]) ?? []) if (c.type === "output_text" && c.text) out.text += c.text;
    } else if (item.type === "function_call") {
      out.calls.push({ call_id: String(item.call_id), name: String(item.name), arguments: String(item.arguments ?? "{}") });
    } else if (item.type === "reasoning") {
      out.reasoning.push(item);
    }
  }
  return out;
}

async function viaChatgpt(env: Env, req: Req): Promise<LlmResult> {
  const auth = await resolveAuth(env, "chatgpt");
  try {
    return await call(env, auth, req);
  } catch (e) {
    // Access token may have been revoked/expired early: refresh once and retry.
    if (e instanceof HttpStatusError && e.status === 401) return call(env, await resolveAuth(env, "chatgpt", true), req);
    throw e;
  }
}

export async function respond(env: Env, req: Req): Promise<LlmResult> {
  const mode = authMode(env);
  if (mode === "api_key") return call(env, await resolveAuth(env, "api_key"), req);
  if (mode === "chatgpt") return viaChatgpt(env, req);
  try {
    return await viaChatgpt(env, req);
  } catch (e) {
    // Fall back only on auth/eligibility/quota problems — never on bad requests — and only if a key exists.
    const fallbackable = e instanceof LlmAuthError || (e instanceof HttpStatusError && [401, 403, 429].includes(e.status)) || (e as { oauthError?: string }).oauthError !== undefined;
    if (!fallbackable || !env.OPENAI_API_KEY) throw e;
    if (!(e instanceof LlmAuthError)) await noteFallback(env, e instanceof Error ? e.message : String(e));
    return call(env, await resolveAuth(env, "api_key"), req);
  }
}
