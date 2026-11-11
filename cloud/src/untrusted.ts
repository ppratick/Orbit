/**
 * External content (email, web pages, Slack, Canvas, files) is data, not instructions.
 * It is fenced before entering model context, and fences inside the content are neutralised
 * so the content cannot "close" the block. Fencing is defence in depth: the real protection
 * is that every consequential action is gated by policy.ts outside the model.
 */
export function untrusted(source: string, content: string, max = 12000): string {
  const clean = content
    .replace(/<\/?untrusted[^>]*>/gi, "[tag removed]")
    .replace(/\u0000/g, "")
    .slice(0, max);
  return `<untrusted source="${source.replace(/[^\w:.@-]/g, "_")}">\n${clean}\n</untrusted>`;
}

export function htmlToText(html: string): string {
  return html
    .replace(/<(script|style|head|noscript)[\s\S]*?<\/\1>/gi, " ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|tr|h\d)>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, " ")
    .replace(/\n\s*\n+/g, "\n\n")
    .trim();
}
