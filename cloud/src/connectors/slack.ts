import type { Env } from "../env";
import { accountSecret, type AccountRow } from "../accounts";

/**
 * Slack via a user token (xoxp-) from a personal Slack app installed to the workspace.
 * Needed user scopes: search:read, channels:history, groups:history, im:history, mpim:history,
 * channels:read, users:read, chat:write (chat:write only used after approval).
 */
interface SlackSecret {
  token: string;
}

async function slack<T>(env: Env, acct: AccountRow, method: string, params: Record<string, string>, post = false): Promise<T> {
  const { token } = await accountSecret<SlackSecret>(env, acct);
  const r = post
    ? await fetch(`https://slack.com/api/${method}`, {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json; charset=utf-8" },
        body: JSON.stringify(params),
      })
    : await fetch(`https://slack.com/api/${method}?${new URLSearchParams(params)}`, { headers: { authorization: `Bearer ${token}` } });
  const j = (await r.json()) as T & { ok: boolean; error?: string };
  if (!j.ok) throw new Error(`Slack ${method}: ${j.error}`);
  return j;
}

export const slackApi = {
  verify: (env: Env, acct: AccountRow) => slack<{ user: string; team: string; user_id: string }>(env, acct, "auth.test", {}),

  async search(env: Env, acct: AccountRow, query: string) {
    const r = await slack<{ messages: { matches: { text: string; username: string; channel: { name: string; id: string }; ts: string; permalink: string }[] } }>(
      env,
      acct,
      "search.messages",
      { query, count: "15", sort: "timestamp" },
    );
    return r.messages.matches.map((m) => ({ channel: m.channel.name, channel_id: m.channel.id, user: m.username, text: m.text, ts: m.ts, link: m.permalink }));
  },

  async history(env: Env, acct: AccountRow, channel: string, limit = 20) {
    const r = await slack<{ messages: { user?: string; text: string; ts: string }[] }>(env, acct, "conversations.history", { channel, limit: String(Math.min(limit, 50)) });
    return r.messages;
  },

  /** Approval-gated. */
  postMessage: (env: Env, acct: AccountRow, channel: string, text: string, threadTs?: string) =>
    slack<{ ts: string; channel: string }>(env, acct, "chat.postMessage", { channel, text, ...(threadTs ? { thread_ts: threadTs } : {}) }, true),
};
