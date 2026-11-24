import FamilyControls
import Observation
import OSLog
import ScrollockKit
import UIKit
import UserNotifications

@MainActor @Observable
final class AppModel {
  private(set) var authorization = AuthorizationCenter.shared.authorizationStatus
  private(set) var session: Session?
  private(set) var pairing: Pairing?
  private(set) var leases: [Site: Lease] = [:]
  private(set) var selections: [Site: FamilyActivitySelection] = [:]
  var breakSite: Site?
  var choosingBreakSite = false
  private(set) var notificationsAllowed = false
  /// Time Sensitive notifications pass through Focus unless the user turned that off.
  private(set) var notificationsBypassFocus = false
  var error: String?
  /// Unread X and Instagram conversations, newest first.
  private(set) var messages: [UnreadThread] = []
  /// Sites whose inbox couldn't be read on the last check.
  private(set) var messageProblems: [Site] = []
  /// Sites with an active Web Push subscription stored on device.
  var pushSubscriptions: Set<Site> = []
  /// A conversation to open in the in-app browser, from the list or a notification.
  var openingURL: URL?

  @ObservationIgnored let shields = ShieldController()
  @ObservationIgnored let sessions = SessionStore()
  @ObservationIgnored let api = ScrollockAPI(origin: AppModel.apiOrigin)
  @ObservationIgnored private var expiryTask: Task<Void, Never>?
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var messageCheck: Task<Bool, Never>?

  static let apiOrigin: URL = {
    let value = Bundle.main.object(forInfoDictionaryKey: "ScrollockAPIOrigin") as? String
    return value.flatMap(URL.init(string:)) ?? URL(string: "https://scrollock.poronga.com.ar")!
  }()

  /// The live model, for App Intents that run inside the app process.
  static weak var shared: AppModel?

  init() {
    session = sessions.load()?.session
    pushSubscriptions = Set(MessageFetcher.sites.filter { shields.store.pushSubscription(for: $0) != nil })
    Self.shared = self
    #if DEBUG
      if Self.isDemo { applyDemo() }
    #endif
  }

  /// After a break starts, go back to the app the person came for.
  func returnToFeed(_ site: Site) {
    let urls: [Site: String] = [.x: "twitter://timeline", .instagram: "instagram://app", .youtube: "youtube://"]
    guard let url = urls[site].flatMap(URL.init(string:)) else { return }
    UIApplication.shared.open(url)
  }

  var isAuthorized: Bool { authorization == .approved }

  func activeLease(for site: Site) -> Lease? {
    leases[site].flatMap { $0.isActive() ? $0 : nil }
  }

  #if DEBUG
    /// `-demo` launch argument: sample feeds and a break, for simulator screenshots.
    static let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")
    private static let demoCounts: [Site: Int] = [.instagram: 2, .youtube: 1, .x: 1]
    private static let demoBreakEnds = Date.now.addingTimeInterval(12 * 60 + 4)

    private func applyDemo() {
      authorization = .approved
      session = Session(token: "demo", user: TelegramUser(id: 1, name: "Mati", username: "matixlol"))
      leases[.youtube] = Lease(id: "demo", site: .youtube, expiresAt: Self.demoBreakEnds)
      messages = [
        UnreadThread(
          site: .instagram, conversationID: "1", title: "Ana", preview: "are you coming tonight?", unreadCount: 3,
          latestMessageID: "1", sentAt: .now.addingTimeInterval(-240), url: Site.instagram.webURL),
        UnreadThread(
          site: .x, conversationID: "2", title: "Bob", preview: "Sent an attachment", unreadCount: 1,
          latestMessageID: "2", sentAt: .now.addingTimeInterval(-3900), url: Site.x.webURL),
      ]
    }
  #endif

  func selectedCount(for site: Site) -> Int {
    #if DEBUG
      if Self.isDemo { return Self.demoCounts[site] ?? 0 }
    #endif
    let selection = selections[site] ?? FamilyActivitySelection()
    return selection.applicationTokens.count + selection.categoryTokens.count
  }

