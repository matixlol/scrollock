import http from "node:http";
import {
  createHash,
  createHmac,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const json = (res, status, value, headers = {}) => {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    ...headers,
  });
  res.end(body);
};
const esc = (value) =>
  String(value).replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const id = (bytes = 24) => randomBytes(bytes).toString("base64url");

export function config(env = process.env) {
  const production = env.NODE_ENV === "production";
  const mock = env.MOCK_TELEGRAM === "1";
  if (production && mock)
    throw new Error("MOCK_TELEGRAM is forbidden in production");
  if (!mock && (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_GROUP_ID))
    throw new Error("TELEGRAM_BOT_TOKEN and TELEGRAM_GROUP_ID are required");
  if (!mock && !/^[A-Za-z0-9_]+bot$/i.test(env.TELEGRAM_BOT_USERNAME || ""))
    throw new Error("TELEGRAM_BOT_USERNAME is required (without @)");
  if (
    production &&
    (!env.PUBLIC_ORIGIN?.startsWith("https://") || !env.ALLOWED_ORIGINS)
  )
    throw new Error(
      "Production requires HTTPS PUBLIC_ORIGIN and ALLOWED_ORIGINS",
    );
  const host = env.HOST || (mock ? "127.0.0.1" : "0.0.0.0");
  if (mock && !["127.0.0.1", "localhost", "::1"].includes(host))
    throw new Error("mock mode must bind to localhost");
  const origins = (env.ALLOWED_ORIGINS || "")
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean);
  for (const origin of origins)
    if (
      !/^((chrome|moz)-extension:\/\/[^/]+|safari-web-extension:\/\/[^/]+|https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?)$/.test(
        origin,
      )
    )
      throw new Error(`unsafe ALLOWED_ORIGINS entry: ${origin}`);
  return {
    production,
    mock,
    host,
    port: Number(env.PORT || 8787),
    botToken: env.TELEGRAM_BOT_TOKEN,
    botUsername: env.TELEGRAM_BOT_USERNAME,
    groupId: env.TELEGRAM_GROUP_ID,
    origins,
    origin: env.PUBLIC_ORIGIN || `http://localhost:${env.PORT || 8787}`,
    storePath: resolve(env.STORE_PATH || "server/data/store.json"),
  };
}

class Store {
  constructor(path) {
    this.path = path;
    this.data = { sessions: {}, leases: {}, usedAuth: {} };
    this.ready = this.load();
    this.saving = Promise.resolve();
  }
  async load() {
    try {
      this.data = JSON.parse(await readFile(this.path, "utf8"));
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
    }
  }
  save() {
    this.saving = this.saving.then(async () => {
      await mkdir(dirname(this.path), { recursive: true });
      const tmp = `${this.path}.${process.pid}.tmp`;
      await writeFile(tmp, JSON.stringify(this.data), { mode: 0o600 });
      await rename(tmp, this.path);
    });
    return this.saving;
  }
}

async function body(req, limit = 4096) {
  let size = 0,
    chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit)
      throw Object.assign(new Error("body too large"), { status: 413 });
    chunks.push(chunk);
  }
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString() || "{}");
    if (!value || typeof value !== "object" || Array.isArray(value))
      throw new Error();
    return value;
  } catch {
    throw Object.assign(new Error("invalid JSON"), { status: 400 });
  }
}

