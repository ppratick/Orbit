import { htmlToText } from "../untrusted";

/** Minimal MIME parsing for IMAP-fetched messages (headers, multipart, QP/base64, RFC 2047 words). */
export function splitHeaderBody(raw: string): { headers: Record<string, string>; body: string } {
  const idx = raw.search(/\r?\n\r?\n/);
  const head = idx === -1 ? raw : raw.slice(0, idx);
  const body = idx === -1 ? "" : raw.slice(idx).replace(/^\r?\n\r?\n/, "");
  const headers: Record<string, string> = {};
  for (const line of head.replace(/\r?\n[ \t]+/g, " ").split(/\r?\n/)) {
    const m = line.match(/^([\w-]+):\s*(.*)$/);
    if (m) headers[m[1].toLowerCase()] = m[2];
  }
  return { headers, body };
}

export function decodeWords(v: string): string {
  return v.replace(/\?=\s+=\?/g, "?==?").replace(/=\?([^?]+)\?([BbQq])\?([^?]*)\?=/g, (_, charset: string, enc: string, text: string) => {
    try {
      const bytes =
        enc.toUpperCase() === "B"
          ? Uint8Array.from(atob(text), (c) => c.charCodeAt(0))
          : qpBytes(text.replace(/_/g, " "));
      return new TextDecoder(charset.toLowerCase()).decode(bytes);
    } catch {
      return text;
    }
  });
}

function qpBytes(s: string): Uint8Array {
  const out: number[] = [];
  const src = s.replace(/=\r?\n/g, "");
  for (let i = 0; i < src.length; i++) {
    if (src[i] === "=" && /^[0-9A-Fa-f]{2}$/.test(src.slice(i + 1, i + 3))) {
      out.push(parseInt(src.slice(i + 1, i + 3), 16));
      i += 2;
    } else out.push(src.charCodeAt(i) & 0xff);
  }
  return new Uint8Array(out);
}

function charsetOf(ct: string) {
  return ct.match(/charset="?([^";\s]+)"?/i)?.[1]?.toLowerCase() ?? "utf-8";
}

function decodePart(body: string, headers: Record<string, string>): string {
  const cte = (headers["content-transfer-encoding"] ?? "").toLowerCase();
  const charset = charsetOf(headers["content-type"] ?? "");
  let bytes: Uint8Array;
  if (cte === "base64") {
    try {
      bytes = Uint8Array.from(atob(body.replace(/\s+/g, "")), (c) => c.charCodeAt(0));
    } catch {
      return body;
    }
  } else if (cte === "quoted-printable") bytes = qpBytes(body);
  else bytes = Uint8Array.from(body, (c) => c.charCodeAt(0) & 0xff);
  try {
    return new TextDecoder(charset).decode(bytes);
  } catch {
    return new TextDecoder().decode(bytes);
  }
}

/** Return the best plain-text rendering of a raw (latin1-decoded) RFC 822 message or MIME part. */
export function extractText(raw: string, depth = 0): string {
  const { headers, body } = splitHeaderBody(raw);
  const ct = headers["content-type"] ?? "text/plain";
  if (/^multipart\//i.test(ct) && depth < 5) {
    const boundary = ct.match(/boundary="?([^";]+)"?/i)?.[1];
    if (!boundary) return body;
    const parts = body.split(`--${boundary}`).slice(1).filter((p) => !p.startsWith("--"));
    const texts = parts.map((p) => ({ ct: splitHeaderBody(p.replace(/^\r?\n/, "")).headers["content-type"] ?? "text/plain", p: p.replace(/^\r?\n/, "") }));
    const plain = texts.find((t) => /^text\/plain/i.test(t.ct));
    if (plain) return extractText(plain.p, depth + 1);
    for (const t of texts) {
      const r = extractText(t.p, depth + 1);
      if (r.trim()) return r;
    }
    return "";
  }
  if (/^text\/html/i.test(ct)) return htmlToText(decodePart(body, headers));
  if (/^text\//i.test(ct)) return decodePart(body, headers);
  return "";
}