  /// Re-syncs with shared state whenever the app becomes active. This is also a
  /// fallback relock in case a Device Activity callback was delayed.
  func refresh() {
    // Picks up a sign-in or sign-out made in the Safari extension without
    // clearing an active session if the Keychain is temporarily unreadable.
    if let record = sessions.load() { session = record.session }
    authorization = AuthorizationCenter.shared.authorizationStatus
    if isAuthorized {
      shields.clearWebShields()
      shields.relockExpired()
    }
    selections = Dictionary(uniqueKeysWithValues: Site.allCases.map { ($0, shields.selection(for: $0)) })
    leases = Dictionary(uniqueKeysWithValues: Site.allCases.compactMap { site in shields.store.lease(for: site).map { (site, $0) } })
    pushSubscriptions = Set(MessageFetcher.sites.filter { shields.store.pushSubscription(for: $0) != nil })
    scheduleExpiryRefresh()
    if let request = shields.store.takeBreakRequest() { requestBreak(request) }
    Task { await checkNotifications() }
    if pairing != nil { pollPairing() }
    #if DEBUG
      if !Self.isDemo {
        Task {
          await MessageFetcher.importDebugCookiesIfRequested()
          await checkMessages()
        }
      }
    #else
      Task { await checkMessages() }
    #endif
    #if DEBUG
      if Self.isDemo { applyDemo() }
    #endif
  }

  /// Opens the break form, or asks which feed when the block screen couldn't tell.
  func requestBreak(_ site: Site?) {
    shields.store.requestedBreak = nil
    shields.store.breakRequestedAt = nil
    if let site { breakSite = site } else { choosingBreakSite = true }
  }

  /// "Take a break…" on the block screen and message/push forwarding use local notifications.
  func checkNotifications() async {
    let center = UNUserNotificationCenter.current()
    #if DEBUG
      if Self.isDemo { return }
    #endif
    let shouldAsk =
      isAuthorized || session != nil || !messages.isEmpty
      || MessageFetcher.sites.contains { shields.store.pushSubscription(for: $0) != nil }
    if shouldAsk, await center.notificationSettings().authorizationStatus == .notDetermined {
      _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
    let settings = await center.notificationSettings()
    notificationsAllowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
    notificationsBypassFocus = notificationsAllowed && settings.timeSensitiveSetting == .enabled
  }

  func open(_ url: URL) {
    // scrollock://break?site=instagram
    guard url.scheme == "scrollock", url.host() == "break" else { return }
    let site = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "site" }?.value
    requestBreak(site.flatMap(Site.init(rawValue:)))
  }

  func requestAuthorization() async {
    do {
      try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
    } catch {
      self.error = "Screen Time access wasn't granted. You can allow it in Settings → Screen Time."
    }
    refresh()
  }

  func setSelection(_ selection: FamilyActivitySelection, for site: Site) {
    shields.setSelection(selection, for: site)
    selections[site] = selection
  }

  // MARK: Telegram

