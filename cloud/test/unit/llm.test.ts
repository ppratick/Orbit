import { describe, expect, it } from "vitest";
import { buildBody, readStream, LlmError, friendlyError } from "../../src/agent/llm";
import { chooseModel } from "../../src/agent/router";
import type { Env } from "../../src/env";

const sse = (events: object[], tail = "") =>
  new Response(events.map((e) => `event: ${(e as { type: string }).type}\ndata: ${JSON.stringify(e)}\n\n`).join("") + tail).body!;

describe("Responses request body (ChatGPT plan usage rules)", () => {
  it("streams, never stores, omits unsupported fields and namespaces tools", () => {
    const b = buildBody({ model: "gpt-6-luna", instructions: "x", input: [], tools: [{ type: "function", name: "remember", description: "", parameters: {} }] });
    expect(b.stream).toBe(true);
    expect(b.store).toBe(false);
    for (const k of ["max_output_tokens", "temperature", "previous_response_id", "metadata", "user", "truncation"]) expect(b).not.toHaveProperty(k);
    expect((b.tools as { type: string; tools: unknown[] }[])[0].type).toBe("namespace");
    expect((b.tools as { tools: unknown[] }[])[0].tools).toHaveLength(1);
  });
});

describe("SSE parsing", () => {
  it("collects deltas, function calls (with namespace) and reasoning; succeeds only on completed", async () => {
    const deltas: string[] = [];
    const r = await readStream(
      sse([
        { type: "response.output_text.delta", delta: "Hel" },
        { type: "response.output_text.delta", delta: "lo" },
        { type: "response.output_item.done", item: { type: "message", content: [{ type: "output_text", text: "Hello" }] } },
        { type: "response.output_item.done", item: { type: "function_call", call_id: "c1", name: "remember", namespace: "orbit", arguments: "{}" } },
        { type: "response.output_item.done", item: { type: "reasoning", id: "r1", encrypted_content: "x" } },
        { type: "response.completed", response: { usage: { input_tokens: 3 } } },
      ]),
      (d) => void deltas.push(d),
    );
    expect(deltas.join("")).toBe("Hello");
    expect(r.text).toBe("Hello");
    expect(r.calls).toEqual([{ call_id: "c1", name: "remember", namespace: "orbit", arguments: "{}" }]);
    expect(r.reasoning).toHaveLength(1);
  });
  it("separates distinct text messages in the live stream and saved answer", async () => {
    const deltas:string[]=[];
    const r=await readStream(sse([
      {type:"response.output_text.delta",item_id:"a",delta:"Checking."},
      {type:"response.output_text.delta",item_id:"b",delta:"The answer."},
      {type:"response.output_item.done",item:{type:"message",content:[{type:"output_text",text:"Checking."}]}},
      {type:"response.output_item.done",item:{type:"message",content:[{type:"output_text",text:"The answer."}]}},
      {type:"response.completed",response:{}},
    ]),(d)=>void deltas.push(d));
    expect(r.text).toBe("Checking.\n\nThe answer.");
    expect(deltas.join("")).toBe(r.text);
  });
  it("handles events split across chunks", async () => {
    const body = new ReadableStream<Uint8Array>({
      start(c) {
        const s = `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "a" })}\n\ndata: ${JSON.stringify({ type: "response.completed", response: {} })}\n\n`;
        for (const ch of s) c.enqueue(new TextEncoder().encode(ch));
        c.close();
      },
    });
    expect((await readStream(body)).text).toBe("a");
  });
  it("maps response.failed codes and interrupted streams to errors", async () => {
    await expect(readStream(sse([{ type: "response.failed", response: { error: { code: "subscription_sharing_usage_limit_exceeded" } } }]))).rejects.toMatchObject({ code: "subscription_sharing_usage_limit_exceeded" });
    await expect(readStream(sse([{ type: "response.output_text.delta", delta: "x" }]))).rejects.toMatchObject({ code: "stream_interrupted" });
    expect(friendlyError(new LlmError(429, "subscription_sharing_usage_limit_exceeded", "raw"))).toMatch(/Settings → Usage/);
  });
});

describe("model routing", () => {
  const env = { OPENAI_MODEL_BASIC: "gpt-6-luna", OPENAI_MODEL_ADVANCED: "gpt-6.1-sol" } as Env;
  it("uses Luna for basic work and Sol for harder work", () => {
    expect(chooseModel(env, "triage")).toBe("gpt-6-luna");
    expect(chooseModel(env, "briefing")).toBe("gpt-6-luna");
    expect(chooseModel(env, "chat", { text: "what's on today?" })).toBe("gpt-6-luna");
    expect(chooseModel(env, "chat", { text: "Draft a reply to Sam" })).toBe("gpt-6.1-sol");
    expect(chooseModel(env, "chat", { text: "x".repeat(700) })).toBe("gpt-6.1-sol");
    expect(chooseModel(env, "chat", { text: "ok", step: 2 })).toBe("gpt-6.1-sol");
    expect(chooseModel(env, "chat", { text: "ok", deviceResult: true })).toBe("gpt-6.1-sol");
    expect(chooseModel(env, "chat", { text: "/luna plan my week" })).toBe("gpt-6-luna");
    expect(chooseModel(env, "chat", { text: "/sol hi" })).toBe("gpt-6.1-sol");
  });
});
