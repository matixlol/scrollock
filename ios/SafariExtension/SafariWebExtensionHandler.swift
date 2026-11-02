import SafariServices

/// The web extension runs entirely in JavaScript; it sends no native messages.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
  func beginRequest(with context: NSExtensionContext) {
    context.completeRequest(returningItems: [], completionHandler: nil)
  }
}
