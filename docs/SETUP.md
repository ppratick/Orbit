# Setup

Every step here is something only you can do: logins, consoles, credentials. Nothing has been deployed or connected for you.

## 1. Cloudflare (Workers Free + D1)

```bash
cd cloud && npm install
npx wrangler login
npx wrangler d1 create orbit          # paste the printed database_id into wrangler.jsonc
npm run db:migrate:remote
```

Set secrets with `npx wrangler secret put NAME`. Each command prompts for the value.

| Secret | Value |
|---|---|
| `ADMIN_TOKEN` | Long random string. Used once to pair your first device. |
| `ENCRYPTION_KEY` | Output of `openssl rand -base64 32`. Encrypts stored account credentials. Back it up: if it's lost, every account must be reconnected. |
| `PUBLIC_BASE_URL` | `https://orbit.<your-subdomain>.workers.dev`, shown after the first deploy. Set it and deploy again. |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | See section 3. |
| `OPENAI_API_KEY` | Leave unset. The paid API fallback is disabled; it would only be used if `OPENAI_AUTH_MODE` were changed. |

Deploy with `npm run deploy`. Non-secret settings live under `vars` in `wrangler.jsonc`:
- `OPENAI_MODEL_BASIC` (`gpt-6-luna`) and `OPENAI_MODEL_ADVANCED` (`gpt-6.1-sol`). Both were confirmed in your account's model list on 2026-11-11.
- `OPENAI_AUTH_MODE`
- `ORBIT_TIMEZONE`
- `ORBIT_CALENDAR_NAME`

Free-plan limits this design relies on:
- 100k requests/day
- 10 ms CPU and 50 D1 queries per invocation
- 5 cron triggers per account; Orbit uses 1
- D1: 5M rows read/day, 100k rows written/day, 500 MB per database

Since 2026-09-01, D1 rejects queries once a daily limit is hit until the 00:00 UTC reset. See STATUS.md for the expected load.

## 2. Model: Sign in with ChatGPT (official dynamic registration)

No client registration, secret or API key is needed. Orbit uses OpenAI's dynamic client registration for ChatGPT plan usage (developers.openai.com/siwc/token-sharing-open-source).

In the Mac or iPhone app, go to **Settings → AI model → Continue with ChatGPT**:
1. The app starts a listener on `127.0.0.1:1455`. It sends `client_id=dynamic_agent_client` with `agent_name_hint=Orbit` the first time, or the saved issued `oaiapp_…` ID after that, plus a per-device `ext_agent_host_id`, PKCE and a nonce.
2. You approve in the browser: Safari on the Mac, or an in-app sheet on the iPhone. OpenAI redirects back to the app's loopback listener.
3. The app exchanges the code and hands the credentials to the Worker. The Worker validates the ID token against OpenAI's published keys and checks the `chatgpt.tokens.use.direct` scope. From then on, only the Worker refreshes the tokens.
4. **Verify model IDs** checks Luna and Sol against your account's model list.

Plan usage is shared with your other apps under ChatGPT's five-hour limit; see ChatGPT Settings → Usage. When the limit is hit, Orbit says so and doesn't switch to the paid API. `OPENAI_AUTH_MODE` stays `chatgpt`. Signing out revokes the session but keeps the client registration, so the next sign-in is quick.

OpenAI's docs describe this flow for open-source and self-hosted apps. Whether a Worker on your own Cloudflare account counts as self-hosted is not confirmed; see STATUS.md.

**Local development:** run `wrangler dev --ip 0.0.0.0` and point the apps at `http://<Mac>.local:8787`. Plain HTTP is accepted only for local and private-network hosts.

## 3. Google (Gmail + Drive): personal-use OAuth app in Production

1. In the Google Cloud console, create a project and enable the **Gmail API** and the **Google Drive API**.
2. Under **Google Auth Platform → Branding**, enter an app name and your email.
3. Under **Audience**, choose user type **External** and **Publish app**, so the status is **In production**.
   - Production avoids Testing mode's 7-day refresh-token expiry.
   - Skip verification for personal use. Consent will show "Google hasn't verified this app": choose *Advanced → Go to Orbit*.
   - Unverified apps are capped at 100 users.
4. Under **Data access**, add these scopes:
   - `gmail.readonly`
   - `gmail.compose` (drafts; sending still requires your approval in Orbit)
   - `drive.readonly`
   - `openid`
   - `email`
