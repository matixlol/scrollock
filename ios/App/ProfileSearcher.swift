import Foundation
import ScrollockKit
import os

/// Looks up profiles with the same typeahead endpoints instagram.com's and
/// x.com's own search boxes call, signed in with the in-app browser's cookies.
/// Like `MessageFetcher`, everything stays on the device.
enum ProfileSearcher {
  private static let log = Logger(subsystem: "ar.com.poronga.Scrollock", category: "ProfileSearch")
  /// `PolarisSearchBoxRefetchableQuery` Relay document ID.
  private static let instagramSearchDocID = "27706427925724183"

  /// Profiles matching `query` on `site`, best match first.
  /// Throws `ProfileSearchError.signedOut` when the site needs a login.
  @MainActor static func search(_ query: String, on site: Site) async throws -> [ProfileResult] {
    guard let query = ProfileSearch.normalizedQuery(query) else { return [] }
    let cookies = await MessageFetcher.cookies(for: site)
    func cookie(_ name: String) -> String? { cookies.first { $0.name == name }?.value }
    switch site {
    case .instagram:
      guard cookie("sessionid") != nil, let csrf = cookie("csrftoken") else { throw ProfileSearchError.signedOut }
      return try await instagram(query, cookies: cookies, csrf: csrf)
    case .x:
      guard cookie("auth_token") != nil, let csrf = cookie("ct0") else { throw ProfileSearchError.signedOut }
      return try await x(query, cookies: cookies, csrf: csrf)
    case .youtube:
      return []
    }
  }

  /// Page tokens for Instagram's GraphQL API, per login. They last for
  /// hours, so one page load serves a whole search session.
  @MainActor private static var instagramTokens: (session: String, tokens: MessageFetcher.InstagramPageTokens)?

  @MainActor private static func instagram(
    _ query: String, cookies: [HTTPCookie], csrf: String
  ) async throws -> [ProfileResult] {
    let sessionID = cookies.first { $0.name == "sessionid" }?.value ?? ""
    let cached = instagramTokens?.session == sessionID ? instagramTokens?.tokens : nil
    var tokens = cached
    if tokens == nil {
      tokens = try await MessageFetcher.instagramPageTokens(
        cookies: cookies, page: "https://www.instagram.com/explore/search/")
    }
    guard let tokens else { throw ProfileSearchError.signedOut }
    instagramTokens = (sessionID, tokens)
    do {
      return try await instagram(query, cookies: cookies, csrf: csrf, tokens: tokens)
    } catch ProfileSearchError.unexpectedResponse where cached != nil {
      // The cached tokens may have expired; fetch fresh ones once.
      instagramTokens = nil
      return try await instagram(query, cookies: cookies, csrf: csrf)
    }
  }

  @MainActor private static func instagram(
    _ query: String, cookies: [HTTPCookie], csrf: String, tokens: MessageFetcher.InstagramPageTokens
  ) async throws -> [ProfileResult] {
    // instagram.com's search box runs this Relay query; the old
    // `web/search/topsearch` REST endpoint now answers 404.
    let variables: [String: Any] = [
      "data": [
        "context": "blended", "include_reel": "true", "query": query, "rank_token": "",
        "search_surface": "web_top_search",
      ],
      "hasQuery": true,
    ]
    let variablesJSON = String(decoding: try JSONSerialization.data(withJSONObject: variables), as: UTF8.self)
    var request = URLRequest(url: URL(string: "https://www.instagram.com/api/graphql")!)
    request.httpMethod = "POST"
    request.httpBody = Data(
      MessageFetcher.formURLEncoded([
        ("av", tokens.actorID),
        ("__d", "www"),
        ("__user", "0"),
        ("__a", "1"),
        ("fb_dtsg", tokens.dtsg),
        ("lsd", tokens.lsd),
        ("fb_api_caller_class", "RelayModern"),
        ("fb_api_req_friendly_name", "PolarisSearchBoxRefetchableQuery"),
        ("variables", variablesJSON),
        ("server_timestamps", "true"),
        ("doc_id", instagramSearchDocID),
      ]).utf8)
    MessageFetcher.applyCookies(cookies, to: &request)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(MessageFetcher.instagramMobileWebAppID, forHTTPHeaderField: "X-IG-App-ID")
    request.setValue(csrf, forHTTPHeaderField: "X-CSRFToken")
    request.setValue(tokens.lsd, forHTTPHeaderField: "X-FB-LSD")
    request.setValue("PolarisSearchBoxRefetchableQuery", forHTTPHeaderField: "X-FB-Friendly-Name")
    request.setValue("https://www.instagram.com/explore/search/", forHTTPHeaderField: "Referer")
    request.setValue("https://www.instagram.com", forHTTPHeaderField: "Origin")
    request.setValue(MessageFetcher.userAgent, forHTTPHeaderField: "User-Agent")
    let (data, response) = try await MessageFetcher.session.data(for: request)
    return try decode(data, response, site: .instagram, parse: ProfileSearch.instagram)
  }

  @MainActor private static func x(_ query: String, cookies: [HTTPCookie], csrf: String) async throws -> [ProfileResult] {
    var components = URLComponents(string: "https://x.com/i/api/1.1/search/typeahead.json")!
    components.queryItems = [
      URLQueryItem(name: "include_ext_is_blue_verified", value: "1"),
      URLQueryItem(name: "include_ext_verified_type", value: "1"),
      URLQueryItem(name: "include_ext_profile_image_shape", value: "1"),
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "src", value: "search_box"),
      URLQueryItem(name: "result_type", value: "users"),
    ]
    var request = URLRequest(url: components.url!)
    MessageFetcher.applyCookies(cookies, to: &request)
    request.setValue("Bearer \(MessageFetcher.xWebBearer)", forHTTPHeaderField: "Authorization")
    request.setValue(csrf, forHTTPHeaderField: "X-Csrf-Token")
    request.setValue("OAuth2Session", forHTTPHeaderField: "X-Twitter-Auth-Type")
    request.setValue("yes", forHTTPHeaderField: "X-Twitter-Active-User")
    request.setValue("https://x.com/search", forHTTPHeaderField: "Referer")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(MessageFetcher.userAgent, forHTTPHeaderField: "User-Agent")
    let (data, response) = try await MessageFetcher.session.data(for: request)
    return try decode(data, response, site: .x, parse: ProfileSearch.x)
  }

  private static func decode(
    _ data: Data, _ response: URLResponse, site: Site, parse: (Data) throws -> [ProfileResult]
  ) throws -> [ProfileResult] {
    let http = response as? HTTPURLResponse
    let status = http?.statusCode ?? 0
    let finalPath = http?.url?.path() ?? ""
    log.debug("\(site.rawValue, privacy: .public) search HTTP \(status) \(finalPath, privacy: .public)")
    // Signed-out requests get 401/403, or are redirected to the login page.
    if status == 401 || finalPath.contains("/accounts/login") || finalPath.contains("/i/flow/login") {
      throw ProfileSearchError.signedOut
    }
    do {
      return try parse(data)
    } catch ProfileSearchError.unexpectedResponse where status == 403 {
      throw ProfileSearchError.signedOut
    }
  }
}
