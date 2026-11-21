import Foundation

/// A conversation with messages the person hasn't read yet. Read on the device
/// from the site's own web inbox; nothing here is sent to the Scrollock server.
public struct UnreadThread: Equatable, Identifiable, Sendable {
  public var site: Site
  public var conversationID: String
  /// The sender, or the group's name.
  public var title: String
  public var preview: String
  public var unreadCount: Int
  public var latestMessageID: String
  public var sentAt: Date
  public var url: URL

  public var id: String { "\(site.rawValue):\(conversationID)" }

  public init(
    site: Site, conversationID: String, title: String, preview: String, unreadCount: Int, latestMessageID: String,
    sentAt: Date, url: URL
  ) {
    self.site = site
    self.conversationID = conversationID
    self.title = title
    self.preview = preview
    self.unreadCount = unreadCount
    self.latestMessageID = latestMessageID
    self.sentAt = sentAt
    self.url = url
  }
}

public enum InboxError: Error, Equatable {
  case unexpectedResponse
}

/// Parses the inboxes x.com and instagram.com load for their own Messages pages.
public enum Inbox {
  /// `GET https://www.instagram.com/api/v1/direct_v2/inbox/`. A thread is
  /// unread when its newest message is from someone else and comes after the
  /// viewer's `last_seen_at` marker.
  public static func instagram(_ data: Data, viewerID: String?) throws -> [UnreadThread] {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let inbox = root["inbox"] as? [String: Any]
    else { throw InboxError.unexpectedResponse }
    let viewer = viewerID ?? string((root["viewer"] as? [String: Any])?["pk"])
    let threads = inbox["threads"] as? [[String: Any]] ?? []
    let unread = threads.compactMap { thread -> UnreadThread? in
      guard
        let threadID = string(thread["thread_id"]),
        let items = thread["items"] as? [[String: Any]],
        let latest = items.first,
        let latestID = string(latest["item_id"]),
        let sender = string(latest["user_id"]), sender != viewer,
        let sentAt = date(latest["timestamp"])
      else { return nil }
      var seenAt = Date.distantPast
      if let viewer, let seen = (thread["last_seen_at"] as? [String: Any])?[viewer] as? [String: Any] {
        if string(seen["item_id"]) == latestID { return nil }
        seenAt = date(seen["timestamp"]) ?? .distantPast
        if seenAt >= sentAt { return nil }
      } else if (thread["read_state"] as? NSNumber)?.intValue == 0 {
        return nil
      }
      let count = items.prefix { item in
        string(item["user_id"]) != viewer && (date(item["timestamp"]).map { $0 > seenAt } ?? false)
      }.count
      let users = thread["users"] as? [[String: Any]] ?? []
      let user = users.first { string($0["pk"]) == sender }
      let name =
        (user?["full_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (user?["username"] as? String)
        ?? "Someone"
      let isGroup = thread["is_group"] as? Bool ?? false
      var preview = instagramPreview(latest)
      if isGroup { preview = "\(name): \(preview)" }
      let webID = string(thread["thread_v2_id"]) ?? threadID
      return UnreadThread(
        site: .instagram, conversationID: threadID,
        title: isGroup ? (thread["thread_title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name : name,
        preview: preview, unreadCount: max(count, 1), latestMessageID: latestID, sentAt: sentAt,
        url: URL(string: "https://www.instagram.com/direct/t/\(webID)/")!)
    }
    return unread.sorted { $0.sentAt > $1.sentAt }
  }

  /// `GET https://x.com/i/api/1.1/dm/inbox_initial_state.json`. Like x.com
  /// (see emusks' notes), only Primary conversations count (`trusted`), and a
  /// conversation is unread only when its newest message is from someone else
  /// and comes after both the read marker and the viewer's own last message.
  /// A reply counts as reading, even when X didn't move the read marker.
  public static func x(_ data: Data, viewerID: String?) throws -> [UnreadThread] {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let state = root["inbox_initial_state"] as? [String: Any]
    else { throw InboxError.unexpectedResponse }
    let conversations = state["conversations"] as? [String: [String: Any]] ?? [:]
    let users = state["users"] as? [String: [String: Any]] ?? [:]
    struct Message {
      var id: UInt64
      var sender: String
      var text: String
      var sentAt: Date
    }
    var byConversation: [String: [Message]] = [:]
    for entry in state["entries"] as? [[String: Any]] ?? [] {
      guard
        let message = entry["message"] as? [String: Any],
        let conversationID = string(message["conversation_id"]),
        let body = message["message_data"] as? [String: Any],
        let id = string(body["id"] ?? message["id"]).flatMap(UInt64.init),
        let sender = string(body["sender_id"])
      else { continue }
      let text = (body["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Sent an attachment"
      let sentAt = date(body["time"] ?? message["time"]) ?? .distantPast
      byConversation[conversationID, default: []].append(Message(id: id, sender: sender, text: text, sentAt: sentAt))
    }
    return byConversation.compactMap { conversationID, messages -> UnreadThread? in
      guard
        let conversation = conversations[conversationID],
        conversation["trusted"] as? Bool == true, conversation["muted"] as? Bool != true,
        let newest = messages.max(by: { $0.id < $1.id }), newest.sender != viewerID
      else { return nil }
      let readUpTo = max(
        string(conversation["last_read_event_id"]).flatMap(UInt64.init) ?? 0,
        messages.filter { $0.sender == viewerID }.map(\.id).max() ?? 0)
      let unread = messages.filter { $0.sender != viewerID && $0.id > readUpTo }
      guard !unread.isEmpty else { return nil }
      let name = users[newest.sender]?["name"] as? String ?? "Someone"
      let isGroup = conversation["type"] as? String == "GROUP_DM"
      return UnreadThread(
        site: .x, conversationID: conversationID,
        title: isGroup ? (conversation["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Group" : name,
        preview: isGroup ? "\(name): \(newest.text)" : newest.text,
        unreadCount: unread.count, latestMessageID: String(newest.id), sentAt: newest.sentAt,
        url: URL(string: "https://x.com/messages/\(conversationID)")!)
    }
    .sorted { $0.sentAt > $1.sentAt }
  }

  /// Which threads to notify about: those whose newest unread message wasn't
  /// notified before. `notified` maps thread IDs to the last notified message
  /// and is nil on the very first check, which only records what's already
  /// unread so old messages don't arrive as a burst. Entries for sites that
  /// couldn't be checked are kept.
  public static func notifications(
    for unread: [UnreadThread], checked: Set<Site>, notified: [String: String]?
  ) -> (post: [UnreadThread], notified: [String: String]) {
    var next = (notified ?? [:]).filter { key, _ in !checked.contains { key.hasPrefix("\($0.rawValue):") } }
    let fresh = unread.filter { checked.contains($0.site) }
    for thread in fresh { next[thread.id] = thread.latestMessageID }
    guard let notified else { return ([], next) }
    return (fresh.filter { notified[$0.id] != $0.latestMessageID }, next)
  }

  static func instagramPreview(_ item: [String: Any]) -> String {
    if let text = item["text"] as? String, !text.isEmpty { return text }
    switch item["item_type"] as? String {
    case "like": return "❤️"
    case "voice_media": return "Voice message"
    case "clip", "xma_clip": return "Shared a reel"
    case "media_share", "xma_media_share": return "Shared a post"
    case "story_share", "reel_share", "xma_story_share", "xma_reel_share": return "Shared a story"
    case "media", "raven_media", "visual_media": return "Sent a photo or video"
    case "animated_media": return "Sent a GIF"
    case "link": return ((item["link"] as? [String: Any])?["text"] as? String) ?? "Sent a link"
    default: return "Sent a message"
    }
  }

  static func string(_ value: Any?) -> String? {
    switch value {
    case let string as String: string
    case let number as NSNumber: number.stringValue
    default: nil
    }
  }

  /// Instagram sends microseconds, X milliseconds.
  static func date(_ value: Any?) -> Date? {
    guard let number = string(value).flatMap(Double.init) else { return nil }
    let seconds = number > 1e14 ? number / 1e6 : number > 1e11 ? number / 1e3 : number
    return Date(timeIntervalSince1970: seconds)
  }
}
