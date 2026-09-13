# Scrollock server

Requires Node 22+ and has no dependencies. Start with `node server/index.mjs`.

Required for real Telegram: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_BOT_USERNAME` (without @), and the fixed `TELEGRAM_GROUP_ID`. Production additionally requires `PUBLIC_ORIGIN` (the externally reachable HTTPS origin) and an explicit comma-separated `ALLOWED_ORIGINS`. Allowed values are Chrome/Firefox extension origins, `safari-web-extension://…`, and localhost HTTP(S) origins. Safari extension origins can vary between development and distribution; inspect the extension's actual runtime origin and list each exact value rather than using `*`.

Optional: `PORT` (8787), `HOST` (0.0.0.0), and `STORE_PATH` (`server/data/store.json`). The atomic JSON store persists opaque 7-day sessions and leases. Pairings are intentionally memory-only and expire in 10 minutes.

For local testing, set `MOCK_TELEGRAM=1`; it is rejected in production and forces a localhost bind. Its login page authorizes user 1001 and `GET /__mock/messages` exposes reports to localhost. Never use mock mode for deployment.

Protocol: `POST /api/pair`; Telegram login at returned `loginUrl`; poll `GET /api/pair/:id` with the pairing bearer secret. Authenticated calls use the returned session bearer token: `POST /api/unlock` with `{site,minutes,reason}` and `POST /api/lock` with `{unlockId}`. `minutes` is a required integer from 1 through 60; `reason` is required, trimmed, nonempty, and at most 280 characters. A new lease reports only the unblock intent (user mention, site, selected duration, and plain-text reason), and reporting and membership checks fail closed. Repeated requests return an active lease without extending it or reporting again. `POST /api/activity` remains an authenticated no-op for compatibility with older clients; it does not inspect, store, or report its body. Manual locks are not reported.

Compatibility: requests from pre-1.1 clients that omit both `minutes` and `reason` keep five-minute unlocks, with the explicit report “No reason supplied (older extension).” Supplying only one field is still invalid. Updated clients require both fields.

Run one process with persistent writable storage when using this Node backend. Per-user operations are serialized to prevent concurrent duplicate leases/reports. Real logins are browser-cookie-bound, signature/freshness-verified, membership-checked, and protected against replay across server restarts. Mock mode bypasses real Telegram authorization and must never be exposed through a public proxy. The production Cloudflare deployment uses `worker/index.mjs` and a Durable Object instead; see the [root README](../README.md) for deployment, privacy, installation, and test instructions.
