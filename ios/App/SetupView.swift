import ScrollockKit
import SwiftUI

/// A short checklist so a blocked app always leads straight to the break form.
/// It hides once every step is done.
struct SetupSection: View {
  let model: AppModel
  /// Shows the automation guide. The sheet lives outside the Form: a sheet
  /// attached to a section inside a presented Form dismisses itself.
  let showAutomation: () -> Void
  @AppStorage("automationSetUp") private var automationSetUp = false

  private var hasApps: Bool { model.configuredCount > 0 }
  private var complete: Bool { model.setupProgress(automationSetUp: automationSetUp).isComplete }

  var body: some View {
    if !complete {
      Section {
        Step(done: model.isAuthorized, title: "Allow Screen Time access") {
          Task { await model.requestAuthorization() }
        }
        Step(done: hasApps, title: "Choose apps to lock", detail: "Use Choose apps below for each feed.")
        Step(done: model.session != nil, title: "Connect Telegram") { Task { await model.connect() } }
        Step(
          done: model.notificationsBypassFocus,
          title: model.notificationsAllowed ? "Let breaks through Focus" : "Turn on notifications",
          detail: model.notificationsAllowed
            ? "Turn on Time Sensitive Notifications for Scrollock, and keep them allowed in each Focus."
            : "\"Take a break…\" on the block screen reaches Scrollock through a notification."
        ) {
          UIApplication.shared.open(URL(string: UIApplication.openNotificationSettingsURLString)!)
        }
        Step(
          done: automationSetUp, title: "Skip the block screen (optional)",
          detail: "A Shortcuts automation opens the break form as soon as a locked app opens."
        ) { showAutomation() }
      } header: {
        Text("Setup")
      }
    }
  }
}

struct SetupProgress {
  let done: Int
  let total: Int
  /// The first unfinished step, for a one-line summary.
  let next: String?
  var isComplete: Bool { done == total }
}

extension AppModel {
  func setupProgress(automationSetUp: Bool) -> SetupProgress {
    let steps: [(String, Bool)] = [
      ("Allow Screen Time access", isAuthorized),
      ("Choose apps to lock", configuredCount > 0),
      ("Connect Telegram", session != nil),
      (notificationsAllowed ? "Let breaks through Focus" : "Turn on notifications", notificationsBypassFocus),
      ("Skip the block screen", automationSetUp),
    ]
    return SetupProgress(
      done: steps.filter(\.1).count, total: steps.count, next: steps.first { !$0.1 }?.0)
  }
}

private struct Step: View {
  let done: Bool
  let title: String
  var detail: String?
  var action: (() -> Void)?

  var body: some View {
    let label = HStack(alignment: .firstTextBaseline, spacing: 12) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(done ? .green : .secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).foregroundStyle(done ? .secondary : .primary)
        if let detail, !done { Text(detail).font(.footnote).foregroundStyle(.secondary) }
      }
      Spacer()
      if action != nil, !done { Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
    }
    if let action, !done {
      Button(action: action) { label }.tint(.primary)
    } else {
      label
    }
  }
}

/// Instructions for the "when Instagram opens" automation. iOS doesn't let apps
/// create automations, so the user adds it once in Shortcuts. iOS 27 moved
/// automations into each shortcut (Edit → Automation), so the steps differ.
struct AutomationGuide: View {
  let finish: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var showingManualSteps = false

  /// Shared iCloud shortcuts that include the "<app> is opened" trigger (iOS 27
  /// shares automation triggers with a shortcut). Each runs Take a Scrollock
  /// Break for its feed and is set to run when locked, so it never asks.
  /// Make one on an iPhone, then Share → Copy iCloud Link.
  static let sharedAutomations: [Site: URL] = [:]

  private var oneTapSites: [Site] {
    isIOS27 ? Site.allCases.filter { Self.sharedAutomations[$0] != nil } : []
  }

  private var isIOS27: Bool {
    if #available(iOS 27, *) { true } else { false }
  }

  private var steps: [String] {
    isIOS27
      ? [
        "Open **Shortcuts**, tap **+** to make a new shortcut, and choose to build it yourself instead of describing it.",
        "Search for **Take a Scrollock Break** and add it. Tap **Feed** and choose **Instagram**.",
        "Tap **Edit**, then **Automation**. Choose **App**, select **Instagram**, and keep **Is Opened**.",
        "Tap **Edit**, then the **Info** button, then **Privacy**, and turn on **Allow Running When Locked** so it runs without asking.",
        "Tap **Done**. Repeat for X and YouTube if you lock them.",
      ]
      : [
        "Open **Shortcuts** and go to the **Automation** tab.",
        "Tap **+** and choose **App**.",
        "Tap **Choose**, select **Instagram**, and keep **Is Opened** checked.",
        "Choose **Run Immediately**, turn off **Notify When Run**, and tap **Next**.",
        "Tap **New Blank Automation**, search for **Take a Scrollock Break**, and add it.",
        "Tap **Feed**, choose **Instagram**, and tap **Done**.",
        "Repeat for X and YouTube if you lock them.",
      ]
  }

  var body: some View {
    NavigationStack {
      List {
        if !oneTapSites.isEmpty {
          Section {
            ForEach(oneTapSites) { site in
              Button("Add \(site.displayName) automation") {
                UIApplication.shared.open(Self.sharedAutomations[site]!)
              }
            }
          } header: {
            Text("One tap")
          } footer: {
            Text("Shortcuts opens with the automation ready. **Make sure to turn on the Automation**, then tap **Set Up Shortcut**. Add one for each app you lock.")
          }
        }
        if oneTapSites.isEmpty || showingManualSteps {
          Section {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
              HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                Text(.init(step))
              }
            }
          } footer: {
            Text("When a locked app opens, Scrollock comes up on its break form. During a break the automation does nothing, so the app opens normally.")
          }
        } else {
          Button("Set up manually instead") { showingManualSteps = true }
        }
        Section {
          Button("Open Shortcuts") { UIApplication.shared.open(URL(string: "shortcuts://")!) }
          Button("I've set it up") {
            finish()
            dismiss()
          }
        }
      }
      .navigationTitle("Skip the block screen")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
      }
    }
  }
}
