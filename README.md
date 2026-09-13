# Scrollock

Chrome + iOS Safari Web Extension for a small group of friends. Blocks X, Instagram, and YouTube feeds by default. A Telegram-authenticated friend can unlock one site for a chosen **1–60 minute** duration after providing a reason, with the unblock intent sent to **one fixed Telegram group**.

## What it does

- **X / Twitter:** blocks Home, Explore, and Search timelines.
- **Instagram:** blocks Home, Explore, and Reels.
- **YouTube:** blocks Home, feed pages (including subscriptions), Shorts, and supported recommendation containers beside videos.
- Direct messages, profiles, normal post links, and YouTube watch/search pages remain accessible; direct Reels/Shorts links remain blocked.
- A break applies to that site across tabs in the same browser. Reloading a page or closing the popup does not reset the deadline. Repeated unlock requests reuse the active deadline; another break after expiry sends another report.
- A Telegram unblock-intent report must succeed before an unlock is granted. Manual locking takes effect without sending another report.
- Route changes are detected on single-page apps as well as full navigations. Only feed containers are hidden; the site's navigation and search controls remain usable. A pause notice sits inside the feed area, never over the whole page. Feed selectors may need updates when sites change their markup; unrecognized layouts are not replaced with a whole-page blocker.

**This is cooperative accountability, not tamper-proof parental control.** Anyone can disable/uninstall the extension, revoke website permission, use another browser, or change its code. It cannot observe native X/Instagram/YouTube apps, clicks, likes, watched time, or browser activity outside the permitted sites. Hiding a page does not prevent that site's network requests or necessarily pause already-playing media. Website changes can require updates to supplemental recommendation selectors.

## Reporting and consent

The popup and Telegram login page explain reporting before authorization. Each successful new unlock sends one group message containing the authenticated Telegram user mention, site, selected duration, and trimmed reason. The reason is sent as plain text, not interpreted as markup. Repeated requests during an active lease send nothing and do not extend its deadline. Manual locks and browsing activity send nothing.

During the client rollout, pre-1.1 extensions that omit both duration and reason retain five-minute unlocks. Their report explicitly says “No reason supplied (older extension).” Updated extensions require both fields; partially supplied or invalid fields are rejected. This compatibility path does not collect or report browsing activity.

No browsing paths or activity, message bodies, post content, titles, full URLs, query strings, or search terms are collected or reported. The authenticated compatibility endpoint `POST /api/activity` accepts older clients as a no-op so their active leases are not disrupted. **There is no fabricated “finished” report at expiry**: each page enforces the deadline locally. Intent reports already sent remain in Telegram under the group's retention policy.

## Quick start: local mock Telegram

Requires Node 22+ and current Chrome. The extension has no runtime packages; the server uses only Node built-ins. Playwright and Prettier are development dependencies.

```sh
npm ci
npm run build
```

1. Open Chrome's Extensions page, enable Developer mode, choose **Load unpacked**, and select `dist/chrome`.
2. Copy its extension ID, then start the mock server **on the same computer as Chrome**:

   ```sh
   MOCK_TELEGRAM=1 ALLOWED_ORIGINS=chrome-extension://YOUR_EXTENSION_ID npm start
   ```

3. Pin Scrollock. Open its popup and choose **Connect**.
4. On the explicitly labeled local test page, choose **Authorize fixture user**. Return to the popup and choose **Check login**.
5. Visit one of the supported sites. Its feed should show **Feed blocked**. Choose a duration, enter a reason, and select **Unblock** on the page or in the popup. The extension follows the device's light/dark appearance.
6. The mock server's `/__mock/messages` endpoint returns the reports. It is accessible only from loopback, never in production.

Mock mode refuses `NODE_ENV=production` and non-loopback binding. It is for testing, not a way to authorize real friends. Do not expose the mock server through a public proxy.

## Real Telegram setup

