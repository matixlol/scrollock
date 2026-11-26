import Foundation

/// A profile found by the home screen's search bar.
public struct ProfileResult: Equatable, Identifiable, Sendable {
  public var site: Site
  public var username: String
  public var displayName: String
  public var avatarURL: URL?
  public var isVerified: Bool

  public var id: String { "\(site.rawValue):\(username.lowercased())" }
  public var url: URL { ProfileSearch.profileURL(site: site, username: username) }

  public init(site: Site, username: String, displayName: String, avatarURL: URL?, isVerified: Bool) {
    self.site = site
    self.username = username
    self.displayName = displayName
    self.avatarURL = avatarURL
    self.isVerified = isVerified
  }
}

public enum ProfileSearchError: Error, Equatable {
  /// The site wants a login: nobody is signed in to it in Scrollock, or the session expired.
  case signedOut
  case unexpectedResponse
}

/// Parses the profile typeahead responses of instagram.com and x.com, and
/// turns typed text into a handle for opening a profile directly.
public enum ProfileSearch {
  /// The sites the search bar covers, in display order.
  public static let sites: [Site] = [.instagram, .x]

  public static func profileURL(site: Site, username: String) -> URL {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "._-")
    let path = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username
    switch site {
    case .instagram: return URL(string: "https://www.instagram.com/\(path)/")!
    case .x: return URL(string: "https://x.com/\(path)")!
    case .youtube: return URL(string: "https://m.youtube.com/@\(path)")!
    }
  }

  /// The query trimmed for sending to a site, or nil when there's nothing to search.
  public static func normalizedQuery(_ query: String) -> String? {
    var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("@") { text.removeFirst() }
    text = text.trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : String(text.prefix(100))
  }

  /// The handle someone typed or pasted, if it could be a username on `site`:
  /// `@name`, `name`, or a profile link like `instagram.com/name`.
  public static func handle(from query: String, for site: Site) -> String? {
    var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: text.contains("://") ? text : "https://\(text)"),
      let host = url.host(), host.contains("."), Site(host: host) == site
    {
      text = url.pathComponents.dropFirst().first ?? ""
    }
    if text.hasPrefix("@") { text.removeFirst() }
    switch site {
    case .instagram:
      // Letters, numbers, periods and underscores; no leading/trailing or double period.
      guard (1...30).contains(text.count), text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }),
        !text.hasPrefix("."), !text.hasSuffix("."), !text.contains("..")
      else { return nil }
      return text.lowercased()
    case .x:
      guard (1...15).contains(text.count), text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
      else { return nil }
      return text
    case .youtube:
      return nil
    }
  }

  /// Parses Instagram's `web/search/topsearch` response (also served at
  /// `api/v1/web/search/topsearch`), whose users are wrapped as
  /// `{"position": 0, "user": {…}}`, and the GraphQL
  /// `xdt_api__v1__fbsearch__topsearch_connection` with the same user shape.
  public static func instagram(_ data: Data) throws -> [ProfileResult] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ProfileSearchError.unexpectedResponse
    }
    if root["require_login"] as? Bool == true || root["message"] as? String == "login_required" {
      throw ProfileSearchError.signedOut
    }
    let container =
      ((root["data"] as? [String: Any])?["xdt_api__v1__fbsearch__topsearch_connection"] as? [String: Any]) ?? root
    guard let users = container["users"] as? [[String: Any]] else {
      throw ProfileSearchError.unexpectedResponse
    }
    let ranked = users.enumerated().sorted { a, b in
      let pa = (a.element["position"] as? NSNumber)?.intValue ?? a.offset
      let pb = (b.element["position"] as? NSNumber)?.intValue ?? b.offset
      return pa < pb
    }
    return unique(
      ranked.compactMap { _, item in
        let user = item["user"] as? [String: Any] ?? item
        guard let username = user["username"] as? String, !username.isEmpty else { return nil }
        return ProfileResult(
          site: .instagram, username: username, displayName: user["full_name"] as? String ?? "",
          avatarURL: (user["profile_pic_url"] as? String).flatMap(URL.init(string:)),
          isVerified: user["is_verified"] as? Bool ?? false)
      })
  }

  /// Parses x.com's `i/api/1.1/search/typeahead.json` response.
  public static func x(_ data: Data) throws -> [ProfileResult] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ProfileSearchError.unexpectedResponse
    }
    if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
      // 32: could not authenticate, 89: expired token, 215: bad authentication, 353: CSRF mismatch.
      let codes = errors.compactMap { ($0["code"] as? NSNumber)?.intValue }
      throw codes.contains(where: [32, 89, 215, 239, 353].contains)
        ? ProfileSearchError.signedOut : ProfileSearchError.unexpectedResponse
    }
    guard let users = root["users"] as? [[String: Any]] else { throw ProfileSearchError.unexpectedResponse }
    return unique(
      users.compactMap { user in
        guard let username = user["screen_name"] as? String, !username.isEmpty else { return nil }
        // `_normal` is 48 px; the 200 px variant stays sharp at row size.
        let avatar = (user["profile_image_url_https"] as? String)?
          .replacingOccurrences(of: "_normal.", with: "_200x200.")
        let verified =
          user["verified"] as? Bool == true || user["is_blue_verified"] as? Bool == true
          || user["ext_is_blue_verified"] as? Bool == true
        return ProfileResult(
          site: .x, username: username, displayName: user["name"] as? String ?? "",
          avatarURL: avatar.flatMap(URL.init(string:)), isVerified: verified)
      })
  }

  private static func unique(_ results: [ProfileResult]) -> [ProfileResult] {
    var seen = Set<String>()
    return results.filter { seen.insert($0.id).inserted }
  }
}
