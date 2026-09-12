# Scrollock

A little less feed. A little more life.

Chrome + iOS Safari Web Extension for a small group of friends. Blocks X, Instagram, and YouTube feeds by default. A Telegram-authenticated friend can unlock **one site for five minutes**, with accountability reports sent to **one fixed Telegram group**.

## What it does

- **X / Twitter:** blocks Home, Explore, and Search timelines.
- **Instagram:** blocks Home, Explore, and Reels.
- **YouTube:** blocks Home, feed pages (including subscriptions), Shorts, and supported recommendation containers beside videos.
- Direct messages, profiles, normal post links, and YouTube watch/search pages remain accessible; direct Reels/Shorts links remain blocked.
- A break applies to that site across tabs in the same browser. Reloading a page or closing the popup does not reset the deadline. Repeated unlock requests reuse the active deadline; another break after expiry sends another report.
- A Telegram start report must succeed before an unlock is granted. A detected activity-report failure removes local access. Lock now takes effect locally even if its notification fails.
- Route changes are detected on single-page apps as well as full navigations. Only feed containers are hidden; the site's navigation and search controls remain usable. A pause notice sits inside the feed area, never over the whole page. Feed selectors may need updates when sites change their markup; unrecognized layouts are not replaced with a whole-page blocker.

**This is cooperative accountability, not tamper-proof parental control.** Anyone can disable/uninstall the extension, revoke website permission, use another browser, or change its code. It cannot observe native X/Instagram/YouTube apps, clicks, likes, watched time, or browser activity outside the permitted sites. Hiding a page does not prevent that site's network requests or necessarily pause already-playing media. Website changes can require updates to supplemental recommendation selectors.

## Reporting and consent

The popup and Telegram login page explain reporting before authorization. Group messages contain:

1. Telegram display name and ID, the unlocked site, and the five-minute limit.
2. The first visit to each category during that break: `/feed`, `/watch`, `/search`, `/messages`, or `/other`.
3. A manual lock notification, if delivered.

No message bodies, post content, titles, usernames from visited paths, full URLs, query strings, or search terms are collected. Categories are calculated inside the isolated content script and allowlisted again by the background and server. A `/messages` report only means a messages route was opened. **There is no fabricated “finished” report at expiry**: the start message already states the deadline, and each page enforces it locally. Reports already sent remain in Telegram under the group's retention policy.

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
5. Visit one of the supported sites. Its feed should be paused. Choose **Unlock 5 min** in the popup to reveal that site's feed.
6. The mock server's `/__mock/messages` endpoint returns the reports. It is accessible only from loopback, never in production.

Mock mode refuses `NODE_ENV=production` and non-loopback binding. It is for testing, not a way to authorize real friends. Do not expose the mock server through a public proxy.

## Real Telegram setup

