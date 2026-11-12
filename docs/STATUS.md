# Status (2026-11-12)

Orbit is deployed on Cloudflare Workers Free at `https://orbit.mmkjp6pw26.workers.dev`, with D1 as the source of truth. Your Mac, your iPhone and the iPhone Simulator are paired. Each item below is one of:
- **Verified live:** exercised against the real service.
- **Verified by tests:** covered by automated tests against scripted stand-ins.
- **Not yet verified.**
- **Blocked / not built.**

Tests as of this update:
- `npm test`: 32 unit tests
- `npm run test:e2e`: 34 end-to-end checks against `wrangler dev`
- OrbitKit: 12 Swift tests

## Verified live

| Area | Result |
|---|---|
| Deployment | Worker and D1 on Cloudflare Free; 10-minute cron heartbeat; scheduled briefings delivered (verified by Codex) |
| ChatGPT sign-in | Official dynamic registration from Mac and iPhone; the Worker validates the ID token and owns token refresh; refresh observed live |
| Models | `gpt-6-luna` and `gpt-6.1-sol` confirmed in your account's catalog; Luna for simple turns, Sol for harder or multi-step ones |
| Replies | Streamed live; plain conversational text with no Markdown (instructions, server-side cleanup and plain-text rendering) |
| Gmail (personal + CMU) | Search and read on both accounts; draft created in personal Gmail and confirmed in Drafts; nothing sent. Sending stays approval-gated. |
| iCloud Mail | IMAP over Workers sockets: newest inbox mail, Gmail-style queries (`is:unread newer_than:3d`, `from:`, `subject:`, `in:sent`) translated to IMAP, full message read |
| Google Drive | Most-recently-modified listing (personal + CMU), full-text search, Google Doc text read |
| Canvas | Upcoming deadlines read with local due times (needed `User-Agent: Orbit/0.1` to avoid a 403) |
| GitHub | Open issues and PRs involving you (fallback, since the notifications inbox rejects fine-grained tokens); repository README read. Private repos need to be added to the token. |
| Dates | Tool results carry local times, so replies say "Fri, Nov 13, 11:59 PM" instead of ISO timestamps |
| iPhone Simulator | Pairing, sync of the shared conversation, chat, every integration above, chat stays pinned to the newest message while typing |

Fixed during this round of testing:
- **Simulator pairing:** pairing failed with "network connection lost" because the HTTP/3 (QUIC) connection dropped. The apps now switch to TCP after such a failure, and they never resend a POST automatically, because the first attempt may already have used the single-use code.
- **GitHub:** the issue-search queries were missing `is:issue` / `is:pull-request` (GitHub now returns 422 without them). The private-repo 404 message now explains token scope.
- **Drive:** an empty query now returns the most recently modified files.
- **iCloud:** search previously matched only subject or sender words.
- **Dates:** raw ISO dates appeared in replies.

## Not yet verified live

| Item | Notes |
|---|---|
| Calendar / Reminders actions | EventKit executors and Orbit-calendar policy are covered by tests; live device runs and Mac↔iPhone hand-offs are next |
| Approval-gated sends | Gmail send, GitHub comment/merge and Canvas submit are gated and unit-tested; deliberately not exercised (no test emails) |
| Mac UI | Builds cleanly; this round tested on the iPhone Simulator only |
| Closed-app iPhone notifications | Not built yet; see SETUP.md §6 |
| OpenAI policy for a Worker host | Works technically; OpenAI documents plan usage for open-source and self-hosted apps, and a Worker on your own account isn't explicitly covered |

## Blocked or not built yet

| Item | Reason / plan |
|---|---|
| APNs remote push | Requires the paid Apple Developer Program, which you declined. The code is kept optional in `notify.ts`. Workers' HTTP/2 support for APNs is also unverified. See SETUP.md §6 for alternatives. |
| iCloud Reminders from the cloud | No supported cloud API; upgraded Reminders don't sync over CalDAV. Done on-device with EventKit, routed to Mac/iPhone. |
| iCloud Calendar from the cloud | CalDAV with an app-specific password is possible but not built. The devices upload EventKit snapshots instead. |
| iCloud Mail sending | SMTP not built; Orbit creates drafts you send from Mail. |
| iPhone-only native actions | Only EventKit (calendar/reminders) runs on iPhone. Running Shortcuts on iPhone needs the app in the foreground, so it isn't advertised. |
| Mac browser control | Skipped by decision. The Mac can still open URLs for you. |
| Slack | Removed; not used. |
| GitHub notifications inbox | GitHub doesn't accept fine-grained tokens there; Orbit falls back to issue/PR search. |
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
