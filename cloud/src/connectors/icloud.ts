import { connect } from "cloudflare:sockets";
import type { Env } from "../env";
import { accountSecret, type AccountRow } from "../accounts";
import { buildMime, validateRecipients, type MailMessage, type MailSummary, type OutgoingMail } from "./mail";
import { decodeWords, extractText, splitHeaderBody } from "./mime";

/**
 * iCloud Mail over IMAP (imap.mail.me.com:993, TLS) using Workers TCP sockets.
 * Auth: full iCloud address + an app-specific password (appleid.apple.com).
 * Drafts are created by APPENDing to the Drafts mailbox. Sending (SMTP) is not implemented yet.
 */
interface IcloudSecret {
  username: string;
  app_password: string;
}

const latin1 = new TextDecoder("latin1");

export class ImapSession {
  private reader!: ReadableStreamDefaultReader<Uint8Array>;
  private writer!: WritableStreamDefaultWriter<Uint8Array>;
  private socket!: ReturnType<typeof connect>;
  private buf = "";
  private tagN = 0;

  async open(host = "imap.mail.me.com", port = 993) {
    this.socket = connect({ hostname: host, port }, { secureTransport: "on", allowHalfOpen: false });
    this.reader = this.socket.readable.getReader();
    this.writer = this.socket.writable.getWriter();
    await this.readLine(); // server greeting
  }

  private async fill(): Promise<void> {
    const { value, done } = await this.reader.read();
    if (done) throw new Error("IMAP connection closed");
    this.buf += latin1.decode(value, { stream: true });
  }

  private async readLine(): Promise<string> {
    for (;;) {
      const i = this.buf.indexOf("\r\n");
      if (i !== -1) {
        const line = this.buf.slice(0, i);
        this.buf = this.buf.slice(i + 2);
        return line;
      }
      await this.fill();
    }
  }

  private async readBytes(n: number): Promise<string> {
    while (this.buf.length < n) await this.fill();
    const out = this.buf.slice(0, n);
    this.buf = this.buf.slice(n);
    return out;
  }

  private async write(s: string) {
    await this.writer.write(Uint8Array.from(s, (c) => c.charCodeAt(0) & 0xff));
  }

  /**
   * Send a command; return untagged responses with literals inlined as {literal: string} segments.
   * `literal` is used for APPEND (waits for the "+" continuation).
   */
  async cmd(command: string, literal?: string): Promise<{ untagged: { text: string; literals: string[] }[]; status: string }> {
    const tag = `A${++this.tagN}`;
    if (literal !== undefined) {
      const bytes = new TextEncoder().encode(literal);
      await this.write(`${tag} ${command} {${bytes.length}}\r\n`);
      const cont = await this.readLine();
      if (!cont.startsWith("+")) throw new Error(`IMAP APPEND rejected: ${cont}`);
      let bin = "";
      for (const b of bytes) bin += String.fromCharCode(b);
      await this.write(bin + "\r\n");
    } else {
      await this.write(`${tag} ${command}\r\n`);
    }
    const untagged: { text: string; literals: string[] }[] = [];
    for (;;) {
      let line = await this.readLine();
      if (line.startsWith(`${tag} `)) {
        const status = line.slice(tag.length + 1);
        if (!status.startsWith("OK")) throw new Error(`IMAP ${command.split(" ")[0]} failed: ${status}`);
        return { untagged, status };
      }
      const entry = { text: "", literals: [] as string[] };
      // A response may contain several literals: "... {123}" then 123 bytes, then the rest of the line.
      for (;;) {
        const m = line.match(/\{(\d+)\}$/);
        if (!m) {
          entry.text += line;
          break;
        }
        entry.text += line.slice(0, -m[0].length) + `\u0000${entry.literals.length}\u0000`;
        entry.literals.push(await this.readBytes(Number(m[1])));
        line = await this.readLine();
      }
      untagged.push(entry);
    }
  }

  async close() {
    try {
      await this.cmd("LOGOUT");
    } catch {
      /* ignore */
    }
    try {
      await this.socket.close();
    } catch {
      /* ignore */
    }
  }
}

