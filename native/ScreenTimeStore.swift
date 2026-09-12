import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

enum ScreenTimeStore {
    static let sites = ["x", "instagram", "youtube"]
    static let defaults = UserDefaults(suiteName: "group.ar.com.poronga.Scrollock")!

    static func selection(_ site: String) -> FamilyActivitySelection {
        guard let data = defaults.data(forKey: "selection.\(site)"),
              let value = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return FamilyActivitySelection() }
        return value
    }

    static func save(_ selection: FamilyActivitySelection, for site: String) throws {
        // Only individual app tokens are supported, not categories or websites.
        var apps = FamilyActivitySelection()
        apps.applicationTokens = selection.applicationTokens
        guard sites.filter({ $0 != site }).allSatisfy({
            Self.selection($0).applicationTokens.isDisjoint(with: apps.applicationTokens)
        }) else { throw NativeError.duplicateApps }
        defaults.set(try JSONEncoder().encode(apps), forKey: "selection.\(site)")
        lock(site)
    }

    static func store(_ site: String) -> ManagedSettingsStore {
        ManagedSettingsStore(named: ManagedSettingsStore.Name("scrollock.\(site)"))
    }

    static func lock(_ site: String) {
        defaults.removeObject(forKey: "expires.\(site)")
        applyShield(site)
        DeviceActivityCenter().stopMonitoring([DeviceActivityName("scrollock.\(site)")])
    }

    static func applyShield(_ site: String) {
        let tokens = selection(site).applicationTokens
        store(site).shield.applications = tokens.isEmpty ? nil : tokens
    }

    static func reconcile() {
        for site in sites {
            let expiry = defaults.double(forKey: "expires.\(site)")
            if expiry <= Date().timeIntervalSince1970 { lock(site) }
        }
    }

    static func unlock(_ site: String, until expiry: Date) throws -> Int {
        guard sites.contains(site), expiry > Date(), expiry.timeIntervalSinceNow <= 3601 else {
            throw NativeError.invalidRequest
        }
        let count = selection(site).applicationTokens.count
        if count == 0 { return 0 }
        guard AuthorizationCenter.shared.authorizationStatus == .approved else {
            throw NativeError.authorizationRequired
        }
        // Warning/end callbacks run in the extension, with no usage events.
        let timing = UnlockSchedule(now: Date(), expiry: expiry)
        let schedule = DeviceActivitySchedule(
            intervalStart: timing.start,
            intervalEnd: timing.end,
            repeats: false,
            warningTime: timing.warning
        )
        // Fail closed: do not remove shields if scheduling fails.
        lock(site)
        defaults.set(expiry.timeIntervalSince1970, forKey: "expires.\(site)")
        do {
            try DeviceActivityCenter().startMonitoring(DeviceActivityName("scrollock.\(site)"), during: schedule)
        } catch {
            defaults.removeObject(forKey: "expires.\(site)")
            throw error
        }
        store(site).shield.applications = nil
        return count
    }

    static func relockIfExpired(_ activity: DeviceActivityName) {
        let site = String(activity.rawValue.dropFirst("scrollock.".count))
        guard activity.rawValue.hasPrefix("scrollock."), sites.contains(site) else { return }
        let expiry = defaults.double(forKey: "expires.\(site)")
        // Ignore stale callbacks belonging to a replaced schedule. The 1 second
        // tolerance accounts for calendar schedules discarding subsecond precision.
        if expiry <= Date().timeIntervalSince1970 + 1 {
            defaults.removeObject(forKey: "expires.\(site)")
            applyShield(site)
        }
    }
}

enum NativeError: LocalizedError {
    case invalidRequest, authorizationRequired, duplicateApps
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid native unlock request."
        case .authorizationRequired: return "Open Scrollock and allow Screen Time access first."
        case .duplicateApps: return "An app can belong to only one site. Remove it from the other selection first."
        }
    }
}
