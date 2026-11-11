# Status (2026-11-11, updated after on-device testing)

Each capability is in one of three states:
- **Verified locally**: exercised by automated tests against the real Worker code running in `wrangler dev`
  with local D1. The model and OAuth servers are scripted test doubles (`cloud/test/e2e/mock-openai.mjs`), so this
  proves Orbit's logic, not third-party behaviour.
- **Implemented, untested**: the code is written against the provider's documented API, but has never run against
  the real service, because that needs your credentials or a deployment.
- **Blocked / not built**: with the reason.

Nothing is deployed, and no real account has been connected.

## Verified locally (`npm test`: 21 unit tests; `npm run test:e2e`: 33 end-to-end checks)

| Area | What was checked |
|---|---|
| Device auth | Admin-token bootstrap; single-use 10-minute pairing codes; device tokens hashed at rest; revocation |
| Chatbot | Responses-API agent loop: tool calls, parallel calls, history replay with matched call/output pairs, conversation titles |
| Retry safety | Same `client_msg_id` replays the stored reply with no new model call and no duplicate side effects |
| Memory | Preferences/facts with source and dates; model `remember`; edit/delete via the API; memories injected into the system prompt |
| Responsibilities | Created from chat; due items notified exactly once by the heartbeat, then rescheduled |
| Policy | Auto vs approval matrix (unit-tested per action); a non-Orbit calendar, sending, and model-requested deletion all wait for approval; devices can't claim before approval |
| Approvals | Approve/deny from another device; double decisions rejected; params shown to the user; approval bound to the params hash |
| Task routing | `apple` tasks leased to exactly one device; the other device gets nothing; a stale lease token or a different device can't complete; double completion rejected |
| Cloud execution | Approved cloud task executes, fails cleanly (no account) and notifies; non-idempotent sends get `max_attempts = 1` |
| Device → chat | Mac file-read result returns to the conversation as fenced untrusted content, and the assistant continues |
| Sync | Cursor-based incremental sync across all entities; no token hashes, lease tokens or ciphertext leak |
| Search / export | FTS5 conversation search; Markdown export of memory, responsibilities, approvals, activity, notifications and conversations |
| Heartbeat | Cron trigger (`/__scheduled`) runs and records itself; stays under the 44-query budget; phase rotation |
| Google OAuth | Consent URL with offline access and state; forged `state` rejected |
| ChatGPT sign-in | PKCE S256 (mock token server checks the verifier); custom-scheme redirect hand-back; single-use state; tokens never returned; access token used instead of API key; 401 → refresh with rotation → retry; quota 429 → logged API-key fallback (`chatgpt_then_api_key` only) |
| Parsing | MIME multipart/QP/base64/RFC 2047, Gmail payload text, header-injection-safe message building, recipient validation, private-URL blocking |

## Verified live with real services (2026-11-11, local Worker + your Mac and iPhone)

| Check | Result |
|---|---|
| Builds | macOS and iOS apps compile with no warnings (Xcode 27.2). OrbitKit tests (7) pass on macOS and on the iOS Simulator. |
| Mac sign-in | Real dynamic registration: account picker → agent name "Orbit" → loopback callback → code exchange → Worker validated the ID token against OpenAI's JWKS; `chatgpt.tokens.use.direct` granted |
| iPhone sign-in (physical iPhone 17 Pro Max, free Personal Team) | Returning sign-in with the issued client ID in the in-app sheet; consent screen → loopback callback to the app's own listener → credentials imported |
| Model IDs | `gpt-6-luna` and `gpt-6.1-sol` are in your account's catalog (`/v1/model?verify=1`); the catalog also lists gpt-6-astra, gpt-6.1-terra and others |
| Responses API rules | The real API accepted stream=true, store=false, namespaced tools, and replayed tool calls carrying `namespace: "orbit"` |
| Routing | Simple turns → Luna; drafting → Sol (recorded on each reply) |
| Streaming | Live deltas over SSE through the Worker, shown in the iPhone chat (with a "Luna" label) |
| Tools | `remember` tool call → memory saved |
| Cross-device sync | A conversation started on the Mac appeared on the iPhone |
| Not yet observed live | Token refresh against the real token endpoint. The access token lasts 1 hour; refresh logic, serialization and rotation are covered by the e2e mock. Send a message more than an hour after sign-in to confirm. |

