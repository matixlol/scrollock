import DeviceActivity
import ScrollockKit

/// Re-applies a site's shields when its break's Device Activity interval ends.
final class RelockMonitor: DeviceActivityMonitor {
  override func intervalDidEnd(for activity: DeviceActivityName) {
    super.intervalDidEnd(for: activity)
    guard let site = RelockWindow.site(forActivityName: activity.rawValue) else { return }
    ShieldController().relockIfDue(site)
  }

  override func intervalDidStart(for activity: DeviceActivityName) {
    super.intervalDidStart(for: activity)
    // Short breaks backdate their start, so this fires immediately; use it as a
    // chance to catch any other break whose end callback was missed.
    ShieldController().relockExpired()
  }
}
