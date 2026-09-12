import SafariServices
import FamilyControls

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        var result: [String: Any]
        do {
            switch message["type"] as? String {
            case "status":
                ScreenTimeStore.reconcile()
                result = ["ok": true,
                          "authorized": AuthorizationCenter.shared.authorizationStatus == .approved,
                          "selections": Dictionary(uniqueKeysWithValues: ScreenTimeStore.sites.map {
                              ($0, ScreenTimeStore.selection($0).applicationTokens.count)
                          })]
            case "unlock":
                guard let site = message["site"] as? String,
                      let milliseconds = message["expiresAt"] as? Double else { throw NativeError.invalidRequest }
                let count = try ScreenTimeStore.unlock(site, until: Date(timeIntervalSince1970: milliseconds / 1000))
                result = ["ok": true, "selectedApps": count]
            case "lock":
                guard let site = message["site"] as? String,
                      ScreenTimeStore.sites.contains(site) else { throw NativeError.invalidRequest }
                ScreenTimeStore.lock(site)
                result = ["ok": true]
            default:
                throw NativeError.invalidRequest
            }
        } catch {
            result = ["ok": false, "error": error.localizedDescription]
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: result]
        context.completeRequest(returningItems: [response])
    }
}
