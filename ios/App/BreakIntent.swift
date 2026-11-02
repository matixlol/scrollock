import AppIntents
import ScrollockKit

/// Feeds as a Shortcuts parameter.
enum BreakFeed: String, AppEnum {
  case x, instagram, youtube

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Feed"
  static let caseDisplayRepresentations: [BreakFeed: DisplayRepresentation] = [
    .x: "X", .instagram: "Instagram", .youtube: "YouTube",
  ]

  var site: Site { Site(rawValue: rawValue)! }
}

/// "Take a Scrollock break": meant for a Shortcuts automation that runs when a
/// blocked app opens. It checks in the background and, only while that feed is
/// locked, hands off to `OpenBreakFormIntent`, which opens the app straight to
/// the break form. That hand-off avoids the "continue in Scrollock?" prompt that
/// `continueInForeground` can show. Needs iOS 26 for intent modes.
@available(iOS 26.0, *)
struct TakeBreakIntent: AppIntent {
  static let title: LocalizedStringResource = "Take a Scrollock Break"
  static let description = IntentDescription(
    "Opens Scrollock's break form for a feed while it's locked. Does nothing during a break.")
  static let supportedModes: IntentModes = .background

  @Parameter(title: "Feed") var feed: BreakFeed

  init() {}
  init(feed: BreakFeed) { self.feed = feed }

  static var parameterSummary: some ParameterSummary {
    Summary("Take a break from \(\.$feed)")
  }

  func perform() async throws -> some IntentResult & OpensIntent {
    let store = SharedStore()
    let site = feed.site
    guard store.selectionData(for: site) != nil, store.lease(for: site)?.isActive() != true else { return .result() }
    return .result(opensIntent: OpenBreakFormIntent(feed: feed))
  }
}

/// Opens Scrollock directly on the break form for a feed.
@available(iOS 26.0, *)
struct OpenBreakFormIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Scrollock Break Form"
  static let isDiscoverable = false
  static let supportedModes: IntentModes = .foreground(.immediate)

  @Parameter(title: "Feed") var feed: BreakFeed

  init() {}
  init(feed: BreakFeed) { self.feed = feed }

  @MainActor
  func perform() async throws -> some IntentResult {
    // The app picks this up as it becomes active and opens the break form.
    let store = SharedStore()
    store.requestedBreak = feed.site
    store.breakRequestedAt = .now
    AppModel.shared?.requestBreak(feed.site)
    return .result()
  }
}

@available(iOS 26.0, *)
struct ScrollockShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: TakeBreakIntent(),
      phrases: ["Take a \(.applicationName) break from \(\.$feed)", "Take a \(.applicationName) break"],
      shortTitle: "Take a Break",
      systemImageName: "lock.open")
  }
}
