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

test("Worker pairing and durable five-minute lease survive object restart", async () => {
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
      body: '{"site":"youtube"}',
    });
  const leases = await Promise.all(
    Array.from({ length: 8 }, async () => (await unlock()).json()),
  );
  assert.equal(new Set(leases.map((lease) => lease.id)).size, 1);
  assert.equal(leases[0].expiresAt, 1_800_000_300_000);
  assert.equal(
    (await (await first.request("/__mock/messages")).json()).messages.length,
    1,
  );

  const restarted = fixture(first.storage);
  const repeated = await (
    await restarted.request("/api/unlock", {
      method: "POST",
      headers,
      body: '{"site":"youtube"}',
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
    PUBLIC_ORIGIN: "https://scrollock.putos.club",
    ALLOWED_ORIGINS: "chrome-extension://abc",
  };
  const state = new ScrollockState({ storage }, liveEnv);
  state.now = () => 1_800_000_000_000;
  state.telegram = async () => ({ status: "member" });
  const request = (path, init = {}) =>
    state.fetch(new Request(`https://scrollock.putos.club${path}`, init));
  const pairing = await (await request("/api/pair", { method: "POST" })).json();
  const login = await request(`/login?id=${pairing.id}`);
  const cookie = login.headers.get("set-cookie").split(";")[0];
  const fields = {
    id: "42",
    first_name: "Ada",
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

test("Worker validates CORS and activity categories, deduplicates reports, and persists lock", async () => {
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
  const lease = await (await post("/api/unlock", { site: "x" })).json();
  assert.equal(
    (await post("/api/activity", { unlockId: lease.id, path: "/watch?secret" }))
      .status,
    400,
  );
  assert.equal(
    (await post("/api/activity", { unlockId: lease.id, path: "/messages" }))
      .status,
    200,
  );
  assert.equal(
    (await post("/api/activity", { unlockId: lease.id, path: "/messages" }))
      .status,
    200,
  );
  assert.equal(
    (await (await value.request("/__mock/messages")).json()).messages.length,
    2,
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
    410,
  );
});