1. Create a bot using **@BotFather**. Keep the token private. Record the bot's **username**, not its numeric ID.
2. Add the bot to your friends' group and make it an administrator, so `getChatMember` reliably verifies other users. Ensure it can send messages.
3. Set the one fixed `TELEGRAM_GROUP_ID` on the server. Everyone uses this destination; neither popup nor API accepts a group override. The real ID and bot credentials are intentionally not invented or committed.
4. Deploy the Cloudflare Worker. Use `/setdomain` in BotFather to register `scrollock.poronga.com.ar` for the [Telegram login widget](https://core.telegram.org/widgets/login-legacy).
5. Copy `.env.example` to `.env` and populate it privately. Use exact Chrome/Firefox extension origins in `ALLOWED_ORIGINS`; never use `*`. Set `ALLOW_SAFARI_EXTENSION_ORIGINS=1` to accept Safari's installation-specific `safari-web-extension://UUID` origins. This allows Safari extensions to reach the API, not ordinary websites, and does not replace Telegram login, group membership or bearer-session checks. To restrict Safari to individual installations instead, omit this flag and add their exact origins to `ALLOWED_ORIGINS`.
6. Start the server and build the extension for that same HTTPS origin:

   ```sh
   npm run deploy
   npm run build:production
   ```

7. Reload/install the built extension on each friend's browser. Choose Connect and log in through Telegram. Only members of the configured group can authenticate. Membership is checked again when creating a new break.

The API host permission is restricted at build time to this server. The bot token never enters the extension. Login signatures use Telegram's documented HMAC/SHA-256 verification, a five-minute freshness window, browser-bound pairing cookies, and persistent replay prevention. Pairing secrets are separate from login URLs. Sessions are opaque random tokens, expire after seven days, and are kept in local extension storage, not synchronized browser storage.

### Cloudflare deployment

```sh
npm ci
node --env-file=.env -e 'process.stdout.write(process.env.TELEGRAM_BOT_TOKEN)' | npx wrangler secret put TELEGRAM_BOT_TOKEN
node --env-file=.env -e 'process.stdout.write(process.env.TELEGRAM_GROUP_ID)' | npx wrangler secret put TELEGRAM_GROUP_ID
npm run deploy
curl https://scrollock.poronga.com.ar/health
```

Pushes to `main` run the complete test suite, build downloadable Chrome and Safari ZIPs, deploy the Worker, check its production health endpoint, and publish the ZIPs on the [repository's latest GitHub Release](https://github.com/matixlol/scrollock/releases/latest). Pull requests run the same checks and build the packages without deploying. Configure this GitHub Actions repository secret:

- `CLOUDFLARE_API_TOKEN` — a least-privilege token scoped to this account and the `poronga.com.ar` zone, with Workers Scripts and Workers Routes edit access

Telegram credentials remain Cloudflare Worker secrets and are not copied to GitHub. Worker deployments preserve them.

The production backend is a Worker at `scrollock.poronga.com.ar`, with a single named Durable Object providing serialized requests and durable SQLite-backed state. Cloudflare provisions DNS and TLS from the custom-domain declaration in `wrangler.jsonc`. The bot token and group ID are Worker secrets; never put them in `wrangler.jsonc`. The committed Chrome public key gives every unpacked copy the stable extension ID `ahdgaahcjnpaegmopigcpgabcjmcilid`, which is the only Chrome origin allowlisted by default. Production enables `ALLOW_SAFARI_EXTENSION_ORIGINS` so each friend's Safari installation can connect without manually registering its random UUID origin.

`GET /health` returns `{"ok":true}`. Do not enable request logging of Telegram callback query strings or authorization headers. The built-in limiter allows 120 requests per minute per connecting IP while the Durable Object is active. Sessions expire after seven days. The Node/Docker backend remains available for local or non-Cloudflare hosting, but production uses the Worker.

## iOS Safari installation

The build produces **`dist/safari`** with the same content/popup code. Target iOS 17+ with current Safari. The containing iPhone app adds optional **Screen Time controls for selected installed apps**: allow access, select individual apps for each site, then request timed unblocks with a reason in Safari. Only Scrollock's shields are removed; parental or other Screen Time limits still apply. App tokens stay on-device and no usage events are monitored. Native relocking uses iOS callbacks, which can be delayed. See [native implementation and distribution requirements](native/README.md). Chrome on iOS does not load this Chrome extension.

### With macOS + Xcode

```sh
API_ORIGIN=https://your-scrollock-server.example npm run build
SAFARI_BUNDLE_ID=ar.com.poronga.Scrollock npm run safari:package
```

The script uses Apple's `safari-web-extension-packager` (previously named `safari-web-extension-converter`) to generate the native iOS containing app and extension target under `safari/`. It references `dist/safari`, so rebuild those resources after JS changes.

Open the generated project, select your Apple signing team for all three targets (app, Safari extension, Device Activity monitor), review manifest compatibility warnings, build, and run on your iPhone. Family Controls and the shared App Group require provisioning; distribution requires Apple's approval. Enable Scrollock in Settings → Apps → Safari → Extensions, grant access to all three websites, and allow its configured API host if Safari requests it. On a site, open Safari's extensions menu to access the popup. Authenticate, return to Safari, and check login.

For friends, distribute a signed build via TestFlight/App Store or your chosen valid Apple development distribution route. Apple Developer membership/signing and each installation's permissions are required; copying an unpacked folder onto an iPhone is not installation.

### Without a Mac

Apple offers a **Safari Web Extension Packager in App Store Connect** for the website-only extension ZIP. It does not include this repository's native Screen Time code or monitor target. Use the Xcode packaging workflow above for the complete app. See [Apple's packaging guide](https://developer.apple.com/documentation/safariservices/converting-a-web-extension-for-safari).

### Upload to TestFlight from a Mac

On a Mac where Xcode is signed into the Apple developer team and the Apple Distribution certificate is available in Keychain, run:

```sh
npm run safari:deploy
```

This runs the checks, makes a production build, regenerates the native Xcode project, signs all three targets using Xcode's automatic signing, assigns a UTC timestamp build number, and uploads it to App Store Connect/TestFlight. Set `BUILD_NUMBER` to override the generated build number or `APPLE_TEAM_ID` to override the default `BQ7842UUHJ` team. Each uploaded build number must be new. Do not strip Screen Time entitlements to work around signing failures.

The GitHub Release's Chrome ZIP is unsigned because Chrome does not sign unpacked extensions. Unzip it before using **Load unpacked**. Automatic signed Chrome installation and updates require a Chrome Web Store listing (or enterprise browser policy), which is intentionally outside this friends-only distribution.

**Verification boundary:** the Safari resources and native Xcode project can be generated on macOS, but signing requires an Apple account in Xcode and Safari behavior must be checked on a real iPhone before TestFlight distribution. Playwright Chromium is not an iOS Safari extension runtime.

For local simulator checks, build the `Scrollock` scheme with `-sdk iphonesimulator CODE_SIGNING_ALLOWED=NO`, install the resulting app with `xcrun simctl install booted`, and enable it in Safari's **Manage Extensions** menu. Grant website access before testing. Check the popup in Safari's half-height sheet: connection and all three feed controls should fit its width, buttons should be touch-sized, and the reporting explanation should be reachable by scrolling. Verify that YouTube search and bottom navigation still respond with the feed paused, and that unlock/expiry restores and hides the feed without replacing the page shell.

## Tests

```sh
npm test
npm run check
npx playwright install chromium
npm run test:e2e
```

The end-to-end test launches a real Chromium browser with the actual unpacked Chrome extension. It does **not** replace extension messaging or storage with mocks. It runs a local mock Telegram server and serves synthetic social pages at matching origins via network interception, without visiting real accounts.

Coverage includes signed login validation/replay, group membership rejection, production mock guard, pairing/session expiry, API input/CORS validation, selected-duration boundaries, persistent leases, concurrent unlock deduplication, all three blocked/unblocked sites, cross-tab state, reloads, closed-popup expiry, manual lock, private-data exclusion, and Telegram reporting failure. E2E may inject a **15-second Node server lease override** to exercise real timer expiry quickly; production expiry uses the selected duration. Test screenshots are written to `.amp/in/artifacts/` for review.

### Real-device release checklist

- Test current signed-in desktop sites and mobile Safari sites, not just fixtures.
- Confirm Home/Explore/Reels/Shorts/feed pages are blocked; direct messages and normal links are accessible.
- Complete real Telegram login as a member; reject a nonmember.
- Unlock each site; confirm one real group intent report with its duration and reason, and no browsing-activity or lock reports.
- Wait for the selected duration with popup closed, reload, switch tabs, background Safari, and resume after the deadline. Confirm the feed relocks.
- Disconnect the server or remove bot posting permission: a new unlock must fail closed.
- Verify browser permission prompts, Safari background execution, origin allowlisting, and your signed distribution build.

## Layout and credits

- `extension/`: shared Web Extension, including blocking rules and unblock forms.
- `native/`: iOS Screen Time settings, Safari bridge, and timed relocking monitor.
- `server/`: Telegram auth, fixed-group reporting, persistence, API tests.
- `scripts/`: browser builds, syntax checks, Safari native packaging.
- `tests/`: rule tests and actual-extension end-to-end test.

Original implementation inspired by the user-mentioned **Blockit** and **News Feed Eradicator/news-feed disablers**. No source code or assets from those products were copied or cloned. Telegram and social-platform names belong to their respective owners; this project is not affiliated with them.

Feed-selector references: [News Feed Eradicator](https://github.com/jordwest/news-feed-eradicator) for X and Instagram's content containers, and [Remove YouTube Suggestions](https://github.com/lawrencehook/remove-youtube-suggestions) for mobile YouTube feed and recommendation containers.
