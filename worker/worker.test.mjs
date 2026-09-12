import test from "node:test";
import assert from "node:assert/strict";
import { createHash, createHmac } from "node:crypto";
import { ScrollockState } from "./index.mjs";

class MemoryStorage {
  data = new Map();

  async get(key) {
    return structuredClone(this.data.get(key));
  }

  async put(key, value) {
    if (typeof key === "object") {
      for (const [entryKey, entryValue] of Object.entries(key))
        this.data.set(entryKey, structuredClone(entryValue));
    } else this.data.set(key, structuredClone(value));
  }

  async delete(key) {
    this.data.delete(key);
  }
}

const env = {
  MOCK_TELEGRAM: "1",
  PUBLIC_ORIGIN: "http://localhost:8787",
  ALLOWED_ORIGINS: "chrome-extension://abc",
};

function fixture(storage = new MemoryStorage()) {
  let now = 1_800_000_000_000;
  const state = new ScrollockState({ storage }, { ...env });
  state.now = () => now;
  const request = (path, init = {}) =>
    state.fetch(new Request(`http://localhost:8787${path}`, init));
  const pair = async () => {
    const pairing = await (
      await request("/api/pair", { method: "POST" })
    ).json();
    await request(`/api/telegram-auth?pair=${pairing.id}&mock=1`);
    return (
      await (
        await request(`/api/pair/${pairing.id}`, {
          headers: { authorization: `Bearer ${pairing.secret}` },
        })
      ).json()
    ).token;
  };
  return {
    state,
    storage,
    request,
    pair,
    tick: (duration) => (now += duration),
  };
}

test("Safari installation origins can pair when enabled, without bypassing authentication", async () => {
  const value = fixture();
  const safari = "safari-web-extension://508d8d32-17ee-45b2-9c6b-6077d09412f9";
  assert.equal(
    (
      await value.request("/api/pair", {
        method: "OPTIONS",
        headers: { origin: safari },
      })
    ).status,
    403,
  );
  value.state.env.ALLOW_SAFARI_EXTENSION_ORIGINS = "1";
  for (const origin of [
    safari,
    "safari-web-extension://C7E24139-A05F-42B8-91DA-5B73DE28F046",
    "chrome-extension://abc",
  ]) {
    const preflight = await value.request("/api/pair", {
      method: "OPTIONS",
      headers: { origin },
    });
    assert.equal(preflight.status, 204);
    assert.equal(preflight.headers.get("access-control-allow-origin"), origin);
    assert.equal(preflight.headers.get("vary"), "Origin");
    const response = await value.request("/api/pair", {
      method: "POST",
      headers: { origin },
    });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("access-control-allow-origin"), origin);
    const pair = await response.json();
    assert.ok(pair.loginUrl.includes(pair.id));
    assert.equal(
      (
        await value.request(`/api/pair/${pair.id}`, {
          headers: { origin, authorization: "Bearer wrong-secret" },
        })
      ).status,
      401,
    );
    const unlock = await value.request("/api/unlock", {
      method: "POST",
      headers: { origin, "content-type": "application/json" },
      body: '{"site":"x"}',
    });
    assert.equal(unlock.status, 401);
    assert.equal(unlock.headers.get("access-control-allow-origin"), origin);
  }
  for (const origin of [
    "null",
    "https://evil.example",
    "chrome-extension://other",
    "safari-web-extension://anything",
    `${safari}.evil.example`,
    `${safari}/`,
    `${safari}:443`,
    `${safari}@evil.example`,
    safari.replace("safari-web-extension", "https"),
  ]) {
    const response = await value.request("/api/pair", {
      method: "POST",
      headers: { origin },
    });
    assert.equal(response.status, 403, origin);
    assert.equal(response.headers.get("access-control-allow-origin"), null);
  }
});

test("Worker pairing and selected-duration lease survive object restart", async () => {
  const first = fixture();
  const token = await first.pair();
  const headers = {
    authorization: `Bearer ${token}`,
    "content-type": "application/json",
  };
  const unlock = () =>
    first.request("/api/unlock", {
      method: "POST",
      headers,
      body: '{"site":"youtube","minutes":17,"reason":"focus"}',
    });
  const leases = await Promise.all(
    Array.from({ length: 8 }, async () => (await unlock()).json()),
  );
  assert.equal(new Set(leases.map((lease) => lease.id)).size, 1);
  assert.equal(leases[0].expiresAt, 1_800_001_020_000);
  assert.equal(
    (await (await first.request("/__mock/messages")).json()).messages.length,
    1,
  );

  const restarted = fixture(first.storage);
  const repeated = await (
    await restarted.request("/api/unlock", {
      method: "POST",
      headers,
      body: '{"site":"youtube","minutes":60,"reason":"do not extend"}',
    })
  ).json();
  assert.deepEqual(repeated, leases[0]);
});

