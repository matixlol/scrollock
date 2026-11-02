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
    guard action == .secondaryButtonPressed else { return completion(.close) }
    // Apps locked through a category arrive with their own token, which may not
    // map to a feed. Fall back to the only configured feed, or let the app ask.
    let site = site ?? controller.onlyConfiguredSite
    controller.store.requestedBreak = site
    controller.store.breakRequestedAt = .now
    let content = UNMutableNotificationContent()
    content.title = site.map { "Take a break from \($0.displayName)" } ?? "Take a break"
    content.body = "Tap to choose how long and why. Your group will see it."
    content.sound = .default
    if let site { content.userInfo = ["site": site.rawValue] }
    let request = UNNotificationRequest(identifier: "break", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { _ in completion(.close) }
  }
}
