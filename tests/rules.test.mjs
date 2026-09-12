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
    ["instagram", "/reels/123"],
    ["youtube", "/"],
    ["youtube", "/shorts/abc"],
    ["youtube", "/feed/subscriptions"],
  ])
    assert.ok(blockedRoute(site, path), site + path);
  for (const [site, path] of [
    ["x", "/messages/123"],
    ["x", "/user/status/123"],
    ["instagram", "/direct/inbox/"],
    ["instagram", "/p/abc/"],
    ["youtube", "/watch"],
    ["youtube", "/results"],
  ])
    assert.equal(blockedRoute(site, path), false, site + path);
});
