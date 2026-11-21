import ScrollockKit
import UIKit
import WebKit

/// Reads unread direct messages and registers web push with the login of
/// Scrollock's in-app browser: it sends the browser's cookies to the same
/// endpoints x.com and instagram.com call. Everything stays on the device.
enum MessageFetcher {
  static let sites: [Site] = [.instagram, .x]

  /// The public token x.com's web app sends with every API request.
  private static let xWebBearer =
    "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
  /// The app IDs instagram.com's web app sends.
  private static let instagramWebAppID = "936619743392459"
  private static let instagramMobileWebAppID = "1217981644879628"
  /// `PolarisDirectInboxMobileQuery` Relay document ID.
  private static let instagramInboxDocID = "29635390039379294"

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForRequest = 20
    return URLSession(configuration: configuration)
  }()

  /// Cookies for `site`, deduplicated by name and preferring the canonical host
  /// (`x.com` over `twitter.com`, `www.instagram.com` over `.instagram.com`).
  @MainActor static func cookies(for site: Site) async -> [HTTPCookie] {
    let now = Date()
    let matching = await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter { cookie in
      let domain = String(cookie.domain.drop { $0 == "." })
      guard Site(host: domain) == site else { return false }
      if let expires = cookie.expiresDate, expires <= now { return false }
      return true
    }
    // Prefer canonical domain cookies over legacy/broader ones so X's `.x.com`
    // `ct0` is never shadowed by an older `.twitter.com` cookie.
    let preferredDomain: String =
      switch site {
      case .x: "x.com"
      case .instagram: "instagram.com"
      case .youtube: "youtube.com"
      }
    var byName: [String: HTTPCookie] = [:]
    for cookie in matching {
      let domain = String(cookie.domain.drop { $0 == "." }).lowercased()
      let isPreferred = domain == preferredDomain || domain.hasSuffix("." + preferredDomain)
      if let existing = byName[cookie.name] {
        let existingDomain = String(existing.domain.drop { $0 == "." }).lowercased()
        let existingPreferred = existingDomain == preferredDomain || existingDomain.hasSuffix("." + preferredDomain)
        if isPreferred && !existingPreferred {
          byName[cookie.name] = cookie
        } else if isPreferred == existingPreferred && domain.count > existingDomain.count {
          byName[cookie.name] = cookie
        }
      } else {
        byName[cookie.name] = cookie
      }
    }
    return Array(byName.values)
  }

  /// Unread conversations, or nil when the person isn't signed in to the site in Scrollock.
  @MainActor static func unread(on site: Site) async throws -> [UnreadThread]? {
    let cookies = await self.cookies(for: site)
    func cookie(_ name: String) -> String? { cookies.first { $0.name == name }?.value }
    switch site {
    case .instagram:
      guard cookie("sessionid") != nil, let csrf = cookie("csrftoken") else { return nil }
      return try await fetchInstagramUnread(cookies: cookies, csrf: csrf, viewerID: cookie("ds_user_id"))
    case .x:
      guard cookie("auth_token") != nil, let csrf = cookie("ct0") else { return nil }
      var request = URLRequest(
        url: URL(
          string:
            "https://x.com/i/api/1.1/dm/inbox_initial_state.json?dm_users=true&include_groups=true&include_conversation_info=true&filter_low_quality=true&include_quality=all"
        )!)
      request.setValue("Bearer \(xWebBearer)", forHTTPHeaderField: "Authorization")
      request.setValue(csrf, forHTTPHeaderField: "X-Csrf-Token")
      request.setValue("OAuth2Session", forHTTPHeaderField: "X-Twitter-Auth-Type")
      request.setValue("yes", forHTTPHeaderField: "X-Twitter-Active-User")
      request.setValue("https://x.com/messages", forHTTPHeaderField: "Referer")
      applyCookies(cookies, to: &request)
      request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      let (data, response) = try await session.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InboxError.unexpectedResponse }
      // twid is "u=<user ID>", percent-encoded.
      let viewer = cookie("twid")?.removingPercentEncoding.map { String($0.drop { $0 != "=" }.dropFirst()) }
      return try Inbox.x(data, viewerID: viewer)
    case .youtube:
      return nil
    }
  }

  /// Instagram removed `/api/v1/direct_v2/inbox/` on web; mobile web now uses
  /// GraphQL `PolarisDirectInboxMobileQuery` with `fb_dtsg` and `lsd` tokens
  /// embedded in `/direct/inbox/`.
  @MainActor private static func fetchInstagramUnread(
    cookies: [HTTPCookie], csrf: String, viewerID: String?
  ) async throws -> [UnreadThread]? {
    var pageRequest = URLRequest(url: URL(string: "https://www.instagram.com/direct/inbox/")!)
    applyCookies(cookies, to: &pageRequest)
    pageRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    pageRequest.setValue("text/html", forHTTPHeaderField: "Accept")
    let (htmlData, pageResponse) = try await session.data(for: pageRequest)
    guard (pageResponse as? HTTPURLResponse)?.statusCode == 200 else { throw InboxError.unexpectedResponse }
    let html = String(decoding: htmlData, as: UTF8.self)
    guard
      let dtsg = firstMatch(in: html, pattern: #""DTSGInitialData"[^}]*"token":"([^"]+)""#)
        ?? firstMatch(in: html, pattern: #""dtsg":\{"token":"([^"]+)""#),
      let lsd = firstMatch(in: html, pattern: #""LSD"[^}]*"token":"([^"]+)""#)
    else {
      // Redirected to login or not signed in.
      return nil
    }
    let actorID = firstMatch(in: html, pattern: #""actorID":"(\d+)""#) ?? "0"
    let variables = """
      {"device_id_for_iris_subscription":"00000000-0000-4000-8000-000000000000","__relay_internal__pv__IGDIsProfessionalAccountGKrelayprovider":true,"__relay_internal__pv__IGDPinnedThreadsRenderEnabledGKrelayprovider":true,"__relay_internal__pv__IGDMaxUnreadMessagesCountrelayprovider":5,"__relay_internal__pv__IGDThreadListActionsEnabledGKrelayprovider":true}
      """
    let form: [(String, String)] = [
      ("av", actorID),
      ("__d", "www"),
      ("__user", "0"),
      ("__a", "1"),
      ("fb_dtsg", dtsg),
      ("lsd", lsd),
      ("fb_api_caller_class", "RelayModern"),
      ("fb_api_req_friendly_name", "PolarisDirectInboxMobileQuery"),
      ("doc_id", instagramInboxDocID),
      ("variables", variables),
    ]
    var request = URLRequest(url: URL(string: "https://www.instagram.com/api/graphql")!)
    request.httpMethod = "POST"
    request.httpBody = Data(formURLEncoded(form).utf8)
    applyCookies(cookies, to: &request)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(instagramMobileWebAppID, forHTTPHeaderField: "X-IG-App-ID")
    request.setValue(csrf, forHTTPHeaderField: "X-CSRFToken")
    request.setValue(lsd, forHTTPHeaderField: "X-FB-LSD")
    request.setValue("PolarisDirectInboxMobileQuery", forHTTPHeaderField: "X-FB-Friendly-Name")
    request.setValue("https://www.instagram.com/direct/inbox/", forHTTPHeaderField: "Referer")
    request.setValue("https://www.instagram.com", forHTTPHeaderField: "Origin")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InboxError.unexpectedResponse }
    return try Inbox.instagram(data, viewerID: viewerID)
  }

  /// Registers a Web Push subscription directly with X or Instagram using the
  /// in-app browser's cookies, without needing a fake ServiceWorker in WKWebView.
  @MainActor static func registerWebPush(on site: Site, endpoint: URL, keys: WebPushKeys) async throws {
    let cookies = await self.cookies(for: site)
    func cookie(_ name: String) -> String? { cookies.first { $0.name == name }?.value }
    let p256dh = try keys.publicKey.base64URL
    let auth = keys.authSecret.base64URL
    var request: URLRequest
    switch site {
    case .instagram:
      guard cookie("sessionid") != nil, let csrf = cookie("csrftoken") else {
        throw ScrollockError.invalid("Log in to Instagram in Scrollock first.")
      }
      let keysJSON = #"{"p256dh":"\#(p256dh)","auth":"\#(auth)"}"#
      let form: [(String, String)] = [
        ("device_token", endpoint.absoluteString),
        ("device_type", "web_vapid"),
        ("mid", cookie("mid") ?? ""),
        ("subscription_keys", keysJSON),
      ]
      request = URLRequest(url: URL(string: "https://www.instagram.com/api/v1/web/push/register/")!)
      request.httpMethod = "POST"
      request.httpBody = Data(formURLEncoded(form).utf8)
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.setValue(instagramWebAppID, forHTTPHeaderField: "X-IG-App-ID")
      request.setValue(csrf, forHTTPHeaderField: "X-CSRFToken")
      request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
      request.setValue("https://www.instagram.com/direct/inbox/", forHTTPHeaderField: "Referer")
      request.setValue("https://www.instagram.com", forHTTPHeaderField: "Origin")
      request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
    case .x:
      guard cookie("auth_token") != nil, let csrf = cookie("ct0") else {
        throw ScrollockError.invalid("Log in to X in Scrollock first.")
      }
      let payload: [String: Any] = [
        "push_device_info": [
          "udid": "Mac/Chrome",
          "os_version": "Mac/Chrome",
          "env": 3,
          "protocol_version": 1,
          "locale": "en",
          "token": endpoint.absoluteString,
          "encryption_key1": p256dh,
          "encryption_key2": auth,
        ]
      ]
      request = URLRequest(url: URL(string: "https://x.com/i/api/1.1/notifications/settings/login.json")!)
      request.httpMethod = "POST"
      request.httpBody = try JSONSerialization.data(withJSONObject: payload)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(xWebBearer)", forHTTPHeaderField: "Authorization")
      request.setValue(csrf, forHTTPHeaderField: "X-Csrf-Token")
      request.setValue("OAuth2Session", forHTTPHeaderField: "X-Twitter-Auth-Type")
      request.setValue("yes", forHTTPHeaderField: "X-Twitter-Active-User")
      request.setValue("https://x.com/", forHTTPHeaderField: "Referer")
      request.setValue("https://x.com", forHTTPHeaderField: "Origin")
      request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
    case .youtube:
      throw ScrollockError.invalid("Web push isn't supported for YouTube.")
    }
    applyCookies(cookies, to: &request)
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let detail = String(decoding: data, as: UTF8.self).prefix(120)
      throw ScrollockError.server("\(site.displayName) rejected push registration (HTTP \(status)): \(detail)")
    }
  }

  private static func applyCookies(_ cookies: [HTTPCookie], to request: inout URLRequest) {
    for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
      request.setValue(value, forHTTPHeaderField: name)
    }
  }

  private static func firstMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }

  private static func formURLEncoded(_ pairs: [(String, String)]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return pairs.map { key, value in
      let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
      let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
      return "\(k)=\(v)"
    }.joined(separator: "&")
  }

  /// Mobile Safari's user agent, which the in-app browser also presents.
  @MainActor private static var userAgent: String {
    let version = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
    let major = UIDevice.current.systemVersion.split(separator: ".").first ?? "18"
    return
      "Mozilla/5.0 (iPhone; CPU iPhone OS \(version) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
  }

  /// Desktop Chrome user agent for web push registration endpoints that check for desktop browsers.
  private static let desktopUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

  #if DEBUG
    /// Imports Playwright `storageState` JSON files into WKWebView's cookie store
    /// when launched with `-importCookies path1,path2` in the simulator.
    @MainActor static func importDebugCookiesIfRequested() async {
      guard let raw = UserDefaults.standard.string(forKey: "importCookies"), !raw.isEmpty else { return }
      let store = WKWebsiteDataStore.default().httpCookieStore
      var imported = 0
      for path in raw.split(separator: ",").map(String.init) {
        guard
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = json["cookies"] as? [[String: Any]]
        else { continue }
        for item in list {
          guard
            let name = item["name"] as? String,
            let value = item["value"] as? String,
            let domain = item["domain"] as? String
          else { continue }
          var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: (item["path"] as? String) ?? "/",
          ]
          if (item["secure"] as? Bool) == true { props[.secure] = "TRUE" }
          if let expires = item["expires"] as? Double, expires > 0 {
            props[.expires] = Date(timeIntervalSince1970: expires)
          }
          if let cookie = HTTPCookie(properties: props) {
            await store.setCookie(cookie)
            imported += 1
          }
        }
      }
      print("[ScrollockDebug] Imported \(imported) cookies from -importCookies")
    }
  #endif
}
