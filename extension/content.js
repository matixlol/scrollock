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
      shadow.innerHTML = `<style>:host{color-scheme:light dark!important;display:block!important;position:relative!important;box-sizing:border-box!important;flex:1 1 100%!important;min-width:0!important;width:100%!important;background:Canvas!important;color:CanvasText!important;font:14px/1.5 system-ui!important}main{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:16px}button{min-height:44px;padding:8px 12px;border:1px solid GrayText;border-radius:6px;background:ButtonFace;color:ButtonText;font:inherit;cursor:pointer}button:focus-visible{outline:2px solid Highlight;outline-offset:2px}button:disabled{opacity:.6}p{margin:0;padding:0 16px 16px;font-size:13px}p:empty{display:none}</style><main><span>Feed blocked</span><button title="Unblock for 5 minutes; your Telegram group receives your name, site and route categories.">Unblock</button></main><p role="status" aria-live="polite"></p>`;
      const button = shadow.querySelector("button");
      button.addEventListener("click", async (event) => {
        if (!event.isTrusted || button.disabled) return;
        button.disabled = true;
        const status = shadow.querySelector("p");
        status.textContent = "";
        try {
          const result = await api.runtime.sendMessage({ type: "unlock" });
          if (!result.ok) throw new Error(result.error);
          const state = await api.runtime.sendMessage({ type: "state" });
          expiresAt = state.leases?.[site]?.expiresAt || 0;
          render();
        } catch (error) {
          status.textContent = error.message;
        } finally {
          button.disabled = false;
        }
      });
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
