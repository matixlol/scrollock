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
    if (site === "youtube")
      return /^\/(?:feed(?:\/.*)?|shorts(?:\/.*)?)?$/.test(path);
    return false;
  };
  globalThis.ScrollockRules = { siteForHost, blockedRoute };
})();