test("Worker verifies browser-bound Telegram login and rejects a replay", async () => {
  const storage = new MemoryStorage();
  const liveEnv = {
    TELEGRAM_BOT_TOKEN: "123:secret",
    TELEGRAM_BOT_USERNAME: "scrollock_bot",
    TELEGRAM_GROUP_ID: "-1",
    PUBLIC_ORIGIN: "https://scrollock.poronga.com.ar",
    ALLOWED_ORIGINS: "chrome-extension://abc",
  };
  const state = new ScrollockState({ storage }, liveEnv);
  state.now = () => 1_800_000_000_000;
  state.telegram = async () => ({ status: "member" });
  const request = (path, init = {}) =>
    state.fetch(new Request(`https://scrollock.poronga.com.ar${path}`, init));
  const pairing = await (await request("/api/pair", { method: "POST" })).json();
  const login = await request(`/login?id=${pairing.id}`);
  const cookie = login.headers.get("set-cookie").split(";")[0];
  const fields = {
    id: "42",
    first_name: "Ada",
    username: "ada_lovelace",
    auth_date: "1800000000",
  };
  const check = Object.entries(fields)
    .sort()
    .map(([name, value]) => `${name}=${value}`)
    .join("\n");
  const hash = createHmac(
    "sha256",
    createHash("sha256").update(liveEnv.TELEGRAM_BOT_TOKEN).digest(),
  )
    .update(check)
    .digest("hex");
  const callback = `/api/telegram-auth?pair=${pairing.id}&${new URLSearchParams({ ...fields, hash })}`;
  assert.equal((await request(callback)).status, 401, "cookie is required");
  assert.equal((await request(callback, { headers: { cookie } })).status, 200);
  const session = await (
    await request(`/api/pair/${pairing.id}`, {
      headers: { authorization: `Bearer ${pairing.secret}` },
    })
  ).json();
  assert.equal(session.user.username, "ada_lovelace");

  const second = await (await request("/api/pair", { method: "POST" })).json();
  const secondLogin = await request(`/login?id=${second.id}`);
  const secondCookie = secondLogin.headers.get("set-cookie").split(";")[0];
  assert.equal(
    (
      await request(
        `/api/telegram-auth?pair=${second.id}&${new URLSearchParams({ ...fields, hash })}`,
        { headers: { cookie: secondCookie } },
      )
    ).status,
    401,
  );
});

test("Worker sends real mentions, including existing sessions without usernames", async () => {
  const value = fixture();
  const token = await value.pair();
  const session = await value.storage.get(`session:${token}`);
  value.state.env.MOCK_TELEGRAM = "0";
  value.state.env.PUBLIC_ORIGIN = "https://scrollock.poronga.com.ar";
  value.state.env.TELEGRAM_BOT_TOKEN = "123:secret";
  value.state.env.TELEGRAM_BOT_USERNAME = "scrollock_bot";
  value.state.env.TELEGRAM_GROUP_ID = "-1";
  const messages = [];
  value.state.telegram = async (method, data) => {
    if (method === "sendMessage") messages.push(data);
    return { status: "member" };
  };
  const post = (path, body) =>
    value.request(path, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    });
  for (const username of ["ada_lovelace", undefined]) {
    session.user = {
      id: 42,
      name: "Ada 🦊 <&> _*",
      ...(username ? { username } : {}),
    };
    await value.storage.put(`session:${token}`, session);
    const lease = await (
      await post("/api/unlock", {
        site: "youtube",
        minutes: 17,
        reason: "  focus <b>now</b>  ",
      })
    ).json();
    assert.ok(lease.id);
    assert.equal((await post("/api/lock", { unlockId: lease.id })).status, 200);
    assert.equal(messages.length, 1);
    for (const message of messages.splice(0)) {
      assert.ok(
        message.text.startsWith(username ? "@ada_lovelace " : "Ada 🦊 <&> _* "),
      );
      assert.ok(!message.text.includes("(42)"));
      assert.match(
        message.text,
        /17-minute youtube unlock: focus <b>now<\/b>$/,
      );
      assert.equal(message.parse_mode, undefined);
      assert.deepEqual(message.entities, [
        { type: "text_link", offset: 0, length: 13, url: "tg://user?id=42" },
      ]);
    }
  }
});

test("Worker validates unlock input, ignores activity, and persists lock", async () => {
  const value = fixture();
  assert.equal(
    (
      await value.request("/api/pair", {
        method: "POST",
        headers: { origin: "https://evil.example" },
      })
    ).status,
    403,
  );
  const token = await value.pair();
  const headers = {
    authorization: `Bearer ${token}`,
    "content-type": "application/json",
  };
  const post = (path, body) =>
    value.request(path, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
  const valid = { site: "x", minutes: 1, reason: "focus" };
  for (const input of [
    { ...valid, minutes: 0 },
    { ...valid, minutes: 61 },
    { ...valid, minutes: 1.5 },
    { ...valid, reason: " " },
    { ...valid, reason: "x".repeat(281) },
  ])
    assert.equal((await post("/api/unlock", input)).status, 400);
  const lease = await (await post("/api/unlock", valid)).json();
  assert.equal(lease.expiresAt, 1_800_000_060_000);
  assert.equal(
    (await post("/api/activity", { private: "secret" })).status,
    200,
  );
  assert.equal(
    (await (await value.request("/__mock/messages")).json()).messages.length,
    1,
  );
  assert.equal((await post("/api/lock", { unlockId: lease.id })).status, 200);

  const restarted = fixture(value.storage);
  assert.equal(
    (
      await restarted.request("/api/activity", {
        method: "POST",
        headers,
        body: JSON.stringify({ unlockId: lease.id, path: "/feed" }),
      })
    ).status,
    200,
  );
});
