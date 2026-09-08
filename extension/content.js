/* global chrome, browser, ScrollockRules */
(() => {
  const api = globalThis.browser || chrome;
  const site = ScrollockRules.siteForHost(location.hostname);
  let expiresAt = 0,
    gate,
    lastActivity = "",
    lastPath = "";
  function render() {
    if (!document.documentElement) return;
    const unlocked = expiresAt > Date.now();
    const blocked =
      !unlocked && ScrollockRules.blockedRoute(site, location.pathname);
    document.documentElement.toggleAttribute(
      "data-scrollock-unlocked",
      unlocked,
    );
    document.documentElement.toggleAttribute("data-scrollock-blocked", blocked);
    if (blocked && document.body && !gate?.isConnected) {
      gate = document.createElement("div");
      gate.id = "scrollock-gate";
      const shadow = gate.attachShadow({ mode: "closed" });
      shadow.innerHTML = `<style>:host{position:fixed!important;inset:0!important;z-index:2147483647!important;display:grid!important;place-items:center!important;background:#f5f3ed!important;color:#203a30!important;font:16px/1.6 system-ui!important}main{max-width:480px;padding:40px}small{letter-spacing:3px;font-size:12px}h1{font:normal 54px/1.05 Georgia;margin:28px 0 20px}p{color:#637268}span{display:block;margin-top:30px;padding-top:20px;border-top:1px solid #d6dbd1;font-size:13px}.mark{font:48px Georgia;color:#51775d}</style><main><div class="mark">↟</div><small>SCROLLOCK / FEED PAUSED</small><h1>A little less feed.<br>A little more life.</h1><p>Your feed is tucked away. Messages, profiles and direct links are still yours to use.</p><span>Want a quick look? Open Scrollock in your browser’s extensions menu for a five-minute break, shared with your Telegram group.</span></main>`;
      document.body.append(gate);
    }
    if (!blocked && gate) {
      gate.remove();
      gate = null;
    }
    if (unlocked) {
      const key =
        expiresAt + ":" + ScrollockRules.activityPath(site, location.pathname);
      if (key !== lastActivity) {
        lastActivity = key;
        api.runtime
          .sendMessage({
            type: "activity",
            category: ScrollockRules.activityPath(site, location.pathname),
          })
          .then((result) => {
            if (!result.ok) {
              expiresAt = 0;
              render();
            }
          })
          .catch(() => {
            expiresAt = 0;
            render();
          });
      }
    } else lastActivity = "";
    lastPath = location.pathname;
  }
  api.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.leases) {
      expiresAt = changes.leases.newValue?.[site]?.expiresAt || 0;
      render();
    }
  });
  api.runtime
    .sendMessage({ type: "state" })
    .then((result) => {
      expiresAt = result.leases?.[site]?.expiresAt || 0;
      render();
    })
    .catch(() => {});
  new MutationObserver(() => {
    if (lastPath !== location.pathname || !gate?.isConnected) render();
  }).observe(document, { childList: true, subtree: true });
  setInterval(render, 500);
  addEventListener("pageshow", render);
  addEventListener("popstate", render);
  document.addEventListener("visibilitychange", render);
  render();
})();
