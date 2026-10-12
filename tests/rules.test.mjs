import { test } from "node:test";
import assert from "node:assert/strict";
import "../extension/rules.js";
const { siteForHost, blockedRoute } = globalThis.ScrollockRules;
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