1. Create a bot using **@BotFather**. Keep the token private. Record the bot's **username**, not its numeric ID.
2. Add the bot to your friends' group and make it an administrator, so `getChatMember` reliably verifies other users. Ensure it can send messages.
3. Set the one fixed `TELEGRAM_GROUP_ID` on the server. Everyone uses this destination; neither popup nor API accepts a group override. The real ID and bot credentials are intentionally not invented or committed.
4. Deploy the Cloudflare Worker. Use `/setdomain` in BotFather to register `scrollock.poronga.com.ar` for the [Telegram login widget](https://core.telegram.org/widgets/login-legacy).
5. Copy `.env.example` to `.env` and populate it privately. Use the exact extension origins in `ALLOWED_ORIGINS`; never use `*`. For Safari, inspect `browser.runtime.getURL('')` in the extension's background inspector and remove the trailing slash. Safari origins may differ by installation/build, so allowlist each friend’s actual origin.
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

The production backend is a Worker at `scrollock.poronga.com.ar`, with a single named Durable Object providing serialized requests and durable SQLite-backed state. Cloudflare provisions DNS and TLS from the custom-domain declaration in `wrangler.jsonc`. The bot token and group ID are Worker secrets; never put them in `wrangler.jsonc`. The committed Chrome public key gives every unpacked copy the stable extension ID `ahdgaahcjnpaegmopigcpgabcjmcilid`, which is the only Chrome origin allowlisted by default. Add actual Safari origins to `ALLOWED_ORIGINS` after packaging.

`GET /health` returns `{"ok":true}`. Do not enable request logging of Telegram callback query strings or authorization headers. The built-in limiter allows 120 requests per minute per connecting IP while the Durable Object is active. Sessions expire after seven days. The Node/Docker backend remains available for local or non-Cloudflare hosting, but production uses the Worker.

## iOS Safari installation

The build produces **`dist/safari`** with a nonpersistent Safari background script and the same content/popup code. Target iOS 17+ with current Safari. Safari extensions work in **Safari websites**, not native social apps. Chrome on iOS does not load this Chrome extension.

### With macOS + Xcode

```sh
API_ORIGIN=https://your-scrollock-server.example npm run build
SAFARI_BUNDLE_ID=ar.com.poronga.Scrollock npm run safari:package
```

The script uses Apple's `safari-web-extension-packager` (previously named `safari-web-extension-converter`) to generate the native iOS containing app and extension target under `safari/`. It references `dist/safari`, so rebuild those resources after JS changes.

Open the generated project, select your Apple signing team for both targets, review manifest compatibility warnings, build, and run on your iPhone. Enable Scrollock in Settings → Apps → Safari → Extensions (Settings → Safari on older iOS), grant access to all three websites, and allow its configured API host if Safari requests it. On a site, open Safari's extensions menu to access the popup. Authenticate, return to Safari, and check login.

For friends, distribute a signed build via TestFlight/App Store or your chosen valid Apple development distribution route. Apple Developer membership/signing and each installation's permissions are required; copying an unpacked folder onto an iPhone is not installation.

### Without a Mac

Apple now offers a **Safari Web Extension Packager in App Store Connect**. ZIP the contents of `dist/safari` (manifest at the ZIP root), upload, and follow Apple's packaging/TestFlight workflow. See [Apple's packaging guide](https://developer.apple.com/documentation/safariservices/converting-a-web-extension-for-safari).

### Upload to TestFlight from a Mac

On a Mac where Xcode is signed into the Apple developer team and the Apple Distribution certificate is available in Keychain, run:

```sh
npm run safari:deploy
```

This runs the checks, makes a production build, regenerates the native Xcode project, signs both targets using Xcode's automatic signing, assigns a UTC timestamp build number, and uploads it to App Store Connect/TestFlight. Set `BUILD_NUMBER` to override the generated build number or `APPLE_TEAM_ID` to override the default `BQ7842UUHJ` team. Each uploaded build number must be new.

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

Coverage includes signed login validation/replay, group membership rejection, production mock guard, pairing/session expiry, API input/CORS validation, persistent leases, concurrent unlock deduplication, all three blocked/unblocked sites, cross-tab state, SPA reporting, reloads, closed-popup expiry, manual lock, private-data exclusion, and Telegram reporting failure. E2E injects a **15-second server lease** to exercise real timer expiry quickly; unit tests separately assert the production deadline is exactly **300,000 milliseconds**. Test screenshots are written to `.amp/in/artifacts/` for review.

### Real-device release checklist

- Test current signed-in desktop sites and mobile Safari sites, not just fixtures.
- Confirm Home/Explore/Reels/Shorts/feed pages are blocked; direct messages and normal links are accessible.
- Complete real Telegram login as a member; reject a nonmember.
- Unlock each site; confirm real group start/category reports, no full URLs or contents.
- Wait a full five minutes with popup closed, reload, switch tabs, background Safari, and resume after the deadline. Confirm the feed relocks.
- Disconnect the server or remove bot posting permission: unlock must fail; an existing break must relock when an activity report fails.
- Verify browser permission prompts, Safari background execution, origin allowlisting, and your signed distribution build.

## Layout and credits

- `extension/`: shared Web Extension, including blocking rules and privacy categorization.
- `server/`: Telegram auth, fixed-group reporting, persistence, API tests.
- `scripts/`: browser builds, syntax checks, Safari native packaging.
- `tests/`: rule tests and actual-extension end-to-end test.

Original implementation inspired by the user-mentioned **Blockit** and **News Feed Eradicator/news-feed disablers**. No source code or assets from those products were copied or cloned. Telegram and social-platform names belong to their respective owners; this project is not affiliated with them.

Feed-selector references: [News Feed Eradicator](https://github.com/jordwest/news-feed-eradicator) for X and Instagram's content containers, and [Remove YouTube Suggestions](https://github.com/lawrencehook/remove-youtube-suggestions) for mobile YouTube feed and recommendation containers.
