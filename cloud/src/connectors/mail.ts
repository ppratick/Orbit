/** Provider-neutral mail types shared by Gmail and iCloud (IMAP). */
export interface MailSummary {
  id: string;
  thread_id?: string;
  from: string;
  to?: string;
  subject: string;
  date: number | null;
  snippet: string;
  unread?: boolean;
}

export interface MailMessage extends MailSummary {
  cc?: string;
  message_id_header?: string;
  references?: string;
  body: string;
}

export interface OutgoingMail {
  to: string;
  cc?: string;
  subject: string;
  body: string;
  in_reply_to?: string; // provider message id being replied to
  from?: string;
}

/** Build an RFC 5322 message (UTF-8, quoted headers encoded). */
export function buildMime(m: OutgoingMail & { inReplyToHeader?: string; referencesHeader?: string; threadSubject?: string }): string {
  const encodeHeader = (v: string) => (/^[\x20-\x7e]*$/.test(v) ? v : `=?UTF-8?B?${b64Utf8(v)}?=`);
  const clean = (v: string) => v.replace(/[\r\n]+/g, " ").trim(); // prevent header injection
  const lines = [
    m.from ? `From: ${clean(m.from)}` : null,
    `To: ${clean(m.to)}`,
    m.cc ? `Cc: ${clean(m.cc)}` : null,
    `Subject: ${encodeHeader(clean(m.subject))}`,
    m.inReplyToHeader ? `In-Reply-To: ${clean(m.inReplyToHeader)}` : null,
    m.referencesHeader || m.inReplyToHeader ? `References: ${clean(`${m.referencesHeader ?? ""} ${m.inReplyToHeader ?? ""}`)}` : null,
    "MIME-Version: 1.0",
    'Content-Type: text/plain; charset="UTF-8"',
    "Content-Transfer-Encoding: base64",
    "",
    b64Utf8(m.body).replace(/(.{76})/g, "$1\r\n"),
  ].filter((x) => x !== null);
  return lines.join("\r\n");
}

export function b64Utf8(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

export function parseAddressList(v: string): string[] {
  return v
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean);
}

export function validateRecipients(v: string): string {
  const list = parseAddressList(v);
  if (!list.length) throw new Error("At least one recipient is required");
  for (const a of list) {
    const addr = a.match(/<([^>]+)>/)?.[1] ?? a;
    if (!/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(addr)) throw new Error(`Invalid email address: ${a}`);
  }
  return list.join(", ");
}
