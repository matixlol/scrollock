import FamilyControls
import ScrollockKit
import SwiftUI

struct ContentView: View {
  @Bindable var model: AppModel
  @AppStorage("homeStyle") private var homeStyle = HomeStyle.icons
  @State private var browsing: Site?

  var body: some View {
    HomeScreen(model: model, style: homeStyle) { browsing = $0 }
    .confirmationDialog("Take a break from…", isPresented: $model.choosingBreakSite, titleVisibility: .visible) {
      ForEach(Site.allCases.filter { model.selectedCount(for: $0) > 0 && model.activeLease(for: $0) == nil }) { site in
        Button(site.displayName) { model.breakSite = site }
      }
    }
    .onChange(of: model.breakSite) { _, site in
      // A break request from a notification replaces an open browser.
      if site != nil { browsing = nil }
    }
    .fullScreenCover(item: $browsing) { site in
      FeedBrowser(model: model, site: site)
    }
    .fullScreenCover(item: $model.breakSite) { site in
      BreakForm(model: model, site: site)
    }
    .alert("Scrollock", isPresented: .init(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.error ?? "")
    }
    #if DEBUG
      // `-browse instagram` opens the browser at launch, for simulator screenshots.
      .onAppear { browsing = UserDefaults.standard.string(forKey: "browse").flatMap(Site.init(rawValue:)) }
    #endif
  }
}

/// Everything that isn't day-to-day: setup, which apps to lock, Telegram and design.
struct SettingsForm: View {
  let model: AppModel
  @State private var picking: Site?
  @State private var showingAutomation = false
  @AppStorage("homeStyle") private var homeStyle = HomeStyle.icons
  @AppStorage("automationSetUp") private var automationSetUp = false

  var body: some View {
    Form {
      SetupSection(model: model) { showingAutomation = true }

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
          Text("While an app is locked, iOS also blocks its website in Safari, so browse it in Scrollock instead. A break unlocks the app only for the time you choose, and your group sees your name, the feed, the duration and your reason.")
        }
      }

      TelegramSection(model: model)

      Section("Design") {
        Picker("Home screen", selection: $homeStyle) {
          ForEach(HomeStyle.allCases) { Text($0.title).tag($0) }
        }
      }

      Section {
        Text("Enable Scrollock in Settings → Apps → Safari → Extensions and allow it on X, Instagram and YouTube.")
      } header: {
        Text("Safari")
      } footer: {
        Text("Scrollock is cooperative accountability, not parental control: you can always remove apps from a list, turn off Screen Time access or delete the app.")
      }
    }
    .appPicker(model: model, site: $picking)
    .sheet(isPresented: $showingAutomation) {
      AutomationGuide { automationSetUp = true }
    }
  }
}

extension View {
  func appPicker(model: AppModel, site: Binding<Site?>) -> some View {
    sheet(item: site) { site in
      AppPicker(site: site, selection: model.selections[site] ?? FamilyActivitySelection()) {
        model.setSelection($0, for: site)
      }
    }
    .onChange(of: model.breakSite) { _, breakSite in
      // A break request from a notification replaces an open app picker.
      if breakSite != nil { site.wrappedValue = nil }
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
        Button("Open Telegram login") { Task { await model.reopenLogin() } }
        Button("Cancel", role: .cancel) { model.cancelPairing() }
      } else {
        Button("Connect Telegram") { Task { await model.connect() } }
      }
    } header: {
      Text("Telegram")
    } footer: {
      Text("Shared with the Scrollock Safari extension. Breaks are reported to your group before apps unlock. Only group members can connect.")
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
  @FocusState private var reasonFocused: Bool
  @Environment(\.dismiss) private var dismiss

  private var canSubmit: Bool {
    model.session != nil && !sending && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          if model.session == nil {
            VStack(alignment: .leading, spacing: 8) {
              Text("Connect Telegram to take breaks.")
              Button("Connect Telegram") { Task { await model.connect() } }
            }
          }
          VStack(alignment: .leading, spacing: 10) {
            Text("How long?").font(.headline)
            DurationSlider(minutes: $minutes)
          }
          VStack(alignment: .leading, spacing: 10) {
            Text("Why are you unblocking?").font(.headline)
            TextField("A brief reason", text: $reason, axis: .vertical)
              .lineLimit(2...5)
              .focused($reasonFocused)
              .padding(12)
              .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
              .onChange(of: reason) { _, value in
                if value.count > BreakRequest.maxReasonLength { reason = String(value.prefix(BreakRequest.maxReasonLength)) }
              }
            Text("Your group will see your name, \(site.displayName), \(minutes) min and your reason. Apps relock automatically; iOS may take a few minutes.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          if let error {
            Text(error).foregroundStyle(.red)
          }
        }
        .padding()
      }
      .scrollDismissesKeyboard(.interactively)
      .safeAreaInset(edge: .bottom) {
        Button(action: submit) {
          Group {
            if sending { ProgressView() } else { Text("Unblock for \(minutes) min") }
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canSubmit)
        .padding()
        .background(.bar)
      }
      .navigationTitle("Break from \(site.displayName)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
      .task {
        // Wait for the full-screen transition so the keyboard comes up reliably.
        try? await Task.sleep(for: .milliseconds(400))
        reasonFocused = true
      }
    }
  }

  func submit() {
    sending = true
    error = nil
    Task {
      defer { sending = false }
      do {
        try await model.takeBreak(site: site, minutes: minutes, reason: reason)
        dismiss()
        model.returnToFeed(site)
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}
