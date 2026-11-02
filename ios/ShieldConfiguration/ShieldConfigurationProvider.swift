import ManagedSettings
import ManagedSettingsUI
import ScrollockKit
import UIKit

/// Scrollock's block screen. Breaks need a reason, so the secondary button hands
/// off to the app instead of unblocking from here.
final class ShieldConfigurationProvider: ShieldConfigurationDataSource {
  let controller = ShieldController()

  override func configuration(shielding application: Application) -> ShieldConfiguration {
    configuration(for: application.token.flatMap(controller.site(for:)), name: application.localizedDisplayName)
  }

  override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
    let site = application.token.flatMap(controller.site(for:)) ?? category.token.flatMap(controller.site(for:))
    return configuration(for: site, name: application.localizedDisplayName)
  }

  override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
    configuration(for: webDomain.token.flatMap(controller.site(for:)), name: webDomain.domain)
  }

  override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
    let site = webDomain.token.flatMap(controller.site(for:)) ?? category.token.flatMap(controller.site(for:))
    return configuration(for: site, name: webDomain.domain)
  }

  func configuration(for site: Site?, name: String?) -> ShieldConfiguration {
    let title = name ?? site?.displayName ?? "This app"
    return ShieldConfiguration(
      backgroundBlurStyle: .systemThickMaterial,
      icon: UIImage(named: "ShieldIcon"),
      title: .init(text: "\(title) is locked", color: .label),
      subtitle: .init(
        text: "Scrollock is keeping this feed closed. Tap \"Take a break…\" to get a notification where you choose how long and tell your group why.",
        color: .secondaryLabel),
      primaryButtonLabel: .init(text: "Close", color: .white),
      primaryButtonBackgroundColor: .systemBlue,
      secondaryButtonLabel: .init(text: "Take a break…", color: .systemBlue))
  }
}
