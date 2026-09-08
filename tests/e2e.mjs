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
try {
  const extension = resolve("dist/chrome");
  context = await chromium.launchPersistentContext(join(temp, "browser"), {
    channel: "chromium",
    headless: true,
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
    (route) =>
      route.fulfill({
        contentType: "text/html",
        body: '<!doctype html><html><head><title>Social-site fixture</title></head><body><main id="feed"><h1>Fixture feed</h1><p>A stream of posts</p></main><ytd-watch-next-secondary-results-renderer>Recommended videos</ytd-watch-next-secondary-results-renderer></body></html>',
      }),
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
  }
  await pages.x.screenshot({
    path: join(artifacts, "scrollock-feed-paused.png"),
  });
  const loginPromise = context.waitForEvent("page");
  await popup.locator("#connect").click();
  const login = await loginPromise;
  await login.waitForLoadState();
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

  await popup.locator("#x button").click();
  await eventually(
    () => pages.x.locator("html[data-scrollock-unlocked]").count(),
    "X unlock",
  );
  assert.equal(await pages.x.locator("#feed").isVisible(), true);
  assert.equal(await pages.instagram.locator("#feed").isVisible(), false);
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
  await popup.locator("#x button").click();
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
