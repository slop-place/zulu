import Foundation
import GRDB
import ZulipAPI

/// A channel with the counts the sidebar needs, so the list is one query not N+1.
public struct ChannelSummary: Decodable, FetchableRecord, Sendable, Identifiable, Equatable {
    public var id: Int
    public var name: String
    public var isRestricted: Bool
    public var isMuted: Bool
    public var pinned: Bool
    public var topicCount: Int
    /// The detector's answer, already overruled by the person's choice if they made one.
    public var isForum: Bool
    public var unreadCount: Int
    public var generalChatUnreadCount: Int
    public var mentionCount: Int
    public var generalChatMentionCount: Int
    /// Where the viewer dragged it. Null until they drag anything.
    public var position: Int?

    /// A channel whose recent traffic all sits in one topic is a chat room in practice,
    /// whatever the server thinks. This is the auto-detection the map fixed.
    public var rendersAsForum: Bool { isForum }

    /// A forum's row stands for its general chat; its other topics light their own rows.
    public var rowUnreadCount: Int { rendersAsForum ? generalChatUnreadCount : unreadCount }
    public var rowMentionCount: Int { rendersAsForum ? generalChatMentionCount : mentionCount }
}

public struct TopicSummary: Decodable, FetchableRecord, Sendable, Identifiable, Equatable {
    public var channelID: Int
    public var name: String
    public var maxMessageID: Int
    public var unreadCount: Int
    public var lastSender: String?
    public var lastTimestamp: Int?

