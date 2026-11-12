import { describe, expect, it } from "vitest";
import { dotStuff, envelopeAddresses, smtpSend } from "../../src/connectors/smtp";

/** A scripted SMTP server: answers each client line, records everything the client sent. */
function fakeServer(opts: { authOk?: boolean; caps?: string } = {}) {
  const sent: string[] = [];
  let tls = false;
  const enc = new TextEncoder(), dec = new TextDecoder();
  let push: (s: string) => void = () => {};
  let inData = false, data = "";
  const respond = (line: string) => {
    if (inData) {
      if (line === ".") { inData = false; push("250 2.0.0 Ok: queued\r\n"); } else data += line + "\r\n";
      return;
    }
    sent.push(line);
    if (/^EHLO/.test(line)) push(`250-smtp.test\r\n250-${tls ? (opts.caps ?? "AUTH PLAIN LOGIN") : "STARTTLS"}\r\n250 8BITMIME\r\n`);
    else if (line === "STARTTLS") push("220 2.0.0 Ready to start TLS\r\n");
    else if (/^AUTH PLAIN/.test(line)) push(opts.authOk === false ? "535 5.7.8 Authentication failed\r\n" : "235 2.7.0 Authentication successful\r\n");
    else if (/^(MAIL FROM|RCPT TO)/.test(line)) push("250 2.1.0 Ok\r\n");
    else if (line === "DATA") { inData = true; push("354 End data with <CR><LF>.<CR><LF>\r\n"); }
    else if (line === "QUIT") push("221 Bye\r\n");
  };
  const makeSocket = () => {
    let controller!: ReadableStreamDefaultController<Uint8Array>;
    const readable = new ReadableStream<Uint8Array>({ start: (c) => { controller = c; } });
    push = (s) => controller.enqueue(enc.encode(s));
    let pending = "";
    const writable = new WritableStream<Uint8Array>({
      write(chunk) {
        pending += dec.decode(chunk);
        let i;
        while ((i = pending.indexOf("\r\n")) !== -1) { const l = pending.slice(0, i); pending = pending.slice(i + 2); respond(l); }
      },
    });
    return { readable, writable };
  };
  const plain = makeSocket();
  const socket = {
    ...plain,
    startTls() { tls = true; return makeSocket(); },
    close: async () => {},
  };
  setTimeout(() => push("220 smtp.test ESMTP\r\n"), 0);
  const connectFn = (() => socket) as never;
  return { sent, connectFn, data: () => data };
}

const base = { host: "smtp.test", port: 587, username: "me@icloud.com", password: "app-pass-1234", from: "me@icloud.com" };

describe("SMTP submission", () => {
  it("upgrades with STARTTLS before authenticating, then delivers to every recipient", async () => {
    const srv = fakeServer();
    const msg = "Subject: Hi\r\n\r\nLine one\r\n.leading dot\r\n";
    const r = await smtpSend({ ...base, recipients: ["a@x.com", "b@y.com"], message: msg, connectFn: srv.connectFn });
    expect(r.accepted).toEqual(["a@x.com", "b@y.com"]);
    const order = srv.sent.map((l) => l.split(" ")[0].replace(/:.*/, ""));
    expect(order.slice(0, 4)).toEqual(["EHLO", "STARTTLS", "EHLO", "AUTH"]);
    expect(srv.sent).toContain("MAIL FROM:<me@icloud.com>");
    expect(srv.sent).toContain("RCPT TO:<b@y.com>");
    expect(srv.data()).toContain("\r\n..leading dot\r\n");
  });
  it("reports a clear auth error without echoing credentials", async () => {
    const srv = fakeServer({ authOk: false });
    const err = (await smtpSend({ ...base, recipients: ["a@x.com"], message: "x", connectFn: srv.connectFn }).catch((e) => e)) as Error;
    expect(err.message).toMatch(/authentication failed/i);
    expect(err.message).not.toContain("app-pass-1234");
    expect(srv.sent.some((l) => l.startsWith("MAIL FROM"))).toBe(false);
  });
  it("dot-stuffs and extracts envelope addresses", () => {
    expect(dotStuff("a\n.b\n..c")).toBe("a\r\n..b\r\n...c");
    expect(envelopeAddresses("Sam <sam@x.com>, lee@y.org")).toEqual(["sam@x.com", "lee@y.org"]);
  });
});
