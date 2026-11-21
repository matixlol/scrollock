import OSLog
import ScrollockKit
import SwiftUI
import UserNotifications

extension AppModel {
  /// Directly creates a relay endpoint and registers it with X or Instagram
  /// using the in-app browser's cookies.
  func registerPush(for site: Site) async throws {
    guard let session else { throw ScrollockError.invalid("Connect Telegram in Scrollock first.") }
    let (id, endpoint) = try await api.registerPush(site: site, session: session)
    let keys = WebPushKeys.generate()
    try await MessageFetcher.registerWebPush(on: site, endpoint: endpoint, keys: keys)
    let record = PushSubscriptionRecord(site: site, id: id, endpoint: endpoint, keys: keys, subscribedAt: .now)
    shields.store.setPushSubscription(record, for: site)
    pushSubscriptions.insert(site)
    await checkNotifications()
  }

  func forgetPush(for site: Site) {
    shields.store.setPushSubscription(nil, for: site)
    pushSubscriptions.remove(site)
  }

  /// Pulls newly captured web pushes from the relay, decrypts them on device,
  /// and forwards them as local notifications.
  func forwardCapturedPushes() async {
    guard let session else { return }
    let defaults = UserDefaults.standard
    let lastSeenKey = "forwardedPushTimestamps"
    var lastSeen = defaults.dictionary(forKey: lastSeenKey) as? [String: Double] ?? [:]
    var changed = false
    for site in MessageFetcher.sites {
      guard let record = shields.store.pushSubscription(for: site) else { continue }
      guard let pushes = try? await api.capturedPushes(id: record.id, session: session) else { continue }
      let cutoff = lastSeen[site.rawValue] ?? record.subscribedAt.timeIntervalSince1970
      let fresh = pushes
        .filter { $0.receivedAt.timeIntervalSince1970 > cutoff }
        .sorted { $0.receivedAt < $1.receivedAt }
      for push in fresh {
        lastSeen[site.rawValue] = max(lastSeen[site.rawValue] ?? 0, push.receivedAt.timeIntervalSince1970)
        changed = true
        guard
          push.headers["content-encoding"] == "aes128gcm",
          let plaintext = try? record.keys.decrypt(push.body),
          let parsed = Inbox.pushNotification(site: site, payload: plaintext)
        else { continue }
        let content = UNMutableNotificationContent()
        content.title = parsed.title
        content.subtitle = site.displayName
        content.body = parsed.body
        content.sound = .default
        if let url = parsed.url { content.userInfo = ["url": url.absoluteString] }
        let id = "push.\(site.rawValue).\(Int(push.receivedAt.timeIntervalSince1970 * 1000))"
        try? await UNUserNotificationCenter.current().add(
          UNNotificationRequest(identifier: id, content: content, trigger: nil))
      }
    }
    if changed { defaults.set(lastSeen, forKey: lastSeenKey) }
  }
}

/// Settings section for registering and inspecting Web Push subscriptions.
struct PushSpikeSection: View {
  let model: AppModel
  @State private var showing: Site?
  @State private var registering: Site?
  @State private var registrationError: String?

  var body: some View {
    Section {
      ForEach(MessageFetcher.sites) { site in
        HStack {
          Text(site.displayName)
          Spacer()
          if model.pushSubscriptions.contains(site) {
            Button("Captured pushes") { showing = site }.buttonStyle(.borderless)
          } else if registering == site {
            ProgressView()
          } else {
            Button("Subscribe") {
              registering = site
              registrationError = nil
              Task {
                defer { registering = nil }
                do {
                  try await model.registerPush(for: site)
                } catch {
                  registrationError = error.localizedDescription
                }
              }
            }
            .buttonStyle(.borderless)
          }
        }
      }
      if let registrationError {
        Text(registrationError).font(.footnote).foregroundStyle(.red)
      }
    } header: {
      Text("Web push")
    } footer: {
      Text(
        "Subscribe registers Scrollock's relay directly with your X or Instagram login. Pushes are encrypted end-to-end to keys on this iPhone and decrypted here."
      )
    }
    .sheet(item: $showing) { site in CapturedPushList(model: model, site: site) }
  }
}

private struct CapturedPushList: View {
  let model: AppModel
  let site: Site
  @State private var pushes: [String]?
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if let error { Text(error).foregroundStyle(.red) }
        if let pushes {
          if pushes.isEmpty { Text("Nothing yet. Send yourself a message on \(site.displayName).") }
          ForEach(pushes.indices, id: \.self) { index in
            Text(pushes[index]).font(.footnote.monospaced()).textSelection(.enabled)
          }
        } else if error == nil {
          ProgressView()
        }
      }
      .navigationTitle("\(site.displayName) pushes")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .destructiveAction) {
          // The site keeps the old endpoint until it subscribes again.
          Button("Forget", role: .destructive) {
            model.forgetPush(for: site)
            dismiss()
          }
        }
      }
      .refreshable { await load() }
      .task { await load() }
    }
  }

  private func load() async {
    guard let session = model.session, let record = model.shields.store.pushSubscription(for: site) else {
      error = "Not subscribed, or Telegram isn't connected."
      return
    }
    do {
      pushes = try await model.api.capturedPushes(id: record.id, session: session).map {
        Self.describe($0, keys: record.keys)
      }
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// The time, headers and decrypted body of one push.
  static func describe(_ push: CapturedPush, keys: WebPushKeys) -> String {
    let headers = push.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.prefix(100))" }
    let payload: String
    if push.body.isEmpty {
      payload = "(empty body)"
    } else if push.headers["content-encoding"] == "aes128gcm", let plaintext = try? keys.decrypt(push.body) {
      payload = String(decoding: plaintext, as: UTF8.self)
    } else {
      payload = "(\(push.body.count) bytes that couldn't be decrypted)"
    }
    return ([push.receivedAt.formatted(date: .abbreviated, time: .standard)] + headers + ["", payload])
      .joined(separator: "\n")
  }
}
