# Setup

Deploy one private backend for yourself, then build and pair your own apps. Use your own accounts and credentials throughout.

Orbit can use Cloudflare Workers Free + D1 and a free Apple Personal Team for development builds. Your ChatGPT plan, provider access, and usage limits are separate; check current provider terms and quotas before deployment.

## 1. Cloudflare (Workers Free + D1)

```bash
cd cloud && npm ci
npx wrangler login
cp wrangler.jsonc wrangler.local.jsonc  # gitignored; holds your account's IDs
npx wrangler d1 create orbit          # paste the printed database_id (and your account_id) into wrangler.local.jsonc
npm run db:migrate:remote
```

Optionally add `"CONTACT_EMAIL": "you@example.com"` under `vars` in `wrangler.local.jsonc`; it is shown on the public privacy page that Google's consent screen links to.

Set secrets with `npx wrangler secret put NAME -c wrangler.local.jsonc`. Each command prompts for the value.

| Secret | Value |
|---|---|
| `ADMIN_TOKEN` | Long random string. Used once to pair your first device. |
| `ENCRYPTION_KEY` | Output of `openssl rand -base64 32`. Encrypts stored account credentials. Back it up: if it's lost, every account must be reconnected. |
| `PUBLIC_BASE_URL` | `https://orbit.<your-subdomain>.workers.dev`, shown after the first deploy. Set it and deploy again. |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | See section 3. |

Deploy with `npm run deploy`. Non-secret settings live under `vars` in `wrangler.jsonc`:
- `OPENAI_MODEL_BASIC` (`gpt-6-luna`) and `OPENAI_MODEL_ADVANCED` (`gpt-6.1-sol`). Check them against your account with `GET /v1/model?verify=1`.
- `ORBIT_TIMEZONE`
- `ORBIT_CALENDAR_NAME`

