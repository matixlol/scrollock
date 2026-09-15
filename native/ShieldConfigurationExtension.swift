import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        let site = application.token.flatMap(ScreenTimeStore.site(containing:))
        let appName = application.localizedDisplayName ?? "This app"
        let subtitle = site.flatMap(ScreenTimeStore.shieldMessage) ??
            "A five-minute break will be shared with your Telegram group."
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterial,
            backgroundColor: .systemBackground,
            icon: UIImage(systemName: "lock.shield.fill"),
            title: .init(text: "\(appName) is blocked", color: .label),
            subtitle: .init(text: subtitle, color: .secondaryLabel),
            primaryButtonLabel: .init(text: "Unblock for 5 minutes", color: .white),
            primaryButtonBackgroundColor: UIColor(red: 0.15, green: 0.30, blue: 0.24, alpha: 1),
            secondaryButtonLabel: .init(text: "Not now", color: .secondaryLabel)
        )
    }
}
