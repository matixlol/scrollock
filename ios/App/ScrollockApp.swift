import BackgroundTasks
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
      if phase == .background { delegate.scheduleMessageCheck() }
    }
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  @MainActor let model = AppModel()
  static let messageCheck = "ar.com.poronga.Scrollock.messages"

  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.messageCheck, using: .main) { task in
      self.checkMessages(task as! BGAppRefreshTask)
    }
    return true
  }

  /// Asks iOS to wake Scrollock to check for new messages. iOS decides when,
  /// based on how often the app is used, so this is no faster than every 15
  /// minutes and often slower.
  func scheduleMessageCheck() {
    let request = BGAppRefreshTaskRequest(identifier: Self.messageCheck)
    request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  private func checkMessages(_ task: BGAppRefreshTask) {
    scheduleMessageCheck()
    let check = Task { @MainActor in await model.checkMessages() }
    task.expirationHandler = { check.cancel() }
    Task { task.setTaskCompleted(success: await check.value) }
  }

  /// Tapping a message notification opens the conversation; tapping the block
  /// screen's "Take a break…" notification opens the break form.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    if let url = (response.notification.request.content.userInfo["url"] as? String).flatMap(URL.init(string:)) {
      return await MainActor.run { model.openingURL = url }
    }
    let site = (response.notification.request.content.userInfo["site"] as? String).flatMap(Site.init(rawValue:))
    await MainActor.run { model.requestBreak(site) }
  }
}
