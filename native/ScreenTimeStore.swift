import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

enum ScreenTimeStore {
    static let sites = ["x", "instagram", "youtube"]
    static let defaults = UserDefaults(suiteName: "group.ar.com.poronga.Scrollock")!

    static var hasConnection: Bool {
        guard let token = defaults.string(forKey: "connection.sessionToken") else { return false }
        return !token.isEmpty && defaults.string(forKey: "connection.apiOrigin") != nil
    }

    static func syncConnection(apiOrigin: String, sessionToken: String) throws {
        guard let url = URL(string: apiOrigin),
              url.user == nil,
              url.password == nil,
              (url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host)))
        else { throw NativeError.invalidRequest }
        defaults.set(url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: "connection.apiOrigin")
        if sessionToken.isEmpty {
            defaults.removeObject(forKey: "connection.sessionToken")
        } else {
            defaults.set(sessionToken, forKey: "connection.sessionToken")
        }
    }

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
        defaults.removeObject(forKey: "shieldMessage.\(site)")
        applyShield(site)
        DeviceActivityCenter().stopMonitoring([DeviceActivityName("scrollock.\(site)")])
    }

    static func applyShield(_ site: String) {
#if DEBUG && targetEnvironment(simulator)
        if simulatorDemoEnabled {
            store(site).shield.applicationCategories = site == "x" ? .all() : nil
            return
        }
#endif
        let tokens = selection(site).applicationTokens
        store(site).shield.applications = tokens.isEmpty ? nil : tokens
    }

    static func reconcile() {
        for site in sites {
            let expiry = defaults.double(forKey: "expires.\(site)")
            if expiry <= Date().timeIntervalSince1970 { lock(site) }
        }
    }

    static func expiry(_ site: String) -> Date? {
        let value = defaults.double(forKey: "expires.\(site)")
        return value > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: value) : nil
    }

    static func site(containing token: ApplicationToken) -> String? {
#if DEBUG && targetEnvironment(simulator)
        if simulatorDemoEnabled { return "x" }
#endif
        return sites.first { selection($0).applicationTokens.contains(token) }
    }

    static func shieldMessage(_ site: String) -> String? {
        defaults.string(forKey: "shieldMessage.\(site)")
    }

    static func setShieldMessage(_ message: String?, for site: String) {
        defaults.set(message, forKey: "shieldMessage.\(site)")
    }

    static func validateUserUnlock(_ site: String, minutes: Int, reason: String) throws {
        let cleanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sites.contains(site),
              (5...60).contains(minutes),
              minutes.isMultiple(of: 5),
              !cleanReason.isEmpty,
              cleanReason.count <= 280 else { throw NativeError.invalidRequest }
        var hasSelectedApps = !selection(site).applicationTokens.isEmpty
#if DEBUG && targetEnvironment(simulator)
        hasSelectedApps = hasSelectedApps || simulatorDemoEnabled
#endif
        guard hasSelectedApps else { throw NativeError.noAppsSelected }
        guard AuthorizationCenter.shared.authorizationStatus == .approved else {
            throw NativeError.authorizationRequired
        }
    }

    static func unlock(_ site: String, until expiry: Date) throws -> Int {
        guard sites.contains(site), expiry > Date(), expiry.timeIntervalSinceNow <= 3601 else {
            throw NativeError.invalidRequest
        }
        var count = selection(site).applicationTokens.count
#if DEBUG && targetEnvironment(simulator)
        if simulatorDemoEnabled && site == "x" { count = 1 }
#endif
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
        defaults.removeObject(forKey: "shieldMessage.\(site)")
        store(site).shield.applications = nil
#if DEBUG && targetEnvironment(simulator)
        store(site).shield.applicationCategories = nil
#endif
        return count
    }

#if DEBUG && targetEnvironment(simulator)
    private static let simulatorDemoKey = "simulator.categoryShieldDemo"

    static var simulatorDemoEnabled: Bool {
        defaults.bool(forKey: simulatorDemoKey)
    }

    static func startSimulatorDemo() {
        defaults.set(true, forKey: simulatorDemoKey)
        defaults.removeObject(forKey: "expires.x")
        defaults.removeObject(forKey: "shieldMessage.x")
        store("x").shield.applications = nil
        store("x").shield.applicationCategories = .all()
    }

    static func stopSimulatorDemo() {
        defaults.removeObject(forKey: simulatorDemoKey)
        defaults.removeObject(forKey: "expires.x")
        defaults.removeObject(forKey: "shieldMessage.x")
        store("x").shield.applicationCategories = nil
        applyShield("x")
    }
#endif

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
    case invalidRequest, authorizationRequired, duplicateApps, noAppsSelected, connectionRequired, reportingUnavailable, server(String)
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid native unlock request."
        case .authorizationRequired: return "Open Scrollock and allow Screen Time access first."
        case .duplicateApps: return "An app can belong to only one site. Remove it from the other selection first."
        case .noAppsSelected: return "Choose at least one app for this site first."
        case .connectionRequired: return "Connect Telegram in Safari’s Scrollock extension first."
        case .reportingUnavailable: return "Telegram reporting is unavailable. Apps stay blocked. Try again."
        case .server(let message): return message
        }
    }
}
