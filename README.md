# Orbit

A personal AI assistant: native iPhone and Mac apps sharing one assistant. Conversations, memory, tasks, approvals and activity history are shared across both apps. The backend runs on the Cloudflare Workers Free plan with D1 as the source of truth. A heartbeat watches email and ongoing responsibilities while your devices sleep.

```
cloud/   Cloudflare Worker (TypeScript) + D1 migrations + tests
apple/   OrbitKit Swift package + SwiftUI apps for iOS 17 / macOS 14 (XcodeGen project)
docs/    SETUP.md (step by step), STATUS.md (what works / untested / blocked), ARCHITECTURE.md
```

**Start with [docs/STATUS.md](docs/STATUS.md).** It says honestly what has been verified, what has not, and what is blocked.
For deployment and account setup, see [docs/SETUP.md](docs/SETUP.md).

## Local development (backend)

```bash
cd cloud
npm install
npm run typecheck
npm test            # unit tests (policy, crypto, MIME, history replay, URL guard, …)
npm run test:e2e    # boots the real Worker in `wrangler dev` with local D1 and a scripted model stand-in
```

To run it interactively, copy `cloud/.dev.vars.example` to `cloud/.dev.vars`, fill in values, then:

```bash
npm run db:migrate:local
npm run dev
```

The backend is deployed at `https://orbit.mmkjp6pw26.workers.dev` (Cloudflare Workers Free). Redeploy with `npm run deploy` from `cloud/`.
