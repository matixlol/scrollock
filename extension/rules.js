(function () {
  const siteForHost = (host) => {
    const is = (domain) => host === domain || host.endsWith("." + domain);
    return is("x.com") || is("twitter.com")
      ? "x"
      : is("instagram.com")
        ? "instagram"
        : is("youtube.com")
          ? "youtube"
          : null;
  };
  const blockedRoute = (site, path) => {
    if (site === "x") return /^\/(?:home|explore|search)?\/?$/.test(path);
    if (site === "instagram")
      return /^\/(?:explore(?:\/.*)?|reels?(?:\/.*)?)?$/.test(path);
    if (site === "youtube")
      return /^\/(?:feed(?:\/.*)?|shorts(?:\/.*)?)?$/.test(path);
    return false;
  };
  // Deliberately report route categories, not usernames, search terms or video IDs.
  const activityPath = (site, path) => {
    if (blockedRoute(site, path)) return "/feed";
    if (/^\/(?:messages|direct|inbox)(?:\/|$)/.test(path)) return "/messages";
    if (site === "youtube" && path === "/watch") return "/watch";
    if (/^\/(?:results|search)(?:\/|$)/.test(path)) return "/search";
    return "/other";
  };
  globalThis.ScrollockRules = { siteForHost, blockedRoute, activityPath };
})();
