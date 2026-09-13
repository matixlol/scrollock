import test from "node:test";
import assert from "node:assert/strict";
import { createHash, createHmac } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer, config } from "./server.mjs";

async function fixture({ mock = true, telegram, failure, leaseDuration } = {}) {
  const dir = await mkdtemp(join(tmpdir(), "scrollock-"));
  let time = 1_800_000_000_000;
  const cfg = {
    mock,
    host: "127.0.0.1",
    botToken: "123:secret",
    botUsername: "scrollock_test_bot",
    groupId: "-1",
    origins: ["chrome-extension://abc"],
    origin: "",
    storePath: join(dir, "store.json"),
  };
  let server = await createServer({
    config: cfg,
    telegram,
    now: () => time,
    leaseDuration,
    mockFailure: failure,
  });
  await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
  let base = `http://127.0.0.1:${server.address().port}`;
  cfg.origin = base;
  const request = (path, init = {}) => fetch(base + path, init);
  const pair = async () => {
    const p = await (await request("/api/pair", { method: "POST" })).json();
    await request(`/api/telegram-auth?pair=${p.id}&mock=1`);
    const result = await (
      await request(`/api/pair/${p.id}`, {
        headers: { authorization: `Bearer ${p.secret}` },
      })
    ).json();
    return result.token;
  };
  return {
    request,
    pair,
    tick: (n) => (time += n),
    restart: async () => {
      await new Promise((ok) => server.close(ok));
      server = await createServer({
        config: cfg,
        telegram,
        now: () => time,
        leaseDuration,
        mockFailure: failure,
      });
      await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
      base = `http://127.0.0.1:${server.address().port}`;
      cfg.origin = base;
    },
    close: async () => {
      await new Promise((ok) => server.close(ok));
      await rm(dir, { recursive: true });
    },
    cfg,
  };
}

test("pairing is pending, secret protected, authorized, and consumed once", async (t) => {
  const f = await fixture();
  t.after(f.close);
  const p = await (await f.request("/api/pair", { method: "POST" })).json();
  assert.deepEqual(
    await (
      await f.request(`/api/pair/${p.id}`, {
        headers: { authorization: `Bearer ${p.secret}` },
      })
    ).json(),
    { pending: true },
  );
  assert.equal(
    (
      await f.request(`/api/pair/${p.id}`, {
        headers: { authorization: "Bearer wrong" },
      })
    ).status,
    401,
  );
  await f.request(`/api/telegram-auth?pair=${p.id}&mock=1`);
  assert.ok(
    (
      await (
        await f.request(`/api/pair/${p.id}`, {
          headers: { authorization: `Bearer ${p.secret}` },
        })
      ).json()
    ).token,
  );
  assert.equal(
    (
      await f.request(`/api/pair/${p.id}`, {
        headers: { authorization: `Bearer ${p.secret}` },
      })
    ).status,
    401,
  );
});

test("validates Telegram signature, freshness, and membership", async (t) => {
  let status = "member";
  const calls = [];
  const f = await fixture({
    mock: false,
    telegram: {
      call: async (method) => {
        calls.push(method);
        return { status };
      },
    },
  });
  t.after(f.close);
  async function login(age = 0, corrupt = false) {
    const p = await (await f.request("/api/pair", { method: "POST" })).json();
    const page = await f.request(`/login?id=${p.id}`);
    const cookie = page.headers.get("set-cookie").split(";")[0];
    assert.match(await page.text(), /data-telegram-login="scrollock_test_bot"/);
    const fields = {
      id: "42",
      first_name: "Ada",
      auth_date: String(1_800_000_000 - age),
    };
    const check = Object.entries(fields)
      .sort()
      .map(([k, v]) => `${k}=${v}`)
      .join("\n");
    let hash = createHmac(
      "sha256",
      createHash("sha256").update(f.cfg.botToken).digest(),
    )
      .update(check)
      .digest("hex");
    if (corrupt) hash = "0".repeat(64);
    return f.request(
      `/api/telegram-auth?pair=${p.id}&${new URLSearchParams({ ...fields, hash })}`,
      { headers: { cookie } },
    );
  }
  assert.equal((await login(0, true)).status, 401);
  assert.equal((await login(301)).status, 401);
  status = "left";
  assert.equal((await login()).status, 403);
  status = "member";
  assert.equal((await login()).status, 200);
  assert.equal(
    (await login()).status,
    401,
    "signed payload cannot be replayed",
  );
  await f.restart();
  assert.equal(
    (await login()).status,
    401,
    "replay protection survives restart",
  );
  assert.ok(calls.includes("getChatMember"));
});

