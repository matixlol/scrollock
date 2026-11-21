import OSLog
import ScrollockKit
import SwiftUI
import UserNotifications
import WebKit

/// Web push spike. WKWebView has no Push API, so the in-app browser gives X and
/// Instagram stand-ins for `Notification`, `navigator.serviceWorker` and
/// `PushManager`. When a site subscribes, it gets an endpoint on Scrollock's
/// Worker and keys generated here, so pushes it sends land at the Worker still
/// encrypted, and only this iPhone can read them. This only finds out whether
/// the sites accept such an endpoint and what their pushes contain.
enum PushSpike {
  /// Off by default: faking a service worker can keep logged-in Instagram from loading.
  static let enabledKey = "pushSpikeEnabled"

  @MainActor static func install(in controller: WKUserContentController, model: AppModel) {
    guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
    controller.addUserScript(
      WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    controller.addScriptMessageHandler(PushBridge(model: model), contentWorld: .page, name: "scrollockPush")
  }

  /// Runs in the page's own world, because the sites' scripts call these APIs.
  static let script = """
    (() => {
      const host = location.hostname;
      if (!["x.com", "twitter.com", "instagram.com"].some((d) => host === d || host.endsWith("." + d))) return;
      const call = (message) => webkit.messageHandlers.scrollockPush.postMessage(message);
      const bytes = (value) => {
        const binary = atob(value.replace(/-/g, "+").replace(/_/g, "/"));
        return Uint8Array.from(binary, (c) => c.charCodeAt(0)).buffer;
      };
      const base64url = (key) => {
        if (!key) return null;
        if (typeof key === "string") return key;
        const array = key instanceof ArrayBuffer ? new Uint8Array(key) : new Uint8Array(key.buffer, key.byteOffset, key.byteLength);
        return btoa(String.fromCharCode(...array)).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
      };
      class PushSubscription {
        constructor(record, options) {
          this.endpoint = record.endpoint;
          this.expirationTime = null;
          this.options = options;
          this._keys = record.keys;
        }
        getKey(name) { return this._keys[name] ? bytes(this._keys[name]) : null; }
        toJSON() { return { endpoint: this.endpoint, expirationTime: null, keys: { ...this._keys } }; }
        unsubscribe() { return call({ type: "unsubscribe" }).then(() => true); }
      }
      class PushManager {
        static get supportedContentEncodings() { return ["aes128gcm"]; }
        subscribe(options = {}) {
          return call({ type: "subscribe", applicationServerKey: base64url(options.applicationServerKey) }).then(
            (record) => new PushSubscription(record, { userVisibleOnly: true, applicationServerKey: options.applicationServerKey ?? null }));
        }
        getSubscription() {
          return call({ type: "get" }).then((record) =>
            record ? new PushSubscription(record, { userVisibleOnly: true, applicationServerKey: null }) : null);
        }
        permissionState() { return Promise.resolve("granted"); }
      }
      const noop = () => {};
      const registration = {
        scope: location.origin + "/",
        active: { state: "activated", scriptURL: location.origin + "/sw.js", postMessage: noop, addEventListener: noop },
        installing: null,
        waiting: null,
        pushManager: new PushManager(),
        update: () => Promise.resolve(registration),
        unregister: () => Promise.resolve(true),
        showNotification: () => Promise.resolve(),
        getNotifications: () => Promise.resolve([]),
        addEventListener: noop,
        removeEventListener: noop,
      };
      const container = {
        controller: null,
        ready: Promise.resolve(registration),
        register: () => Promise.resolve(registration),
        getRegistration: () => Promise.resolve(registration),
        getRegistrations: () => Promise.resolve([registration]),
        startMessages: noop,
        addEventListener: noop,
        removeEventListener: noop,
      };
      Object.defineProperty(Navigator.prototype, "serviceWorker", { get: () => container, configurable: true });
      class Notification {
        static permission = "granted";
        static requestPermission(callback) { callback?.("granted"); return Promise.resolve("granted"); }
        close() {}
        addEventListener() {}
      }
      Object.assign(window, { PushManager, PushSubscription, Notification });
      if (navigator.permissions) {
        const query = navigator.permissions.query.bind(navigator.permissions);
        navigator.permissions.query = (descriptor) =>
          ["notifications", "push"].includes(descriptor?.name)
            ? Promise.resolve({ name: descriptor.name, state: "granted", onchange: null, addEventListener: noop, removeEventListener: noop })
            : query(descriptor);
      }
    })();
    """
}

/// Answers the page's push calls. Holds the model weakly; the content controller retains its handlers.
private final class PushBridge: NSObject, WKScriptMessageHandlerWithReply {
  weak var model: AppModel?

