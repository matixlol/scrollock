import CryptoKit
import Foundation

/// The keys behind a push subscription Scrollock hands to X or Instagram in
/// place of the browser's own. Sites encrypt each push to these keys (RFC 8291),
/// so the relay only ever sees ciphertext and the phone decrypts it.
public struct WebPushKeys: Codable, Equatable, Sendable {
  public var privateKey: Data
  public var authSecret: Data

  public init(privateKey: Data, authSecret: Data) {
    self.privateKey = privateKey
    self.authSecret = authSecret
  }

  public static func generate() -> WebPushKeys {
    WebPushKeys(
      privateKey: P256.KeyAgreement.PrivateKey().rawRepresentation,
      authSecret: Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))
  }

  /// The uncompressed point the page reports as the subscription's `p256dh` key.
  public var publicKey: Data {
    get throws { try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.x963Representation }
  }

  /// Decrypts an `aes128gcm` push body: salt, record size and the sender's
  /// public key, then one or more AES-GCM records.
  public func decrypt(_ body: Data) throws -> Data {
    let body = Data(body)
    guard body.count > 21 else { throw WebPushError.malformed }
    let salt = body.prefix(16)
    let recordSize = body[16..<20].reduce(0) { $0 << 8 | Int($1) }
    let keyLength = Int(body[20])
    guard recordSize > 17, body.count > 21 + keyLength else { throw WebPushError.malformed }
    let senderKey = body[21..<(21 + keyLength)]
    let receiver = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
    let sender = try P256.KeyAgreement.PublicKey(x963Representation: senderKey)
    let keyInfo = Data("WebPush: info\0".utf8) + receiver.publicKey.x963Representation + senderKey
    let ikm = try receiver.sharedSecretFromKeyAgreement(with: sender).hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: authSecret, sharedInfo: keyInfo, outputByteCount: 32)
    func derive(_ label: String, _ length: Int) -> SymmetricKey {
      HKDF<SHA256>.deriveKey(
        inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: \(label)\0".utf8), outputByteCount: length)
    }
    let key = derive("aes128gcm", 16)
    let baseNonce = derive("nonce", 12).withUnsafeBytes { Data($0) }

    var plaintext = Data()
    var offset = 21 + keyLength
    var sequence: UInt64 = 0
    while offset < body.count {
      let record = body[offset..<min(offset + recordSize, body.count)]
      guard record.count > 16 else { throw WebPushError.malformed }
      var nonce = baseNonce
      for index in 0..<8 { nonce[nonce.startIndex + 4 + index] ^= UInt8(truncatingIfNeeded: sequence >> (8 * (7 - index))) }
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce), ciphertext: record.dropLast(16), tag: record.suffix(16))
      var padded = try AES.GCM.open(box, using: key)
      // Strip padding: zeros, then a delimiter of 2 on the last record and 1 before it.
      while padded.last == 0 { padded.removeLast() }
      guard let delimiter = padded.popLast(), delimiter == 1 || delimiter == 2 else { throw WebPushError.malformed }
      plaintext += padded
      offset += recordSize
      sequence += 1
      if delimiter == 2 { break }
    }
    return plaintext
  }
}

public enum WebPushError: Error, Equatable {
  case malformed
}

/// A push the relay received for one of this device's subscriptions, still encrypted.
public struct CapturedPush: Codable, Equatable, Sendable {
  public var receivedAt: Date
  /// Request headers such as `content-encoding`, `ttl`, `urgency` and the VAPID `authorization`.
  public var headers: [String: String]
  public var body: Data

  enum CodingKeys: String, CodingKey { case receivedAt, headers, body }

  public init(receivedAt: Date, headers: [String: String], body: Data) {
    self.receivedAt = receivedAt
    self.headers = headers
    self.body = body
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    receivedAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .receivedAt) / 1000)
    headers = try container.decode([String: String].self, forKey: .headers)
    body = Data(base64Encoded: try container.decode(String.self, forKey: .body)) ?? Data()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(receivedAt.timeIntervalSince1970 * 1000, forKey: .receivedAt)
    try container.encode(headers, forKey: .headers)
    try container.encode(body.base64EncodedString(), forKey: .body)
  }
}

/// A subscription faked for a site: the relay endpoint plus the keys sites encrypt to.
public struct PushSubscriptionRecord: Codable, Equatable, Sendable {
  public var site: Site
  public var id: String
  public var endpoint: URL
  public var keys: WebPushKeys
  public var subscribedAt: Date

  public init(site: Site, id: String, endpoint: URL, keys: WebPushKeys, subscribedAt: Date) {
    self.site = site
    self.id = id
    self.endpoint = endpoint
    self.keys = keys
    self.subscribedAt = subscribedAt
  }
}

extension Data {
  /// Unpadded base64url, as Web Push uses for keys.
  public var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public init?(base64URL: String) {
    var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    self.init(base64Encoded: value)
  }
}