test("Telegram reports mention the authenticated user with or without a username", async (t) => {
  const messages = [];
  const f = await fixture({
    mock: false,
    telegram: {
      call: async (method, data) => {
        if (method === "sendMessage") messages.push(data);
        return { status: "member" };
      },
    },
  });
  t.after(f.close);
  for (const username of ["ada_lovelace", undefined]) {
    const p = await (await f.request("/api/pair", { method: "POST" })).json();
    const login = await f.request(`/login?id=${p.id}`);
    const cookie = login.headers.get("set-cookie").split(";")[0];
    const fields = {
      id: username ? "42" : "43",
      first_name: "Ada 🦊 <&> _*",
      auth_date: "1800000000",
      ...(username ? { username } : {}),
    };
    const hash = createHmac(
      "sha256",
      createHash("sha256").update(f.cfg.botToken).digest(),
    )
      .update(
        Object.entries(fields)
          .sort()
          .map(([key, value]) => `${key}=${value}`)
          .join("\n"),
      )
      .digest("hex");
    assert.equal(
      (
        await f.request(
          `/api/telegram-auth?pair=${p.id}&${new URLSearchParams({ ...fields, hash })}`,
          { headers: { cookie } },
        )
      ).status,
      200,
    );
    const session = await (
      await f.request(`/api/pair/${p.id}`, {
        headers: { authorization: `Bearer ${p.secret}` },
      })
    ).json();
    assert.equal(session.user.username, username);
    const post = (path, body) =>
      f.request(path, {
        method: "POST",
        headers: {
          authorization: `Bearer ${session.token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
      });
    const lease = await (
      await post("/api/unlock", {
        site: "x",
        minutes: 17,
        reason: "  focus <b>now</b>  ",
      })
    ).json();
    assert.ok(lease.id);
    assert.equal((await post("/api/lock", { unlockId: lease.id })).status, 200);
    const label = username ? "@ada_lovelace" : fields.first_name;
    assert.equal(messages.length, 1);
    for (const message of messages.splice(0)) {
      assert.ok(message.text.startsWith(`${label} `));
      assert.match(message.text, /17-minute x unlock: focus <b>now<\/b>$/);
      assert.ok(!message.text.includes(`(${fields.id})`));
      assert.equal(message.parse_mode, undefined);
      assert.deepEqual(message.entities, [
        {
          type: "text_link",
          offset: 0,
          length: 13,
          url: `tg://user?id=${fields.id}`,
        },
      ]);
    }
  }
});

test("unlock uses selected durations, is idempotent, and activity is a no-op", async (t) => {
  const f = await fixture();
  t.after(f.close);
  const token = await f.pair(),
    auth = {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    };
  const post = (path, value) =>
    f.request(path, {
      method: "POST",
      headers: auth,
      body: JSON.stringify(value),
    });
  const a = await (
    await post("/api/unlock", {
      site: "youtube",
      minutes: 17,
      reason: " break ",
    })
  ).json();
  assert.equal(a.expiresAt, 1_800_001_020_000);
  f.tick(1000);
  const b = await (
    await post("/api/unlock", {
      site: "youtube",
      minutes: 60,
      reason: "longer",
    })
  ).json();
  assert.deepEqual(b, a);
  assert.equal(
    (await post("/api/activity", { private: "full URL" })).status,
    200,
  );
  assert.equal((await post("/api/activity", null)).status, 200);
  const messages = await (await f.request("/__mock/messages")).json();
  assert.deepEqual(messages.messages, [
    "Fixture User requested a 17-minute youtube unlock: break",
  ]);
});

