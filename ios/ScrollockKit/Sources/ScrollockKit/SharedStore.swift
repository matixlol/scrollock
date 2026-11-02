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
}
