import ManagedSettings

final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(
        action: ShieldAction,
        for application: ApplicationToken,
        completionHandler: @escaping (ShieldActionResponse) -> Void
    ) {
        guard action == .primaryButtonPressed else {
            completionHandler(.close)
            return
        }
        guard let site = ScreenTimeStore.site(containing: application) else {
            completionHandler(.close)
            return
        }

        Task {
            do {
                _ = try await ScreenTimeStore.requestUnlock(
                    site,
                    minutes: 5,
                    reason: "Opened from the iOS block screen."
                )
                // Ask iOS to reevaluate the shield after its application token
                // has been removed from our ManagedSettingsStore.
                completionHandler(.defer)
            } catch {
                ScreenTimeStore.setShieldMessage(error.localizedDescription, for: site)
                completionHandler(.defer)
            }
        }
    }
}
