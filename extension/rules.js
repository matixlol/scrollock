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
  const shortId = (path) =>
    /^\/shorts\/([A-Za-z0-9_-]+)\/?$/.exec(path)?.[1] || null;
  // Shorts opened directly (address bar, new tab or a link) stay accessible;
  // the shorts the player advances to are the feed, so they stay blocked.
  const blockedRoute = (site, path, openedShorts = new Set()) => {
    if (site === "x") return /^\/(?:home|explore)?\/?$/.test(path);
    if (site === "instagram") {
      // Shared reels are individual posts, not the Reels feed. Match a single
      // shortcode so feed subroutes (such as /reels/audio/...) stay blocked.
      if (
        /^\/reels?\/[A-Za-z0-9_-]+(?:\/embed(?:\/captioned)?)?\/?$/.test(path)
      )
        return false;
      return /^\/(?:explore(?:\/.*)?|reels?(?:\/.*)?)?$/.test(path);
    }
    if (site === "youtube") {
      const id = shortId(path);
      if (id) return !openedShorts.has(id);
      return /^\/(?:feed(?:\/.*)?|shorts(?:\/.*)?)?$/.test(path);
    }
    return false;
  };
  globalThis.ScrollockRules = { siteForHost, shortId, blockedRoute };
})();
