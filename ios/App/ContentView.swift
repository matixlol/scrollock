import FamilyControls
import ScrollockKit
import SwiftUI

struct ContentView: View {
  @Bindable var model: AppModel
  @State private var picking: Site?

  var body: some View {
    NavigationStack {
      Form {
        if !model.isAuthorized {
          Section {
            Button("Allow Screen Time access") { Task { await model.requestAuthorization() } }
          } header: {
            Text("Block apps")
          } footer: {
            Text("Scrollock uses Screen Time to lock the apps you choose. Your choices stay on this iPhone, and app usage is never monitored or reported.")
          }
        } else {
          Section {
            ForEach(Site.allCases) { site in
              SiteRow(model: model, site: site) { picking = site }
            }
          } header: {
            Text("Locked apps")
          } footer: {
            Text("Choose the apps to lock for each feed. A break unlocks them only for the time you choose, and your group sees your name, the feed, the duration and your reason.")
          }
        }

        TelegramSection(model: model)

        Section {
          Text("Enable Scrollock in Settings → Apps → Safari → Extensions and allow it on X, Instagram and YouTube.")
        } header: {
          Text("Safari")
        } footer: {
          Text("Scrollock is cooperative accountability, not parental control: you can always remove apps from a list, turn off Screen Time access or delete the app.")
        }
      }
      .navigationTitle("Scrollock")
      .sheet(item: $picking) { site in
        AppPicker(site: site, selection: model.selections[site] ?? FamilyActivitySelection()) {
          model.setSelection($0, for: site)
        }
      }
      .sheet(item: $model.breakSite) { site in
        BreakForm(model: model, site: site)
      }
      .alert("Scrollock", isPresented: .init(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(model.error ?? "")
      }
    }
  }
}

struct SiteRow: View {
  let model: AppModel
  let site: Site
  let choose: () -> Void

  var body: some View {
    let count = model.selectedCount(for: site)
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(site.displayName).font(.headline)
        Spacer()
        Button(count == 0 ? "Choose apps" : "\(count) selected", action: choose)
          .buttonStyle(.borderless)
      }
      if count > 0 {
        if let lease = model.activeLease(for: site) {
          HStack {
            Label {
              Text("Unlocked · ") + Text(timerInterval: Date.now...lease.expiresAt, countsDown: true)
            } icon: {
              Image(systemName: "lock.open")
            }
            .foregroundStyle(.orange)
            Spacer()
            Button("Lock now") { Task { await model.lockNow(site) } }.buttonStyle(.borderless)
          }
        } else {
          HStack {
            Label("Locked", systemImage: "lock.fill").foregroundStyle(.secondary)
            Spacer()
            Button("Take a break…") { model.requestBreak(site) }.buttonStyle(.borderless)
          }
        }
      }
    }
    .padding(.vertical, 4)
  }
}

struct TelegramSection: View {
  let model: AppModel

  var body: some View {
    Section {
      if let session = model.session {
        LabeledContent("Connected", value: session.user.label)
        Button("Disconnect", role: .destructive) { model.disconnect() }
      } else if model.pairing != nil {
        HStack {
          ProgressView()
          Text("Waiting for Telegram…").padding(.leading, 8)
        }
        Button("Open Telegram login") { Task { await model.connect() } }
        Button("Cancel", role: .cancel) { model.cancelPairing() }
      } else {
        Button("Connect Telegram") { Task { await model.connect() } }
      }
    } header: {
      Text("Telegram")
    } footer: {
      Text("Breaks are reported to your group before apps unlock. Only group members can connect.")
    }
  }
}

struct AppPicker: View {
  let site: Site
  @State var selection: FamilyActivitySelection
  let save: (FamilyActivitySelection) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      FamilyActivityPicker(headerText: "Choose the apps to lock for \(site.displayName)", selection: $selection)
        .navigationTitle(site.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              save(selection)
              dismiss()
            }
          }
        }
    }
  }
}

struct BreakForm: View {
  let model: AppModel
  let site: Site
  @State private var minutes = 5
  @State private var reason = ""
  @State private var sending = false
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        if model.session == nil {
          Section {
            Text("Connect Telegram to take breaks.")
            Button("Connect Telegram") { Task { await model.connect() } }
          }
        }
        Section {
          Stepper(value: $minutes, in: BreakRequest.minutes) {
            LabeledContent("Duration", value: "\(minutes) min")
          }
          TextField("Why are you unblocking?", text: $reason, axis: .vertical)
            .lineLimit(1...4)
        } footer: {
          Text("Your group will see your name, \(site.displayName), \(minutes) min and your reason. Apps relock automatically; iOS may take a few minutes.")
        }
        if let error {
          Text(error).foregroundStyle(.red)
        }
      }
      .navigationTitle("Break from \(site.displayName)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          if sending {
            ProgressView()
          } else {
            Button("Unblock") { submit() }
              .disabled(model.session == nil || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  func submit() {
    sending = true
    error = nil
    Task {
      defer { sending = false }
      do {
        try await model.takeBreak(site: site, minutes: minutes, reason: reason)
        dismiss()
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}
