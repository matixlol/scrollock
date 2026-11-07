import ScrollockKit
import SwiftUI
import WebKit

/// Browses X, Instagram and YouTube inside Scrollock. While an app is locked,
/// Screen Time also blocks its website in Safari, so this web view runs the
/// Safari extension's feed blocking itself.
struct FeedBrowser: View {
  let model: AppModel
  let site: Site
  @State private var browser: BrowserModel?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        if let browser {
          WebView(webView: browser.webView).ignoresSafeArea(edges: .bottom)
        } else {
          ProgressView()
        }
      }
      .navigationTitle(site.displayName)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItemGroup(placement: .bottomBar) {
          Button("Back", systemImage: "chevron.backward") { browser?.webView.goBack() }
            .disabled(browser?.canGoBack != true)
          Button("Forward", systemImage: "chevron.forward") { browser?.webView.goForward() }
            .disabled(browser?.canGoForward != true)
          Spacer()
          Button("Reload", systemImage: "arrow.clockwise") { browser?.webView.reload() }
        }
      }
    }
    .task {
      guard browser == nil else { return }
      do {
        let browser = try BrowserModel(model: model)
        browser.webView.load(URLRequest(url: site.webURL))
        self.browser = browser
      } catch {
        model.error = "Couldn't load Scrollock's feed blocker. Reinstall the app from TestFlight."
        dismiss()
      }
    }
  }
}

private struct WebView: UIViewRepresentable {
  let webView: WKWebView
  func makeUIView(context: Context) -> WKWebView { webView }
  func updateUIView(_ view: WKWebView, context: Context) {}
}

@MainActor @Observable
final class BrowserModel: NSObject, WKNavigationDelegate, WKUIDelegate {
  /// Keeps the extension's scripts and messages away from the page's own scripts.
  static let world = WKContentWorld.world(name: "scrollock")

  let webView: WKWebView
  private(set) var canGoBack = false
  private(set) var canGoForward = false
  @ObservationIgnored private let model: AppModel
  @ObservationIgnored private var observations: [NSKeyValueObservation] = []

  init(model: AppModel) throws {
    self.model = model
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.allowsInlineMediaPlayback = true
    // Sites serve their regular mobile pages to Safari's user agent.
    let major = UIDevice.current.systemVersion.split(separator: ".").first ?? "18"
    configuration.applicationNameForUserAgent = "Version/\(major).0 Mobile/15E148 Safari/604.1"
    let controller = configuration.userContentController
    controller.addUserScript(
      WKUserScript(
        source: try Self.feedBlocker(), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    controller.addScriptMessageHandler(MessageHandler(browser: self), contentWorld: Self.world, name: "scrollock")
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    #if DEBUG
      webView.isInspectable = true
    #endif
    observations = [
      webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
        MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
      },
      webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
        MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
      },
    ]
  }

  /// The Safari extension's content script and styles, with a stand-in for the
  /// two extension APIs it uses. The files come from the embedded extension, so
  /// both always run the same rules.
  static func feedBlocker() throws -> String {
    guard
      let plugins = Bundle.main.builtInPlugInsURL,
      let ext = Bundle(url: plugins.appending(path: "Scrollock Extension.appex"))
    else { throw CocoaError(.fileNoSuchFile) }
    func read(_ name: String) throws -> String {
      guard let url = ext.url(forResource: name, withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
      return try String(contentsOf: url, encoding: .utf8)
    }
    let css = try JSONSerialization.data(withJSONObject: [try read("content.css")], options: .fragmentsAllowed)
    return """
      globalThis.browser = {
        runtime: { sendMessage: (message) => webkit.messageHandlers.scrollock.postMessage(message) },
        storage: { onChanged: { addListener() {} } },
      };
      \(try read("rules.js"))
      \(try read("timer.js"))
      if (ScrollockRules.siteForHost(location.hostname)) {
        const style = document.createElement("style");
        style.textContent = \(String(decoding: css, as: UTF8.self))[0];
        document.documentElement.append(style);
        \(try read("content.js"))
      }
      """
  }

  /// Answers the content script's `state` and `unlock` messages like the
  /// extension's background script. A break here unlocks the app too.
  func handle(_ body: Any, from url: URL?) async -> Any? {
    let message = body as? [String: Any] ?? [:]
    switch message["type"] as? String {
    case "state":
      return ["leases": leases()]
    case "unlock":
      guard let site = url?.host().flatMap(Site.init(host:)) else {
        return ["ok": false, "error": "This page isn't a Scrollock feed."]
      }
      do {
        try await model.takeBreak(
          site: site, minutes: (message["minutes"] as? NSNumber)?.intValue ?? 0,
          reason: message["reason"] as? String ?? "")
        return ["ok": true]
      } catch {
        return ["ok": false, "error": error.localizedDescription]
      }
    default:
      return nil
    }
  }

  private func leases() -> [String: Any] {
    var leases: [String: Any] = [:]
    for site in Site.allCases {
      if let lease = model.activeLease(for: site) {
        leases[site.rawValue] = ["expiresAt": lease.expiresAt.timeIntervalSince1970 * 1000]
      }
    }
    return leases
  }

  // Stay on the web: app links would open the locked native app.
  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    ["http", "https", "about", "blob", "data"].contains(action.request.url?.scheme ?? "") ? .allow : .cancel
  }

  // Open links meant for a new tab in this one.
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if action.targetFrame == nil { webView.load(action.request) }
    return nil
  }
}

/// Holds the browser weakly; the content controller retains its handlers.
private final class MessageHandler: NSObject, WKScriptMessageHandlerWithReply {
  weak var browser: BrowserModel?

  init(browser: BrowserModel) { self.browser = browser }

  @MainActor
  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) async -> (Any?, String?) {
    guard let browser else { return (nil, "Scrollock closed.") }
    return (await browser.handle(message.body, from: message.frameInfo.request.url), nil)
  }
}
