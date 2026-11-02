import Foundation
import Testing

@testable import ScrollockKit

final class StubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
  nonisolated(unsafe) static var requests: [URLRequest] = []

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var request = request
    if let stream = request.httpBodyStream {
      stream.open()
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
      }
      stream.close()
      request.httpBody = data
    }
    Self.requests.append(request)
    let (status, body) = Self.handler!(request)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

func stubbedAPI(_ handler: @escaping (URLRequest) -> (Int, String)) -> ScrollockAPI {
  StubProtocol.handler = handler
  StubProtocol.requests = []
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubProtocol.self]
  return ScrollockAPI(origin: URL(string: "https://api.example")!, session: URLSession(configuration: configuration))
}

let session = Session(token: "token", user: TelegramUser(id: 1, name: "Fixture User"))

@Suite(.serialized) struct APITests {
  @Test func unlockSendsTrimmedReasonAndDecodesMillisecondDeadline() async throws {
    let api = stubbedAPI { _ in (200, #"{"id":"lease","site":"instagram","expiresAt":1800000000000}"#) }
    let lease = try await api.unlock(try BreakRequest(site: .instagram, minutes: 5, reason: "  Reply to a DM \n"), session: session)
    #expect(lease == Lease(id: "lease", site: .instagram, expiresAt: Date(timeIntervalSince1970: 1_800_000_000)))
    let request = try #require(StubProtocol.requests.first)
    #expect(request.url?.absoluteString == "https://api.example/api/unlock")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect(body["site"] as? String == "instagram")
    #expect(body["minutes"] as? Int == 5)
    #expect(body["reason"] as? String == "Reply to a DM")
  }

  @Test func failuresKeepAppsLockedWithSpecificErrors() async throws {
    for (status, body, expected) in [
      (401, "{}", ScrollockError.unauthorized),
      (502, "{}", .unavailable),
      (403, #"{"error":"group membership required"}"#, .server("group membership required")),
    ] {
      let api = stubbedAPI { _ in (status, body) }
      await #expect(throws: expected) {
        try await api.unlock(try BreakRequest(site: .x, minutes: 1, reason: "why"), session: session)
      }
    }
  }

  @Test func pairingPollsUntilTelegramAuthorizes() async throws {
    let pairing = Pairing(id: "pair", secret: "secret", loginUrl: URL(string: "https://api.example/login?id=pair")!)
    var api = stubbedAPI { _ in (200, #"{"pending":true}"#) }
    #expect(try await api.poll(pairing) == .pending)
    #expect(StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    api = stubbedAPI { _ in (200, #"{"token":"new","user":{"id":7,"name":"Ana","username":"ana"}}"#) }
    #expect(try await api.poll(pairing) == .connected(Session(token: "new", user: TelegramUser(id: 7, name: "Ana", username: "ana"))))
    api = stubbedAPI { _ in (401, #"{"error":"invalid pairing"}"#) }
    await #expect(throws: ScrollockError.pairingExpired) { try await api.poll(pairing) }
  }

  @Test func startPairingAndLock() async throws {
    var api = stubbedAPI { _ in (200, #"{"id":"p","secret":"s","loginUrl":"https://api.example/login?id=p"}"#) }
    #expect(try await api.startPairing().loginUrl.absoluteString == "https://api.example/login?id=p")
    api = stubbedAPI { _ in (200, #"{"ok":true}"#) }
    try await api.lock(Lease(id: "lease", site: .x, expiresAt: .now), session: session)
    let body = try JSONSerialization.jsonObject(with: StubProtocol.requests[0].httpBody!) as! [String: String]
    #expect(body == ["unlockId": "lease"])
  }
}

@Test func breakRequestsMatchServerLimits() throws {
  #expect(throws: ScrollockError.self) { try BreakRequest(site: .x, minutes: 0, reason: "why") }
  #expect(throws: ScrollockError.self) { try BreakRequest(site: .x, minutes: 61, reason: "why") }
  #expect(throws: ScrollockError.self) { try BreakRequest(site: .x, minutes: 5, reason: "   ") }
  #expect(throws: ScrollockError.self) { try BreakRequest(site: .x, minutes: 5, reason: String(repeating: "a", count: 281)) }
  #expect(try BreakRequest(site: .x, minutes: 60, reason: String(repeating: "a", count: 280)).minutes == 60)
}

@Test func shortBreaksBackdateTheRelockSchedule() {
  let now = Date(timeIntervalSince1970: 1_000_000)
  let short = RelockWindow(expiresAt: now.addingTimeInterval(5 * 60), now: now)
  #expect(short.end == now.addingTimeInterval(5 * 60))
  #expect(short.end.timeIntervalSince(short.start) == RelockWindow.minimumInterval)
  let long = RelockWindow(expiresAt: now.addingTimeInterval(45 * 60), now: now)
  #expect(long.start == now)
  #expect(RelockWindow.site(forActivityName: RelockWindow.activityName(for: .youtube)) == .youtube)
  #expect(RelockWindow.site(forActivityName: "other") == nil)
}

@Test func storeReportsOnlyExpiredLeases() throws {
  let defaults = UserDefaults(suiteName: "scrollock-tests-\(UUID())")!
  let store = SharedStore(defaults: defaults)
  let now = Date()
  store.setLease(Lease(id: "a", site: .x, expiresAt: now.addingTimeInterval(-1)), for: .x)
  store.setLease(Lease(id: "b", site: .youtube, expiresAt: now.addingTimeInterval(60)), for: .youtube)
  #expect(store.expiredSites(at: now) == [.x])
  #expect(store.lease(for: .youtube)?.id == "b")
  store.setLease(nil, for: .x)
  #expect(store.expiredSites(at: now).isEmpty)
  store.requestedBreak = .instagram
  #expect(store.requestedBreak == .instagram)
}