    public var id: String { "\(channelID)/\(name)" }
    public var date: Date? { lastTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

public struct DMSummary: Decodable, FetchableRecord, Sendable, Identifiable, Equatable {
    public var dmKey: String
    public var unreadCount: Int
    public var lastMessageID: Int
    public var lastSender: String?
    public var lastSenderID: Int?
    /// Rendered HTML, flattened for display by the caller.
    public var lastContent: String?
    public var lastTimestamp: Int?

    public var id: String { dmKey }
    public var participantIDs: [Int] { dmKey.split(separator: ",").compactMap { Int($0) } }
    public var date: Date? { lastTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

extension ZuluStore {

    public func observeChannels() -> ValueObservation<ValueReducers.Fetch<[ChannelSummary]>> {
        ValueObservation.tracking { db in
            try ChannelSummary.fetchAll(db, sql: """
                SELECT c.id, COALESCE(c.alias, c.name) AS name, c.isRestricted, c.isMuted, c.pinned,
                       COALESCE(c.modeOverride, c.detectedForum) AS isForum,
                       (SELECT COUNT(*) FROM topic t WHERE t.channelID = c.id) AS topicCount,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.channelID = c.id AND \(TopicMuting.unreadIsVisible)) AS unreadCount,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.channelID = c.id AND \(TopicMuting.unreadIsVisible)
                           AND \(GeneralChat.unreadIsGeneralChat)) AS generalChatUnreadCount,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.channelID = c.id AND u.isMention = 1) AS mentionCount,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.channelID = c.id AND u.isMention = 1
                           AND \(GeneralChat.unreadIsGeneralChat)) AS generalChatMentionCount,
                       c.position
                  FROM channel c
                 WHERE \(ChannelVisibility.clause)
                 ORDER BY c.pinned DESC, c.position IS NULL, c.position, name COLLATE NOCASE
                """)
        }
    }

    public func observeTopics(inChannel id: Int) -> ValueObservation<ValueReducers.Fetch<[TopicSummary]>> {
        ValueObservation.tracking { db in
            try TopicSummary.fetchAll(db, sql: """
                SELECT t.channelID, t.name, t.maxMessageID,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.channelID = t.channelID AND u.topic = t.name) AS unreadCount,
                       (SELECT m.senderName FROM message m
                         WHERE m.channelID = t.channelID AND m.topic = t.name
                         ORDER BY m.id DESC LIMIT 1) AS lastSender,
                       (SELECT m.timestamp FROM message m
                         WHERE m.channelID = t.channelID AND m.topic = t.name
                         ORDER BY m.id DESC LIMIT 1) AS lastTimestamp
                  FROM topic t
                 WHERE t.channelID = ?
                   -- A promoted topic sits at channel level instead; listing it in
                   -- both places would duplicate it and count its unread twice.
                   AND t.name NOT IN (
                       SELECT topic FROM promotedTopic WHERE channelID = t.channelID
                   )
                   AND \(TopicMuting.isNotMuted(channel: "t.channelID", topic: "t.name"))
                 ORDER BY t.maxMessageID DESC
                """, arguments: [id])
        }
    }

    public func observeDMs() -> ValueObservation<ValueReducers.Fetch<[DMSummary]>> {
        ValueObservation.tracking { db in
            try DMSummary.fetchAll(db, sql: """
                SELECT m.dmKey,
                       (SELECT COUNT(*) FROM unread u WHERE u.dmKey = m.dmKey) AS unreadCount,
                       MAX(m.id) AS lastMessageID,
                       (SELECT s.senderName FROM message s WHERE s.dmKey = m.dmKey
                         ORDER BY s.id DESC LIMIT 1) AS lastSender,
                       (SELECT s.senderID FROM message s WHERE s.dmKey = m.dmKey
                         ORDER BY s.id DESC LIMIT 1) AS lastSenderID,
                       (SELECT s.renderedContent FROM message s WHERE s.dmKey = m.dmKey
                         ORDER BY s.id DESC LIMIT 1) AS lastContent,
                       (SELECT s.timestamp FROM message s WHERE s.dmKey = m.dmKey
                         ORDER BY s.id DESC LIMIT 1) AS lastTimestamp
                  FROM message m
                 WHERE m.dmKey IS NOT NULL
                 GROUP BY m.dmKey
                 ORDER BY lastMessageID DESC
                """)
        }
    }

    public func observeMessages(channelID: Int, topic: String)
        -> ValueObservation<ValueReducers.Fetch<[MessageRecord]>>
    {
        ValueObservation.tracking { db in
            try MessageRecord
                .filter(Column("channelID") == channelID && Column("topic") == topic)
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    /// How many stored messages a conversation with nothing unread needs before it opens
    /// on them. It opens on its newest message, and what the server adds goes above the
    /// oldest stored one; with fewer than a screen's worth stored, that change would be on
    /// screen.
    public static let storedMessagesToOpenOn = 20

    /// Whether a topic can be shown from what is stored while the server is asked for the
    /// rest, without what the server adds moving what is on screen. With something unread,
    /// the oldest unread message has to be stored: the conversation opens on it, and what
    /// arrives goes above it. With nothing unread, enough has to be stored to fill the
    /// screen.
    public func canOpenFromStore(channelID: Int, topic: String) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT COALESCE(
                    (SELECT EXISTS (SELECT 1 FROM message m WHERE m.id = u.messageID)
                       FROM unread u WHERE u.channelID = ? AND u.topic = ?
                      ORDER BY u.messageID LIMIT 1),
                    (SELECT COUNT(*) FROM message WHERE channelID = ? AND topic = ?) >= ?)
                """, arguments: [channelID, topic, channelID, topic, Self.storedMessagesToOpenOn]) ?? false
        }
    }

    public func canOpenFromStore(dmKey: String) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT COALESCE(
                    (SELECT EXISTS (SELECT 1 FROM message m WHERE m.id = u.messageID)
                       FROM unread u WHERE u.dmKey = ?
                      ORDER BY u.messageID LIMIT 1),
                    (SELECT COUNT(*) FROM message WHERE dmKey = ?) >= ?)
                """, arguments: [dmKey, dmKey, Self.storedMessagesToOpenOn]) ?? false
        }
    }

    public func observeMessages(dmKey: String) -> ValueObservation<ValueReducers.Fetch<[MessageRecord]>> {
        ValueObservation.tracking { db in
            try MessageRecord
                .filter(Column("dmKey") == dmKey)
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    public func observeUsers() -> ValueObservation<ValueReducers.Fetch<[UserRecord]>> {
        ValueObservation.tracking { db in try UserRecord.fetchAll(db) }
    }

    public func reactions(forMessage id: Int) throws -> [ReactionRecord] {
        try writer.read { db in
            try ReactionRecord.filter(Column("messageID") == id).fetchAll(db)
        }
    }

    public func markRead(messageIDs: [Int]) throws {
        try writer.write { db in
            try MessageRecord
                .filter(messageIDs.contains(Column("id")))
                .updateAll(db, Column("isRead").set(to: true))
        }
    }
}

// MARK: - Mutations the sync engine needs, so GRDB stays inside this target

extension ZuluStore {

    public func channels() throws -> [ChannelRecord] {
        try writer.read { db in try ChannelRecord.fetchAll(db) }
    }

    public func deleteMessages(ids: [Int]) throws {
        try writer.write { db in
            try MessageRecord.filter(ids.contains(Column("id"))).deleteAll(db)
        }
    }

    public func setRead(ids: [Int], read: Bool) throws {
        try writer.write { db in
            try MessageRecord
                .filter(ids.contains(Column("id")))
                .updateAll(db, Column("isRead").set(to: read))
        }
    }

    public func updateRenderedContent(id: Int, html: String, editedAt: Int? = nil) throws {
        try writer.write { db in
            var assignments = [Column("renderedContent").set(to: html)]
            if let editedAt { assignments.append(Column("editedAt").set(to: editedAt)) }
            try MessageRecord
                .filter(Column("id") == id)
                .updateAll(db, assignments)
        }
    }

    /// What pressing up in an empty composer edits. Polls are left out: their text is
    /// the `/poll` command, and editing it does not change the poll.
    public func latestMessage(from senderID: Int, channelID: Int, topic: String) throws -> MessageRecord? {
        try writer.read { db in
            try MessageRecord
                .filter(Column("senderID") == senderID && !Column("isWidget"))
                .filter(Column("channelID") == channelID && Column("topic") == topic)
                .order(Column("id").desc)
                .fetchOne(db)
        }
    }

    public func latestMessage(from senderID: Int, dmKey: String) throws -> MessageRecord? {
        try writer.read { db in
            try MessageRecord
                .filter(Column("senderID") == senderID && !Column("isWidget"))
                .filter(Column("dmKey") == dmKey)
                .order(Column("id").desc)
                .fetchOne(db)
        }
    }

    /// Applies one `reaction` event.
    ///
    /// The server sends these for every message in every subscribed channel, fetched or
    /// not. One for a message this client does not hold is dropped: the reactions arrive
    /// with the message itself when it is fetched, and a row pointing at nothing would
    /// fail the foreign key and wedge the event queue on that batch.
    public func setReaction(_ reaction: Reaction, onMessage id: Int, added: Bool) throws {
        try writer.write { db in
            guard try MessageRecord.exists(db, key: id) else { return }
            if added {
                try ReactionRecord(messageID: id, reaction: reaction).save(db)
            } else {
                try ReactionRecord
                    .filter(Column("messageID") == id
                        && Column("emojiCode") == reaction.emoji_code
                        && Column("reactionType") == reaction.reaction_type
                        && Column("userID") == reaction.user_id)
                    .deleteAll(db)
            }
        }
    }
}

/// The topic a channel's "general chat" lives in, as this server spells it.
///
/// Newer servers use the empty name and let clients label it; older ones, and any
/// server talking to a client that has not opted into the empty name, send the label
/// itself as the topic. Whichever exists here is the one to open.
enum GeneralChat {
    static let fallbackName = "general chat"

    static func topicName(inChannel channel: String) -> String {
        """
        (SELECT name FROM topic
          WHERE channelID = \(channel) AND name IN ('', 'general chat', '(no topic)')
          ORDER BY CASE name WHEN '' THEN 0 WHEN 'general chat' THEN 1 ELSE 2 END
          LIMIT 1)
        """
    }

    static let unreadIsGeneralChat =
        "u.topic = COALESCE(\(topicName(inChannel: "u.channelID")), '\(fallbackName)')"
}

extension ZuluStore {
    public func generalChatTopicName(inChannel id: Int) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT \(GeneralChat.topicName(inChannel: "?"))", arguments: [id])
        }
    }

    /// The most recently active topics across every channel, so the sidebar can show a
    /// channel's live conversations without a query per channel. An unread topic is
    /// always included, however old, because a forum's own row no longer lights for it.
    public func observeRecentTopics(perChannel limit: Int = 3)
        -> ValueObservation<ValueReducers.Fetch<[TopicSummary]>>
    {
        ValueObservation.tracking { db in
            try TopicSummary.fetchAll(db, sql: """
                SELECT t.channelID, t.name, t.maxMessageID,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.channelID = t.channelID AND u.topic = t.name) AS unreadCount,
                       (SELECT m.senderName FROM message m
                         WHERE m.channelID = t.channelID AND m.topic = t.name
                         ORDER BY m.id DESC LIMIT 1) AS lastSender,
                       (SELECT m.timestamp FROM message m
                         WHERE m.channelID = t.channelID AND m.topic = t.name
                         ORDER BY m.id DESC LIMIT 1) AS lastTimestamp
                  FROM topic t
                 WHERE t.name NOT IN (
                           SELECT topic FROM promotedTopic WHERE channelID = t.channelID
                       )
                   AND \(TopicMuting.isNotMuted(channel: "t.channelID", topic: "t.name"))
                   AND ((
                        SELECT COUNT(*) FROM topic peer
                         WHERE peer.channelID = t.channelID
                           AND peer.maxMessageID > t.maxMessageID
                           AND \(TopicMuting.isNotMuted(channel: "peer.channelID", topic: "peer.name"))
                       ) < ?
                        OR EXISTS (SELECT 1 FROM unread u
                                    WHERE u.channelID = t.channelID AND u.topic = t.name))
                 ORDER BY t.channelID, t.maxMessageID DESC
                """, arguments: [limit])
        }
    }
}

// MARK: - Recent conversations

/// One line of the Recent view: a topic or a direct message, and what last happened in
/// it. A channel's own name arrives already aliased, the way the sidebar shows it.
public struct RecentConversation: Decodable, FetchableRecord, Sendable, Identifiable, Equatable {
    public var channelID: Int?
    public var channelName: String?
    public var topic: String?
    public var isForum: Bool?
    public var isRestricted: Bool?
    public var dmKey: String?
    public var lastMessageID: Int
    public var lastSenderID: Int?
    public var lastSender: String?
    /// Rendered HTML, flattened for display by the caller. Nil when the topic is known
    /// from the server's topic list but none of its messages have been fetched yet.
    public var lastContent: String?
    public var lastTimestamp: Int?
    public var unreadCount: Int
    public var mentionCount: Int

    public var id: String {
        if let dmKey { "d:\(dmKey)" } else { "c:\(channelID ?? 0)/\(topic ?? "")" }
    }
    public var isDirect: Bool { dmKey != nil }
    public var date: Date? { lastTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

extension ZuluStore {

    /// Every conversation that is not muted or hidden, newest first, so catching up is
    /// reading top to bottom. Message ids are monotonic across a realm, which is why a
    /// topic with no fetched messages can still take its place in the order.
    public func observeRecentConversations(limit: Int = 60)
        -> ValueObservation<ValueReducers.Fetch<[RecentConversation]>>
    {
        ValueObservation.tracking { db in
            try RecentConversation.fetchAll(db, sql: """
                SELECT * FROM (
                    SELECT t.channelID AS channelID,
                           COALESCE(c.alias, c.name) AS channelName,
                           t.name AS topic,
                           COALESCE(c.modeOverride, c.detectedForum) AS isForum,
                           c.isRestricted AS isRestricted,
                           NULL AS dmKey,
                           t.maxMessageID AS lastMessageID,
                           (SELECT m.senderID FROM message m
                             WHERE m.channelID = t.channelID AND m.topic = t.name
                             ORDER BY m.id DESC LIMIT 1) AS lastSenderID,
                           (SELECT m.senderName FROM message m
                             WHERE m.channelID = t.channelID AND m.topic = t.name
                             ORDER BY m.id DESC LIMIT 1) AS lastSender,
                           (SELECT m.renderedContent FROM message m
                             WHERE m.channelID = t.channelID AND m.topic = t.name
                             ORDER BY m.id DESC LIMIT 1) AS lastContent,
                           (SELECT m.timestamp FROM message m
                             WHERE m.channelID = t.channelID AND m.topic = t.name
                             ORDER BY m.id DESC LIMIT 1) AS lastTimestamp,
                           (SELECT COUNT(*) FROM unread u
                             WHERE u.channelID = t.channelID AND u.topic = t.name) AS unreadCount,
                           (SELECT COUNT(*) FROM unread u
                             WHERE u.channelID = t.channelID AND u.topic = t.name
                               AND u.isMention = 1) AS mentionCount
                      FROM topic t
                      JOIN channel c ON c.id = t.channelID
                     WHERE c.hidden = 0
                       AND c.isMuted = 0
                       AND \(TopicMuting.isNotMuted(channel: "t.channelID", topic: "t.name"))
                    UNION ALL
                    SELECT NULL, NULL, NULL, NULL, NULL,
                           m.dmKey,
                           MAX(m.id) AS lastMessageID,
                           (SELECT s.senderID FROM message s WHERE s.dmKey = m.dmKey
                             ORDER BY s.id DESC LIMIT 1),
                           (SELECT s.senderName FROM message s WHERE s.dmKey = m.dmKey
                             ORDER BY s.id DESC LIMIT 1),
                           (SELECT s.renderedContent FROM message s WHERE s.dmKey = m.dmKey
                             ORDER BY s.id DESC LIMIT 1),
                           (SELECT s.timestamp FROM message s WHERE s.dmKey = m.dmKey
                             ORDER BY s.id DESC LIMIT 1),
                           (SELECT COUNT(*) FROM unread u WHERE u.dmKey = m.dmKey),
                           (SELECT COUNT(*) FROM unread u WHERE u.dmKey = m.dmKey AND u.isMention = 1)
                      FROM message m
                     WHERE m.dmKey IS NOT NULL
                     GROUP BY m.dmKey
                )
                ORDER BY lastMessageID DESC
                LIMIT ?
                """, arguments: [limit])
        }
    }
}