  init(model: AppModel) { self.model = model }

  @MainActor
  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) async -> (Any?, String?) {
    guard let model, let site = Site(host: message.frameInfo.securityOrigin.host), MessageFetcher.sites.contains(site)
    else { return (nil, "Push isn't available here.") }
    do {
      return (try await model.pushRequest(message.body as? [String: Any] ?? [:], site: site), nil)
    } catch {
      return (nil, error.localizedDescription)
    }
  }
}

extension AppModel {
  /// `get`, `subscribe` and `unsubscribe` from the page's stand-in PushManager.
  func pushRequest(_ body: [String: Any], site: Site) async throws -> Any? {
    let store = shields.store
    let log = Logger(subsystem: "ar.com.poronga.Scrollock", category: "push")
    switch body["type"] as? String {
    case "get":
      return store.pushSubscription(for: site).map(Self.subscriptionJSON)
    case "subscribe":
      log.notice(
        "\(site.rawValue, privacy: .public) subscribed with key \(body["applicationServerKey"] as? String ?? "none", privacy: .public)"
      )
      if let existing = store.pushSubscription(for: site) { return Self.subscriptionJSON(existing) }
      guard let session else { throw ScrollockError.invalid("Connect Telegram in Scrollock first.") }
      let (id, endpoint) = try await api.registerPush(site: site, session: session)
      let record = PushSubscriptionRecord(site: site, id: id, endpoint: endpoint, keys: .generate(), subscribedAt: .now)
      store.setPushSubscription(record, for: site)
      return Self.subscriptionJSON(record)
    case "unsubscribe":
      store.setPushSubscription(nil, for: site)
      return true
    default:
      return nil
    }
  }

  /// Directly creates a relay endpoint and registers it with X or Instagram
  /// using the in-app browser's cookies.
  func registerPush(for site: Site) async throws {
    guard let session else { throw ScrollockError.invalid("Connect Telegram in Scrollock first.") }
    let (id, endpoint) = try await api.registerPush(site: site, session: session)
    let keys = WebPushKeys.generate()
    try await MessageFetcher.registerWebPush(on: site, endpoint: endpoint, keys: keys)
    let record = PushSubscriptionRecord(site: site, id: id, endpoint: endpoint, keys: keys, subscribedAt: .now)
    shields.store.setPushSubscription(record, for: site)
    await checkNotifications()
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

  private static func subscriptionJSON(_ record: PushSubscriptionRecord) -> [String: Any] {
    [
      "endpoint": record.endpoint.absoluteString,
      "keys": ["p256dh": (try? record.keys.publicKey.base64URL) ?? "", "auth": record.keys.authSecret.base64URL],
    ]
  }
}

/// Settings section listing the pushes each site sent to its faked subscription.
struct PushSpikeSection: View {
  let model: AppModel
  @State private var showing: Site?
  @State private var registering: Site?
  @State private var registrationError: String?
  @AppStorage(PushSpike.enabledKey) private var enabled = false

  var body: some View {
    Section {
      ForEach(MessageFetcher.sites) { site in
        HStack {
          Text(site.displayName)
          Spacer()
          if model.shields.store.pushSubscription(for: site) != nil {
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
      Toggle("Fake push support in the browser", isOn: $enabled)
    } header: {
      Text("Web push")
    } footer: {
      Text(
        "Subscribe registers Scrollock's relay directly with your X or Instagram login (no fake service worker needed). Pushes are encrypted end-to-end to keys on this iPhone and decrypted here."
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
            model.shields.store.setPushSubscription(nil, for: site)
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