5. Under **Clients**, create an OAuth client of type **Web application** with redirect URI `https://<worker>/oauth/google/callback`.
6. Set the `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` secrets.
7. In the app, open **Settings → Connect a Google account**. Repeat for each Gmail account; each becomes its own account row.

Refresh tokens can still be revoked: changing your Google password revokes tokens with Gmail scopes, and you can remove access manually. Orbit marks the account as needing attention and notifies you. Reconnecting fixes it.

## 4. Other accounts

All are added in **Settings** in the app. Credentials go to the Worker once and are stored encrypted.

- **iCloud Mail:**
  1. Go to appleid.apple.com → Sign-In and Security → App-Specific Passwords.
  2. In Orbit, enter your full iCloud address and that password. Orbit verifies them with an IMAP login (`imap.mail.me.com:993`).
- **GitHub:** a fine-grained personal access token.
  - Read-only for reading: Issues, Pull requests, Contents, Notifications.
  - Add write access only if you want approved comments and merges to work.
- **Slack:** create your own Slack app, then install it to your workspace and use its **user** token (`xoxp-`).
  - User scopes: `search:read`, `channels:history`, `groups:history`, `im:history`, `mpim:history`, `channels:read`, `users:read`.
  - Add `chat:write` only if you want approved sends.
- **Canvas:** in Canvas, go to Account → Settings → New Access Token. Enter your school's base URL, for example `https://school.instructure.com`.
- **Browser Run (optional):** a Cloudflare API token with Browser Rendering/Run permission, set as `CF_BROWSER_TOKEN` and `CF_ACCOUNT_ID`.
  - Free tier: about 10 browser minutes/day.
  - Used only when the model asks to render a JavaScript-heavy page; plain fetch is the default.

## 5. Apple apps (free Personal Team, no paid membership)

```bash
brew install xcodegen
cd apple && xcodegen && open Orbit.xcodeproj
```

1. In Xcode, go to Settings → Accounts and add your Apple ID. This creates a free **Personal Team**.
2. In `project.yml`, set `ORBIT_BUNDLE_PREFIX` to something unique, such as `com.ppratick.orbit` (the iPhone test build used `com.ppratick.orbit.ios`), then run `xcodegen` again.
3. Select your Personal Team under *Signing & Capabilities* for both targets.
4. **Mac:** run the `Orbit-macOS` scheme. It stays in the menu bar as the companion.
5. **iPhone:**
   1. Enable Developer Mode on the phone.
   2. Run the `Orbit-iOS` scheme on your device.
   3. Trust the developer certificate under Settings → General → VPN & Device Management.
6. **Pair:** on the first device, enter the Worker URL and the admin token. On the other device, use **Settings → Pair another device** to get a one-time code.
7. Grant Calendar, Reminders and Notifications access when asked.

Free Personal Team limits (Apple's membership comparison page):
- iPhone provisioning profiles expire **7 days** after issue, so re-run from Xcode weekly.
- At most 3 apps per device. Finance Coach was removed from your iPhone to make room for Orbit.
- **No Push Notifications capability.**
- Background modes are available, so opportunistic background refresh is used.
- Whether the development-signed Mac app also stops launching after 7 days is not verified.

## 6. Notifications while the iPhone app is closed (undecided — your call)

Already in place:
- Every notification is stored in D1 and syncs to both apps.
- The **Mac companion** posts local notifications as they arrive. These work without a paid membership. Approval notifications have Approve/Deny buttons.
- The iPhone posts local notifications while open and during opportunistic background refresh. iOS decides when that runs: sometimes hours apart, sometimes never.

Options for alerts while the iPhone app is closed:

| Option | Cost | Content privacy | Status |
|---|---|---|---|
| **ntfy.sh** with a long random topic. Install the ntfy iOS app, then set `NTFY_TOPIC_URL`. | Free | Orbit sends only a generic line ("An action is waiting for your approval"). The topic URL acts as the password. | Implemented, untested |
| **Email to yourself** from your Gmail. iOS Mail push alerts you. | Free | Stays in your mailbox | Not implemented. Would need a policy exception for "send to self only". |
| **iMessage to yourself** through the Mac (Messages via AppleScript) | Free | Apple end-to-end | Not implemented. Only works while the Mac is awake. |
| **APNs** (code present in `notify.ts`) | $99/yr Apple Developer Program | Direct | Blocked: you declined the membership. It may also need an HTTP/2 workaround on Workers. |
| Pushover | One-time app purchase | Third party | Not implemented |