The backend uses two cron schedules (source polling and minute-by-minute schedules). Check the current [Workers limits](https://developers.cloudflare.com/workers/platform/limits/) and [D1 limits](https://developers.cloudflare.com/d1/platform/limits/) for your plan before deployment.

## 2. Model: Sign in with ChatGPT (official dynamic registration)

No manually registered model client or model API key is needed for this sign-in flow. Orbit uses OpenAI's dynamic client registration for ChatGPT plan usage (developers.openai.com/siwc/token-sharing-open-source).

In the Mac or iPhone app, go to **Settings → AI model → Continue with ChatGPT**:
1. The app starts a listener on `127.0.0.1:1455`. It sends `client_id=dynamic_agent_client` with `agent_name_hint=Orbit` the first time, or the saved issued `oaiapp_…` ID after that, plus a per-device `ext_agent_host_id`, PKCE and a nonce.
2. You approve in the browser: Safari on the Mac, or an in-app sheet on the iPhone. OpenAI redirects back to the app's loopback listener.
3. The app exchanges the code and hands the credentials to the Worker. The Worker validates the ID token against OpenAI's published keys and checks the `chatgpt.tokens.use.direct` scope. From then on, only the Worker refreshes the tokens.
4. **Verify model IDs** checks Luna and Sol against your account's model list.

Plan usage is shared with your other apps under ChatGPT's five-hour limit; see ChatGPT Settings → Usage. When the limit is hit, Orbit says so. There is no paid API fallback. Signing out revokes the session but keeps the client registration, so the next sign-in is quick.

OpenAI's docs describe this flow for open-source and self-hosted apps. Whether a Worker on your own Cloudflare account counts as self-hosted is not confirmed by OpenAI.

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
   - If you later rename the Worker, update this redirect URI and any branding links in Google Cloud before reconnecting Google. Existing connections remain dependent on their saved authorization.
   - Branding links: the Worker serves the home page `https://<worker>/about`, the privacy policy `/privacy` and the terms `/terms`.
6. Set the `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` secrets.
7. In the app, open **Settings → Connect a Google account**. Repeat for each Gmail account; each becomes its own account row.

Refresh tokens can still be revoked: changing your Google password revokes tokens with Gmail scopes, and you can remove access manually. Orbit marks the account as needing attention and notifies you. Reconnecting fixes it.

## 4. Other accounts

All are added in **Settings** in the app. Credentials go to the Worker once and are stored encrypted.

- **iCloud Mail:**
  1. Go to appleid.apple.com → Sign-In and Security → App-Specific Passwords.
  2. In Orbit, enter your full iCloud address and that password. Orbit verifies them with an IMAP login (`imap.mail.me.com:993`).
- **GitHub:** a fine-grained personal access token with read access to Issues, Pull requests and Contents.
  - GitHub's notifications inbox doesn't accept fine-grained tokens, so Orbit shows open issues and pull requests that involve you or request your review instead.
  - Fine-grained tokens only see the repositories you select when creating them. To let Orbit read a private repo such as `you/your-repo`, add it to the token.
  - Add write access only if you want approved comments and merges to work.
- **Canvas:** in Canvas, go to Account → Settings → New Access Token. Enter your school's base URL, for example `https://canvas.example.edu`.
- **Browser Run (optional):** a Cloudflare API token with Browser Rendering/Run permission, set as `CF_BROWSER_TOKEN` and `CF_ACCOUNT_ID`.
  - Free tier: about 10 browser minutes/day.
  - Used only when the model asks to render a JavaScript-heavy page; plain fetch is the default.

## 5. Apple apps (free Personal Team, no paid membership)

```bash
brew install xcodegen
cd apple && xcodegen && open Orbit.xcodeproj
```

1. In Xcode, go to Settings → Accounts and add your Apple ID. This creates a free **Personal Team**.
2. In `project.yml`, set `ORBIT_BUNDLE_PREFIX` to something unique, such as `com.yourname.orbit` (or pass `ORBIT_BUNDLE_PREFIX=com.yourname.orbit` to `xcodebuild`), then run `xcodegen` again.
3. Select your Personal Team under *Signing & Capabilities* for both targets.
4. **Mac:** run the `Orbit-macOS` scheme. It stays in the menu bar as the companion.
5. **iPhone:**
   1. Enable Developer Mode on the phone.
   2. Run the `Orbit-iOS` scheme on your device.
   3. Trust the developer certificate under Settings → General → VPN & Device Management.
6. **Pair:** on the first device, enter the Worker URL and use *First device setup* with the admin token. On other devices, get a one-time code from **Settings → Devices → Pair a device** on a paired device. Codes expire after 10 minutes and work once.
   - If pairing reports a dropped connection, tap Connect again. If the code is then rejected as used, the first attempt went through anyway, so get a new code. The apps switch from HTTP/3 to TCP after such a failure.
7. Grant Calendar, Reminders and Notifications access when asked.

Free Personal Team limits (Apple's membership comparison page):
- iPhone provisioning profiles expire **7 days** after issue, so re-run from Xcode weekly.
- Other device and App ID limits also apply; check Apple’s current membership comparison.
- **No Push Notifications capability.**
- Background modes are available, so opportunistic background refresh is used.
- Whether the development-signed Mac app also stops launching after 7 days is not verified.

## 6. Notifications while the iPhone app is closed (optional)

Already in place:
- Every notification is stored in D1 and syncs to both apps.
- The **Mac companion** posts local notifications as they arrive. These work without a paid membership. Approval notifications have Approve/Deny buttons.
- The iPhone posts local notifications while open and during opportunistic background refresh. iOS decides when that runs: sometimes hours apart, sometimes never.

Options for alerts while the iPhone app is closed:

| Option | Cost | Content privacy | Status |
|---|---|---|---|
| **ntfy.sh** with a long random topic. Install the ntfy iOS app, then set `NTFY_TOPIC_URL`. | Free | Orbit sends only a generic line ("An action is waiting for your approval"). The topic URL acts as the password. | Implemented, untested |
| **Email to yourself** from your own mailbox. iOS Mail push alerts you. | Free | Stays in your mailbox | Not implemented. Would need a policy exception for "send to self only". |
| **iMessage to yourself** through the Mac (Messages via AppleScript) | Free | Apple end-to-end | Not implemented. Only works while the Mac is awake. |
| **APNs** (code present in `notify.ts`) | $99/yr Apple Developer Program | Direct | Requires the paid membership. It may also need an HTTP/2 workaround on Workers. |
| Pushover | One-time app purchase | Third party | Not implemented |

## Keeping your deployment private

The committed Wrangler file is a template. Keep your working `wrangler.local.jsonc`, `.dev.vars`, database exports, pairing details, and generated access tokens ignored. Set a fresh random `ADMIN_TOKEN`; never deploy the example placeholder. Preserve `ENCRYPTION_KEY` when moving an existing database, otherwise saved account credentials cannot be decrypted. Changing a Worker URL also requires updating the app connection settings and Google OAuth redirect URI.
