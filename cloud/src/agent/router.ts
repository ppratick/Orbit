import type { Env } from "../env";

/**
 * Model routing: GPT-6 Luna for basic work, GPT-6.1 Sol for harder work.
 * IDs come from wrangler vars (verified against OpenAI's model docs and the signed-in account's
 * /v1/models catalog via GET /v1/model?verify=1).
 */
export type TaskKind = "chat" | "triage" | "briefing" | "title";

const HARD = /\b(plan|planning|research|analy[sz]e|analysis|compare|comparison|draft|write|rewrite|essay|code|debug|refactor|strategy|review|negotiat|summari[sz]e (the|this|my) (thread|document|file|pdf)|figure out|step[- ]by[- ]step|pros and cons|trade-?offs?|why)\b/i;

export function chooseModel(env: Env, kind: TaskKind, ctx: { text?: string; step?: number; deviceResult?: boolean } = {}): string {
  const basic = env.OPENAI_MODEL_BASIC;
  const advanced = env.OPENAI_MODEL_ADVANCED;
  if (kind === "triage" || kind === "title" || kind === "briefing") return basic;
  const text = (ctx.text ?? "").trim();
  if (/^\/sol\b/i.test(text)) return advanced;
  if (/^\/luna\b/i.test(text)) return basic;
  // Escalate when the turn turns into multi-step tool work.
  if ((ctx.step ?? 0) >= 2) return advanced;
  if (ctx.deviceResult) return advanced;
  if (text.length > 600 || text.split("\n").length > 8) return advanced;
  if (HARD.test(text)) return advanced;
  return basic;
}
