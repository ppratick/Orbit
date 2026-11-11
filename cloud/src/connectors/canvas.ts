import type { Env } from "../env";
import { accountSecret, type AccountRow } from "../accounts";
import { parseJson } from "../util";

/** Canvas LMS via a user-generated access token (Account → Settings → New Access Token). */
interface CanvasSecret {
  token: string;
}

async function canvas<T>(env: Env, acct: AccountRow, path: string, init: RequestInit = {}): Promise<T> {
  const { token } = await accountSecret<CanvasSecret>(env, acct);
  const base = parseJson<{ base_url?: string }>(acct.config, {}).base_url;
  if (!base) throw new Error("Canvas base_url is not configured for this account");
  const r = await fetch(`${base.replace(/\/$/, "")}/api/v1${path}`, {
    ...init,
    headers: { authorization: `Bearer ${token}`, accept: "application/json", ...(init.body ? { "content-type": "application/json" } : {}) },
  });
  if (!r.ok) throw new Error(`Canvas ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return (await r.json()) as T;
}

export const canvasApi = {
  verify: (env: Env, acct: AccountRow) => canvas<{ id: number; name: string }>(env, acct, "/users/self"),

  async upcoming(env: Env, acct: AccountRow) {
    const todo = await canvas<{ assignment?: { id: number; name: string; due_at: string | null; course_id: number; html_url: string; points_possible: number }; context_name: string; type: string }[]>(
      env,
      acct,
      "/users/self/todo?per_page=50",
    );
    return todo
      .filter((t) => t.assignment)
      .map((t) => ({
        course: t.context_name,
        course_id: t.assignment!.course_id,
        assignment_id: t.assignment!.id,
        name: t.assignment!.name,
        due_at: t.assignment!.due_at,
        url: t.assignment!.html_url,
        type: t.type,
      }));
  },

  async courses(env: Env, acct: AccountRow) {
    const c = await canvas<{ id: number; name: string; course_code: string }[]>(env, acct, "/courses?enrollment_state=active&per_page=50");
    return c.map((x) => ({ id: x.id, name: x.name, code: x.course_code }));
  },

  async assignments(env: Env, acct: AccountRow, courseId: number) {
    const a = await canvas<{ id: number; name: string; due_at: string | null; description: string | null; html_url: string; has_submitted_submissions: boolean }[]>(
      env,
      acct,
      `/courses/${courseId}/assignments?per_page=50&order_by=due_at&bucket=future`,
    );
    return a.map((x) => ({ id: x.id, name: x.name, due_at: x.due_at, url: x.html_url, description: (x.description ?? "").slice(0, 2000) }));
  },

  /** Approval-gated: online_text_entry or online_url submissions only. */
  submit: (env: Env, acct: AccountRow, courseId: number, assignmentId: number, submission: { type: "online_text_entry" | "online_url"; body?: string; url?: string }) =>
    canvas<{ id: number; workflow_state: string }>(env, acct, `/courses/${courseId}/assignments/${assignmentId}/submissions`, {
      method: "POST",
      body: JSON.stringify({ submission: { submission_type: submission.type, body: submission.body, url: submission.url } }),
    }),
};
