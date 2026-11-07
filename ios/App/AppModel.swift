import FamilyControls
import Observation
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

  @ObservationIgnored let shields = ShieldController()
  @ObservationIgnored let sessions = SessionStore()
  @ObservationIgnored let api = ScrollockAPI(origin: AppModel.apiOrigin)
  @ObservationIgnored private var expiryTask: Task<Void, Never>?
  @ObservationIgnored private var pollTask: Task<Void, Never>?

  static let apiOrigin: URL = {
    let value = Bundle.main.object(forInfoDictionaryKey: "ScrollockAPIOrigin") as? String
    return value.flatMap(URL.init(string:)) ?? URL(string: "https://scrollock.poronga.com.ar")!
  }()

  /// The live model, for App Intents that run inside the app process.
  static weak var shared: AppModel?

  init() {
    session = sessions.load()?.session
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
    // Picks up a sign-in or sign-out made in the Safari extension.
    session = sessions.load()?.session
    authorization = AuthorizationCenter.shared.authorizationStatus
    if isAuthorized {
      shields.clearWebShields()
      shields.relockExpired()
    }
    selections = Dictionary(uniqueKeysWithValues: Site.allCases.map { ($0, shields.selection(for: $0)) })
    leases = Dictionary(uniqueKeysWithValues: Site.allCases.compactMap { site in shields.store.lease(for: site).map { (site, $0) } })
    scheduleExpiryRefresh()
    if let request = shields.store.takeBreakRequest() { requestBreak(request) }
    Task { await checkNotifications() }
    if pairing != nil { pollPairing() }
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

  /// "Take a break…" on the block screen only works through a notification.
  func checkNotifications() async {
    let center = UNUserNotificationCenter.current()
    #if DEBUG
      if Self.isDemo { return }
    #endif
    if isAuthorized, await center.notificationSettings().authorizationStatus == .notDetermined {
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
    setSession(nil)
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
      disconnect()
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
