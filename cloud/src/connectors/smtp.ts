import { connect } from "cloudflare:sockets";

/**
 * Minimal SMTP submission client for Workers TCP sockets: EHLO → STARTTLS → EHLO → AUTH PLAIN
 * → MAIL FROM / RCPT TO → DATA. Used for iCloud Mail (smtp.mail.me.com:587). Credentials stay
 * inside this call and are never logged or returned; error messages omit the AUTH exchange.
 */
export interface SmtpOptions {
  host: string;
  port: number;
  username: string;
  password: string;
  /** Envelope sender (must be the account's address for iCloud). */
  from: string;
  recipients: string[];
  /** Complete RFC 5322 message with CRLF line endings. */
  message: string;
  heloName?: string;
  /** Test hook: provide the socket factory (defaults to cloudflare:sockets). */
  connectFn?: typeof connect;
}

const enc = new TextEncoder();
const dec = new TextDecoder();

export class SmtpError extends Error {
  constructor(public code: number, message: string) {
    super(message);
  }
}

class Conn {
  private reader: ReadableStreamDefaultReader<Uint8Array>;
  private writer: WritableStreamDefaultWriter<Uint8Array>;
  private buf = "";
  constructor(public socket: ReturnType<typeof connect>) {
    this.reader = socket.readable.getReader();
    this.writer = socket.writable.getWriter();
  }
  release() {
    this.reader.releaseLock();
    this.writer.releaseLock();
  }
  async write(s: string) {
    await this.writer.write(enc.encode(s));
  }
  /** Read one (possibly multi-line) reply: "250-…" continues, "250 …" ends. */
  async reply(): Promise<{ code: number; lines: string[] }> {
    const lines: string[] = [];
    for (;;) {
      let i: number;
      while ((i = this.buf.indexOf("\r\n")) === -1) {
        const { value, done } = await this.reader.read();
        if (done) throw new SmtpError(0, "SMTP connection closed unexpectedly");
        this.buf += dec.decode(value, { stream: true });
      }
      const line = this.buf.slice(0, i);
      this.buf = this.buf.slice(i + 2);
      lines.push(line.slice(4));
      if (line[3] !== "-") return { code: Number(line.slice(0, 3)), lines };
    }
  }
  async expect(okCodes: number[], step: string, command?: string): Promise<string[]> {
    if (command !== undefined) await this.write(command + "\r\n");
    const r = await this.reply();
    if (!okCodes.includes(r.code)) throw new SmtpError(r.code, `SMTP ${step} failed (${r.code}): ${r.lines.join(" ").slice(0, 200)}`);
    return r.lines;
  }
}

/** Escape lines that begin with "." (RFC 5321 §4.5.2) and normalise to CRLF. */
export function dotStuff(message: string): string {
  return message.replace(/\r?\n/g, "\r\n").replace(/^\./gm, "..");
}

const b64 = (s: string) => {
  let bin = "";
  for (const b of enc.encode(s)) bin += String.fromCharCode(b);
  return btoa(bin);
};

export async function smtpSend(o: SmtpOptions): Promise<{ accepted: string[]; response: string }> {
  if (!o.recipients.length) throw new Error("No recipients");
  const open = o.connectFn ?? connect;
  const socket = open({ hostname: o.host, port: o.port }, { secureTransport: "starttls", allowHalfOpen: false });
  let c = new Conn(socket);
  try {
    await c.expect([220], "greeting");
    const helo = o.heloName ?? "orbit.local";
    await c.expect([250], "EHLO", `EHLO ${helo}`);
    await c.expect([220], "STARTTLS", "STARTTLS");
    c.release();
    c = new Conn(socket.startTls());
    const caps = await c.expect([250], "EHLO (TLS)", `EHLO ${helo}`);
    const auth = caps.find((l) => /^AUTH\b/i.test(l)) ?? "";
    if (/\bPLAIN\b/i.test(auth)) {
      await c.expect([235], "authentication", `AUTH PLAIN ${b64(`\u0000${o.username}\u0000${o.password}`)}`).catch((e) => {
        throw new SmtpError((e as SmtpError).code ?? 535, "SMTP authentication failed. Check the iCloud app-specific password in Settings.");
      });
    } else {
      await c.expect([334], "authentication", "AUTH LOGIN");
      await c.expect([334], "authentication", b64(o.username));
      await c.expect([235], "authentication", b64(o.password)).catch((e) => {
        throw new SmtpError((e as SmtpError).code ?? 535, "SMTP authentication failed. Check the iCloud app-specific password in Settings.");
      });
    }
    await c.expect([250], "MAIL FROM", `MAIL FROM:<${o.from}>`);
    const accepted: string[] = [];
    for (const r of o.recipients) {
      await c.expect([250, 251], `RCPT TO <${r}>`, `RCPT TO:<${r}>`);
      accepted.push(r);
    }
    await c.expect([354], "DATA", "DATA");
    const body = dotStuff(o.message);
    await c.write(body.endsWith("\r\n") ? body : body + "\r\n");
    const done = await c.expect([250], "message", ".");
    await c.write("QUIT\r\n").catch(() => undefined);
    return { accepted, response: done.join(" ").slice(0, 200) };
  } finally {
    try {
      await socket.close();
    } catch {
      /* ignore */
    }
  }
}

/** Bare addresses from "Name <a@b>, c@d". */
export function envelopeAddresses(list: string): string[] {
  return list
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean)
    .map((a) => a.match(/<([^>]+)>/)?.[1] ?? a);
}
