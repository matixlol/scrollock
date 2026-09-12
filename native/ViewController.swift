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
    @State private var selection = FamilyActivitySelection()
    @State private var counts: [String: Int] = [:]
    @State private var error: String?
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
                Text("Choose individual apps, not categories. Selected apps are blocked. Use Unblock in Safari to choose a duration and reason. App selections stay on this device; browsing activity is not recorded.")
            }
            Section {
                Button("Block selected apps now") {
                    ScreenTimeStore.sites.forEach { ScreenTimeStore.lock($0) }
                }
                .disabled(!authorized)
            } footer: {
                Text("Only Scrollock’s restrictions can be removed. Other Screen Time limits still apply. iOS may delay automatic relocking; opening this app or Safari rechecks expired unlocks.")
            }
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
        .alert("Screen Time", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onAppear { refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private func refresh() {
        authorized = AuthorizationCenter.shared.authorizationStatus == .approved
        if authorized { ScreenTimeStore.reconcile() }
        counts = Dictionary(uniqueKeysWithValues: ScreenTimeStore.sites.map {
            ($0, ScreenTimeStore.selection($0).applicationTokens.count)
        })
    }
}
