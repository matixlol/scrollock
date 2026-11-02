# Scrollock

Chrome + iOS Safari Web Extension for a small group of friends. Blocks X, Instagram, and YouTube feeds by default. A Telegram-authenticated friend can unlock one site for a chosen **1–60 minute** duration after providing a reason, with the unblock intent sent to **one fixed Telegram group**.

## Download and update

**[Download the latest Chrome ZIP](https://github.com/matixlol/scrollock/releases/latest/download/scrollock-chrome.zip)** · [Latest build and release notes](https://github.com/matixlol/scrollock/releases/latest)

Every passing GitHub build on `main` automatically publishes a versioned extension package. The download URL stays the same between builds. The popup shows the installed version and has a **Download / update** link to the [download instructions](https://scrollock.poronga.com.ar/downloads).

To update Chrome without losing your Telegram connection:

1. Download and unzip the latest package.
2. Copy its contents into **the same folder you originally loaded**, replacing the old files. Keep `manifest.json` directly inside that folder, not inside another nested folder.
3. Open `chrome://extensions`, enable Developer mode, and click **Reload** on Scrollock.
4. Refresh your open X, Instagram, and YouTube tabs. Check the version in the Scrollock popup against the build number in the release notes.

**Do not remove/reinstall the extension.** Replacing its files and reloading preserves local extension storage, including Telegram login and unlock deadlines. For a first installation, unzip into a permanent folder and select it with **Load unpacked** at `chrome://extensions`. Chrome does not silently update unpacked extensions.

**Safari / iPhone:** update the signed Scrollock app through TestFlight; enable Automatic Updates there if desired. The [Safari source ZIP](https://github.com/matixlol/scrollock/releases/latest/download/scrollock-safari.zip) is for developer packaging, not direct iPhone installation.

## What it does

- **X / Twitter:** blocks Home and Explore timelines plus sidebar news and trends. Search stays accessible.
- **Instagram:** blocks Home, Explore, and Reels.
- **YouTube:** blocks Home, feed pages (including subscriptions), Shorts, and supported recommendation containers beside videos.
- Direct messages, profiles, normal post links, individual Instagram Reel links, X search, and YouTube watch/search pages remain accessible; YouTube Shorts links remain blocked.
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
2. Copy its extension ID, then start the mock server **on the same computer as Chrome**. The committed Chrome key pins the ID, so it is always `ahdgaahcjnpaegmopigcpgabcjmcilid`; a mismatch here makes unblock attempts fail instantly with "Failed to fetch":

   ```sh
   MOCK_TELEGRAM=1 ALLOWED_ORIGINS=chrome-extension://ahdgaahcjnpaegmopigcpgabcjmcilid npm start
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

Pushes to `main` run the complete test suite and build downloadable Chrome and Safari ZIPs. CI appends its run number to the extension version (for example `1.1.1.42`) so each build is identifiable. After verification, publishing the ZIPs on the [repository's latest GitHub Release](https://github.com/matixlol/scrollock/releases/latest) and deploying the Worker run independently: a backend deployment failure does not block extension downloads. Pull requests run the same checks and build the packages without deploying or publishing a release. Configure this GitHub Actions repository secret:

- `CLOUDFLARE_API_TOKEN` — a least-privilege token scoped to this account and the `poronga.com.ar` zone, with Workers Scripts and Workers Routes edit access

Telegram credentials remain Cloudflare Worker secrets and are not copied to GitHub. Worker deployments preserve them.

The production backend is a Worker at `scrollock.poronga.com.ar`, with a single named Durable Object providing serialized requests and durable SQLite-backed state. Cloudflare provisions DNS and TLS from the custom-domain declaration in `wrangler.jsonc`. The bot token and group ID are Worker secrets; never put them in `wrangler.jsonc`. The committed Chrome public key gives every unpacked copy the stable extension ID `ahdgaahcjnpaegmopigcpgabcjmcilid`, which is the only Chrome origin allowlisted by default. Production enables `ALLOW_SAFARI_EXTENSION_ORIGINS` so each friend's Safari installation can connect without manually registering its random UUID origin.

`GET /health` returns `{"ok":true}`. Do not enable request logging of Telegram callback query strings or authorization headers. The built-in limiter allows 120 requests per minute per connecting IP while the Durable Object is active. Sessions expire after seven days. The Node/Docker backend remains available for local or non-Cloudflare hosting, but production uses the Worker.

## iOS app: Safari extension and Screen Time

The iPhone app (iOS 17+) contains the Safari Web Extension and also locks the **native X, Instagram, and YouTube apps** with Screen Time. Chrome on iOS does not load this Chrome extension.

- **Choose apps per feed.** After allowing Screen Time access, pick the apps (or categories/websites) to lock for X, Instagram, and YouTube. Selections are opaque Screen Time tokens that stay on the device. Scrollock cannot see which apps they are, and no usage is monitored or reported.
- **Block screen.** Opening a locked app shows Scrollock's shield. **Take a break…** posts a notification that opens the break form in the app. A shield cannot collect a reason itself, so this keeps the same "duration and reason" rule as the extension.
- **Breaks.** A break uses the same `/api/unlock` endpoint and limits (1–60 minutes, reason of up to 280 characters). The group report must succeed before anything unlocks. A break for a feed that already has an active lease (for example from Safari) reuses that deadline and sends no second report. **Lock now** ends it early.
- **Relocking.** Each feed has its own Managed Settings store and its own Device Activity schedule, so a break lifts only that feed's shields and never touches parental or other Screen Time limits. The Device Activity monitor relocks when the schedule ends. iOS may deliver that a few minutes late, so the app also relocks expired breaks whenever it opens. Device Activity requires intervals of at least 15 minutes, so shorter breaks backdate the interval start.
- **Telegram.** The app and the Safari extension share one login. The session lives in a Keychain item shared through the App Group, and the extension syncs with it through native messaging whenever it checks state. Connecting or disconnecting on either side applies to both: the most recent change wins.

The native code lives in `ios/`:

- `ios/Scrollock.xcodeproj`: committed project with five targets (app, Safari extension, Device Activity monitor, shield configuration, shield action). It uses folder-synchronized groups, so adding a Swift file to a target folder needs no project edits.
- `ios/ScrollockKit`: platform-independent Swift package (API client, lease and relock math, shared App Group state, shared session Keychain), unit-tested with `swift test`.
- `ios/Shared`: Screen Time shield controller shared by the app and extensions.

The Safari extension target copies `dist/safari` into its bundle at build time, so run `npm run build` (or `build:production`) before building in Xcode.

### Build and run with Xcode

```sh
npm run build:production
open ios/Scrollock.xcodeproj
```

Signing uses team `BQ7842UUHJ` with automatic signing. The app and the three Screen Time extensions carry the Family Controls entitlement and the `group.ar.com.poronga.Scrollock` App Group. Apple must approve Family Controls (Distribution) **per bundle ID** for TestFlight/App Store builds: `ar.com.poronga.Scrollock`, `.Monitor`, `.ShieldConfiguration`, and `.ShieldAction`. Do not strip the entitlement to work around signing failures.

Enable Scrollock in Settings → Apps → Safari → Extensions, grant access to all three websites, and allow its configured API host if Safari requests it.

To point a Debug build at the local mock server, build with `SCROLLOCK_API_ORIGIN=http://localhost:8787`.

### Without a Mac

Apple offers a **Safari Web Extension Packager in App Store Connect** for the extension ZIP. See [Apple's packaging guide](https://developer.apple.com/documentation/safariservices/converting-a-web-extension-for-safari).

### Upload to TestFlight from a Mac

On a Mac with the Apple Distribution certificate available in Keychain and either an App Store Connect API key or an Apple developer account in Xcode, run:

```sh
npm run safari:deploy
```

This runs the checks (including the Swift package tests), makes a production build, signs all five targets using Xcode's automatic signing, assigns a UTC timestamp build number, and uploads it to App Store Connect/TestFlight. Set `BUILD_NUMBER` to override the generated build number or `APPLE_TEAM_ID` to override the default `BQ7842UUHJ` team. Each uploaded build number must be new.

API-key authentication uses the existing local `~/.config/caloric/apple.json` when present. Set `APPLE_API_CREDENTIALS` to use another credential JSON file with `keyPath`, `keyID`, and `issuerID`, or set `ASC_KEY_PATH`, `ASC_KEY_ID`, and `ASC_ISSUER_ID` directly. Keep the credential JSON and `.p8` private key outside the repository. Without an API key, the script uses Xcode's saved Apple Account session.

For local distribution signing, the script uses `~/.config/scrollock/ExportOptions.plist` when present; `SAFARI_EXPORT_OPTIONS` overrides that path. This plist must reference valid profiles for all five Scrollock bundle IDs that include the local distribution certificate. Unlock its signing Keychain before deploying. Without a saved export plist, Xcode uses automatic distribution signing.

The GitHub Release's Chrome ZIP is unsigned because Chrome does not sign unpacked extensions. Unzip it before using **Load unpacked**. Automatic signed Chrome installation and updates require a Chrome Web Store listing (or enterprise browser policy), which is intentionally outside this friends-only distribution.

**Verification boundary:** `npm run test:ios` runs the Swift package tests and compiles every target for the simulator. The simulator accepts Screen Time settings but does not enforce shields, so blocking, the block screen, and relocking must be checked on a real iPhone. Playwright Chromium is not an iOS Safari extension runtime.

For local Safari-only simulator checks, build the `Scrollock` scheme in `ios/Scrollock.xcodeproj` with `-sdk iphonesimulator CODE_SIGNING_ALLOWED=NO`, install the resulting app with `xcrun simctl install booted`, and enable it in Safari's **Manage Extensions** menu. Grant website access before testing. Check the popup in Safari's half-height sheet: connection and all three feed controls should fit its width, buttons should be touch-sized, and the reporting explanation should be reachable by scrolling. Verify that YouTube search and bottom navigation still respond with the feed paused, and that unlock/expiry restores and hides the feed without replacing the page shell.

## Tests

```sh
npm test
npm run check
npx playwright install chromium
npm run test:e2e
npm run test:ios   # macOS + Xcode only
```

The end-to-end test launches a real Chromium browser with the actual unpacked Chrome extension. It does **not** replace extension messaging or storage with mocks. It runs a local mock Telegram server and serves synthetic social pages at matching origins via network interception, without visiting real accounts.

Coverage includes signed login validation/replay, group membership rejection, production mock guard, pairing/session expiry, API input/CORS validation, selected-duration boundaries, persistent leases, concurrent unlock deduplication, all three blocked/unblocked sites, cross-tab state, reloads, closed-popup expiry, manual lock, private-data exclusion, and Telegram reporting failure. E2E may inject a **15-second Node server lease override** to exercise real timer expiry quickly; production expiry uses the selected duration. Test screenshots are written to `.amp/in/artifacts/` for review.

### Real-device release checklist

- Test current signed-in desktop sites and mobile Safari sites, not just fixtures.
- Confirm Home/Explore/Reels/Shorts/feed pages are blocked; direct messages and Instagram post/individual Reel links (including shared links with query parameters) are accessible. Navigate from a blocked feed to a post and back, and confirm the post is restored and the feed relocks.
- Complete real Telegram login as a member; reject a nonmember.
- Unlock each site; confirm one real group intent report with its duration and reason, and no browsing-activity or lock reports.
- Wait for the selected duration with popup closed, reload, switch tabs, background Safari, and resume after the deadline. Confirm the feed relocks.
- Disconnect the server or remove bot posting permission: a new unlock must fail closed.
- On iPhone: choose apps for each feed and open one to see the Scrollock block screen. Tap **Take a break…**, open the notification, and take a 1-minute break. Confirm the group report arrives before the app unlocks, that a reporting failure leaves it locked with an error, and that it relocks after the deadline with Scrollock closed. Check that **Lock now** relocks immediately.
- Verify browser permission prompts, Safari background execution, origin allowlisting, and your signed distribution build.

## Layout and credits

- `extension/`: shared Web Extension, including blocking rules and unblock forms.
- `ios/`: iPhone app, Safari extension host, and Screen Time blocking (app picker, block screen, timed relock).
- `server/`: Telegram auth, fixed-group reporting, persistence, API tests.
- `scripts/`: browser builds, syntax checks, iOS checks and TestFlight upload.
- `tests/`: rule tests and actual-extension end-to-end test.

Original implementation inspired by the user-mentioned **Blockit** and **News Feed Eradicator/news-feed disablers**. No source code or assets from those products were copied or cloned. Telegram and social-platform names belong to their respective owners; this project is not affiliated with them.

Feed-selector references: [News Feed Eradicator](https://github.com/jordwest/news-feed-eradicator) for X and Instagram's content containers, and [Remove YouTube Suggestions](https://github.com/lawrencehook/remove-youtube-suggestions) for mobile YouTube feed and recommendation containers.
