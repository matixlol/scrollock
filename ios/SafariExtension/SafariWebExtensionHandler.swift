import SafariServices
import ScrollockKit

/// Merges the extension's Telegram session with the app's shared Keychain copy
/// and replies with the winner, so signing in or out on either side applies to both.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
  func beginRequest(with context: NSExtensionContext) {
    let item = context.inputItems.first as? NSExtensionItem
    let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
    var reply: [String: Any] = [:]
    if message?["type"] as? String == "session",
      let data = try? JSONSerialization.data(withJSONObject: message ?? [:]),
      let incoming = try? JSONDecoder().decode(SessionRecord.self, from: data)
    {
      let store = SessionStore()
      let stored = store.load()
      let winner = stored?.merged(with: incoming) ?? incoming
      if winner != stored { store.save(winner) }
      if let encoded = try? JSONEncoder().encode(winner),
        let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
      {
        reply = object
      }
    }
    let response = NSExtensionItem()
    response.userInfo = [SFExtensionMessageKey: reply]
    context.completeRequest(returningItems: [response], completionHandler: nil)
  }
}
