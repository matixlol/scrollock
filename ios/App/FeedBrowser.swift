import ScrollockKit
import SwiftUI
import WebKit

/// Browses X, Instagram and YouTube inside Scrollock. While an app is locked,
/// Screen Time also blocks its website in Safari, so this web view runs the
/// Safari extension's feed blocking itself. The page fills the screen, with
/// one floating pill for closing, going back and reloading.
struct FeedBrowser: View {
  let model: AppModel
  let site: Site
  @State private var browser: BrowserModel?
  @State private var barHeight: CGFloat = 0
  @State private var keyboardShown = false
  @Environment(\.dismiss) private var dismiss

  /// How much of the page's bottom the pill covers. With the keyboard up the
  /// pill hides and the web view makes room for the keyboard itself.
  private var obscuredBottom: CGFloat { keyboardShown ? 0 : barHeight }

  var body: some View {
    ZStack(alignment: .bottom) {
      Group {
        if let browser {
          WebView(webView: browser.webView, obscuredBottom: obscuredBottom)
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      // The page scrolls behind the pill and the home indicator, like Safari.
      .ignoresSafeArea(edges: .bottom)

      if !keyboardShown {
        bar
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
          .transition(.opacity)
      }
    }
    .ignoresSafeArea(.keyboard)
    .animation(.easeOut(duration: 0.2), value: keyboardShown)
    .background(Color(.systemBackground))
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
      keyboardShown = true
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
      keyboardShown = false
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
    // Breaks that start or end elsewhere show or hide the feed right away.
    .onChange(of: model.leases) { browser?.pushLeases() }
  }

  private var bar: some View {
    HStack(spacing: 2) {
      PillButton(systemImage: "xmark", label: "Close") { dismiss() }
      PillButton(systemImage: "chevron.backward", label: "Back") { browser?.webView.goBack() }
        .disabled(browser?.canGoBack != true)
      VStack(spacing: 1) {
        Text(browser?.host ?? site.webURL.host() ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
        LockBadge(model: model, site: site).font(.caption)
      }
      .frame(maxWidth: .infinity)
      PillButton(systemImage: "arrow.clockwise", label: "Reload") { browser?.webView.reload() }
    }
    .padding(5)
    .glassBackground(in: Capsule())
    .padding(.horizontal, 16)
    .padding(.bottom, 2)
  }
}

private struct PillButton: View {
  let systemImage: String
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 16, weight: .semibold))
        .frame(width: 42, height: 42)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// "Feed hidden", or the time left on a break.
private struct LockBadge: View {
  let model: AppModel
  let site: Site

  var body: some View {
    if let lease = model.activeLease(for: site) {
      Label {
        Text(timerInterval: Date.now...lease.expiresAt, countsDown: true).monospacedDigit()
      } icon: {
        Image(systemName: "lock.open.fill")
      }
      .foregroundStyle(.orange)
    } else {
      Label("Feed hidden", systemImage: "lock.fill").foregroundStyle(.secondary)
    }
  }
}

/// Hosts the web view in a controller so the pill can count as unsafe area,
/// the way Safari treats its toolbar. The page scrolls behind the pill, while
/// bars fixed to the page's bottom (and `env(safe-area-inset-bottom)`) stay
/// above it.
private struct WebView: UIViewControllerRepresentable {
  let webView: WKWebView
  let obscuredBottom: CGFloat

  func makeUIViewController(context: Context) -> UIViewController {
    let controller = UIViewController()
    webView.translatesAutoresizingMaskIntoConstraints = false
    controller.view.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: controller.view.topAnchor),
      webView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
    ])
    return controller
  }

  func updateUIViewController(_ controller: UIViewController, context: Context) {
    if controller.additionalSafeAreaInsets.bottom != obscuredBottom {
      controller.additionalSafeAreaInsets.bottom = obscuredBottom
    }
  }
}

@MainActor @Observable
final class BrowserModel: NSObject, WKNavigationDelegate, WKUIDelegate {
  /// Keeps the extension's scripts and messages away from the page's own scripts.
  static let world = WKContentWorld.world(name: "scrollock")

  let webView: WKWebView
  private(set) var canGoBack = false
  private(set) var canGoForward = false
  private(set) var host: String?
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
    webView.scrollView.keyboardDismissMode = .interactive
    webView.removeInputAccessoryBar()
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
      webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
        MainActor.assumeIsolated { self?.host = webView.url?.host()?.replacingOccurrences(of: "www.", with: "") }
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
    let css = try JSONSerialization.data(withJSONObject: [try read("content.css")])
    return """
      const scrollockListeners = [];
      globalThis.scrollockLeasesChanged = (leases) =>
        scrollockListeners.forEach((listener) => listener({ leases: { newValue: leases } }, "local"));
      globalThis.browser = {
        runtime: { sendMessage: (message) => webkit.messageHandlers.scrollock.postMessage(message) },
        storage: { onChanged: { addListener: (listener) => scrollockListeners.push(listener) } },
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

  /// Tells the page about breaks that started or ended outside it.
  func pushLeases() {
    webView.callAsyncJavaScript(
      "globalThis.scrollockLeasesChanged?.(leases)", arguments: ["leases": leases()], in: nil, in: Self.world)
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

extension WKWebView {
  /// Removes the bar with previous/next arrows above the keyboard. WebKit has no
  /// setting for it, so this swaps the content view for a subclass whose
  /// `inputAccessoryView` is nil (the approach of Cordova's keyboard plugin).
  fileprivate func removeInputAccessoryBar() {
    guard
      let content = scrollView.subviews.first(where: { NSStringFromClass(type(of: $0)).hasPrefix("WKContent") })
    else { return }
    let base: AnyClass = type(of: content)
    let name = "\(NSStringFromClass(base))_ScrollockNoAccessory"
    var subclass: AnyClass? = NSClassFromString(name)
    if subclass == nil, let created = objc_allocateClassPair(base, name, 0) {
      let selector = #selector(getter: UIResponder.inputAccessoryView)
      let nothing: @convention(block) (AnyObject) -> UIView? = { _ in nil }
      if let method = class_getInstanceMethod(base, selector) {
        class_addMethod(created, selector, imp_implementationWithBlock(nothing), method_getTypeEncoding(method))
      }
      objc_registerClassPair(created)
      subclass = created
    }
    if let subclass { object_setClass(content, subclass) }
  }
}