test("rejects invalid inputs and fails unlock closed when reporting fails", async (t) => {
  let fail = true;
  const f = await fixture({ failure: () => fail });
  t.after(f.close);
  const token = await f.pair(),
    headers = {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    };
  const post = (value) =>
    f.request("/api/unlock", {
      method: "POST",
      headers,
      body: JSON.stringify(value),
    });
  const valid = { site: "x", minutes: 1, reason: "ok" };
  for (const input of [
    { ...valid, site: "other" },
    { ...valid, minutes: 0 },
    { ...valid, minutes: 61 },
    { ...valid, minutes: 1.5 },
    { ...valid, minutes: "1" },
    { ...valid, reason: "   " },
    { ...valid, reason: 42 },
    { ...valid, reason: "x".repeat(281) },
    { site: "x", minutes: 1 },
  ])
    assert.equal((await post(input)).status, 400);
  assert.equal((await post(valid)).status, 502);
  fail = false;
  for (const minutes of [1, 60]) {
    const response = await post({
      site: minutes === 1 ? "x" : "instagram",
      minutes,
      reason: "x".repeat(280),
    });
    assert.equal(response.status, 200);
    assert.equal(
      (await response.json()).expiresAt,
      1_800_000_000_000 + minutes * 60_000,
    );
  }
});

test("lock ends a lease without reporting", async (t) => {
  const f = await fixture();
  t.after(f.close);
  const token = await f.pair(),
    headers = {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    };
  const lease = await (
    await f.request("/api/unlock", {
      method: "POST",
      headers,
      body: '{"site":"x","minutes":1,"reason":"done"}',
    })
  ).json();
  assert.equal(
    (
      await f.request("/api/lock", {
        method: "POST",
        headers,
        body: JSON.stringify({ unlockId: lease.id }),
      })
    ).status,
    200,
  );
  assert.equal(
    (
      await f.request("/api/activity", {
        method: "POST",
        headers,
        body: JSON.stringify({ unlockId: lease.id, path: "/home" }),
      })
    ).status,
    200,
  );
  assert.equal(
    (await (await f.request("/__mock/messages")).json()).messages.length,
    1,
  );
});

test("older clients retain five-minute access without claiming a typed reason", async (t) => {
  const f = await fixture();
  t.after(f.close);
  const token = await f.pair();
  const headers = {
    authorization: `Bearer ${token}`,
    "content-type": "application/json",
  };
  const response = await f.request("/api/unlock", {
    method: "POST",
    headers,
    body: '{"site":"x"}',
  });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).expiresAt, 1_800_000_300_000);
  const { messages } = await (await f.request("/__mock/messages")).json();
  assert.deepEqual(messages, [
    "Fixture User requested a 5-minute x unlock: No reason supplied (older extension).",
  ]);
  assert.equal(
    (
      await f.request("/api/unlock", {
        method: "POST",
        headers,
        body: '{"site":"instagram","reason":"missing duration"}',
      })
    ).status,
    400,
  );
});

test("Node leaseDuration explicitly overrides selected duration", async (t) => {
  const f = await fixture({ leaseDuration: 15_000 });
  t.after(f.close);
  const token = await f.pair();
  const response = await f.request("/api/unlock", {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ site: "x", minutes: 60, reason: "fast E2E" }),
  });
  assert.equal((await response.json()).expiresAt, 1_800_000_015_000);
});

test("concurrent unlocks share one durable lease and report", async (t) => {
  const f = await fixture();
  t.after(f.close);
  const token = await f.pair();
  const headers = {
    authorization: `Bearer ${token}`,
    "content-type": "application/json",
  };
  const unlock = () =>
    f
      .request("/api/unlock", {
        method: "POST",
        headers,
        body: '{"site":"x","minutes":17,"reason":"focus"}',
      })
      .then((r) => r.json());
  const leases = await Promise.all(Array.from({ length: 8 }, unlock));
  assert.equal(new Set(leases.map((l) => l.id)).size, 1);
  assert.equal(
    (await (await f.request("/__mock/messages")).json()).messages.length,
    1,
  );
  await f.restart();
  assert.deepEqual(await unlock(), leases[0]);
});

