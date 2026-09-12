/* global chrome, browser, ScrollockRules */
(() => {
  const api = globalThis.browser || chrome;
  const site = ScrollockRules.siteForHost(location.hostname);
  let expiresAt = 0,
    gate,
    lastActivity = "";
  // Keep the site shell, navigation and search controls intact. Never fall back
  // to hiding body/main when a site changes its feed markup.
  const feeds = {
    x: '[data-testid="primaryColumn"] section[role="region"], [data-testid="primaryColumn"] [data-testid="cellInnerDiv"]',
    instagram:
      'main > :nth-child(1) > div[style], main article, main div:has(> div > div > a[href^="/p/"]), section > main div.xw7yly9 > div.xmnaoh6',
    youtube:
      "ytd-browse, ytd-shorts, ytm-shorts, ytm-reel-video-renderer, .rich-grid-renderer-contents, ytm-browse ytm-section-list-renderer",
  };
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
    const selector =
      site === "instagram" && /^\/reels?(?:\/|$)/.test(location.pathname)
        ? "main > div"
        : feeds[site];
    const targets = new Set(
      blocked && selector
        ? [...document.querySelectorAll(selector)].filter(
            (element) => element !== gate,
          )
        : [],
    );
    document.querySelectorAll("[data-scrollock-feed]").forEach((element) => {
      if (!targets.has(element)) element.removeAttribute("data-scrollock-feed");
    });
    targets.forEach((element) => {
      if (!element.hasAttribute("data-scrollock-feed"))
        element.setAttribute("data-scrollock-feed", "");
    });
    // Use the outermost feed target so the notice is never inside hidden content.
    const first = [...targets].find(
      (element) => !element.parentElement.closest("[data-scrollock-feed]"),
    );
    if (first && !gate) {
      gate = document.createElement("div");
      gate.id = "scrollock-gate";
      const shadow = gate.attachShadow({ mode: "closed" });
      shadow.innerHTML = `<style>:host{display:block!important;position:relative!important;box-sizing:border-box!important;flex:1 1 100%!important;min-width:0!important;width:100%!important;background:#f5f3ed!important;color:#203a30!important;font:15px/1.6 system-ui!important}main{max-width:480px;margin:auto;padding:28px 24px}small{letter-spacing:2px;font-size:11px}h1{font:normal 36px/1.1 Georgia;margin:20px 0 16px}p{color:#637268}span{display:block;margin-top:24px;padding-top:16px;border-top:1px solid #d6dbd1;font-size:13px}.mark{font:36px Georgia;color:#51775d}</style><main><div class="mark">↟</div><small>SCROLLOCK / FEED PAUSED</small><h1>A little less feed.<br>A little more life.</h1><p>Your feed is tucked away. Messages, profiles and direct links are still yours to use.</p><span>Want a quick look? Open Scrollock in your browser’s extensions menu for a five-minute break, shared with your Telegram group.</span></main>`;
    }
    if (first && first.previousSibling !== gate) first.before(gate);
    if (!first && gate) {
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
  new MutationObserver(render).observe(document, {
    childList: true,
    subtree: true,
  });
  setInterval(render, 500);
  addEventListener("pageshow", render);
  addEventListener("popstate", render);
  document.addEventListener("visibilitychange", render);
  render();
})();
