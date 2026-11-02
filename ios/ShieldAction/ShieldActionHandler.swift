import ManagedSettings
import ScrollockKit
import UserNotifications

/// Handles block-screen buttons. A shield extension cannot open the app or show
/// a form, so "Take a break…" posts a notification that opens the break form.
final class ShieldActionHandler: ShieldActionDelegate {
  let controller = ShieldController()

  override func handle(
    action: ShieldAction, for application: ApplicationToken,
    completionHandler: @escaping (ShieldActionResponse) -> Void
  ) {
    respond(to: action, site: controller.site(for: application), completionHandler)
  }

  override func handle(
    action: ShieldAction, for webDomain: WebDomainToken,
    completionHandler: @escaping (ShieldActionResponse) -> Void
  ) {
    respond(to: action, site: controller.site(for: webDomain), completionHandler)
  }

  override func handle(
    action: ShieldAction, for category: ActivityCategoryToken,
    completionHandler: @escaping (ShieldActionResponse) -> Void
  ) {
    respond(to: action, site: controller.site(for: category), completionHandler)
  }

  func respond(to action: ShieldAction, site: Site?, _ completion: @escaping (ShieldActionResponse) -> Void) {
    guard action == .secondaryButtonPressed, let site else { return completion(.close) }
    controller.store.requestedBreak = site
    let content = UNMutableNotificationContent()
    content.title = "Take a break from \(site.displayName)"
    content.body = "Tap to choose how long and why. Your group will see it."
    content.userInfo = ["site": site.rawValue]
    let request = UNNotificationRequest(identifier: "break.\(site.rawValue)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { _ in completion(.close) }
  }
}