  func connect() async {
    do {
      let pairing = try await api.startPairing()
      self.pairing = pairing
      await UIApplication.shared.open(pairing.loginUrl)
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Reopens the current login instead of starting a new pairing, so a login
  /// already in progress in Safari keeps working.
  func reopenLogin() async {
    guard let pairing else { return await connect() }
    await UIApplication.shared.open(pairing.loginUrl)
  }

  func cancelPairing() {
    pollTask?.cancel()
    pairing = nil
  }

  /// Also signs out the Safari extension the next time it syncs.
  func disconnect() {
    let old = session
    setSession(nil)
    if let old { Task { try? await api.logout(session: old) } }
  }

  private func setSession(_ session: Session?) {
    sessions.save(SessionRecord(session: session))
    self.session = session
  }

  private func pollPairing() {
    pollTask?.cancel()
    pollTask = Task {
      while let pairing, !Task.isCancelled {
        do {
          if case .connected(let session) = try await api.poll(pairing) {
            setSession(session)
            self.pairing = nil
            return
          }
        } catch ScrollockError.pairingExpired {
          self.pairing = nil
          self.error = ScrollockError.pairingExpired.localizedDescription
          return
        } catch {}
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  // MARK: Messages

  /// Reads both inboxes and notifies about messages that arrived since the
  /// last check. Overlapping calls share one check. Returns false when an inbox
  /// couldn't be read.
  @discardableResult func checkMessages() async -> Bool {
    if let messageCheck { return await messageCheck.value }
    let check = Task { () -> Bool in
      var unread: [UnreadThread] = []
      var failed: [Site] = []
      for site in MessageFetcher.sites {
        do {
          unread += try await MessageFetcher.unread(on: site) ?? []
        } catch {
          Logger(subsystem: "ar.com.poronga.Scrollock", category: "messages")
            .error("Couldn't read \(site.rawValue, privacy: .public) messages: \(error, privacy: .public)")
          failed.append(site)
        }
      }
      // Keep showing what an inbox that failed this time had before.
      messages = (unread + messages.filter { failed.contains($0.site) }).sorted { $0.sentAt > $1.sentAt }
      messageProblems = failed
      let defaults = UserDefaults.standard
      let (post, notified) = Inbox.notifications(
        for: unread, checked: Set(MessageFetcher.sites).subtracting(failed),
        notified: defaults.dictionary(forKey: "notifiedMessages") as? [String: String])
      defaults.set(notified, forKey: "notifiedMessages")
      for thread in post { await notify(thread) }
      await clearReadNotifications(unread: unread, failed: failed)
      await forwardCapturedPushes()
      if !unread.isEmpty { await checkNotifications() }
      return failed.isEmpty
    }
    messageCheck = check
    defer { messageCheck = nil }
    return await check.value
  }

  /// Removes delivered message notifications for conversations that are no
  /// longer unread, on sites that were checked successfully.
  private func clearReadNotifications(unread: [UnreadThread], failed: [Site]) async {
    let center = UNUserNotificationCenter.current()
    let current = Set(unread.map { "message.\($0.id)" })
    let checked = MessageFetcher.sites.filter { !failed.contains($0) }
    let stale = await center.deliveredNotifications().map(\.request.identifier).filter { id in
      !current.contains(id) && checked.contains { id.hasPrefix("message.\($0.rawValue):") }
    }
    if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
  }

  private func notify(_ thread: UnreadThread) async {
    let content = UNMutableNotificationContent()
    content.title = thread.title
    content.subtitle = thread.site.displayName
    content.body = thread.unreadCount > 1 ? "\(thread.preview) (+\(thread.unreadCount - 1) more)" : thread.preview
    content.sound = .default
    content.threadIdentifier = thread.id
    content.userInfo = ["url": thread.url.absoluteString]
    // One notification per conversation, replaced as more messages arrive.
    try? await UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "message.\(thread.id)", content: content, trigger: nil))
  }

  // MARK: Breaks

  /// Reports the break to the group first; apps unlock only after the server
  /// grants a lease and the relock is scheduled.
  func takeBreak(site: Site, minutes: Int, reason: String) async throws {
    guard let session else { throw ScrollockError.invalid("Connect Telegram first.") }
    let request = try BreakRequest(site: site, minutes: minutes, reason: reason)
    let lease: Lease
    do {
      lease = try await api.unlock(request, session: session)
    } catch ScrollockError.unauthorized {
      setSession(nil)
      throw ScrollockError.unauthorized
    }
    do {
      try shields.beginBreak(lease)
    } catch {
      throw ScrollockError.invalid("Couldn't schedule the relock, so apps stay locked. Try again.")
    }
    leases[site] = lease
    scheduleExpiryRefresh()
  }

  func lockNow(_ site: Site) async {
    let lease = leases.removeValue(forKey: site)
    shields.endBreak(site)
    if let lease, let session { try? await api.lock(lease, session: session) }
  }

  private func scheduleExpiryRefresh() {
    expiryTask?.cancel()
    guard let next = leases.values.map(\.expiresAt).filter({ $0 > .now }).min() else { return }
    expiryTask = Task {
      try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.5))
      if !Task.isCancelled { refresh() }
    }
  }
}