export async function createServer(options = {}) {
  const cfg = options.config || config(options.env);
  const now = options.now || Date.now;
  const pairMs = options.pairDuration ?? 600_000,
    sessionMs = options.sessionDuration ?? 604_800_000,
    leaseMs = options.leaseDuration ?? 300_000;
  const store = options.store || new Store(cfg.storePath);
  await store.ready;
  const pairs = new Map(),
    messages = [],
    rates = new Map();
  const queues = new Map();
  function serialize(userId, operation) {
    const work = (queues.get(userId) || Promise.resolve())
      .catch(() => {})
      .then(operation);
    queues.set(userId, work);
    const clear = () => {
      if (queues.get(userId) === work) queues.delete(userId);
    };
    work.then(clear, clear);
    return work;
  }
  const telegram = options.telegram || {
    async call(method, data) {
      const response = await fetch(
        `https://api.telegram.org/bot${cfg.botToken}/${method}`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(data),
          signal: AbortSignal.timeout(8000),
        },
      );
      const result = await response.json();
      if (!response.ok || !result.ok)
        throw new Error("Telegram request failed");
      return result.result;
    },
  };
  const report = async (text) => {
    if (cfg.mock) {
      if (options.mockFailure?.()) throw new Error("mock failure");
      messages.push(text);
    } else await telegram.call("sendMessage", { chat_id: cfg.groupId, text });
  };
  const cleanup = () => {
    const t = now();
    for (const [key, p] of pairs) if (p.expiresAt <= t) pairs.delete(key);
    for (const [key, value] of rates) if (value.until <= t) rates.delete(key);
    for (const [key, value] of Object.entries(store.data.sessions))
      if (value.expiresAt <= t) delete store.data.sessions[key];
    for (const [key, value] of Object.entries(store.data.leases))
      if (value.expiresAt + 86400000 <= t) delete store.data.leases[key];
    for (const [key, expiresAt] of Object.entries(store.data.usedAuth))
      if (expiresAt <= t) delete store.data.usedAuth[key];
  };
  const authenticate = (req) => {
    const token = /^Bearer (\S+)$/.exec(req.headers.authorization || "")?.[1];
    const s = token && store.data.sessions[token];
    return s && s.expiresAt > now() ? s : null;
  };
  const authorizePair = async (pairId, user) => {
    const p = pairs.get(pairId);
    if (!p || p.expiresAt <= now() || p.user) return false;
    p.user = user;
    return true;
  };
  const handler = async (req, res) => {
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("X-Frame-Options", "DENY");
    cleanup();
    const url = new URL(req.url, cfg.origin);
    const origin = req.headers.origin;
    let cors = {};
    if (origin) {
      if (!cfg.origins.includes(origin))
        return json(res, 403, { error: "origin not allowed" });
      cors = { "access-control-allow-origin": origin, vary: "Origin" };
      for (const [key, value] of Object.entries(cors))
        res.setHeader(key, value);
    }
    if (req.method === "OPTIONS") {
      res.writeHead(204, {
        ...cors,
        "access-control-allow-methods": "GET,POST,OPTIONS",
        "access-control-allow-headers": "authorization,content-type",
      });
      return res.end();
    }
    const ip = req.socket.remoteAddress || "unknown";
    const rate = rates.get(ip) || { count: 0, until: now() + 60_000 };
    if (++rate.count > 120)
      return json(res, 429, { error: "rate limit" }, cors);
    rates.set(ip, rate);
    if (req.method === "GET" && url.pathname === "/health")
      return json(res, 200, { ok: true }, cors);
    if (req.method === "POST" && url.pathname === "/api/pair") {
      const pairId = id(18),
        secret = id();
      pairs.set(pairId, { secret, expiresAt: now() + pairMs });
      return json(
        res,
        200,
        {
          id: pairId,
          secret,
          loginUrl: `${cfg.origin}/login?id=${encodeURIComponent(pairId)}`,
        },
        cors,
      );
    }
    const poll = /^\/api\/pair\/([^/]+)$/.exec(url.pathname);
    if (req.method === "GET" && poll) {
      const p = pairs.get(poll[1]);
      const secret = /^Bearer (\S+)$/.exec(
        req.headers.authorization || "",
      )?.[1];
      if (
        !p ||
        p.expiresAt <= now() ||
        !secret ||
        secret.length !== p.secret.length ||
        !timingSafeEqual(Buffer.from(secret), Buffer.from(p.secret))
      )
        return json(res, 401, { error: "invalid pairing" }, cors);
      if (!p.user) return json(res, 200, { pending: true }, cors);
      pairs.delete(poll[1]);
      const token = id(32);
      store.data.sessions[token] = {
        user: p.user,
        expiresAt: now() + sessionMs,
      };
      await store.save();
      return json(res, 200, { token, user: p.user }, cors);
    }
    if (req.method === "GET" && url.pathname === "/login") {
      const pairId = url.searchParams.get("id") || "";
      if (!pairs.has(pairId))
        return json(res, 404, { error: "pairing not found" });
      const nonce = id();
      pairs.get(pairId).nonce = nonce;
      res.setHeader(
        "Set-Cookie",
        `scrollock_pair=${nonce}; HttpOnly; SameSite=Lax; Path=/api/telegram-auth; Max-Age=600${cfg.origin.startsWith("https:") ? "; Secure" : ""}`,
      );
      const html = cfg.mock
        ? `<form method="get" action="/api/telegram-auth"><input type="hidden" name="pair" value="${esc(pairId)}"><input type="hidden" name="mock" value="1"><button>Authorize fixture user</button></form>`
        : `<script async src="https://telegram.org/js/telegram-widget.js?22" data-telegram-login="${esc(cfg.botUsername)}" data-size="large" data-auth-url="${esc(cfg.origin)}/api/telegram-auth?pair=${encodeURIComponent(pairId)}"></script>`;
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      return res.end(
        `<!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Connect Scrollock</title><style>body{background:#f5f3ed;color:#203a30;font:16px/1.6 system-ui;max-width:420px;margin:12vh auto;padding:24px}h1{font:42px Georgia}button{background:#264d3d;color:white;padding:14px 20px;border:0;border-radius:6px;cursor:pointer}small{color:#647460}</style><h1>Better together.</h1><p>Connect Telegram to take accountable five-minute breaks.</p><p>Your friends’ group will receive your name, the site you unlock, and route categories visited during your break. Never message contents or search terms.</p>${cfg.mock ? "<p><strong>LOCAL TEST · Mock Telegram</strong></p>" : ""}${html}<p><small>Only members of the configured friends’ group can connect. Return to the extension after authorizing.</small></p></html>`,
      );
    }
    if (req.method === "GET" && url.pathname === "/api/telegram-auth") {
      const pairId = url.searchParams.get("pair");
      const pair = pairs.get(pairId);
      if (!pair || pair.user)
        return json(res, 404, { error: "pairing not found" });
      if (
        !cfg.mock &&
        (!pair.nonce ||
          !req.headers.cookie
            ?.split(/;\s*/)
            .includes(`scrollock_pair=${pair.nonce}`))
      )
        return json(res, 401, { error: "login browser mismatch" });
      let user;
      if (cfg.mock && url.searchParams.get("mock") === "1")
        user = { id: 1001, name: "Fixture User" };
      else {
        const supplied = url.searchParams.get("hash") || "";
        const fields = [...url.searchParams]
          .filter(([k]) => !["hash", "pair"].includes(k))
          .sort(([a], [b]) => a.localeCompare(b))
          .map(([k, v]) => `${k}=${v}`)
          .join("\n");
        const expected = createHmac(
          "sha256",
          createHash("sha256").update(cfg.botToken).digest(),
        )
          .update(fields)
          .digest("hex");
        const authDate = Number(url.searchParams.get("auth_date"));
        if (
          new Set(url.searchParams.keys()).size !==
            [...url.searchParams].length ||
          !/^[1-9][0-9]{0,15}$/.test(url.searchParams.get("id") || "") ||
          !/^[a-f0-9]{64}$/.test(supplied) ||
          store.data.usedAuth[supplied] ||
          !timingSafeEqual(Buffer.from(supplied), Buffer.from(expected)) ||
          !authDate ||
          Math.abs(now() / 1000 - authDate) > 300
        )
          return json(res, 401, { error: "invalid Telegram login" });
        const member = await telegram.call("getChatMember", {
          chat_id: cfg.groupId,
          user_id: url.searchParams.get("id"),
        });
        if (
          !["creator", "administrator", "member"].includes(member.status) &&
          !(member.status === "restricted" && member.is_member)
        )
          return json(res, 403, { error: "group membership required" });
        // Check again after the network await to reject concurrent replays.
        if (store.data.usedAuth[supplied])
          return json(res, 401, { error: "Telegram login already used" });
        store.data.usedAuth[supplied] = now() + 600_000;
        await store.save();
        user = {
          id: Number(url.searchParams.get("id")),
          name: [
            url.searchParams.get("first_name"),
            url.searchParams.get("last_name"),
          ]
            .filter(Boolean)
            .join(" "),
        };
      }
      if (!(await authorizePair(pairId, user)))
        return json(res, 404, { error: "pairing not found" });
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      return res.end("<p>Authorized. Return to the extension.</p>");
    }
    if (
      cfg.mock &&
      req.method === "GET" &&
      url.pathname === "/__mock/messages"
    ) {
      if (!["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(ip))
        return json(res, 403, { error: "localhost only" });
      return json(res, 200, { messages });
    }
    const session = authenticate(req);
    if (!session) return json(res, 401, { error: "invalid session" }, cors);
    return serialize(session.user.id, async () => {
      if (req.method === "POST" && url.pathname === "/api/unlock") {
        const input = await body(req);
        if (!["x", "instagram", "youtube"].includes(input.site))
          return json(res, 400, { error: "invalid site" }, cors);
        const existing = Object.values(store.data.leases).find(
          (l) =>
            l.userId === session.user.id &&
            l.site === input.site &&
            !l.ended &&
            l.expiresAt > now(),
        );
        if (existing)
          return json(
            res,
            200,
            {
              id: existing.id,
              site: existing.site,
              expiresAt: existing.expiresAt,
            },
            cors,
          );
        const lease = {
          id: id(18),
          site: input.site,
          userId: session.user.id,
          expiresAt: now() + leaseMs,
          paths: [],
          ended: false,
        };
        if (!cfg.mock) {
          const member = await telegram.call("getChatMember", {
            chat_id: cfg.groupId,
            user_id: session.user.id,
          });
          if (
            !["creator", "administrator", "member"].includes(member.status) &&
            !(member.status === "restricted" && member.is_member)
          )
            return json(res, 403, { error: "group membership required" }, cors);
        }
        await report(
          `${session.user.name} (${session.user.id}) started a 5-minute ${lease.site} unlock. Feed access ends automatically; activity categories follow.`,
        );
        lease.expiresAt = now() + leaseMs;
        store.data.leases[lease.id] = lease;
        await store.save();
        return json(
          res,
          200,
          { id: lease.id, site: lease.site, expiresAt: lease.expiresAt },
          cors,
        );
      }
      if (req.method === "POST" && url.pathname === "/api/activity") {
        const input = await body(req),
          lease = store.data.leases[input.unlockId];
        if (
          !lease ||
          lease.userId !== session.user.id ||
          lease.ended ||
          lease.expiresAt <= now()
        )
          return json(res, 410, { error: "lease expired" }, cors);
        if (
          !["/feed", "/messages", "/watch", "/search", "/other"].includes(
            input.path,
          )
        )
          return json(res, 400, { error: "invalid path" }, cors);
        if (!lease.paths.includes(input.path)) {
          await report(
            `${session.user.name} activity on ${lease.site}: ${input.path}`,
          );
          lease.paths.push(input.path);
          await store.save();
        }
        return json(res, 200, { ok: true }, cors);
      }
      if (req.method === "POST" && url.pathname === "/api/lock") {
        const input = await body(req),
          lease = store.data.leases[input.unlockId];
        if (!lease || lease.userId !== session.user.id || lease.ended)
          return json(res, 404, { error: "lease not found" }, cors);
        lease.ended = true;
        await store.save();
        await report(`${session.user.name} locked ${lease.site}`);
        return json(res, 200, { ok: true }, cors);
      }
      return json(res, 404, { error: "not found" }, cors);
    });
  };
  return http.createServer((req, res) =>
    handler(req, res).catch((error) =>
      json(res, error.status || 502, {
        error: error.status ? error.message : "upstream failure",
      }),
    ),
  );
}
