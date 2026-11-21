import ScrollockKit
import UIKit
import WebKit

/// Reads unread direct messages with the login of Scrollock's in-app browser:
/// it sends the browser's cookies to the same inbox endpoints x.com and
/// instagram.com call for their Messages pages. Everything stays on the device.
enum MessageFetcher {
  static let sites: [Site] = [.instagram, .x]

  /// The public token x.com's web app sends with every API request.
  private static let xWebBearer =
    "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
  /// The app ID instagram.com's web app sends.
  private static let instagramWebAppID = "936619743392459"

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForRequest = 20
    return URLSession(configuration: configuration)
  }()

  /// Unread conversations, or nil when the person isn't signed in to the site in Scrollock.
  @MainActor static func unread(on site: Site) async throws -> [UnreadThread]? {
    let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter {
      Site(host: String($0.domain.drop { $0 == "." })) == site
    }
    func cookie(_ name: String) -> String? { cookies.first { $0.name == name }?.value }
    var request: URLRequest
    switch site {
    case .instagram:
      guard cookie("sessionid") != nil, let csrf = cookie("csrftoken") else { return nil }
      request = URLRequest(
        url: URL(
          string:
            "https://www.instagram.com/api/v1/direct_v2/inbox/?persistentBadging=true&folder=0&limit=20&thread_message_limit=10&visual_message_return_type=unseen"
        )!)
      request.setValue(instagramWebAppID, forHTTPHeaderField: "X-IG-App-ID")
      request.setValue(csrf, forHTTPHeaderField: "X-CSRFToken")
      request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
      request.setValue("https://www.instagram.com/direct/inbox/", forHTTPHeaderField: "Referer")
    case .x:
      guard cookie("auth_token") != nil, let csrf = cookie("ct0") else { return nil }
      request = URLRequest(
        url: URL(
          string:
            "https://x.com/i/api/1.1/dm/inbox_initial_state.json?dm_users=true&include_groups=true&include_conversation_info=true&filter_low_quality=true&include_quality=all"
        )!)
      request.setValue("Bearer \(xWebBearer)", forHTTPHeaderField: "Authorization")
      request.setValue(csrf, forHTTPHeaderField: "X-Csrf-Token")
      request.setValue("OAuth2Session", forHTTPHeaderField: "X-Twitter-Auth-Type")
      request.setValue("yes", forHTTPHeaderField: "X-Twitter-Active-User")
      request.setValue("https://x.com/messages", forHTTPHeaderField: "Referer")
    case .youtube:
      return nil
    }
    for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
      request.setValue(value, forHTTPHeaderField: name)
    }
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InboxError.unexpectedResponse }
    switch site {
    case .instagram:
      return try Inbox.instagram(data, viewerID: cookie("ds_user_id"))
    default:
      // twid is "u=<user ID>", percent-encoded.
      let viewer = cookie("twid")?.removingPercentEncoding.map { String($0.drop { $0 != "=" }.dropFirst()) }
      return try Inbox.x(data, viewerID: viewer)
    }
  }

  /// Mobile Safari's user agent, which the in-app browser also presents.
  @MainActor private static var userAgent: String {
    let version = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
    let major = UIDevice.current.systemVersion.split(separator: ".").first ?? "18"
    return
      "Mozilla/5.0 (iPhone; CPU iPhone OS \(version) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
  }
}
