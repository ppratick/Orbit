import type { Env } from "./env";
import { firstAccount, mailAccount } from "./connectors";
import { github } from "./connectors/github";
import { canvasApi } from "./connectors/canvas";
import { now } from "./util";

type P = Record<string, unknown>;
const s = (p: P, k: string) => (typeof p[k] === "string" ? (p[k] as string) : "");
const n = (p: P, k: string) => Number(p[k]);

/**
 * Cloud-side executors. These run ONLY from tasks.ts after assertAuthorized() passed.
 * Credentials are decrypted inside connector calls and never returned in results.
 */
const EXECUTORS: Record<string, (env: Env, p: P) => Promise<unknown>> = {
  async "email.create_draft"(env, p) {
    const { acct, mail } = await mailAccount(env, s(p, "account_id") || null);
    const r = await mail.createDraft(env, acct, { to: s(p, "to"), cc: s(p, "cc") || undefined, subject: s(p, "subject"), body: s(p, "body"), in_reply_to: s(p, "in_reply_to") || undefined });
    return { ...r, account: acct.identity };
  },
  async "email.send"(env, p) {
    const { acct, mail } = await mailAccount(env, s(p, "account_id") || null);
    if (!mail.send) throw new Error(`Sending is not supported yet for ${acct.provider}; a draft can be created instead.`);
    return mail.send(env, acct, { to: s(p, "to"), cc: s(p, "cc") || undefined, subject: s(p, "subject"), body: s(p, "body"), in_reply_to: s(p, "in_reply_to") || undefined });
  },
  async "email.send_draft"(env, p) {
    const { acct, mail } = await mailAccount(env, s(p, "account_id") || null);
    if (!mail.sendDraft) throw new Error(`Sending drafts is not supported yet for ${acct.provider}.`);
    return mail.sendDraft(env, acct, s(p, "draft_id"));
  },
  async "github.comment"(env, p) {
    const a = await firstAccount(env, "github", s(p, "account_id") || null);
    return github.comment(env, a, s(p, "repo"), n(p, "number"), s(p, "body"));
  },
  async "github.create_issue"(env, p) {
    const a = await firstAccount(env, "github", s(p, "account_id") || null);
    return github.createIssue(env, a, s(p, "repo"), s(p, "title"), s(p, "body"));
  },
  async "github.merge_pr"(env, p) {
    const a = await firstAccount(env, "github", s(p, "account_id") || null);
    return github.mergePr(env, a, s(p, "repo"), n(p, "number"), s(p, "method") || "squash");
  },
  async "canvas.submit"(env, p) {
    const a = await firstAccount(env, "canvas", s(p, "account_id") || null);
    const type = s(p, "submission_type") === "online_url" ? "online_url" : "online_text_entry";
    return canvasApi.submit(env, a, n(p, "course_id"), n(p, "assignment_id"), { type, body: s(p, "body") || undefined, url: s(p, "url") || undefined });
  },
  async "memory.delete"(env, p) {
    const id = s(p, "memory_id");
    await env.DB.batch([
      env.DB.prepare("UPDATE memories SET deleted_at = ?, updated_at = ? WHERE id = ?").bind(now(), now(), id),
    ]);
    return { deleted: id };
  },
};

export async function runCloudAction(env: Env, action: string, params: P, _task: unknown): Promise<unknown> {
  const fn = EXECUTORS[action];
  if (!fn) throw new Error(`No cloud executor for ${action}`);
  return fn(env, params);
}
