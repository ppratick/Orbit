/**
 * Orbit replies like a text message: plain conversational prose. The model is instructed not to use
 * Markdown; this is the safety net for anything that slips through, applied before a reply is stored.
 * Kept in sync with PlainText.swift (used for the live streaming bubble).
 */
export function toPlainText(input: string): string {
  let s = input.replace(/\r\n/g, "\n");
  s = s.replace(/```[a-zA-Z0-9_-]*\n?([\s\S]*?)```/g, (_, code: string) => code.trim()); // fenced code → contents
  s = s.replace(/`([^`\n]+)`/g, "$1"); // inline code
  s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, "$1"); // images → alt text
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, text: string, url: string) => (text === url ? url : `${text} (${url})`)); // links
  s = s.replace(/^[ \t]{0,3}#{1,6}[ \t]+/gm, ""); // headings
  s = s.replace(/^[ \t]{0,3}>[ \t]?/gm, ""); // block quotes
  s = s.replace(/^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$\n?/gm, ""); // horizontal rules
  s = s.replace(/^[ \t]*[-*+•][ \t]+/gm, ""); // bullet markers
  s = s.replace(/(\*\*|__)(?=\S)([\s\S]*?\S)\1/g, "$2"); // bold
  s = s.replace(/(^|[^\w*])\*(?=\S)([^*\n]*?\S)\*(?!\w)/g, "$1$2"); // *italic*
  s = s.replace(/(^|[^\w])_(?=\S)([^_\n]*?\S)_(?!\w)/g, "$1$2"); // _italic_
  s = s.replace(/~~(?=\S)([\s\S]*?\S)~~/g, "$1"); // strikethrough
  s = s.replace(/^\|?([ \t]*:?-{3,}:?[ \t]*\|)+[ \t]*:?-{0,}:?[ \t]*\|?$\n?/gm, ""); // table separator rows
  s = s.replace(/^\|(.*)\|$/gm, (_, row: string) => row.split("|").map((c) => c.trim()).filter(Boolean).join(", ")); // table rows
  s = s.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n");
  return s.trim();
}
