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
  globalThis.ScrollockRules = { siteForHost, blockedRoute };
})();
