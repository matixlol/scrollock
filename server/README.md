# Scrollock server

Requires Node 22+ and has no dependencies. Start with `node server/index.mjs`.

Required for real Telegram: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_BOT_USERNAME` (without @), and the fixed `TELEGRAM_GROUP_ID`. Production additionally requires `PUBLIC_ORIGIN` (the externally reachable HTTPS origin) and an explicit comma-separated `ALLOWED_ORIGINS`. Allowed values are Chrome/Firefox extension origins, `safari-web-extension://…`, and localhost HTTP(S) origins. Safari extension origins can vary between development and distribution; inspect the extension's actual runtime origin and list each exact value rather than using `*`.

Optional: `PORT` (8787), `HOST` (0.0.0.0), and `STORE_PATH` (`server/data/store.json`). The atomic JSON store persists opaque 7-day sessions and leases. Pairings are intentionally memory-only and expire in 10 minutes.

For local testing, set `MOCK_TELEGRAM=1`; it is rejected in production and forces a localhost bind. Its login page authorizes user 1001 and `GET /__mock/messages` exposes reports to localhost. Never use mock mode for deployment.

Protocol: `POST /api/pair`; Telegram login at returned `loginUrl`; poll `GET /api/pair/:id` with the pairing bearer secret. Authenticated calls use the returned session bearer token: `POST /api/unlock` with `{site}`, `POST /api/activity` with `{unlockId,path}`, and `POST /api/lock` with `{unlockId}`. Unlocks last exactly five minutes and repeated unlock requests return the existing lease without extending it. `path` is restricted to `/feed`, `/watch`, `/messages`, `/search`, or `/other`, not arbitrary browsing paths. Each category reports at most once per lease.

Run one process with persistent writable storage when using this Node backend. Per-user operations are serialized to prevent concurrent duplicate leases/reports. Real logins are browser-cookie-bound, signature/freshness-verified, membership-checked, and protected against replay across server restarts. Mock mode bypasses real Telegram authorization and must never be exposed through a public proxy. The production Cloudflare deployment uses `worker/index.mjs` and a Durable Object instead; see the [root README](../README.md) for deployment, privacy, installation, and test instructions.
