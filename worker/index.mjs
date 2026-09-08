const encoder = new TextEncoder();
const SITES = new Set(["x", "instagram", "youtube"]);
const PATHS = new Set(["/feed", "/messages", "/watch", "/search", "/other"]);

const escapeHtml = (value) =>
  String(value).replace(
    /[&<>"']/g,
    (character) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      })[character],
  );

const randomId = (bytes = 24) => {
  const value = crypto.getRandomValues(new Uint8Array(bytes));
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
};

const json = (status, value, headers = {}) =>
  new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });

const secureHeaders = {
  "Cache-Control": "no-store",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
};

const isMember = (member) =>
  ["creator", "administrator", "member"].includes(member.status) ||
  (member.status === "restricted" && member.is_member);

const constantTimeEqual = (left, right) => {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index++)
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return difference === 0;
};

async function telegramHash(token, fields) {
  const secret = await crypto.subtle.digest("SHA-256", encoder.encode(token));
  const key = await crypto.subtle.importKey(
    "raw",
    secret,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(fields),
  );
  return [...new Uint8Array(signature)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function requestBody(request) {
  const text = await request.text();
  if (encoder.encode(text).byteLength > 4096)
    throw Object.assign(new Error("body too large"), { status: 413 });
  try {
    const value = JSON.parse(text || "{}");
    if (!value || typeof value !== "object" || Array.isArray(value))
      throw new Error();
    return value;
  } catch {
    throw Object.assign(new Error("invalid JSON"), { status: 400 });
  }
}

export class ScrollockState {
  constructor(ctx, env) {
    this.storage = ctx.storage;
    this.env = env;
    this.queue = Promise.resolve();
    this.rates = new Map();
    this.messages = [];
    this.now = Date.now;
  }

  fetch(request) {
    const work = this.queue
      .then(() => this.handle(request))
      .catch((error) =>
        json(
          error.status || 502,
          { error: error.status ? error.message : "upstream failure" },
          secureHeaders,
        ),
      );
    this.queue = work.then(() => {});
    return work;
  }

  config() {
    const mock = this.env.MOCK_TELEGRAM === "1";
    if (!mock && (!this.env.TELEGRAM_BOT_TOKEN || !this.env.TELEGRAM_GROUP_ID))
      throw new Error("Telegram configuration is incomplete");
    if (
      !mock &&
      !/^[A-Za-z0-9_]+bot$/i.test(this.env.TELEGRAM_BOT_USERNAME || "")
    )
      throw new Error("Telegram bot username is invalid");
    if (!mock && !this.env.PUBLIC_ORIGIN?.startsWith("https://"))
      throw new Error("PUBLIC_ORIGIN must use HTTPS");
    const origins = (this.env.ALLOWED_ORIGINS || "")
      .split(",")
      .map((origin) => origin.trim())
      .filter(Boolean);
    if (!mock && !origins.length)
      throw new Error("ALLOWED_ORIGINS is required");
    for (const origin of origins)
      if (
        !/^((chrome|moz)-extension:\/\/[^/]+|safari-web-extension:\/\/[^/]+|https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?)$/.test(
          origin,
        )
      )
        throw new Error(`unsafe ALLOWED_ORIGINS entry: ${origin}`);
    return {
      mock,
      origins,
      origin: this.env.PUBLIC_ORIGIN || "http://localhost:8787",
    };
  }

  async telegram(method, data) {
    const response = await fetch(
      `https://api.telegram.org/bot${this.env.TELEGRAM_BOT_TOKEN}/${method}`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(data),
        signal: AbortSignal.timeout(8000),
      },
    );
    const result = await response.json();
    if (!response.ok || !result.ok) throw new Error("Telegram request failed");
    return result.result;
  }

  async report(text, config) {
    if (config.mock) {
      if (this.env.MOCK_FAILURE?.()) throw new Error("mock failure");
      this.messages.push(text);
      return;
    }
    await this.telegram("sendMessage", {
      chat_id: this.env.TELEGRAM_GROUP_ID,
      text,
    });
  }

  async authenticate(request) {
    const token = /^Bearer (\S+)$/.exec(
      request.headers.get("authorization") || "",
    )?.[1];
    const session = token && (await this.storage.get(`session:${token}`));
    if (!session || session.expiresAt <= this.now()) return null;
    return session;
  }

  async handle(request) {
    const config = this.config();
    const url = new URL(request.url);
    const origin = request.headers.get("origin");
    const cors = {};
    if (origin) {
      if (!config.origins.includes(origin))
        return json(403, { error: "origin not allowed" }, secureHeaders);
      cors["Access-Control-Allow-Origin"] = origin;
      cors.Vary = "Origin";
    }
    const headers = { ...secureHeaders, ...cors };
    if (request.method === "OPTIONS")
      return new Response(null, {
        status: 204,
        headers: {
          ...headers,
          "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
          "Access-Control-Allow-Headers": "authorization,content-type",
        },
      });

    const ip = request.headers.get("CF-Connecting-IP") || "unknown";
    const rate = this.rates.get(ip) || { count: 0, until: this.now() + 60_000 };
    if (rate.until <= this.now()) {
      rate.count = 0;
      rate.until = this.now() + 60_000;
    }
    this.rates.set(ip, rate);
    if (++rate.count > 120) return json(429, { error: "rate limit" }, headers);

    if (request.method === "GET" && url.pathname === "/health")
      return json(200, { ok: true }, headers);

    if (request.method === "POST" && url.pathname === "/api/pair") {
      const pair = {
        secret: randomId(),
        expiresAt: this.now() + 600_000,
      };
      const pairId = randomId(18);
      await this.storage.put(`pair:${pairId}`, pair);
      return json(
        200,
        {
          id: pairId,
          secret: pair.secret,
          loginUrl: `${config.origin}/login?id=${encodeURIComponent(pairId)}`,
        },
        headers,
      );
    }

    const poll = /^\/api\/pair\/([^/]+)$/.exec(url.pathname);
    if (request.method === "GET" && poll) {
      const key = `pair:${poll[1]}`;
      const pair = await this.storage.get(key);
      const secret = /^Bearer (\S+)$/.exec(
        request.headers.get("authorization") || "",
      )?.[1];
      if (
        !pair ||
        pair.expiresAt <= this.now() ||
        !secret ||
        !constantTimeEqual(secret, pair.secret)
      ) {
        if (pair?.expiresAt <= this.now()) await this.storage.delete(key);
        return json(401, { error: "invalid pairing" }, headers);
      }
      if (!pair.user) return json(200, { pending: true }, headers);
      const token = randomId(32);
      await this.storage.put(`session:${token}`, {
        user: pair.user,
        expiresAt: this.now() + 604_800_000,
      });
      await this.storage.delete(key);
      return json(200, { token, user: pair.user }, headers);
    }

    if (request.method === "GET" && url.pathname === "/login") {
      const pairId = url.searchParams.get("id") || "";
      const key = `pair:${pairId}`;
      const pair = await this.storage.get(key);
      if (!pair || pair.expiresAt <= this.now())
        return json(404, { error: "pairing not found" }, secureHeaders);
      pair.nonce = randomId();
      await this.storage.put(key, pair);
      const widget = config.mock
        ? `<form method="get" action="/api/telegram-auth"><input type="hidden" name="pair" value="${escapeHtml(pairId)}"><input type="hidden" name="mock" value="1"><button>Authorize fixture user</button></form>`
        : `<script async src="https://telegram.org/js/telegram-widget.js?22" data-telegram-login="${escapeHtml(this.env.TELEGRAM_BOT_USERNAME)}" data-size="large" data-auth-url="${escapeHtml(config.origin)}/api/telegram-auth?pair=${encodeURIComponent(pairId)}"></script>`;
      return new Response(
        `<!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Connect Scrollock</title><style>body{background:#f5f3ed;color:#203a30;font:16px/1.6 system-ui;max-width:420px;margin:12vh auto;padding:24px}h1{font:42px Georgia}button{background:#264d3d;color:white;padding:14px 20px;border:0;border-radius:6px;cursor:pointer}small{color:#647460}</style><h1>Better together.</h1><p>Connect Telegram to take accountable five-minute breaks.</p><p>Your friends’ group will receive your name, the site you unlock, and route categories visited during your break. Never message contents or search terms.</p>${config.mock ? "<p><strong>LOCAL TEST · Mock Telegram</strong></p>" : ""}${widget}<p><small>Only members of the configured friends’ group can connect. Return to the extension after authorizing.</small></p></html>`,
        {
          headers: {
            ...secureHeaders,
            "content-type": "text/html; charset=utf-8",
            "Set-Cookie": `scrollock_pair=${pair.nonce}; HttpOnly; SameSite=Lax; Path=/api/telegram-auth; Max-Age=600${config.origin.startsWith("https:") ? "; Secure" : ""}`,
          },
        },
      );
    }

    if (request.method === "GET" && url.pathname === "/api/telegram-auth") {
      const pairId = url.searchParams.get("pair") || "";
      const key = `pair:${pairId}`;
      const pair = await this.storage.get(key);
      if (!pair || pair.user || pair.expiresAt <= this.now())
        return json(404, { error: "pairing not found" }, secureHeaders);
      if (
        !config.mock &&
        (!pair.nonce ||
          !(request.headers.get("cookie") || "")
            .split(/;\s*/)
            .includes(`scrollock_pair=${pair.nonce}`))
      )
        return json(401, { error: "login browser mismatch" }, secureHeaders);

      let user;
      if (config.mock && url.searchParams.get("mock") === "1") {
        user = { id: 1001, name: "Fixture User" };
      } else {
        const supplied = url.searchParams.get("hash") || "";
        const entries = [...url.searchParams];
        const fields = entries
          .filter(([name]) => !["hash", "pair"].includes(name))
          .sort(([left], [right]) => left.localeCompare(right))
          .map(([name, value]) => `${name}=${value}`)
          .join("\n");
        const expected = await telegramHash(
          this.env.TELEGRAM_BOT_TOKEN,
          fields,
        );
        const authDate = Number(url.searchParams.get("auth_date"));
        const replayKey = `used:${supplied}`;
        const replayExpiry = await this.storage.get(replayKey);
        if (
          new Set(entries.map(([name]) => name)).size !== entries.length ||
          !/^[1-9][0-9]{0,15}$/.test(url.searchParams.get("id") || "") ||
          !/^[a-f0-9]{64}$/.test(supplied) ||
          (replayExpiry && replayExpiry > this.now()) ||
          !constantTimeEqual(supplied, expected) ||
          !authDate ||
          Math.abs(this.now() / 1000 - authDate) > 300
        )
          return json(401, { error: "invalid Telegram login" }, secureHeaders);
        const member = await this.telegram("getChatMember", {
          chat_id: this.env.TELEGRAM_GROUP_ID,
          user_id: url.searchParams.get("id"),
        });
        if (!isMember(member))
          return json(
            403,
            { error: "group membership required" },
            secureHeaders,
          );
        await this.storage.put(replayKey, this.now() + 600_000);
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
      pair.user = user;
      await this.storage.put(key, pair);
      return new Response("<p>Authorized. Return to the extension.</p>", {
        headers: {
          ...secureHeaders,
          "content-type": "text/html; charset=utf-8",
        },
      });
    }

    if (
      config.mock &&
      request.method === "GET" &&
      url.pathname === "/__mock/messages"
    )
      return json(200, { messages: this.messages }, headers);

    const session = await this.authenticate(request);
    if (!session) return json(401, { error: "invalid session" }, headers);

    if (request.method === "POST" && url.pathname === "/api/unlock") {
      const input = await requestBody(request);
      if (!SITES.has(input.site))
        return json(400, { error: "invalid site" }, headers);
      const activeKey = `active:${session.user.id}:${input.site}`;
      const activeId = await this.storage.get(activeKey);
      const existing =
        activeId && (await this.storage.get(`lease:${activeId}`));
      if (existing && !existing.ended && existing.expiresAt > this.now())
        return json(
          200,
          {
            id: existing.id,
            site: existing.site,
            expiresAt: existing.expiresAt,
          },
          headers,
        );
      if (!config.mock) {
        const member = await this.telegram("getChatMember", {
          chat_id: this.env.TELEGRAM_GROUP_ID,
          user_id: session.user.id,
        });
        if (!isMember(member))
          return json(403, { error: "group membership required" }, headers);
      }
      const lease = {
        id: randomId(18),
        site: input.site,
        userId: session.user.id,
        expiresAt: 0,
        paths: [],
        ended: false,
      };
      await this.report(
        `${session.user.name} (${session.user.id}) started a 5-minute ${lease.site} unlock. Feed access ends automatically; activity categories follow.`,
        config,
      );
      lease.expiresAt = this.now() + 300_000;
      await this.storage.put({
        [`lease:${lease.id}`]: lease,
        [activeKey]: lease.id,
      });
      return json(
        200,
        { id: lease.id, site: lease.site, expiresAt: lease.expiresAt },
        headers,
      );
    }

    if (request.method === "POST" && url.pathname === "/api/activity") {
      const input = await requestBody(request);
      const key = `lease:${input.unlockId}`;
      const lease = await this.storage.get(key);
      if (
        !lease ||
        lease.userId !== session.user.id ||
        lease.ended ||
        lease.expiresAt <= this.now()
      )
        return json(410, { error: "lease expired" }, headers);
      if (!PATHS.has(input.path))
        return json(400, { error: "invalid path" }, headers);
      if (!lease.paths.includes(input.path)) {
        await this.report(
          `${session.user.name} activity on ${lease.site}: ${input.path}`,
          config,
        );
        lease.paths.push(input.path);
        await this.storage.put(key, lease);
      }
      return json(200, { ok: true }, headers);
    }

    if (request.method === "POST" && url.pathname === "/api/lock") {
      const input = await requestBody(request);
      const key = `lease:${input.unlockId}`;
      const lease = await this.storage.get(key);
      if (!lease || lease.userId !== session.user.id || lease.ended)
        return json(404, { error: "lease not found" }, headers);
      lease.ended = true;
      await this.storage.put(key, lease);
      await this.report(`${session.user.name} locked ${lease.site}`, config);
      return json(200, { ok: true }, headers);
    }

    return json(404, { error: "not found" }, headers);
  }
}

export default {
  fetch(request, env) {
    const id = env.STATE.idFromName("scrollock");
    return env.STATE.get(id).fetch(request);
  },
};
