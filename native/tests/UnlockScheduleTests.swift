import Foundation

@main
struct UnlockScheduleTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Deliberately near midnight, with nonzero fractional seconds.
        let now = Date(timeIntervalSince1970: 1_800_057_590.9)
        for (minutes, expectedWarning) in [(1, 900), (15, 60), (16, 0), (60, 0)] {
            let expiry = now.addingTimeInterval(Double(minutes * 60))
            let schedule = UnlockSchedule(now: now, expiry: expiry, calendar: calendar)
            let start = calendar.date(from: schedule.start)!
            let end = calendar.date(from: schedule.end)!
            precondition(end.timeIntervalSince(start) >= 15 * 60)
            precondition((schedule.warning?.second ?? 0) == expectedWarning)
            let callback = end.addingTimeInterval(-Double(expectedWarning))
            precondition(abs(callback.timeIntervalSince(expiry)) < 1)
            precondition(callback.addingTimeInterval(1) >= expiry)
        }
        // Network delay must reduce the remaining unlock, not start a new full
        // duration. Fractional warning rounding must not miss the expiry guard.
        let expiry = now.addingTimeInterval(57.65)
        let schedule = UnlockSchedule(now: now, expiry: expiry, calendar: calendar)
        precondition(schedule.warning?.second == 902)
        let callback = calendar.date(from: schedule.end)!.addingTimeInterval(-902)
        precondition(abs(callback.timeIntervalSince(expiry)) < 1)
        precondition(callback.addingTimeInterval(1) >= expiry)
        print("Native unlock schedule tests passed (1, 15, 16, 60 minutes; fractional/network-delay deadline).")
    }
}
