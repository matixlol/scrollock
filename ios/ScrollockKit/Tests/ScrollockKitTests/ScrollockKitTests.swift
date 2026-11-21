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

@Test func latestSessionChangeWins() throws {
  let app = SessionRecord(session: session, updatedAt: 1000)
  let signedOut = SessionRecord(session: nil, updatedAt: 2000)
  #expect(app.merged(with: signedOut) == signedOut)
  #expect(signedOut.merged(with: app) == signedOut)
  #expect(app.merged(with: nil) == app)
  // Matches the extension's wire format: { session: { token, user }, updatedAt }.
  let json = #"{"session":{"token":"t","user":{"id":7,"name":"Ana"}},"updatedAt":1730000000000}"#
  let decoded = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
  #expect(decoded.session?.user.name == "Ana")
  #expect(try JSONDecoder().decode(SessionRecord.self, from: Data(#"{"session":null,"updatedAt":5}"#.utf8)).session == nil)
}

@Test func blockScreenBreakRequestsAreTakenOnceAndExpire() {
  let store = SharedStore(defaults: UserDefaults(suiteName: "scrollock-tests-\(UUID())")!)
  let now = Date()
  #expect(store.takeBreakRequest(now: now) == nil)

  store.requestedBreak = .x
  store.breakRequestedAt = now
  #expect(store.takeBreakRequest(now: now) == .some(.x))
  #expect(store.takeBreakRequest(now: now) == nil)

  // Unknown feed: the app should ask which one.
  store.breakRequestedAt = now
  #expect(store.takeBreakRequest(now: now) == .some(nil))

  // Stale requests are dropped.
  store.requestedBreak = .youtube
  store.breakRequestedAt = now.addingTimeInterval(-3600)
  #expect(store.takeBreakRequest(now: now) == nil)
  #expect(store.requestedBreak == nil)
}

@Test func recentBlockScreenFeedIsRemembered() {
  let store = SharedStore(defaults: UserDefaults(suiteName: "scrollock-tests-\(UUID())")!)
  let now = Date()
  #expect(store.recentShieldShown(now: now) == nil)
  store.noteShieldShown(.instagram, at: now)
  #expect(store.recentShieldShown(now: now.addingTimeInterval(5)) == .instagram)
  #expect(store.recentShieldShown(now: now.addingTimeInterval(3600)) == nil)
}

@Test func sitesMatchHostsLikeTheExtension() {
  #expect(Site(host: "x.com") == .x)
  #expect(Site(host: "mobile.twitter.com") == .x)
  #expect(Site(host: "www.instagram.com") == .instagram)
  #expect(Site(host: "m.youtube.com") == .youtube)
  #expect(Site(host: "notyoutube.com") == nil)
  #expect(Site(host: "x.com.example") == nil)
}

