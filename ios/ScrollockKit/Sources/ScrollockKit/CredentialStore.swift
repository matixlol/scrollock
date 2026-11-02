import Foundation
import Security

/// Keeps the Telegram session bearer token in the Keychain, on this device only.
public struct CredentialStore: Sendable {
  let service: String

  public init(service: String = "ar.com.poronga.Scrollock.session") {
    self.service = service
  }

  public func load() -> Session? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
      return nil
    }
    return try? JSONDecoder().decode(Session.self, from: data)
  }

  @discardableResult
  public func save(_ session: Session?) -> Bool {
    SecItemDelete(baseQuery as CFDictionary)
    guard let session, let data = try? JSONEncoder().encode(session) else { return true }
    var item = baseQuery
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  var baseQuery: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "telegram"]
  }
}
