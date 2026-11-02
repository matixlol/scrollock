import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import ScrollockKit

extension ManagedSettingsStore.Name {
  /// One store per site, so a break clears only that site's shields and leaves
  /// other sites (and any parental Screen Time limits) in place.
  static func scrollock(_ site: Site) -> Self { .init("scrollock.\(site.rawValue)") }
}

/// Applies and lifts Scrollock's Screen Time shields. Shared by the app and the
/// Device Activity monitor, which relocks a site when its break ends.
struct ShieldController {
  /// Device Activity callbacks can arrive slightly early or late; a deadline this
  /// close counts as reached.
  static let deadlineTolerance: TimeInterval = 30

  let store: SharedStore
  var center = DeviceActivityCenter()

  init(store: SharedStore = SharedStore()) {
    self.store = store
  }

  func selection(for site: Site) -> FamilyActivitySelection {
    store.selectionData(for: site).flatMap { try? JSONDecoder().decode(FamilyActivitySelection.self, from: $0) }
      ?? FamilyActivitySelection(includeEntireCategory: true)
  }

  func setSelection(_ selection: FamilyActivitySelection, for site: Site) {
    store.setSelectionData(try? JSONEncoder().encode(selection), for: site)
    if store.lease(for: site)?.isActive() != true { shield(site) }
  }

  func shield(_ site: Site) {
    let selection = selection(for: site)
    let settings = ManagedSettingsStore(named: .scrollock(site))
    settings.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
    settings.shield.applicationCategories =
      selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
    settings.shield.webDomains = selection.webDomainTokens.isEmpty ? nil : selection.webDomainTokens
    settings.shield.webDomainCategories =
      selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)
  }

  /// Schedules the relock before lifting the shield: if the schedule cannot be
  /// created, the apps stay blocked.
  func beginBreak(_ lease: Lease) throws {
    let window = RelockWindow(expiresAt: lease.expiresAt).components()
    try center.startMonitoring(
      DeviceActivityName(RelockWindow.activityName(for: lease.site)),
      during: DeviceActivitySchedule(intervalStart: window.start, intervalEnd: window.end, repeats: false))
    store.setLease(lease, for: lease.site)
    ManagedSettingsStore(named: .scrollock(lease.site)).clearAllSettings()
  }

  func endBreak(_ site: Site) {
    store.setLease(nil, for: site)
    center.stopMonitoring([DeviceActivityName(RelockWindow.activityName(for: site))])
    shield(site)
  }

  /// Called when a relock interval ends. Ignores stale callbacks for a break
  /// that a newer, longer break has replaced.
  func relockIfDue(_ site: Site, now: Date = .now) {
    guard let lease = store.lease(for: site) else { return shield(site) }
    if lease.expiresAt.timeIntervalSince(now) <= Self.deadlineTolerance { endBreak(site) }
  }

  func relockExpired(now: Date = .now) {
    for site in store.expiredSites(at: now) { endBreak(site) }
  }

  func site(for token: ApplicationToken) -> Site? {
    Site.allCases.first { selection(for: $0).applicationTokens.contains(token) }
  }

  func site(for token: WebDomainToken) -> Site? {
    Site.allCases.first { selection(for: $0).webDomainTokens.contains(token) }
  }

  func site(for token: ActivityCategoryToken) -> Site? {
    Site.allCases.first { selection(for: $0).categoryTokens.contains(token) }
  }
}
