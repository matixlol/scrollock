import Foundation

/// State shared through the App Group by the app and its Screen Time extensions.
/// App selections are stored as opaque encoded `FamilyActivitySelection` data:
/// tokens never leave the device and Scrollock cannot tell which apps they are.
public final class SharedStore: @unchecked Sendable {
  public static let appGroup = "group.ar.com.poronga.Scrollock"

  let defaults: UserDefaults

  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  public convenience init() {
    self.init(defaults: UserDefaults(suiteName: Self.appGroup) ?? .standard)
  }

  public func selectionData(for site: Site) -> Data? {
    defaults.data(forKey: "selection.\(site.rawValue)")
  }

  public func setSelectionData(_ data: Data?, for site: Site) {
    defaults.set(data, forKey: "selection.\(site.rawValue)")
  }

  public func lease(for site: Site) -> Lease? {
    defaults.data(forKey: "lease.\(site.rawValue)").flatMap { try? JSONDecoder().decode(Lease.self, from: $0) }
  }

  public func setLease(_ lease: Lease?, for site: Site) {
    defaults.set(lease.flatMap { try? JSONEncoder().encode($0) }, forKey: "lease.\(site.rawValue)")
  }

  /// Sites whose stored lease has passed its deadline. These must be re-shielded.
  public func expiredSites(at now: Date = .now) -> [Site] {
    Site.allCases.filter { lease(for: $0).map { !$0.isActive(at: now) } ?? false }
  }

  /// Set by the shield action when someone asks for a break from a blocked app.
  public var requestedBreak: Site? {
    get { defaults.string(forKey: "requestedBreak").flatMap(Site.init(rawValue:)) }
    set { defaults.set(newValue?.rawValue, forKey: "requestedBreak") }
  }

  /// The feed the block screen last rendered. Its data source sees the app's
  /// category, while the button handler only gets the app token, so the
  /// handler uses this when its own lookup fails.
  public func noteShieldShown(_ site: Site, at now: Date = .now) {
    defaults.set(site.rawValue, forKey: "shieldShownSite")
    defaults.set(now, forKey: "shieldShownAt")
  }

  public func recentShieldShown(now: Date = .now, within window: TimeInterval = 600) -> Site? {
    guard let at = defaults.object(forKey: "shieldShownAt") as? Date, now.timeIntervalSince(at) < window else { return nil }
    return defaults.string(forKey: "shieldShownSite").flatMap(Site.init(rawValue:))
  }

  /// When the block screen's "Take a break…" was tapped. Set even when the feed
  /// is unknown, so the app can ask which feed instead.
  public var breakRequestedAt: Date? {
    get { defaults.object(forKey: "breakRequestedAt") as? Date }
    set { defaults.set(newValue, forKey: "breakRequestedAt") }
  }

  /// Takes a break request from the block screen if it's recent. Returns the
  /// feed (nil when unknown) or nothing when no request is pending.
  public func takeBreakRequest(now: Date = .now, within window: TimeInterval = 600) -> Site?? {
    defer {
      requestedBreak = nil
      breakRequestedAt = nil
    }
    guard let at = breakRequestedAt, now.timeIntervalSince(at) < window else { return nil }
    return .some(requestedBreak)
  }
}
