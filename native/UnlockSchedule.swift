import Foundation

// Calendar-only policy shared with the native schedule regression test.
struct UnlockSchedule {
    let start: DateComponents
    let end: DateComponents
    let warning: DateComponents?

    init(now: Date, expiry: Date, calendar: Calendar = .current) {
        // DeviceActivity rejects intervals shorter than 15 minutes. Use a
        // 16-minute interval and its warning callback for shorter unlocks.
        let intervalEnd = max(expiry, now.addingTimeInterval(16 * 60))
        let warningSeconds = Int(floor(intervalEnd.timeIntervalSince(expiry)))
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        start = calendar.dateComponents(components, from: now)
        end = calendar.dateComponents(components, from: intervalEnd)
        warning = warningSeconds > 0 ? DateComponents(second: warningSeconds) : nil
    }
}
