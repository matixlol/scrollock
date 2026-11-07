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

extension Site {
  var tint: Color {
    switch self {
    case .x: Color(white: 0.08)
    case .instagram: Color(red: 0.88, green: 0.19, blue: 0.42)
    case .youtube: Color(red: 0.9, green: 0.13, blue: 0.09)
    }
  }

  var background: AnyShapeStyle {
    switch self {
    case .instagram:
      AnyShapeStyle(
        LinearGradient(
          colors: [Color(red: 0.98, green: 0.63, blue: 0.25), tint, Color(red: 0.51, green: 0.23, blue: 0.71)],
          startPoint: .bottomLeading, endPoint: .topTrailing))
    default: AnyShapeStyle(tint)
    }
  }
}

struct SiteIcon: View {
  let site: Site
  var size: CGFloat = 32

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
      .fill(site.background)
      .frame(width: size, height: size)
      .overlay {
        Group {
          switch site {
          case .x: Text("𝕏").font(.system(size: size * 0.55, weight: .bold))
          case .instagram: Image(systemName: "camera").font(.system(size: size * 0.45, weight: .semibold))
          case .youtube: Image(systemName: "play.fill").font(.system(size: size * 0.42))
          }
        }
        .foregroundStyle(.white)
      }
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