test("Node backend supports opt-in Safari origins and still requires a session", async (t) => {
  const f = await fixture();
  t.after(f.close);
  const origin = "safari-web-extension://508d8d32-17ee-45b2-9c6b-6077d09412f9";
  const preflight = () =>
    f.request("/api/pair", { method: "OPTIONS", headers: { origin } });
  assert.equal((await preflight()).status, 403);
  f.cfg.allowSafariExtensionOrigins = config({
    MOCK_TELEGRAM: "1",
    ALLOW_SAFARI_EXTENSION_ORIGINS: "1",
  }).allowSafariExtensionOrigins;
  const response = await preflight();
  assert.equal(response.status, 204);
  assert.equal(response.headers.get("access-control-allow-origin"), origin);
  assert.equal(response.headers.get("vary"), "Origin");
  assert.equal(
    (await f.request("/api/pair", { method: "POST", headers: { origin } }))
      .status,
    200,
  );
  assert.equal(
    (
      await f.request("/api/unlock", {
        method: "POST",
        headers: { origin, "content-type": "application/json" },
        body: '{"site":"x","minutes":1,"reason":"focus"}',
      })
    ).status,
    401,
  );
  for (const blocked of [
    "null",
    "https://evil.example",
    "safari-web-extension://anything",
    `${origin}.evil.example`,
    `${origin}/`,
    `${origin}:443`,
  ]) {
    const response = await f.request("/api/pair", {
      method: "POST",
      headers: { origin: blocked },
    });
    assert.equal(response.status, 403);
    assert.equal(response.headers.get("access-control-allow-origin"), null);
  }
});

test("CORS, login binding, pairing/session expiry, JSON validation, and production mock guard", async (t) => {
  const f = await fixture();
  t.after(f.close);
  assert.equal(
    (
      await f.request("/api/pair", {
        method: "POST",
        headers: { origin: "https://evil.example" },
      })
    ).status,
    403,
  );
  const preflight = await f.request("/api/pair", {
    method: "OPTIONS",
    headers: { origin: "chrome-extension://abc" },
  });
  assert.equal(preflight.status, 204);
  assert.equal(
    preflight.headers.get("access-control-allow-origin"),
    "chrome-extension://abc",
  );
  const p = await (await f.request("/api/pair", { method: "POST" })).json();
  f.tick(600001);
  assert.equal(
    (
      await f.request(`/api/pair/${p.id}`, {
        headers: { authorization: `Bearer ${p.secret}` },
      })
    ).status,
    401,
  );
  const token = await f.pair();
  const headers = {
    authorization: `Bearer ${token}`,
    "content-type": "application/json",
  };
  for (const body of ["null", "[]", "{bad", '"string"'])
    assert.equal(
      (await f.request("/api/unlock", { method: "POST", headers, body }))
        .status,
      400,
    );
  f.tick(604800001);
  assert.equal(
    (
      await f.request("/api/unlock", {
        method: "POST",
        headers,
        body: '{"site":"x"}',
      })
    ).status,
    401,
  );
  assert.throws(
    () => config({ NODE_ENV: "production", MOCK_TELEGRAM: "1" }),
    /forbidden/,
  );
  assert.throws(
    () => config({ MOCK_TELEGRAM: "1", HOST: "0.0.0.0" }),
    /localhost/,
  );
  const live = await fixture({
    mock: false,
    telegram: {
      call: async () => {
        throw new Error("must not call");
      },
    },
  });
  t.after(live.close);
  const lp = await (await live.request("/api/pair", { method: "POST" })).json();
  assert.equal(
    (
      await live.request(
        `/api/telegram-auth?pair=${lp.id}&hash=${"0".repeat(64)}`,
      )
    ).status,
    401,
  );
});

test("lock persists without a Telegram lock notification", async (t) => {
  let fail = false;
  const f = await fixture({ failure: () => fail });
  t.after(f.close);
  const token = await f.pair();
  const headers = {
    authorization: `Bearer ${token}`,
    "content-type": "application/json",
  };
  const post = (path, data) =>
    f.request(path, { method: "POST", headers, body: JSON.stringify(data) });
  const lease = await (
    await post("/api/unlock", { site: "x", minutes: 1, reason: "focus" })
  ).json();
  fail = true;
  assert.equal((await post("/api/lock", { unlockId: lease.id })).status, 200);
  await f.restart();
  assert.equal(
    (await post("/api/activity", { unlockId: lease.id, path: "/feed" })).status,
    200,
  );
});
