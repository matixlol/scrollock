import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

test("Safari bridge receives only the granted site/deadline and failures preserve the website lease", async () => {
  const storage = { session: { token: "private-token" }, leases: {} };
  const nativeCalls = [],
    requests = [];
  let fail = false,
    onAlarm;
  const lease = { id: "lease", site: "x", expiresAt: Date.now() + 60_000 };
  const api = {
    storage: {
      local: {
        get: async () => structuredClone(storage),
        set: async (value) => Object.assign(storage, structuredClone(value)),
      },
    },
    runtime: {
      getURL: () => "safari-web-extension://test/",
      onMessage: { addListener() {} },
      sendNativeMessage: async (host, message) => {
        assert.equal(host, "ar.com.poronga.Scrollock");
        nativeCalls.push(structuredClone(message));
        return fail
          ? { ok: false, error: "Not authorized" }
          : { ok: true, selectedApps: 1 };
      },
    },
    alarms: {
      create: async () => {},
      onAlarm: {
        addListener(fn) {
          onAlarm = fn;
        },
      },
    },
  };
  const context = vm.createContext({
    chrome: api,
    URL,
    AbortSignal,
    SCROLLOCK_API: "https://api.example",
    ScrollockRules: { siteForHost: () => "x" },
    fetch: async (url, init) => {
      requests.push({ url, body: JSON.parse(init.body) });
      return { ok: true, json: async () => lease };
    },
  });
  vm.runInContext(
    await readFile(
      new URL("../extension/background.js", import.meta.url),
      "utf8",
    ),
    context,
  );
  const sender = {
    url: "https://x.com/home",
    tab: { url: "https://x.com/home" },
  };
  const fields = {
    type: "unlock",
    site: "instagram",
    minutes: 1,
    reason: "Reply to a friend",
  };
  await context.handle(fields, sender);
  assert.deepEqual(requests[0].body, {
    site: "x",
    minutes: 1,
    reason: fields.reason,
  });
  assert.deepEqual(nativeCalls[0], {
    type: "unlock",
    site: "x",
    expiresAt: lease.expiresAt,
  });
  fail = true;
  const result = await context.handle(fields, sender);
  assert.match(result.warning, /Not authorized/);
  assert.deepEqual(storage.leases.x, lease);
  await context.handle({ type: "activity", category: "/private" }, sender);
  assert.equal(requests.length, 2, "legacy activity causes no request");
  await assert.rejects(
    context.handle({ type: "native-status" }, sender),
    /extension popup/,
  );
  storage.leases.x.expiresAt = Date.now() - 1;
  onAlarm();
  await vm.runInContext("queue", context);
  assert.deepEqual(nativeCalls.at(-1), { type: "lock", site: "x" });
  assert.equal(storage.leases.x, undefined);
});
