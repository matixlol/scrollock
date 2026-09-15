import UIKit
import WebKit
import SwiftUI
import FamilyControls

final class ViewController: UIViewController {
    @IBOutlet var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.removeFromSuperview()
        let host = UIHostingController(rootView: ScreenTimeSettings())
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

struct ScreenTimeSettings: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorized = AuthorizationCenter.shared.authorizationStatus == .approved
    @State private var editingSite: String?
    @State private var unblockingSite: String?
    @State private var selection = FamilyActivitySelection()
    @State private var counts: [String: Int] = [:]
    @State private var expiries: [String: Date] = [:]
    @State private var minutes = 5.0
    @State private var reason = ""
    @State private var busy = false
    @State private var error: String?
#if DEBUG && targetEnvironment(simulator)
    @State private var showingSimulatorShield = false
#endif
    private let labels = ["x": "X", "instagram": "Instagram", "youtube": "YouTube"]

    var body: some View {
        Form {
            Section {
                Text("Enable the extension in Settings → Apps → Safari → Extensions.")
            }
            Section {
                if !authorized {
                    Button("Allow Screen Time access") {
                        Task {
                            do {
                                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                                refresh()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
                ForEach(ScreenTimeStore.sites, id: \.self) { site in
                    Button {
                        selection = ScreenTimeStore.selection(site)
                        editingSite = site
                    } label: {
                        HStack {
                            Text(labels[site]!)
                            Spacer()
                            Text("\(counts[site, default: 0]) selected").foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!authorized)
                }
            } header: {
                Text("Installed apps")
            } footer: {
                Text("Choose individual apps, not categories. Selected apps are blocked immediately. App selections stay on this device; browsing activity is not recorded.")
            }
            Section {
                ForEach(ScreenTimeStore.sites, id: \.self) { site in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(labels[site]!)
                            Text(accessDetail(site)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if expiries[site] != nil {
                            Button("Block") {
                                ScreenTimeStore.lock(site)
                                refresh()
                            }
                        } else {
                            Button("Unblock") {
                                minutes = 5
                                reason = ""
                                unblockingSite = site
                            }
                            .disabled(!authorized || counts[site, default: 0] == 0)
                        }
                    }
                }
            } header: {
                Text("Temporary access")
            } footer: {
                Text(ScreenTimeStore.hasConnection
                     ? "Choose a duration and reason. Your Telegram group receives your name, app group, duration, and reason."
                     : "Connect Telegram in Safari’s Scrollock extension before unblocking. The app will remember that connection on this device.")
            }
            Section {
                Button("Block selected apps now") {
                    ScreenTimeStore.sites.forEach { ScreenTimeStore.lock($0) }
                }
                .disabled(!authorized)
            } footer: {
                Text("Only Scrollock’s restrictions can be removed. Other Screen Time limits still apply. iOS may delay automatic relocking; opening this app or Safari rechecks expired unlocks.")
            }
#if DEBUG && targetEnvironment(simulator)
            Section {
                Button("Preview block screen") {
                    ScreenTimeStore.startSimulatorDemo()
                    showingSimulatorShield = true
                }
                if ScreenTimeStore.simulatorDemoEnabled {
                    Button("Stop block-screen demo", role: .destructive) {
                        ScreenTimeStore.stopSimulatorDemo()
                    }
                }
            } header: {
                Text("Simulator QA")
            } footer: {
                Text("Debug builds only. Renders the production shield design and sends the same native unlock request because iOS Simulator accepts Managed Settings but does not enforce app shields.")
            }
            .disabled(!authorized)
#endif
        }
        .sheet(isPresented: Binding(get: { editingSite != nil }, set: { if !$0 { editingSite = nil } })) {
            VStack {
                HStack {
                    Button("Cancel") { editingSite = nil }
                    Spacer()
                    Button("Save") {
                        guard let site = editingSite else { return }
                        do {
                            try ScreenTimeStore.save(selection, for: site)
                            editingSite = nil
                            refresh()
                        } catch { self.error = error.localizedDescription }
                    }
                }.padding()
                FamilyActivityPicker(selection: $selection)
            }
        }
        .sheet(isPresented: Binding(get: { unblockingSite != nil }, set: { if !$0 { unblockingSite = nil } })) {
            NavigationStack {
                Form {
                    Section("Duration") {
                        HStack {
                            Text("Time")
                            Spacer()
                            Text("\(Int(minutes)) minutes").foregroundStyle(.secondary)
                        }
                        Slider(value: $minutes, in: 5...60, step: 5)
                    }
                    Section {
                        TextEditor(text: $reason)
                            .frame(minHeight: 90)
                            .accessibilityLabel("Reason")
                    } header: {
                        Text("Why are you unblocking?")
                    } footer: {
                        Text("Up to 280 characters. This reason is shared with your Telegram group.")
                    }
                }
                .navigationTitle("Unblock \(labels[unblockingSite ?? ""] ?? "apps")")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { unblockingSite = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Unblock") { Task { await submitUnblock() } }
                            .disabled(busy || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 280)
                    }
                }
                .disabled(busy)
            }
        }
        .alert("Screen Time", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
#if DEBUG && targetEnvironment(simulator)
        .fullScreenCover(isPresented: $showingSimulatorShield) {
            SimulatorShieldPreview()
        }
#endif
        .onAppear { refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private func refresh() {
#if DEBUG && targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        if let origin = environment["SCROLLOCK_SIMULATOR_API_ORIGIN"],
           let token = environment["SCROLLOCK_SIMULATOR_SESSION_TOKEN"] {
            try? ScreenTimeStore.syncConnection(apiOrigin: origin, sessionToken: token)
        }
#endif
        authorized = AuthorizationCenter.shared.authorizationStatus == .approved
        if authorized { ScreenTimeStore.reconcile() }
        counts = Dictionary(uniqueKeysWithValues: ScreenTimeStore.sites.map {
            ($0, ScreenTimeStore.selection($0).applicationTokens.count)
        })
        expiries = Dictionary(uniqueKeysWithValues: ScreenTimeStore.sites.compactMap { site in
            ScreenTimeStore.expiry(site).map { (site, $0) }
        })
    }

    private func accessDetail(_ site: String) -> String {
        guard counts[site, default: 0] > 0 else { return "No apps selected" }
        guard let expiry = expiries[site] else { return "Blocked" }
        return "Unblocked until \(expiry.formatted(date: .omitted, time: .shortened))"
    }

    private func submitUnblock() async {
        guard let site = unblockingSite else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await ScreenTimeStore.requestUnlock(
                site,
                minutes: Int(minutes),
                reason: reason
            )
            unblockingSite = nil
            reason = ""
            refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
private struct SimulatorShieldPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var message = "A five-minute break will be shared with your Telegram group."

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Blocked Demo is blocked")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Spacer()
                Button {
                    Task { await unblock() }
                } label: {
                    HStack {
                        if busy { ProgressView().tint(.white) }
                        Text("Unblock for 5 minutes").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color(red: 0.15, green: 0.30, blue: 0.24))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(busy)
                Button("Not now") { dismiss() }
                    .foregroundStyle(.secondary)
                    .disabled(busy)
                Text("Simulator preview · production uses the iOS shield extension")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
    }

    @MainActor
    private func unblock() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await ScreenTimeStore.requestUnlock(
                "x",
                minutes: 5,
                reason: "Opened from the iOS block screen."
            )
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
#endif
