import ScrollockKit
import SwiftUI

/// Home screen layouts to choose from in Settings → Design.
enum HomeStyle: String, CaseIterable, Identifiable {
  case icons, iconButtons, widgets
  var id: String { rawValue }
  var title: String {
    switch self {
    case .icons: "Icons"
    case .iconButtons: "Icons + buttons"
    case .widgets: "Widgets"
    }
  }
}

/// A feed's app icon, drawn like the real one: the brand glyph (from Simple
/// Icons, CC0) on the app's background.
struct SiteIcon: View {
  let site: Site
  var size: CGFloat = 32

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
    ZStack {
      switch site {
      case .x:
        shape.fill(.black)
        glyph(scale: 0.5).foregroundStyle(.white)
      case .instagram:
        // Instagram's warm-to-purple gradient, brightest in the bottom-left.
        shape.fill(
          RadialGradient(
            colors: [
              Color(red: 1, green: 0.84, blue: 0.36), Color(red: 0.98, green: 0.45, blue: 0.16),
              Color(red: 0.86, green: 0.15, blue: 0.48), Color(red: 0.53, green: 0.2, blue: 0.85),
            ],
            center: UnitPoint(x: 0.25, y: 1.05), startRadius: 0, endRadius: size * 1.25))
        glyph(scale: 0.6).foregroundStyle(.white)
      case .youtube:
        shape.fill(.white)
        shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        glyph(scale: 0.66).foregroundStyle(Color(red: 1, green: 0, blue: 0))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private func glyph(scale: CGFloat) -> some View {
    Image("Glyph-\(site.rawValue)")
      .resizable()
      .renderingMode(.template)
      .aspectRatio(contentMode: .fit)
      .frame(width: size * scale, height: size * scale)
  }
}

/// "Locked", "Unlocked · 12:04" or "No apps locked", for one feed.
struct FeedStatusText: View {
  let model: AppModel
  let site: Site

  var body: some View {
    if let lease = model.activeLease(for: site) {
      (Text("Unlocked · ") + Text(timerInterval: Date.now...lease.expiresAt, countsDown: true))
        .foregroundStyle(.orange)
    } else if model.selectedCount(for: site) > 0 {
      Text(model.selectedCount(for: site) == 1 ? "Locked · 1 app" : "Locked · \(model.selectedCount(for: site)) apps")
        .foregroundStyle(.secondary)
    } else {
      Text("No apps locked").foregroundStyle(.secondary)
    }
  }
}

extension AppModel {
  var lockedCount: Int {
    Site.allCases.filter { selectedCount(for: $0) > 0 && activeLease(for: $0) == nil }.count
  }

  var configuredCount: Int { Site.allCases.filter { selectedCount(for: $0) > 0 }.count }
}

extension View {
  /// Liquid Glass on iOS 26 and later, a material before that.
  @ViewBuilder func glassBackground<S: Shape>(in shape: S) -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(.regular.interactive(), in: shape)
    } else {
      background(.regularMaterial, in: shape)
    }
  }
}
