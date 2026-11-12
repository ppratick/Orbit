/** Public app information for Google's OAuth consent screen; never renders account data. */
const pages: Record<string, { title: string; body: string }> = {
  "/about": {
    title: "Orbit — personal AI assistant",
    body: `<p>Orbit is a private personal assistant with native iPhone and Mac apps. Its owner can connect Gmail and Google Drive to find relevant messages and files, draft replies, and receive briefings in one ongoing conversation.</p><p>Orbit uses a personally operated Cloudflare backend and OpenAI models. It is not a public service and does not offer public account registration. Access to private features requires an authorized paired device.</p><p>Google access is optional and requires account consent. Gmail access supports reading messages, managing drafts and approved sending. Drive access is read-only.</p>`,
  },
  "/privacy": {
    title: "Orbit privacy policy",
    body: `<p>Orbit is operated for its owner's personal use. This policy describes the current assistant and its Google integration.</p><h2>Data accessed and used</h2><p>With account authorization, Orbit accesses the connected account's email address, Gmail messages and drafts, and Google Drive files. It uses this data to provide email and file search, summaries, drafts, approved sends, reminders and briefings requested or configured by the owner.</p><h2>Storage and processing</h2><p>Connected-account credentials are encrypted in the owner's Cloudflare database. Chat history, saved memory and related assistant records are stored in that database and cached on paired devices. Relevant content may be sent to OpenAI to generate responses and perform assistant tasks. Cloudflare processes requests and operational logs as the hosting provider.</p><h2>Sharing</h2><p>Orbit does not sell Google user data or use it for advertising. Data is processed through the services needed to provide the assistant, or sent to a recipient when the owner authorizes an action. Private account data is not published on these pages.</p><h2>Control and retention</h2><p>The owner can revoke Google access in Google Account settings or disconnect an account in Orbit. Disconnecting clears its stored connector credentials. Chat, memory and activity records may remain afterward; the owner manages their retention in the self-hosted database. Device credentials can also be revoked in Orbit.</p><h2>Contact</h2><p>Questions about this personal application can be sent to <a href="mailto:ppratickkafley2@gmail.com">ppratickkafley2@gmail.com</a>.</p>`,
  },
  "/terms": {
    title: "Orbit personal-use terms",
    body: `<p>Orbit is a privately operated personal assistant, not a service offered to the general public. There is no public sign-up. Only its owner and authorized paired devices may access private features.</p><p>Connect only accounts you are authorized to use. Use of connected services remains subject to those services' terms and applicable organizational rules.</p><p>AI responses can be inaccurate. Review generated content and proposed actions. Approval-gated actions are subject to the owner's confirmation in Orbit.</p><p>Operation depends on connected services, account permissions and availability. The owner can disconnect accounts and revoke paired devices. Data handling is described in the <a href="/privacy">privacy policy</a>.</p>`,
  },
};

export function publicPage(path: string): Response | null {
  const page = pages[path];
  if (!page) return null;
  return new Response(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${page.title}</title><style>:root{color-scheme:light dark}body{font:17px/1.65 system-ui,-apple-system,sans-serif;max-width:44rem;margin:3rem auto;padding:0 1.4rem}nav{display:flex;gap:1.2rem;flex-wrap:wrap;font-size:15px}a{color:inherit;text-underline-offset:4px}h1{font-size:2rem;line-height:1.2;margin-top:2rem}h2{font-size:1.15rem;margin-top:2rem}footer{margin-top:3rem;opacity:.65;font-size:14px}</style></head><body><nav><a href="/about">Orbit</a><a href="/privacy">Privacy</a><a href="/terms">Terms</a></nav><main><h1>${page.title}</h1>${page.body}</main><footer>Personal application · Updated November 12, 2026</footer></body></html>`, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=300",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    },
  });
}
