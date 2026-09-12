import { chromium } from "playwright";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { execFileSync } from "node:child_process";
import { createServer } from "../server/server.mjs";

// The browser loads the REAL unpacked extension. Only Telegram and social-site
// HTML are fixtures; storage, messaging, service worker, fetch and timers are real.
const temp = await mkdtemp(join(tmpdir(), "scrollock-e2e-"));
const artifacts = resolve(".amp/in/artifacts");
await mkdir(artifacts, { recursive: true });
let reportingFails = false;
const cfg = {
  mock: true,
  origins: [],
  origin: "http://localhost",
  storePath: join(temp, "store.json"),
};
const server = await createServer({
  config: cfg,
  leaseDuration: 15000,
  mockFailure: () => reportingFails,
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
cfg.origin = `http://127.0.0.1:${server.address().port}`;
execFileSync(process.execPath, ["scripts/build.mjs"], {
  env: { ...process.env, API_ORIGIN: cfg.origin },
  stdio: "inherit",
});
let context;
async function eventually(check, label, timeout = 20000) {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    if (await check()) return;
    await new Promise((ok) => setTimeout(ok, 150));
  }
  throw new Error("Timed out: " + label);
}
async function checkTouchLayout(popup, state) {
  for (const width of [320, 390, 430]) {
    await popup.setViewportSize({ width, height: 430 });
    assert.equal(
      await popup.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
      true,
      `${state}: no horizontal overflow at ${width}px`,
    );
    for (const button of await popup.locator("button").all()) {
      const box = await button.boundingBox();
      assert.ok(box.height >= 44, "touch target at least 44px high");
      assert.ok(box.x >= 0 && box.x + box.width <= width, "button fits sheet");
    }
    await popup.screenshot({
      path: join(artifacts, `scrollock-${state}-${width}.png`),
      fullPage: true,
    });
  }
  await popup.setViewportSize({ width: 390, height: 740 });
}
async function checkAppearance(page, selector, name) {
  for (const colorScheme of ["light", "dark"]) {
    await page.emulateMedia({ colorScheme });
    const background = await page
      .locator(selector)
      .evaluate((element) => getComputedStyle(element).backgroundColor);
    const red = Number(background.match(/\d+/)[0]);
    assert.ok(
      colorScheme === "light" ? red > 200 : red < 60,
      `${name}: ${colorScheme} background`,
    );
    await page.screenshot({
      path: join(artifacts, `${name}-${colorScheme}.png`),
      fullPage: true,
    });
  }
  await page.emulateMedia({ colorScheme: "light" });
}
async function clickInlineUnblock(page) {
  // The content script deliberately uses a closed shadow root. Click the visible
  // right-aligned button with a real pointer event, not a synthetic DOM click.
  const box = await page.locator("#scrollock-gate").boundingBox();
  await page.mouse.click(box.x + box.width - 50, box.y + 38);
}
try {
  const extension = resolve("dist/chrome");
  context = await chromium.launchPersistentContext(join(temp, "browser"), {
    channel: "chromium",
    headless: true,
    hasTouch: true,
    args: [
      `--disable-extensions-except=${extension}`,
      `--load-extension=${extension}`,
    ],
    viewport: { width: 390, height: 740 },
  });
  const worker =
    context.serviceWorkers()[0] ||
    (await context.waitForEvent("serviceworker"));
  const extensionOrigin =
    new URL(worker.url()).origin === "null"
      ? worker.url().split("/").slice(0, 3).join("/")
      : new URL(worker.url()).origin;
  cfg.origins.push(extensionOrigin);
  const popup = await context.newPage();
  const errors = [];
  popup.on("pageerror", (error) => errors.push(error.message));
  await popup.goto(extensionOrigin + "/popup.html");
  await eventually(
    () =>
      popup
        .locator(".site")
        .count()
        .then((n) => n === 3),
    "popup ready",
  );
  await checkTouchLayout(popup, "disconnected");
  assert.equal(await popup.locator("header, nav, footer, img, svg").count(), 0);
  await checkAppearance(popup, "html", "popup");
  await popup
    .locator("body")
    .screenshot({ path: join(artifacts, "scrollock-locked.png") });
  await popup.locator("#x button").click();
  await eventually(
    () =>
      popup
        .locator("#status")
        .textContent()
        .then((t) => t.includes("Connect Telegram")),
    "login required",
  );
  // No traffic reaches these services. Fixture HTML uses their real origins so
  // Chrome itself applies manifest matching and injects isolated content scripts.
  await context.route(
    /^https:\/\/(www\.|m\.)?(x\.com|instagram\.com|youtube\.com)\//,
    (route) => {
      const host = new URL(route.request().url()).hostname;
      const feed = "<h1>Fixture feed</h1><p>A stream of posts</p>";
      const content = host.includes("x.com")
        ? `<main data-testid="primaryColumn"><header><input aria-label="Search" /></header><section role="region" id="feed">${feed}</section></main>`
        : host.includes("instagram")
          ? `<main><div><article id="feed">${feed}</article></div></main>`
          : host === "www.youtube.com"
            ? `<header><input aria-label="Search" /></header><ytd-browse id="feed">${feed}</ytd-browse>`
            : `<ytm-browse><header><input aria-label="Search" /></header><div class="rich-grid-renderer-contents" id="feed">${feed}</div></ytm-browse>`;
      return route.fulfill({
        contentType: "text/html",
        body: `<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Social-site fixture</title><style>body{margin:0;font:16px system-ui}nav,header{padding:16px}nav{display:flex;gap:24px}a{color:#203a30}</style></head><body><div id="app"><nav><a href="/messages">Messages</a><a href="/profile">Profile</a><button onclick="this.textContent='Clicked'">Compose</button></nav>${content}<ytd-watch-next-secondary-results-renderer>Recommended videos</ytd-watch-next-secondary-results-renderer></div></body></html>`,
      });
    },
  );
  const pages = {};
  for (const [site, url] of Object.entries({
    x: "https://x.com/home",
    instagram: "https://www.instagram.com/",
    youtube: "https://m.youtube.com/",
  })) {
    const page = await context.newPage();
    pages[site] = page;
    await page.goto(url);
    await eventually(
      () => page.locator("html[data-scrollock-blocked]").count(),
      site + " blocked",
    );
    assert.equal(await page.locator("#feed").isVisible(), false);
    await page.getByRole("button", { name: "Compose" }).click();
    assert.equal(await page.getByText("Clicked", { exact: true }).count(), 1);
    if (site !== "instagram") {
      await page.getByRole("textbox", { name: "Search" }).fill("a friend");
      assert.equal(await page.getByRole("textbox").inputValue(), "a friend");
    }
    await page.getByRole("link", { name: "Messages" }).click();
    await eventually(
      () => page.locator("#feed").isVisible(),
      "messages usable",
    );
    assert.equal(await page.locator("#scrollock-gate").count(), 0);
    await page.goto(url);
    await eventually(
      async () => !(await page.locator("#feed").isVisible()),
      "feed hidden again",
    );
    // Site re-renders must not resurrect the feed or accumulate notices.
    await page.locator("#feed").evaluate((feed) => {
      feed.replaceWith(feed.cloneNode(true));
      document.querySelector("#scrollock-gate").remove();
    });
    await eventually(
      () => page.locator("#scrollock-gate").count(),
      "notice restored",
    );
    assert.equal(await page.locator("#feed").isVisible(), false);
  }
  await pages.x.screenshot({
    path: join(artifacts, "scrollock-feed-paused.png"),
  });
  await checkAppearance(pages.x, "#scrollock-gate", "feed");
  await clickInlineUnblock(pages.x);
  assert.equal(await pages.x.locator("#feed").isVisible(), false);
  const desktop = await context.newPage();
  for (const path of ["/", "/feed/subscriptions", "/feed/history"]) {
    await desktop.goto("https://www.youtube.com" + path);
    await eventually(
      () => desktop.locator("#scrollock-gate").isVisible(),
      path,
    );
    assert.equal(await desktop.locator("#feed").isVisible(), false);
    await desktop.getByRole("textbox", { name: "Search" }).fill("music");
  }
  await desktop.evaluate(() =>
    history.pushState({}, "", "/results?search_query=music"),
  );
  await eventually(
    () => desktop.locator("#feed").isVisible(),
    "desktop search accessible",
  );
  assert.equal(await desktop.locator("#scrollock-gate").count(), 0);
  await desktop.close();
  const loginPromise = context.waitForEvent("page");
  await popup.locator("#connect").click();
  const login = await loginPromise;
  await login.waitForLoadState();
  await checkAppearance(login, "body", "login");
  await login.screenshot({ path: join(artifacts, "scrollock-mock-login.png") });
  await login.getByRole("button", { name: "Authorize fixture user" }).click();
  await popup.locator("#connect").click();
  await eventually(
    () =>
      popup
        .locator("#identity")
        .textContent()
        .then((t) => t.includes("Fixture User")),
    "Telegram pairing",
  );
  await checkTouchLayout(popup, "connected");

  await clickInlineUnblock(pages.x);
  await eventually(
    () => pages.x.locator("html[data-scrollock-unlocked]").count(),
    "X unlock",
  );
  assert.equal(await pages.x.locator("#feed").isVisible(), true);
  assert.equal(await pages.instagram.locator("#feed").isVisible(), false);
  await eventually(
    () =>
      popup
        .getByRole("button", { name: "Block X / Twitter", exact: true })
        .count(),
    "popup reflects inline unblock",
  );
  // A page cannot choose another site or invoke privileged extension actions.
  await worker.evaluate(async () => {
    const sender = {
      url: "https://x.com/home",
      tab: { url: "https://x.com/home" },
    };
    await handle({ type: "unlock", site: "instagram" }, sender);
  });
  assert.equal(await pages.instagram.locator("#feed").isVisible(), false);
  for (const type of ["pair", "poll", "lock"]) {
    const error = await worker.evaluate(async (type) => {
      try {
        await handle(
          { type, site: "x" },
          { url: "https://x.com/home", tab: { url: "https://x.com/home" } },
        );
      } catch (error) {
        return error.message;
      }
    }, type);
    assert.equal(error, "Use the extension popup");
  }
  await popup
    .locator("body")
    .screenshot({ path: join(artifacts, "scrollock-active.png") });
  await pages.x.evaluate(() =>
    history.pushState({}, "", "/alice/status/123?private=secret"),
  );
  await eventually(
    async () =>
      (
        await (await fetch(cfg.origin + "/__mock/messages")).json()
      ).messages.some((m) => m.includes("x: /other")),
    "SPA activity report",
  );
  await pages.x.reload();
  await eventually(
    () => pages.x.locator("html[data-scrollock-unlocked]").count(),
    "unlock survives reload",
  );
  await popup
    .getByRole("button", { name: "Block X / Twitter", exact: true })
    .click();
  await eventually(
    async () =>
      (
        await (await fetch(cfg.origin + "/__mock/messages")).json()
      ).messages.some((message) => message.includes("locked x")),
    "manual block reported",
  );
  await pages.x.goto("https://x.com/home");
  await eventually(
    () => pages.x.locator("html[data-scrollock-blocked]").count(),
    "manual lock",
  );

  for (const site of ["instagram", "youtube"]) {
    await popup.locator(`#${site} button`).click();
    await eventually(
      () => pages[site].locator("html[data-scrollock-unlocked]").count(),
      site + " unlock",
    );
  }
  const second = await context.newPage();
  await second.goto("https://www.instagram.com/");
  await eventually(
    () => second.locator("html[data-scrollock-unlocked]").count(),
    "cross-tab lease",
  );
  await popup.close();
  await eventually(
    () => pages.instagram.locator("html[data-scrollock-blocked]").count(),
    "automatic expiry with popup closed",
  );
  await eventually(
    () => second.locator("html[data-scrollock-blocked]").count(),
    "cross-tab expiry",
  );
  await eventually(
    () => pages.youtube.locator("html[data-scrollock-blocked]").count(),
    "YouTube expiry",
  );

  await pages.youtube.goto("https://m.youtube.com/watch?v=private");
  assert.equal(await pages.youtube.locator("#feed").isVisible(), true);
  assert.equal(
    await pages.youtube
      .locator("ytd-watch-next-secondary-results-renderer")
      .isVisible(),
    false,
  );
  await pages.instagram.goto("https://www.instagram.com/direct/inbox/");
  assert.equal(await pages.instagram.locator("#feed").isVisible(), true);
  await pages.instagram.evaluate(() =>
    history.pushState({}, "", "/reels/xyz/"),
  );
  await eventually(
    () => pages.instagram.locator("html[data-scrollock-blocked]").count(),
    "SPA relock on reels",
  );
  await eventually(
    () => pages.instagram.locator("#scrollock-gate").isVisible(),
    "Reels notice is outside hidden content",
  );
  assert.equal(await pages.instagram.locator("#feed").isVisible(), false);
  await pages.instagram.getByRole("link", { name: "Profile" }).click();
  await eventually(
    () => pages.instagram.locator("#feed").isVisible(),
    "profile reachable from Reels",
  );

  reportingFails = true;
  const again = await context.newPage();
  await again.goto(extensionOrigin + "/popup.html");
  await again.locator("#x button").click();
  await eventually(
    () => again.locator("#status").textContent().then(Boolean),
    "report failure visible",
  );
  assert.equal(await pages.x.locator("#feed").isVisible(), false);
  await again
    .locator("body")
    .screenshot({ path: join(artifacts, "scrollock-report-failure.png") });
  reportingFails = false;
  await again.locator("#x button").click();
  await eventually(
    () => pages.x.locator("html[data-scrollock-unlocked]").count(),
    "recovery after bot failure",
  );
  const secondX = await context.newPage();
  await secondX.goto("https://x.com/home");
  await eventually(
    () => secondX.locator("html[data-scrollock-unlocked]").count(),
    "second X tab unlocked",
  );
  reportingFails = true;
  await secondX.evaluate(() =>
    history.pushState({}, "", "/someone/status/456"),
  );
  await eventually(
    () => pages.x.locator("html[data-scrollock-blocked]").count(),
    "activity failure revokes all local tabs",
  );
  assert.equal(await pages.x.locator("#feed").isVisible(), false);
  const { messages } = await (
    await fetch(cfg.origin + "/__mock/messages")
  ).json();
  assert.ok(messages.some((m) => m.includes("started a 5-minute x unlock")));
  assert.ok(messages.some((m) => m.includes("locked x")));
  assert.ok(messages.some((m) => m.includes("instagram: /feed")));
  assert.ok(messages.some((m) => m.includes("youtube: /feed")));
  assert.ok(!messages.some((m) => /alice|secret|private|123/.test(m)));
  assert.deepEqual(errors, []);
  console.log(
    "PASS: real Chrome extension + mock Telegram: login, all 3 sites, isolation, SPA activity, reload, cross-tab expiry, closed-popup expiry, manual lock, privacy, bot failure.",
  );
  console.log(
    "Expiry uses a 15-second server test lease; unit tests assert the production 300,000ms lease.",
  );
  console.log("Mock reports:", JSON.stringify(messages, null, 2));
} finally {
  await context?.close();
  await new Promise((ok) => server.close(ok));
  await rm(temp, { recursive: true, force: true });
  execFileSync(process.execPath, ["scripts/build.mjs"], { stdio: "inherit" });
}
