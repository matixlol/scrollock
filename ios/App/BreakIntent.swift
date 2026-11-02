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
/// blocked app opens. It opens the break form only while that feed is locked,
/// so it stays out of the way during a break. Needs iOS 26 to open the app
/// without a confirmation prompt.
@available(iOS 26.0, *)
struct TakeBreakIntent: AppIntent {
  static let title: LocalizedStringResource = "Take a Scrollock Break"
  static let description = IntentDescription(
    "Opens Scrollock's break form for a feed while it's locked. Does nothing during a break.")
  static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

  @Parameter(title: "Feed") var feed: BreakFeed

  init() {}
  init(feed: BreakFeed) { self.feed = feed }

  static var parameterSummary: some ParameterSummary {
    Summary("Take a break from \(\.$feed)")
  }

  func perform() async throws -> some IntentResult {
    let store = SharedStore()
    let site = feed.site
    guard store.selectionData(for: site) != nil, store.lease(for: site)?.isActive() != true else { return .result() }
    // The app picks this up when it becomes active and opens the break form.
    store.requestedBreak = site
    store.breakRequestedAt = .now
    try await continueInForeground(alwaysConfirm: false)
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
