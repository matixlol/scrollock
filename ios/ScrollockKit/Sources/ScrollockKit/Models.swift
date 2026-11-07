import Foundation

/// The sites the server accepts. Native apps are mapped onto these so a break
/// shares one lease (and one group report) with the Safari extension.
public enum Site: String, CaseIterable, Codable, Identifiable, Sendable {
  case x, instagram, youtube

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .x: "X"
    case .instagram: "Instagram"
    case .youtube: "YouTube"
    }
  }

  /// Matches the extension's `ScrollockRules.siteForHost`.
  public init?(host: String) {
    let host = host.lowercased()
    func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
    if matches("x.com") || matches("twitter.com") {
      self = .x
    } else if matches("instagram.com") {
      self = .instagram
    } else if matches("youtube.com") {
      self = .youtube
    } else {
      return nil
    }
  }

  public var webURL: URL {
    switch self {
    case .x: URL(string: "https://x.com/")!
    case .instagram: URL(string: "https://www.instagram.com/")!
    case .youtube: URL(string: "https://m.youtube.com/")!
    }
  }
}

public struct TelegramUser: Codable, Equatable, Sendable {
  public var id: Int64
  public var name: String
  public var username: String?

  public init(id: Int64, name: String, username: String? = nil) {
    self.id = id
    self.name = name
    self.username = username
  }

  public var label: String { username.map { "@\($0)" } ?? name }
}

public struct Session: Codable, Equatable, Sendable {
  public var token: String
  public var user: TelegramUser

  public init(token: String, user: TelegramUser) {
    self.token = token
    self.user = user
  }
}

public struct Pairing: Codable, Equatable, Sendable {
  public var id: String
  public var secret: String
  public var loginUrl: URL
}

/// A server-granted unblock. `expiresAt` is milliseconds since 1970 on the wire.
public struct Lease: Codable, Equatable, Sendable {
  public var id: String
  public var site: Site
  public var expiresAt: Date

  public init(id: String, site: Site, expiresAt: Date) {
    self.id = id
    self.site = site
    self.expiresAt = expiresAt
  }

  enum CodingKeys: String, CodingKey { case id, site, expiresAt }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    site = try container.decode(Site.self, forKey: .site)
    let milliseconds = try container.decode(Double.self, forKey: .expiresAt)
    expiresAt = Date(timeIntervalSince1970: milliseconds / 1000)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(site, forKey: .site)
    try container.encode((expiresAt.timeIntervalSince1970 * 1000).rounded(), forKey: .expiresAt)
  }

  public func isActive(at now: Date = .now) -> Bool { expiresAt > now }
}

/// Mirrors the extension and server limits so invalid input never leaves the device.
public struct BreakRequest: Equatable, Sendable {
  public static let minutes = 1...60
  public static let maxReasonLength = 280

  public let site: Site
  public let minutes: Int
  public let reason: String

  public init(site: Site, minutes: Int, reason: String) throws {
    guard Self.minutes.contains(minutes) else { throw ScrollockError.invalid("Choose a duration from 1 to 60 minutes.") }
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= Self.maxReasonLength else {
      throw ScrollockError.invalid("Enter a brief reason (up to 280 characters).")
    }
    self.site = site
    self.minutes = minutes
    self.reason = trimmed
  }
}

public enum ScrollockError: LocalizedError, Equatable {
  case invalid(String)
  case unauthorized
  case pairingExpired
  case unavailable
  case unreachable
  case server(String)

  public var errorDescription: String? {
    switch self {
    case .invalid(let message), .server(let message): message
    case .unauthorized: "Please reconnect Telegram."
    case .pairingExpired: "Telegram login expired. Connect again."
    case .unavailable: "Telegram reporting unavailable. Apps stay locked. Try again."
    case .unreachable: "Can't reach Scrollock. Apps stay locked. Check your connection."
    }
  }
}
