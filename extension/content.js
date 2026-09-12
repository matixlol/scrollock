/* global chrome, browser, ScrollockRules */
(() => {
  const api = globalThis.browser || chrome;
  const site = ScrollockRules.siteForHost(location.hostname);
  let expiresAt = 0,
    gate;
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
      shadow.innerHTML = `<style>:host{--background:#fff;--label:#000;--secondary:#6c6c70;--action:#007aff;color-scheme:light dark!important;display:block!important;position:relative!important;box-sizing:border-box!important;flex:1 1 100%!important;min-width:0!important;width:100%!important;background:var(--background)!important;color:var(--label)!important;font:17px/1.3 -apple-system,BlinkMacSystemFont,system-ui!important}main,.actions{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:16px}button{-webkit-appearance:none;appearance:none;min-height:44px;padding:8px 4px;border:0;border-radius:8px;background:transparent;color:var(--action);font:inherit;cursor:pointer}button:focus-visible{outline:2px solid var(--action);outline-offset:2px}button:active{opacity:.5}button:disabled{opacity:.4}p{margin:0;padding:0 16px 16px;font-size:13px;color:var(--secondary)}p:empty{display:none}form{padding:0 16px}label{display:block;margin-bottom:12px;font-size:15px}input,textarea{box-sizing:border-box;display:block;width:100%;min-height:44px;margin-top:6px;padding:10px;border:1px solid var(--secondary);border-radius:8px;background:var(--background);color:var(--label);font:16px -apple-system,BlinkMacSystemFont,system-ui}textarea{resize:vertical}.actions{padding:0 0 8px}@media(prefers-color-scheme:dark){:host{--background:#1c1c1e;--label:#fff;--secondary:#aeaeb2;--action:#0a84ff}}</style><main><span>Feed blocked</span><button id="open">Unblock</button></main><form hidden><label>Minutes<input type="number" inputmode="numeric" min="1" max="60" step="1" value="5" required></label><label>Why are you unblocking?<textarea rows="2" maxlength="280" placeholder="A brief reason" required></textarea></label><p>Your Telegram group receives the site, duration and reason with your mention. No browsing activity is collected or reported.</p><div class="actions"><button type="button" id="cancel">Cancel</button><button type="submit">Unblock</button></div></form><p role="status" aria-live="polite"></p>`;
      const button = shadow.querySelector("button");
      const form = shadow.querySelector("form");
      button.addEventListener("click", (event) => {
        if (!event.isTrusted) return;
        form.hidden = !form.hidden;
        if (!form.hidden) shadow.querySelector("textarea").focus();
      });
      shadow.querySelector("#cancel").addEventListener("click", () => {
        form.hidden = true;
      });
      form.addEventListener("submit", async (event) => {
        event.preventDefault();
        const submit = form.querySelector('[type="submit"]');
        if (!event.isTrusted || submit.disabled) return;
        const status = shadow.querySelector('[role="status"]');
        const reason = shadow.querySelector("textarea").value.trim();
        if (!reason) {
          status.textContent = "Enter a brief reason.";
          return;
        }
        submit.disabled = true;
        status.textContent = "";
        try {
          const result = await api.runtime.sendMessage({
            type: "unlock",
            minutes: Number(shadow.querySelector("input").value),
            reason,
          });
          if (!result.ok) throw new Error(result.error);
          if (result.warning) alert(`Feed unblocked. ${result.warning}`);
          const state = await api.runtime.sendMessage({ type: "state" });
          expiresAt = state.leases?.[site]?.expiresAt || 0;
          render();
        } catch (error) {
          status.textContent = error.message;
        } finally {
          submit.disabled = false;
        }
      });
    }
    if (first && first.previousSibling !== gate) first.before(gate);
    if (!first && gate) {
      gate.remove();
      gate = null;
    }
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
