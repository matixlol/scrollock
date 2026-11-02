import Foundation

/// DeviceActivity rejects schedules shorter than 15 minutes, so short breaks
/// backdate the interval start. The interval still ends at the lease deadline,
/// which is when the monitor extension re-applies the shield.
public struct RelockWindow: Equatable, Sendable {
  public static let minimumInterval: TimeInterval = 15 * 60

  public let start: Date
  public let end: Date

  public init(expiresAt: Date, now: Date = .now) {
    end = expiresAt
    start = min(now, expiresAt.addingTimeInterval(-Self.minimumInterval))
  }

  public func components(calendar: Calendar = .current) -> (start: DateComponents, end: DateComponents) {
    let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
    return (calendar.dateComponents(fields, from: start), calendar.dateComponents(fields, from: end))
  }

  /// One DeviceActivity name per site, so a new break replaces only that site's schedule.
  public static func activityName(for site: Site) -> String { "relock.\(site.rawValue)" }

  public static func site(forActivityName name: String) -> Site? {
    guard name.hasPrefix("relock.") else { return nil }
    return Site(rawValue: String(name.dropFirst("relock.".count)))
  }
}
