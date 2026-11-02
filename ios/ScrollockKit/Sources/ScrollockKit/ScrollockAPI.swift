import Foundation

/// Client for the same Worker API the browser extension uses. Native requests
/// carry no Origin header, so they rely solely on Telegram pairing and bearer sessions.
public struct ScrollockAPI: Sendable {
  public enum PollResult: Equatable, Sendable {
    case pending
    case connected(Session)
  }

  public let origin: URL
  let session: URLSession

  public init(origin: URL, session: URLSession = .shared) {
    self.origin = origin
    self.session = session
  }

  public func startPairing() async throws -> Pairing {
    try await send("POST", "/api/pair", body: [String: String]())
  }

  public func poll(_ pairing: Pairing) async throws -> PollResult {
    struct Response: Decodable {
      var pending: Bool?
      var token: String?
      var user: TelegramUser?
    }
    let response: Response
    do {
      response = try await send("GET", "/api/pair/\(pairing.id)", token: pairing.secret)
    } catch ScrollockError.unauthorized {
      throw ScrollockError.pairingExpired
    }
    if let token = response.token, let user = response.user {
      return .connected(Session(token: token, user: user))
    }
    return .pending
  }

  public func unlock(_ request: BreakRequest, session: Session) async throws -> Lease {
    struct Body: Encodable { var site: Site; var minutes: Int; var reason: String }
    return try await send(
      "POST", "/api/unlock",
      body: Body(site: request.site, minutes: request.minutes, reason: request.reason),
      token: session.token)
  }

  public func lock(_ lease: Lease, session: Session) async throws {
    struct Body: Encodable { var unlockId: String }
    struct Empty: Decodable {}
    let _: Empty = try await send("POST", "/api/lock", body: Body(unlockId: lease.id), token: session.token)
  }

  func send<Response: Decodable>(
    _ method: String, _ path: String, body: (some Encodable)? = String?.none, token: String? = nil
  ) async throws -> Response {
    var request = URLRequest(url: origin.appending(path: path), timeoutInterval: 12)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body { request.httpBody = try JSONEncoder().encode(body) }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw ScrollockError.unreachable
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      if status == 401 { throw ScrollockError.unauthorized }
      if status >= 500 { throw ScrollockError.unavailable }
      let message = (try? JSONDecoder().decode(APIFailure.self, from: data))?.error
      throw ScrollockError.server(message ?? "Reporting unavailable. Apps stay locked.")
    }
    return try JSONDecoder().decode(Response.self, from: data)
  }
}

private struct APIFailure: Decodable { var error: String }
