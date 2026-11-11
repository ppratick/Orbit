# Architecture

```
 iPhone app ─┐                         ┌─ OpenAI Responses API (ChatGPT sign-in token, or API key)
             ├─ HTTPS (device token) ─▶│  Cloudflare Worker ──▶ D1 (source of truth)
 Mac app ────┘    sync / chat /        │   ├─ agent loop + tools ──▶ policy engine ──▶ task queue
 (menu-bar        approvals /          │   ├─ connectors: Gmail, Drive, iCloud IMAP, GitHub, Slack, Canvas, web
  companion)      device tasks         │   └─ cron every 10 min → heartbeat phases (email · responsibilities · briefing)
```

## Core ideas

**One assistant, one database.** Every conversation, message, memory, responsibility, task, approval,
notification and activity row lives in D1. SQL triggers write each change to `change_log`. Devices sync
incrementally with `GET /v1/sync?since=<cursor>` and keep a disk cache, so the apps open instantly and
can be read offline.

**Permissions are enforced outside the model** (`cloud/src/policy.ts`, `cloud/src/tasks.ts`).
- The model can only *request* side-effecting actions through tools. Each request becomes a task.
- The policy decides whether a task runs right away or waits for approval:
  - *Auto:* reads, research, drafts, reminders, events on the dedicated "Orbit" calendar, allow-listed Mac scripts.
  - *Ask:* sending, editing or deleting existing items, overwriting files, coursework submission, merges, arbitrary commands, Shortcuts.
- Approvals happen only through authenticated device endpoints. The model has no approve tool.
- An approval is bound to a SHA-256 hash of the exact parameters. Executors re-check the hash and the
  approval immediately before acting, both in the cloud and when handing tasks to devices.
- Purchases and account changes have no tool at all. Orbit prepares the work and hands off, for example by opening the page on the Mac.

**Credentials stay out of model context.**
- Account secrets are encrypted with AES-256-GCM in D1, using the `ENCRYPTION_KEY` Worker secret.
- They are decrypted only inside connector calls, and are never returned by the API or placed in prompts.
- Devices hold only their own device token, in the Keychain.

**Untrusted content.** Email, web, Slack, Canvas, Drive and device output is wrapped in `<untrusted>` fences, and the
system prompt tells the model to treat it as data. This is defence in depth only. The real protection is that
anything consequential still needs an approval the model cannot grant.

**Routing and duplicate prevention.**
- Tasks target `cloud`, `mac`, `iphone`, or `apple` (any Apple device). Devices claim work they advertise capabilities for.
- Each task is leased to one device at a time (5-minute lease, extended while running). Completion requires the
  current lease token, so a stale device after a hand-off is rejected.
- Creation is idempotent per tool call (`call:<conversation>:<call id>`). Chat turns are idempotent per
  `client_msg_id`: a retried send replays the stored reply.
- Non-idempotent actions such as sending are never auto-retried. Device actions are made idempotent with
  markers, for example `orbit://task/<id>` on calendar events and reminders.

**Respecting iOS limits.**
- The cloud does all background and scheduled work.
- The iPhone syncs while open and during opportunistic `BGAppRefresh`.
- The Mac companion runs from the menu bar and polls every 20 seconds, so `apple` tasks usually run on the Mac.
- Apple Calendar and Reminders snapshots are uploaded every 15 minutes, so the cloud assistant can see your schedule.

**Free-plan budget.**
- Workers Free allows 50 D1 queries and about 10 ms CPU per invocation.
- The cron therefore fires every 10 minutes and rotates three phases, so each runs about every 30 minutes.
- A query-budget wrapper (`budget.ts`) stops a run before the limit.
- Chat turns buffer their writes and flush them in one batch.