export const q = (s: string) => `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
export const imapDate = (d: Date) => `${d.getUTCDate()}-${MONTHS[d.getUTCMonth()]}-${d.getUTCFullYear()}`;

async function withSession<T>(env: Env, acct: AccountRow, fn: (s: ImapSession) => Promise<T>): Promise<T> {
  const sec = await accountSecret<IcloudSecret>(env, acct);
  const s = new ImapSession();
  await s.open();
  try {
    await s.cmd(`LOGIN ${q(sec.username)} ${q(sec.app_password)}`);
    return await fn(s);
  } finally {
    await s.close();
  }
}

function parseSearch(untagged: { text: string }[]): number[] {
  const line = untagged.find((u) => u.text.startsWith("* SEARCH"));
  return line ? line.text.slice(8).trim().split(/\s+/).filter(Boolean).map(Number) : [];
}

function summariesFromFetch(untagged: { text: string; literals: string[] }[]): MailSummary[] {
  const out: MailSummary[] = [];
  for (const u of untagged) {
    if (!/^\* \d+ FETCH/.test(u.text)) continue;
    const uid = u.text.match(/UID (\d+)/)?.[1];
    if (!uid || !u.literals[0]) continue;
    const { headers } = splitHeaderBody(u.literals[0]);
    const flags = u.text.match(/FLAGS \(([^)]*)\)/)?.[1] ?? "";
    out.push({
      id: uid,
      from: decodeWords(headers["from"] ?? ""),
      to: decodeWords(headers["to"] ?? ""),
      subject: decodeWords(headers["subject"] ?? ""),
      date: headers["date"] ? Date.parse(headers["date"]) || null : null,
      snippet: "",
      unread: !flags.includes("\\Seen"),
    });
  }
  return out.sort((a, b) => (b.date ?? 0) - (a.date ?? 0));
}

/**
 * Translate the Gmail-style query the assistant tends to write ("in:inbox from:x is:unread newer_than:3d
 * rent") into an IMAP mailbox + SEARCH criteria. Unknown operators are ignored rather than searched literally.
 */
export function imapQuery(query: string, nowMs = Date.now()): { mailbox: string; criteria: string } {
  let mailbox = "INBOX";
  const crit: string[] = [];
  const text: string[] = [];
  const tokens = query.match(/(?:[^\s"]+:"[^"]*"|"[^"]*"|\S+)/g) ?? [];
  const days = (v: string) => {
    const m = v.match(/^(\d+)([dmy])$/i);
    if (!m) return null;
    const n = Number(m[1]) * (m[2].toLowerCase() === "d" ? 1 : m[2].toLowerCase() === "m" ? 30 : 365);
    return imapDate(new Date(nowMs - n * 864e5));
  };
  const date = (v: string) => {
    const t = Date.parse(v.replace(/\//g, "-"));
    return Number.isNaN(t) ? null : imapDate(new Date(t));
  };
  for (const raw of tokens) {
    const m = raw.match(/^(-?)([a-z_]+):(.*)$/i);
    if (!m) {
      text.push(raw.replace(/^"|"$/g, ""));
      continue;
    }
    const [, neg, op, valRaw] = m;
    const val = valRaw.replace(/^"|"$/g, "");
    let c: string | null = null;
    switch (op.toLowerCase()) {
      case "in":
        if (/^(sent)$/i.test(val)) mailbox = "Sent Messages";
        else if (/^drafts?$/i.test(val)) mailbox = "Drafts";
        else if (/^(archive)$/i.test(val)) mailbox = "Archive";
        break; // inbox / anywhere → INBOX
      case "from": c = `FROM ${q(val)}`; break;
      case "to": c = `TO ${q(val)}`; break;
      case "cc": c = `CC ${q(val)}`; break;
      case "subject": c = `SUBJECT ${q(val)}`; break;
      case "is":
        c = /^unread$/i.test(val) ? "UNSEEN" : /^read$/i.test(val) ? "SEEN" : /^(starred|flagged)$/i.test(val) ? "FLAGGED" : null;
        break;
      case "newer_than": { const d = days(val); c = d ? `SINCE ${d}` : null; break; }
      case "older_than": { const d = days(val); c = d ? `BEFORE ${d}` : null; break; }
      case "after": { const d = date(val); c = d ? `SINCE ${d}` : null; break; }
      case "before": { const d = date(val); c = d ? `BEFORE ${d}` : null; break; }
      default: break; // label:, category:, has:… have no IMAP equivalent here
    }
    if (c) crit.push(neg ? `NOT ${c}` : c);
  }
  const words = text.join(" ").trim();
  if (words) crit.push(`TEXT ${q(words)}`);
  return { mailbox, criteria: crit.length ? crit.join(" ") : "ALL" };
}

const HEADER_FETCH = "(UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID)])";

export const icloudMail = {
  async search(env: Env, acct: AccountRow, query: string, max = 10): Promise<MailSummary[]> {
    return withSession(env, acct, async (s) => {
      const { mailbox, criteria } = imapQuery(query);
      await s.cmd(`EXAMINE ${q(mailbox)}`); // read-only: never changes \Seen flags
      const uids = parseSearch((await s.cmd(`UID SEARCH CHARSET UTF-8 ${criteria}`)).untagged).slice(-Math.min(max, 25));
      if (!uids.length) return [];
      const found = summariesFromFetch((await s.cmd(`UID FETCH ${uids.join(",")} ${HEADER_FETCH}`)).untagged);
      // UIDs are per mailbox: prefix non-inbox ids so read() opens the right one.
      return mailbox === "INBOX" ? found : found.map((m) => ({ ...m, id: `${mailbox}|${m.id}` }));
    });
  },

  async recent(env: Env, acct: AccountRow, max = 15): Promise<MailSummary[]> {
    return withSession(env, acct, async (s) => {
      await s.cmd("EXAMINE INBOX");
      const uids = parseSearch((await s.cmd(`UID SEARCH SINCE ${imapDate(new Date(Date.now() - 2 * 864e5))}`)).untagged).slice(-max);
      if (!uids.length) return [];
      return summariesFromFetch((await s.cmd(`UID FETCH ${uids.join(",")} ${HEADER_FETCH}`)).untagged);
    });
  },

  async read(env: Env, acct: AccountRow, id: string): Promise<MailMessage> {
    const [mailbox, uid] = id.includes("|") ? [id.slice(0, id.lastIndexOf("|")), id.slice(id.lastIndexOf("|") + 1)] : ["INBOX", id];
    if (!/^\d+$/.test(uid) || !/^[\w .-]{1,60}$/.test(mailbox)) throw new Error("Unrecognised iCloud message id");
    return withSession(env, acct, async (s) => {
      await s.cmd(`EXAMINE ${q(mailbox)}`);
      const r = await s.cmd(`UID FETCH ${uid} (UID FLAGS BODY.PEEK[]<0.200000>)`);
      const u = r.untagged.find((x) => /^\* \d+ FETCH/.test(x.text) && x.literals[0]);
      if (!u) throw new Error(`Message ${uid} not found`);
      const raw = u.literals[0];
      const { headers } = splitHeaderBody(raw);
      return {
        id,
        from: decodeWords(headers["from"] ?? ""),
        to: decodeWords(headers["to"] ?? ""),
        cc: decodeWords(headers["cc"] ?? ""),
        subject: decodeWords(headers["subject"] ?? ""),
        date: headers["date"] ? Date.parse(headers["date"]) || null : null,
        snippet: "",
        message_id_header: headers["message-id"],
        references: headers["references"],
        body: extractText(raw),
      };
    });
  },

  async createDraft(env: Env, acct: AccountRow, mail: OutgoingMail): Promise<{ draft_id: string }> {
    const sec = await accountSecret<IcloudSecret>(env, acct);
    let inReplyToHeader: string | undefined, referencesHeader: string | undefined;
    if (mail.in_reply_to) {
      const orig = await icloudMail.read(env, acct, mail.in_reply_to);
      inReplyToHeader = orig.message_id_header;
      referencesHeader = orig.references;
    }
    const mime = buildMime({
      ...mail,
      from: sec.username,
      to: validateRecipients(mail.to),
      cc: mail.cc ? validateRecipients(mail.cc) : undefined,
      inReplyToHeader,
      referencesHeader,
    });
    const withDate = `Date: ${new Date().toUTCString()}\r\n${mime}`;
    return withSession(env, acct, async (s) => {
      const r = await s.cmd(`APPEND "Drafts" (\\Draft \\Seen)`, withDate);
      const uid = r.status.match(/APPENDUID \d+ (\d+)/)?.[1];
      return { draft_id: uid ? `drafts:${uid}` : "drafts:unknown" };
    });
  },

  /** Verify credentials (used when the account is added). */
  async verify(username: string, appPassword: string): Promise<void> {
    const s = new ImapSession();
    await s.open();
    try {
      await s.cmd(`LOGIN ${q(username)} ${q(appPassword)}`);
    } finally {
      await s.close();
    }
  },
};
