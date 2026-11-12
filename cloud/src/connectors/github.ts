import type { Env } from "../env";
import { accountSecret, type AccountRow } from "../accounts";

/** GitHub via a fine-grained personal access token stored encrypted in `accounts`. */
interface GithubSecret {
  token: string;
}

async function gh<T>(env: Env, acct: AccountRow, path: string, init: RequestInit = {}): Promise<T> {
  const { token } = await accountSecret<GithubSecret>(env, acct);
  const r = await fetch(`https://api.github.com${path}`, {
    ...init,
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      "user-agent": "orbit-assistant",
      ...(init.body ? { "content-type": "application/json" } : {}),
    },
  });
  if (r.status === 404 && /^\/repos\//.test(path)) {
    throw new Error("GitHub 404: not found, or the connected token can't see this repository (fine-grained tokens only cover the repositories selected when the token was created)");
  }
  if (!r.ok) throw new Error(`GitHub ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return (r.status === 204 ? null : await r.json()) as T;
}

export interface IssueHit {
  repo: string;
  number: number;
  title: string;
  state: string;
  kind: "pr" | "issue";
  url: string;
  updated_at: string;
}

const repoRe = /^[\w.-]+\/[\w.-]+$/;
function checkRepo(repo: string) {
  if (!repoRe.test(repo)) throw new Error("repo must look like owner/name");
  return repo;
}

export const github = {
  verify: (env: Env, acct: AccountRow) => gh<{ login: string }>(env, acct, "/user"),

  async notifications(env: Env, acct: AccountRow) {
    const n = await gh<{ id: string; reason: string; subject: { title: string; type: string; url: string | null }; repository: { full_name: string }; updated_at: string }[]>(
      env,
      acct,
      "/notifications?per_page=30",
    );
    return n.map((x) => ({ repo: x.repository.full_name, title: x.subject.title, type: x.subject.type, reason: x.reason, updated_at: x.updated_at }));
  },

  /**
   * Notifications inbox, falling back to issue/PR search when the token can't read notifications.
   * GitHub's notifications API rejects fine-grained personal access tokens (403), so for those we show
   * open issues and pull requests that involve the user or request their review instead.
   */
  async activity(env: Env, acct: AccountRow) {
    try {
      return { source: "notifications", items: await github.notifications(env, acct) };
    } catch (e) {
      if (!String(e instanceof Error ? e.message : e).includes("GitHub 403")) throw e;
      // GitHub search now requires an explicit is:issue or is:pull-request qualifier.
      const [reviews, prs, issues] = await Promise.all([
        github.searchIssues(env, acct, "is:pull-request is:open review-requested:@me sort:updated-desc"),
        github.searchIssues(env, acct, "is:pull-request is:open involves:@me sort:updated-desc"),
        github.searchIssues(env, acct, "is:issue is:open involves:@me sort:updated-desc"),
      ]);
      const involved = [...prs, ...issues];
      const seen = new Set<string>();
      const items = [...reviews.map((i) => ({ ...i, reason: "review requested" })), ...involved.map((i) => ({ ...i, reason: "involves you" }))].filter((i) => {
        const k = `${i.repo}#${i.number}`;
        return seen.has(k) ? false : (seen.add(k), true);
      });
      return {
        source: "search",
        note: "This GitHub token can't read the notifications inbox (fine-grained tokens aren't supported there), so these are open issues and pull requests that involve the user or request their review.",
        items,
      };
    }
  },

  async searchIssues(env: Env, acct: AccountRow, rawQuery: string): Promise<IssueHit[]> {
    // GitHub's issue search rejects queries without is:issue / is:pull-request (HTTP 422); search both by default.
    const query = /\b(is|type):(issue|pr|pull-request)\b/i.test(rawQuery) ? rawQuery : null;
    if (!query) {
      const [a, b] = await Promise.all([github.searchIssues(env, acct, `${rawQuery} is:issue`), github.searchIssues(env, acct, `${rawQuery} is:pull-request`)]);
      return [...a, ...b].sort((x, y) => y.updated_at.localeCompare(x.updated_at));
    }
    const r = await gh<{ items: { number: number; title: string; state: string; html_url: string; repository_url: string; updated_at: string; pull_request?: unknown }[] }>(
      env,
      acct,
      `/search/issues?${new URLSearchParams({ q: query, per_page: "15" })}`,
    );
    return r.items.map((i) => ({
      repo: i.repository_url.split("/repos/")[1],
      number: i.number,
      title: i.title,
      state: i.state,
      kind: (i.pull_request ? "pr" : "issue") as IssueHit["kind"],
      url: i.html_url,
      updated_at: i.updated_at,
    }));
  },

  async readIssue(env: Env, acct: AccountRow, repo: string, number: number) {
    const i = await gh<{ title: string; body: string | null; state: string; user: { login: string } }>(env, acct, `/repos/${checkRepo(repo)}/issues/${number}`);
    const comments = await gh<{ user: { login: string }; body: string }[]>(env, acct, `/repos/${checkRepo(repo)}/issues/${number}/comments?per_page=20`);
    return { ...i, user: i.user.login, comments: comments.map((c) => ({ user: c.user.login, body: c.body })) };
  },

  async readFile(env: Env, acct: AccountRow, repo: string, path: string, ref?: string) {
    const f = await gh<{ content?: string; encoding?: string; size: number }>(
      env,
      acct,
      `/repos/${checkRepo(repo)}/contents/${path.split("/").map(encodeURIComponent).join("/")}${ref ? `?ref=${encodeURIComponent(ref)}` : ""}`,
    );
    if (!f.content) return "[Not a file or too large]";
    return new TextDecoder().decode(Uint8Array.from(atob(f.content.replace(/\n/g, "")), (c) => c.charCodeAt(0)));
  },

  // ── Approval-gated actions (only called by executors after policy check) ──
  comment: (env: Env, acct: AccountRow, repo: string, number: number, body: string) =>
    gh<{ html_url: string }>(env, acct, `/repos/${checkRepo(repo)}/issues/${number}/comments`, { method: "POST", body: JSON.stringify({ body }) }),
  createIssue: (env: Env, acct: AccountRow, repo: string, title: string, body: string) =>
    gh<{ html_url: string; number: number }>(env, acct, `/repos/${checkRepo(repo)}/issues`, { method: "POST", body: JSON.stringify({ title, body }) }),
  mergePr: (env: Env, acct: AccountRow, repo: string, number: number, method = "squash") =>
    gh<{ merged: boolean; sha: string }>(env, acct, `/repos/${checkRepo(repo)}/pulls/${number}/merge`, { method: "PUT", body: JSON.stringify({ merge_method: method }) }),
};
