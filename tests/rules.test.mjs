import { test } from "node:test";
import assert from "node:assert/strict";
import "../extension/rules.js";
const { siteForHost, shortId, blockedRoute } = globalThis.ScrollockRules;
test("host matching cannot match lookalike domains", () => {
  assert.equal(siteForHost("m.youtube.com"), "youtube");
  assert.equal(siteForHost("evilx.com"), null);
  assert.equal(siteForHost("x.com.evil.com"), null);
});
test("feed routes block but direct links and messaging remain available", () => {
  for (const [site, path] of [
    ["x", "/home"],
    ["x", "/explore"],
    ["instagram", "/"],
    ["instagram", "/reels/"],
    ["youtube", "/"],
    ["youtube", "/shorts/abc"],
    ["youtube", "/feed/subscriptions"],
  ])
    assert.ok(blockedRoute(site, path), site + path);
  for (const [site, path] of [
    ["x", "/messages/123"],
    ["x", "/user/status/123"],
    ["x", "/search"],
    ["x", "/search/"],
    ["instagram", "/direct/inbox/"],
    ["instagram", "/p/abc/"],
    ["youtube", "/watch"],
    ["youtube", "/results"],
  ])
    assert.equal(blockedRoute(site, path), false, site + path);
});
test("Instagram post and reel permalinks stay accessible without unblocking feeds", () => {
  const reportedLink = new URL(
    "https://www.instagram.com/reel/DeXCHxZRPXu/?exln=MXNkZTY3b3M3NDFy",
  );
  assert.equal(blockedRoute("instagram", reportedLink.pathname), false);
  for (const path of [
    "/p/CxYz_123-AB",
    "/p/CxYz_123-AB/",
    "/reel/CxYz_123-AB",
    "/reel/CxYz_123-AB/",
    "/reels/CxYz_123-AB",
    "/reels/CxYz_123-AB/",
    "/reel/CxYz_123-AB/embed/",
    "/reel/CxYz_123-AB/embed/captioned/",
  ]) {
    for (const query of ["", "?igsh=shared-link&utm_source=ig_web_copy_link"]) {
      const url = new URL(path + query, "https://www.instagram.com");
      assert.equal(blockedRoute("instagram", url.pathname), false, url.href);
    }
  }
  for (const path of [
    "/",
    "/explore",
    "/explore/",
    "/explore/tags/music/",
    "/reel",
    "/reel/",
    "/reels",
    "/reels/",
    "/reels/audio/123/",
  ])
    assert.equal(blockedRoute("instagram", path), true, path);
});
test("opened YouTube shorts load while the Shorts feed stays blocked", () => {
  const link = new URL(
    "https://www.youtube.com/shorts/f9jYPLU8h3g?feature=share",
  );
  assert.equal(shortId(link.pathname), "f9jYPLU8h3g");
  const opened = new Set([shortId(link.pathname)]);
  assert.equal(blockedRoute("youtube", link.pathname, opened), false);
  assert.equal(blockedRoute("youtube", "/shorts/f9jYPLU8h3g/", opened), false);
  // The next short in the player was never opened directly.
  assert.equal(blockedRoute("youtube", "/shorts/CIb0cNKjUOo", opened), true);
  assert.equal(blockedRoute("youtube", link.pathname), true);
  for (const path of ["/shorts", "/shorts/", "/shorts/a/b"]) {
    assert.equal(shortId(path), null, path);
    assert.equal(blockedRoute("youtube", path, opened), true, path);
  }
});
