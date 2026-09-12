/* global chrome, browser, SCROLLOCK_API, ScrollockRules */
if (typeof importScripts === "function") importScripts("config.js", "rules.js");
const api = globalThis.browser || chrome;
const sites = ["x", "instagram", "youtube"];
let queue = Promise.resolve();
async function request(path, body, token) {
  const response = await fetch(SCROLLOCK_API + path, {
    method: body === undefined ? "GET" : "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(12000),
  });
  const result = await response.json();
  if (!response.ok)
    throw new Error(
      response.status === 401
        ? "Please reconnect Telegram."
        : response.status >= 500
          ? "Telegram reporting unavailable. Feeds stay locked. Try again."
          : result.error || "Reporting unavailable. Feeds stay locked.",
    );
  return result;
}
async function state() {
  const stored = await api.storage.local.get(["session", "leases", "pair"]);
  stored.leases ||= {};
  return stored;
}
async function native(message) {
  if (!api.runtime.getURL("").startsWith("safari-web-extension:")) return {};
  try {
    const result = await api.runtime.sendNativeMessage(
      "ar.com.poronga.Scrollock",
      message,
    );
    if (!result.ok) throw new Error(result.error);
    return result;
  } catch (error) {
    return {
      warning: `Screen Time: ${error.message}. Open the app to check native app controls.`,
    };
  }
}
async function handle(message, sender) {
  const current = await state();
  const tabSite =
    sender.tab &&
    ScrollockRules.siteForHost(new URL(sender.url || sender.tab.url).hostname);
  const trusted = sender.url?.startsWith(api.runtime.getURL(""));
  if (!trusted && !tabSite) throw new Error("Unsupported sender");
  const site = trusted ? message.site : tabSite;
  if (message.type === "state")
    return {
      user: current.session?.user,
      leases: current.leases,
      pairing: !!current.pair,
    };
  // Ignore messages from an older content script without collecting activity.
  if (message.type === "activity") return {};
  // Content scripts may unblock only their own site, derived from sender above.
  // Pairing, polling and manual locks remain restricted to extension pages.
  if (!trusted && message.type !== "unlock")
    throw new Error("Use the extension popup");
  if (message.type === "native-status") return native({ type: "status" });
  if (message.type === "pair") {
    const pair = await request("/api/pair", {});
    await api.storage.local.set({ pair });
    await api.tabs.create({ url: pair.loginUrl });
    return {};
  }
  if (message.type === "poll") {
    if (!current.pair) return {};
    let result;
    try {
      result = await request(
        "/api/pair/" + current.pair.id,
        undefined,
        current.pair.secret,
      );
    } catch (error) {
      await api.storage.local.remove("pair");
      throw error;
    }
    if (result.token) {
      await api.storage.local.set({ session: result });
      await api.storage.local.remove("pair");
    }
    return {};
  }
  if (!sites.includes(site)) throw new Error("Choose a supported site");
  if (message.type === "unlock") {
    if (!current.session)
      throw new Error("Connect Telegram in the extension first.");
    const lease = await request(
      "/api/unlock",
      { site, minutes: message.minutes, reason: message.reason },
      current.session.token,
    );
    current.leases[site] = lease;
    await api.storage.local.set({ leases: current.leases });
    await api.alarms.create("expire-" + site, { when: lease.expiresAt });
    return native({ type: "unlock", site, expiresAt: lease.expiresAt });
  }
  if (message.type === "lock") {
    const lease = current.leases[site];
    delete current.leases[site];
    await api.storage.local.set({ leases: current.leases });
    const result = await native({ type: "lock", site });
    if (lease)
      await request(
        "/api/lock",
        { unlockId: lease.id },
        current.session?.token,
      );
    return result;
  }
  throw new Error("Unknown action");
}
api.runtime.onMessage.addListener((message, sender, respond) => {
  queue = queue.catch(() => {}).then(() => handle(message, sender));
  queue.then(
    (value) => respond({ ok: true, ...value }),
    (error) => respond({ ok: false, error: error.message }),
  );
  return true;
});
api.alarms.onAlarm.addListener(() => {
  queue = queue
    .catch(() => {})
    .then(async () => {
      const current = await state();
      for (const site of sites)
        if (current.leases[site]?.expiresAt <= Date.now()) {
          delete current.leases[site];
          await native({ type: "lock", site });
        }
      await api.storage.local.set({ leases: current.leases });
    });
});
