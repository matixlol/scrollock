import Foundation
import Security

/// The Telegram session (or a sign-out) and when it happened, in milliseconds
/// since 1970 so it compares directly with the extension's `Date.now()`.
public struct SessionRecord: Codable, Equatable, Sendable {
  public var session: Session?
  public var updatedAt: Double

  public init(session: Session?, updatedAt: Double = (Date.now.timeIntervalSince1970 * 1000).rounded()) {
    self.session = session
    self.updatedAt = updatedAt
  }

  /// The app and Safari extension each keep a copy; the most recent change wins.
  public func merged(with other: SessionRecord?) -> SessionRecord {
    guard let other, other.updatedAt > updatedAt else { return self }
    return other
  }
}

/// Keeps the session in a Keychain item shared through the App Group, so the
/// app and its Safari extension stay signed in together. Never leaves the device.
public struct SessionStore: Sendable {
  let accessGroup: String?

  public init(accessGroup: String? = SharedStore.appGroup) {
    self.accessGroup = accessGroup
  }

  public func load() -> SessionRecord? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
      return nil
    }
    return try? JSONDecoder().decode(SessionRecord.self, from: data)
  }

  @discardableResult
  public func save(_ record: SessionRecord) -> Bool {
    guard let data = try? JSONEncoder().encode(record) else { return false }
    SecItemDelete(baseQuery as CFDictionary)
    var item = baseQuery
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  var baseQuery: [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "ar.com.poronga.Scrollock.session",
      kSecAttrAccount as String: "telegram",
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    return query
  }
}
