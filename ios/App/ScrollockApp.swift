import ScrollockKit
import SwiftUI
import UserNotifications

@main
struct ScrollockApp: App {
  @UIApplicationDelegateAdaptor private var delegate: AppDelegate
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ContentView(model: delegate.model)
        .onOpenURL { delegate.model.open($0) }
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      if phase == .active { delegate.model.refresh() }
    }
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  @MainActor let model = AppModel()

  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return true
  }

  /// Tapping the block screen's "Take a break…" notification opens the break form.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let site = (response.notification.request.content.userInfo["site"] as? String).flatMap(Site.init(rawValue:))
    await MainActor.run { model.requestBreak(site) }
  }
}
