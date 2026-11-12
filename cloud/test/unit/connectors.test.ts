import { describe, expect, it } from "vitest";
import { imapQuery } from "../../src/connectors/icloud";
import { localTime } from "../../src/agent/tools";
import type { Env } from "../../src/env";

const NOW = Date.UTC(2026, 10, 12, 17, 0); // 2026-11-12 12:00 EST

describe("iCloud IMAP query translation", () => {
  it("treats empty and inbox-only queries as the newest inbox mail", () => {
    expect(imapQuery("", NOW)).toEqual({ mailbox: "INBOX", criteria: "ALL" });
    expect(imapQuery("in:inbox", NOW)).toEqual({ mailbox: "INBOX", criteria: "ALL" });
  });
  it("maps Gmail-style operators to IMAP criteria", () => {
    expect(imapQuery('in:inbox from:google subject:"Security alert" is:unread newer_than:3d', NOW)).toEqual({
      mailbox: "INBOX",
      criteria: 'FROM "google" SUBJECT "Security alert" UNSEEN SINCE 9-Nov-2026',
    });
    expect(imapQuery("rent receipt -is:read before:2026/11/01", NOW).criteria).toBe('NOT SEEN BEFORE 1-Nov-2026 TEXT "rent receipt"');
  });
  it("selects other mailboxes and ignores operators IMAP can't express", () => {
    expect(imapQuery("in:sent to:sam@example.com", NOW)).toEqual({ mailbox: "Sent Messages", criteria: 'TO "sam@example.com"' });
    expect(imapQuery("in:drafts label:work category:primary has:attachment", NOW)).toEqual({ mailbox: "Drafts", criteria: "ALL" });
  });
  it("quotes values safely", () => {
    expect(imapQuery("from:o'brien", NOW).criteria).toBe('FROM "o\'brien"');
    expect(imapQuery("subject:x\"y", NOW).criteria).toBe('SUBJECT "x\\"y"');
  });
});

describe("localTime", () => {
  const env = { ORBIT_TIMEZONE: "America/New_York" } as Env;
  it("formats ISO and epoch values in the user's time zone", () => {
    expect(localTime(env, "2026-11-14T04:59:59Z")).toBe("Fri, Nov 13, 11:59 PM");
    expect(localTime(env, 1794463486000)).toMatch(/^Thu, Nov 12, /);
    expect(localTime(env, null)).toBeNull();
    expect(localTime(env, "not a date")).toBeNull();
  });
});

import { vi, afterEach } from "vitest";
import { github } from "../../src/connectors/github";
import { encryptSecret } from "../../src/crypto";
import type { AccountRow } from "../../src/accounts";

describe("GitHub connector", () => {
  const env = { ENCRYPTION_KEY: Buffer.alloc(32, 3).toString("base64") } as Env;
  const acct = async () => ({ id: "a", provider: "github", label: "", identity: "me", scopes: null, secret_ct: await encryptSecret(env, { token: "t" }), config: "{}", status: "active", last_error: null, sync_state: "{}", last_sync_at: null }) as AccountRow;
  afterEach(() => vi.unstubAllGlobals());

  it("always sends is:issue / is:pull-request (GitHub rejects bare queries with 422)", async () => {
    const queries: string[] = [];
    vi.stubGlobal("fetch", async (url: string) => {
      const q = new URL(url).searchParams.get("q") ?? "";
      queries.push(q);
      if (!/is:(issue|pull-request)/.test(q)) return new Response('{"message":"Query must include is:issue"}', { status: 422 });
      return Response.json({ items: [{ number: 1, title: q.includes("pull") ? "PR" : "Issue", state: "open", html_url: "u", repository_url: "https://api.github.com/repos/o/r", updated_at: "2026-01-01" }] });
    });
    const hits = await github.searchIssues(env, await acct(), "is:open involves:@me");
    expect(hits.map((h) => h.title).sort()).toEqual(["Issue", "PR"]);
    expect(queries.every((q) => /is:(issue|pull-request)/.test(q))).toBe(true);
  });

  it("falls back to involved issues/PRs when notifications are forbidden for the token", async () => {
    vi.stubGlobal("fetch", async (url: string) => {
      if (url.includes("/notifications")) return new Response('{"message":"Resource not accessible by personal access token"}', { status: 403 });
      return Response.json({ items: [{ number: 7, title: "Fix", state: "open", html_url: "u", repository_url: "https://api.github.com/repos/o/r", updated_at: "2026-01-01" }] });
    });
    const r = await github.activity(env, await acct());
    expect(r.source).toBe("search");
    expect(r.items[0]).toMatchObject({ repo: "o/r", number: 7 });
    expect(r.items).toHaveLength(1); // de-duplicated across the review/involves queries
  });
});

import { editDistance } from "../../src/agent/tools";
describe("event id tolerance", () => {
  it("measures small copying slips and stops early on big differences", () => {
    const real = "740A34F7-66DA-40F2-88CB-A0C2253B6154:6676FF56-8923-4EAC-A4BC-0B435761DFF4";
    expect(editDistance(real, real.replace("A4BC", "A4CB"), 2)).toBe(2);
    expect(editDistance(real, "10D81026-EB8B-484C-80E0-0EDA244D59F6:72DBFB29-8FE8-4C27-BE09-F2FF0F3DE04D", 2)).toBe(3);
  });
});