Bugs found and fixed during on-device testing: the Mac sidebar couldn't select sections (List selection type mismatch); the apps rejected plain-HTTP local dev servers on the LAN.

## Implemented, untested (needs your credentials and/or a deploy)

| Capability | Notes |
|---|---|
| Running on Cloudflare itself | Only `wrangler dev` was used. The 10 ms CPU and 50-query limits are designed for, but not measured in production. |
| ChatGPT-plan model calls **from Cloudflare** | Verified from a local Worker (`wrangler dev`) on your Mac. Whether OpenAI permits a Worker on your own Cloudflare account (unattended heartbeat included) is unverified: its docs cover open-source and self-hosted apps, and remotely hosted apps go through an interest form. |
| Gmail (multiple accounts) | Search, read, draft (auto), send / send-draft (approval), heartbeat triage of new inbox mail. Production-mode personal-use OAuth app, per your plan. |
| Google Drive | Full-text search including shared drives; read Docs/Sheets/Slides/text |
| iCloud Mail | IMAP over Workers TCP sockets: search, read, recent, draft via APPEND to Drafts. Port 993 isn't on Cloudflare's blocked list, but this hasn't been tried. |
| GitHub | Notifications, issue/PR search and read, file read; comment / create issue / merge (approval) |
| Slack | Search, channel history; post (approval) |
| Canvas | To-dos/upcoming, courses, assignments; heartbeat turns deadlines into responsibilities and Orbit-calendar events; submit (approval) |
| Web research | Plain fetch + HTML→text (default). Browser Run via the REST `/browser-rendering/markdown` endpoint; the endpoint path after the April 2026 rename is unverified. |
| Daily briefing | Generated after 07:00 local time into a "Briefings" conversation, plus a notification |
| ntfy push | Generic text only |

## Blocked or not built yet

| Item | Reason / plan |
|---|---|
| APNs remote push | Requires the paid Apple Developer Program, which you declined. The code is kept optional in `notify.ts`. Workers' HTTP/2 support for APNs is also unverified. See SETUP.md §6 for alternatives. |
| iCloud Reminders from the cloud | No supported cloud API; upgraded Reminders don't sync over CalDAV. Done on-device with EventKit, routed to Mac/iPhone. |
| iCloud Calendar from the cloud | CalDAV with an app-specific password is possible but not built. The devices upload EventKit snapshots instead. |
| iCloud Mail sending | SMTP not built; Orbit creates drafts you send from Mail. |
| iPhone-only native actions | Only EventKit (calendar/reminders) runs on iPhone. Running Shortcuts on iPhone needs the app in the foreground, so it isn't advertised. |
| Mac browser control | Skipped by decision. The Mac can still open URLs for you. |
| Deliveries / returns / refunds / renewals | Detected through email triage, then tracked as responsibilities with reminders. No carrier or merchant APIs. |
| Purchases, account changes | Intentionally no tool. Orbit prepares the work and hands off. |

## Expected Free-plan load (one Mac polling every 20 s + phone)

- Requests: about 9k/day from the Mac (sync + claim), plus 144 cron runs and phone usage. The limit is 100k.
- D1 writes: mostly chat, `last_seen` (throttled to 1/min) and heartbeat rows. Well under 100k/day.
- D1 reads: indexed queries; estimated a few hundred thousand per day against 5M.

## Verified platform facts used in the design

These are from official docs as of November 2026, or search excerpts of them where the page was unreachable.
- **Workers Free:** 100k requests/day; 10 ms CPU per invocation (cron included); 50 external subrequests per invocation; 5 cron triggers per account.
- **D1 Free:** 5M rows read and 100k rows written per day; 500 MB per database; 50 queries per invocation; hard enforcement since 2026-09-01.
- **Browser Rendering** was renamed **Browser Run** on 2026-04-15. Workers Free includes 10 browser-minutes/day and 3 concurrent browsers.
- **EventKit** (iOS 17 / macOS 14): requires `NSCalendarsFullAccessUsageDescription` and `NSRemindersFullAccessUsageDescription`, and has no read-only access.
- **iCloud Mail IMAP:** `imap.mail.me.com:993` with an app-specific password.
- **Free Apple accounts:** no Push Notifications; background modes allowed; 7-day profiles.
- **Gmail scopes:** `gmail.readonly` is restricted. OAuth apps left in Testing (External) get 7-day refresh tokens.
- **ChatGPT Plus** includes no API credits.