@Test func instagramInboxListsOnlyThreadsWithUnseenMessagesFromOthers() throws {
  let json = #"""
    {"viewer":{"pk":1},"inbox":{"threads":[
      {"thread_id":"340282366841710300949128100000000001","thread_v2_id":"17840000000000001","is_group":false,
       "users":[{"pk":2,"username":"ana","full_name":"Ana"}],
       "last_seen_at":{"1":{"item_id":"a0","timestamp":"1800000000000000"}},
       "items":[
         {"item_id":"a2","user_id":2,"timestamp":1800000120000000,"item_type":"text","text":"are you there?"},
         {"item_id":"a1","user_id":2,"timestamp":1800000060000000,"item_type":"clip"},
         {"item_id":"a0","user_id":2,"timestamp":1800000000000000,"item_type":"text","text":"hey"}]},
      {"thread_id":"t-read","users":[{"pk":3,"username":"bob","full_name":""}],
       "last_seen_at":{"1":{"item_id":"b1","timestamp":"1800000000000000"}},
       "items":[{"item_id":"b1","user_id":3,"timestamp":"1800000000000000","item_type":"text","text":"seen"}]},
      {"thread_id":"t-mine","users":[{"pk":4,"username":"cam"}],
       "items":[{"item_id":"c1","user_id":1,"timestamp":"1800000300000000","item_type":"text","text":"my reply"}]},
      {"thread_id":"t-group","thread_title":"Friends","is_group":true,
       "users":[{"pk":5,"username":"dee","full_name":""}],
       "last_seen_at":{"1":{"item_id":"d0","timestamp":"1700000000000000"}},
       "items":[{"item_id":"d1","user_id":5,"timestamp":"1800000200000000","item_type":"like"}]}
    ]}}
    """#
  let threads = try Inbox.instagram(Data(json.utf8), viewerID: nil)
  #expect(threads.map(\.conversationID) == ["t-group", "340282366841710300949128100000000001"])
  let group = threads[0]
  #expect(group.title == "Friends")
  #expect(group.preview == "dee: ❤️")
  let direct = threads[1]
  #expect(direct.title == "Ana")
  #expect(direct.preview == "are you there?")
  #expect(direct.unreadCount == 2)
  #expect(direct.latestMessageID == "a2")
  #expect(direct.sentAt == Date(timeIntervalSince1970: 1_800_000_120))
  #expect(direct.url.absoluteString == "https://www.instagram.com/direct/t/17840000000000001/")
  #expect(throws: InboxError.unexpectedResponse) { try Inbox.instagram(Data(#"{"message":"login_required"}"#.utf8), viewerID: "1") }
}

@Test func xInboxCountsMessagesFromOthersAfterTheReadMarker() throws {
  let json = #"""
    {"inbox_initial_state":{
      "conversations":{
        "1-2":{"type":"ONE_TO_ONE","trusted":true,"last_read_event_id":"1000"},
        "1-3":{"type":"ONE_TO_ONE","trusted":true,"last_read_event_id":"2000"},
        "1-5":{"type":"ONE_TO_ONE","trusted":true,"last_read_event_id":"0"},
        "g":{"type":"GROUP_DM","trusted":true,"name":"Crew","last_read_event_id":"0"},
        "req":{"type":"ONE_TO_ONE","trusted":false,"last_read_event_id":"0"},
        "spam":{"type":"ONE_TO_ONE","trusted":false,"last_read_event_id":"0","low_quality":true}},
      "users":{"2":{"name":"Ana"},"3":{"name":"Bob"},"4":{"name":"Cam"}},
      "entries":[
        {"message":{"conversation_id":"1-2","message_data":{"id":"999","time":"1800000000000","sender_id":"2","text":"old"}}},
        {"message":{"conversation_id":"1-2","message_data":{"id":"1001","time":"1800000060000","sender_id":"2","text":"first"}}},
        {"message":{"conversation_id":"1-2","message_data":{"id":"10000","time":"1800000120000","sender_id":"2","text":""}}},
        {"message":{"conversation_id":"1-2","message_data":{"id":"900","time":"1700000000000","sender_id":"1","text":"mine, before"}}},
        {"message":{"conversation_id":"1-5","message_data":{"id":"30","time":"1700000000000","sender_id":"5","text":"long ago"}}},
        {"message":{"conversation_id":"1-5","message_data":{"id":"31","time":"1700000060000","sender_id":"1","text":"answered, read marker never moved"}}},
        {"message":{"conversation_id":"req","message_data":{"id":"8","time":"1800000300000","sender_id":"6","text":"request"}}},
        {"message":{"conversation_id":"1-3","message_data":{"id":"1500","time":"1800000000000","sender_id":"3","text":"read"}}},
        {"message":{"conversation_id":"g","message_data":{"id":"5","time":"1800000240000","sender_id":"4","text":"yo"}}},
        {"message":{"conversation_id":"spam","message_data":{"id":"7","time":"1800000300000","sender_id":"9","text":"buy"}}},
        {"reaction_create":{"conversation_id":"1-2","id":"20000"}}]}}
    """#
  let threads = try Inbox.x(Data(json.utf8), viewerID: "1")
  #expect(threads.map(\.conversationID) == ["g", "1-2"])
  #expect(threads[0].title == "Crew")
  #expect(threads[0].preview == "Cam: yo")
  // "10000" sorts before "1001" as text, so IDs must compare as numbers.
  #expect(threads[1].latestMessageID == "10000")
  #expect(threads[1].preview == "Sent an attachment")
  #expect(threads[1].unreadCount == 2)
  #expect(threads[1].url.absoluteString == "https://x.com/messages/1-2")
}

@Test func xInboxRespectsInboxLastSeenAndParticipantReadMarkers() throws {
  let json = #"""
    {"inbox_initial_state":{
      "trusted_last_seen_event_id":"5000",
      "conversations":{
        "1-2":{"type":"ONE_TO_ONE","trusted":true,"last_read_event_id":"100"},
        "1-3":{"type":"ONE_TO_ONE","trusted":true,"last_read_event_id":"100",
               "participants":[{"user_id":"1","last_read_event_id":"6000"},{"user_id":"3"}]},
        "1-4":{"type":"ONE_TO_ONE","trusted":true,"last_read_event_id":"100"}
      },
      "users":{"2":{"name":"Old"},"3":{"name":"PartRead"},"4":{"name":"Fresh"}},
      "entries":[
        {"message":{"conversation_id":"1-2","message_data":{"id":"4000","time":"1700000000000","sender_id":"2","text":"old seen in inbox"}}},
        {"message":{"conversation_id":"1-3","message_data":{"id":"5500","time":"1800000000000","sender_id":"3","text":"read via participant marker"}}},
        {"message":{"conversation_id":"1-4","message_data":{"id":"5500","time":"1800000060000","sender_id":"4","text":"genuinely new"}}}
      ]}}
    """#
  let threads = try Inbox.x(Data(json.utf8), viewerID: "1")
  #expect(threads.map(\.conversationID) == ["1-4"])
  #expect(threads[0].title == "Fresh")
  #expect(threads[0].preview == "genuinely new")
}

@Test func notificationsSkipTheFirstCheckRepeatsAndUncheckedSites() {
  func thread(_ site: Site, _ id: String, _ message: String) -> UnreadThread {
    UnreadThread(
      site: site, conversationID: id, title: "", preview: "", unreadCount: 1, latestMessageID: message,
      sentAt: .now, url: URL(string: "https://example.com")!)
  }
  let first = Inbox.notifications(for: [thread(.x, "a", "1")], checked: [.x, .instagram], notified: nil)
  #expect(first.post.isEmpty)
  #expect(first.notified == ["x:a": "1"])
  let second = Inbox.notifications(
    for: [thread(.x, "a", "1"), thread(.instagram, "b", "9")], checked: [.x, .instagram], notified: first.notified)
  #expect(second.post.map(\.id) == ["instagram:b"])
  let third = Inbox.notifications(for: [thread(.x, "a", "2")], checked: [.x], notified: second.notified)
  #expect(third.post.map(\.id) == ["x:a"])
  #expect(third.notified == ["x:a": "2", "instagram:b": "9"])
  let read = Inbox.notifications(for: [], checked: [.x, .instagram], notified: third.notified)
  #expect(read.notified.isEmpty)
}

@Test func webPushDecryptsTheRFC8291Example() throws {
  let keys = WebPushKeys(
    privateKey: Data(base64URL: "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94")!,
    authSecret: Data(base64URL: "BTBZMqHH6r4Tts7J_aSIgg")!)
  #expect(
    try keys.publicKey.base64URL
      == "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")
  let header = Data(
    base64URL: "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8")!
  let ciphertext = Data(
    base64URL: "8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ")!
  let plaintext = try keys.decrypt(header + ciphertext)
  #expect(String(decoding: plaintext, as: UTF8.self) == "When I grow up, I want to be a watermelon")
  var tampered = header + ciphertext
  tampered[tampered.count - 1] ^= 1
  #expect(throws: (any Error).self) { try WebPushKeys.generate().decrypt(header + ciphertext) }
  #expect(throws: (any Error).self) { try keys.decrypt(tampered) }
}

@Test func instagramGraphQLInboxParsesSlideMailbox() throws {
  let json = #"""
    {"data":{"get_slide_mailbox_for_iris_subscription":{
      "id":"17850313595739588",
      "threads_by_folder":{"edges":[
        {"node":{"as_ig_direct_thread":{
          "id":"843140653749119","thread_fbid":"843140653749119","thread_id":"340282366841710301",
          "is_group":false,"is_muted":false,"marked_as_unread":false,"thread_title":"Bruno",
          "users":[{"id":"4220632603","interop_messaging_user_fbid":"106051607458031","full_name":"Bruno✧","username":"bbrunovazquez"}],
          "slide_read_receipts":[{"participant_fbid":"17850313595739588","watermark_timestamp_ms":"1800000000000"}],
          "slide_messages":{"edges":[
            {"node":{"id":"m2","sender_fbid":"106051607458031","timestamp_ms":"1800000120000","content_type":"TEXT","text_body":"holaa","igd_snippet":"holaa"}},
            {"node":{"id":"m1","sender_fbid":"106051607458031","timestamp_ms":"1800000060000","content_type":"TEXT","text_body":"che","igd_snippet":"che"}},
            {"node":{"id":"m0","sender_fbid":"106051607458031","timestamp_ms":"1800000000000","content_type":"TEXT","text_body":"seen","igd_snippet":"seen"}}
          ]}
        }}},
        {"node":{"as_ig_direct_thread":{
          "id":"17934123518595949","thread_fbid":"17934123518595949","thread_id":"340282366841710302",
          "is_group":false,"is_muted":false,"marked_as_unread":false,"thread_title":"mati",
          "users":[{"id":"47872467948","interop_messaging_user_fbid":"17846445962595949","full_name":"mati","username":"matias.aki"}],
          "slide_read_receipts":[{"participant_fbid":"17850313595739588","watermark_timestamp_ms":"1686057342121"}],
          "slide_messages":{"edges":[
            {"node":{"id":"s1","sender_fbid":"17850313595739588","timestamp_ms":"1690048394702","content_type":"MESSAGE_INLINE_SHARE","text_body":"https://example.com","igd_snippet":"You: https://example.com"}}
          ]}
        }}},
        {"node":{"as_ig_direct_thread":{
          "id":"999","thread_fbid":"999","thread_id":"340282366841710303",
          "is_group":true,"is_muted":false,"marked_as_unread":true,"thread_title":"Crew",
          "users":[{"id":"5","interop_messaging_user_fbid":"500","full_name":"","username":"dee"}],
          "slide_read_receipts":[{"participant_fbid":"17850313595739588","watermark_timestamp_ms":"1900000000000"}],
          "slide_messages":{"edges":[
            {"node":{"id":"g1","sender_fbid":"500","timestamp_ms":"1800000200000","content_type":"TEXT","text_body":"","igd_snippet":"Sent a reel"}}
          ]}
        }}},
        {"node":{"as_ig_direct_thread":{
          "id":"muted","thread_fbid":"muted","thread_id":"340282366841710304",
          "is_group":false,"is_muted":true,"marked_as_unread":false,"thread_title":"Noisy",
          "users":[{"id":"6","interop_messaging_user_fbid":"600","full_name":"Noisy","username":"noisy"}],
          "slide_read_receipts":[],
          "slide_messages":{"edges":[
            {"node":{"id":"n1","sender_fbid":"600","timestamp_ms":"1800000300000","content_type":"TEXT","text_body":"spam","igd_snippet":"spam"}}
          ]}
        }}}
      ]}
    }}}
    """#
  let threads = try Inbox.instagram(Data(json.utf8), viewerID: "52259691587")
  #expect(threads.map(\.conversationID) == ["340282366841710303", "340282366841710301"])
  #expect(threads[0].title == "Crew")
  #expect(threads[0].preview == "dee: Sent a reel")
  #expect(threads[0].url.absoluteString == "https://www.instagram.com/direct/t/999/")
  #expect(threads[1].title == "Bruno")
  #expect(threads[1].preview == "holaa")
  #expect(threads[1].unreadCount == 2)
  #expect(threads[1].latestMessageID == "m2")
  #expect(threads[1].url.absoluteString == "https://www.instagram.com/direct/t/843140653749119/")
}

@Test func pushNotificationParsesDecryptedPayloads() {
  let xPayload = Data(#"{"title":"Ana","body":"hey there","data":{"uri":"/messages/1-2"}}"#.utf8)
  let xParsed = Inbox.pushNotification(site: .x, payload: xPayload)
  #expect(xParsed?.title == "Ana")
  #expect(xParsed?.body == "hey there")
  #expect(xParsed?.url?.absoluteString == "https://x.com/messages/1-2")

  let igPayload = Data(#"{"title":"Instagram","message":"New message","url":"https://www.instagram.com/direct/t/123/"}"#.utf8)
  let igParsed = Inbox.pushNotification(site: .instagram, payload: igPayload)
  #expect(igParsed?.title == "Instagram")
  #expect(igParsed?.body == "New message")
  #expect(igParsed?.url?.absoluteString == "https://www.instagram.com/direct/t/123/")
}
