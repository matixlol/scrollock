import ScrollockKit
import SwiftUI

/// A short checklist so a blocked app always leads straight to the break form.
/// It hides once every step is done.
struct SetupSection: View {
  let model: AppModel
  @AppStorage("automationSetUp") private var automationSetUp = false
  @State private var showingAutomation = false

  private var hasApps: Bool { Site.allCases.contains { model.selectedCount(for: $0) > 0 } }
  private var complete: Bool {
    model.isAuthorized && hasApps && model.session != nil && model.notificationsBypassFocus && automationSetUp
  }

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
        ) { showingAutomation = true }
      } header: {
        Text("Setup")
      }
      .sheet(isPresented: $showingAutomation) {
        AutomationGuide { automationSetUp = true }
      }
    }
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
/// create automations, so the user adds it once in Shortcuts. iOS 27 replaced
/// the Automation tab with describing a shortcut in plain language.
struct AutomationGuide: View {
  let finish: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var copied: Site?

  private var isIOS27: Bool {
    if #available(iOS 27, *) { true } else { false }
  }

  private var steps: [String] {
    isIOS27
      ? [
        "Copy the description for an app below.",
        "Open **Shortcuts** and tap **New Shortcut**.",
        "Paste the description and let Shortcuts build it.",
        "Check that it uses **Take a Scrollock Break** with the right feed and runs **without asking** or notifying. Save it.",
        "Repeat for each app you lock.",
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

  private func description(for site: Site) -> String {
    "When I open \(site.displayName), run Take a Scrollock Break with the feed set to \(site.displayName). Run it immediately without asking or notifying me."
  }

  var body: some View {
    NavigationStack {
      List {
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
        if isIOS27 {
          Section("Descriptions") {
            ForEach(Site.allCases) { site in
              Button {
                UIPasteboard.general.string = description(for: site)
                copied = site
              } label: {
                LabeledContent(site.displayName) {
                  Label(copied == site ? "Copied" : "Copy", systemImage: copied == site ? "checkmark" : "doc.on.doc")
                }
              }
            }
          }
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
