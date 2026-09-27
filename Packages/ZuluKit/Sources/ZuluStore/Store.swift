import Foundation
import GRDB
import ZulipAPI

/// The local-first store. Sync writes into it, the UI only ever reads out of it.
public final class ZuluStore: Sendable {
    public let writer: any DatabaseWriter

    /// Pass `nil` for an in-memory store.
    ///
    /// Takes a URL rather than a path because the app's container lives under
    /// "Application Support", and `URL.path()` percent-encodes that space into
    /// something SQLite cannot open.
    public init(url: URL?) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        if let url {
            writer = try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration)
        } else {
            writer = try DatabaseQueue(configuration: configuration)
        }
        try Self.migrator.migrate(writer)
    }

    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = base.appending(path: "Zulu", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "zulu.sqlite")
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "channel") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("color", .text)
                t.column("isRestricted", .boolean).notNull().defaults(to: false)
                t.column("isMuted", .boolean).notNull().defaults(to: false)
                t.column("pinned", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "topic") { t in
                t.column("channelID", .integer).notNull()
                    .references("channel", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("maxMessageID", .integer).notNull()
                t.primaryKey(["channelID", "name"])
            }

            try db.create(table: "user") { t in
                t.primaryKey("id", .integer)
                t.column("fullName", .text).notNull()
                t.column("email", .text)
                t.column("avatarURL", .text)
                t.column("isBot", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "message") { t in
                t.primaryKey("id", .integer)
                t.column("channelID", .integer)
                t.column("topic", .text)
                t.column("dmKey", .text)
                t.column("senderID", .integer).notNull()
                t.column("senderName", .text).notNull()
                t.column("senderAvatar", .text)
                t.column("renderedContent", .text).notNull()
                t.column("timestamp", .integer).notNull()
                t.column("isRead", .boolean).notNull().defaults(to: false)
                t.column("isMentioned", .boolean).notNull().defaults(to: false)
                t.column("editedAt", .integer)
            }
            try db.create(index: "message_conversation", on: "message", columns: ["channelID", "topic", "id"])
            try db.create(index: "message_dm", on: "message", columns: ["dmKey", "id"])

            try db.create(table: "reaction") { t in
                t.column("messageID", .integer).notNull()
                    .references("message", onDelete: .cascade)
                t.column("emojiName", .text).notNull()
                t.column("emojiCode", .text).notNull()
                t.column("reactionType", .text).notNull()
                t.column("userID", .integer).notNull()
                t.primaryKey(["messageID", "reactionType", "emojiCode", "userID"])
            }

            try db.create(table: "syncState") { t in
                t.primaryKey("id", .integer)
                t.column("queueID", .text)
                t.column("lastEventID", .integer).notNull()
            }
        }

        migrator.registerMigration("v2-unread") { db in
            try db.create(table: "unread") { t in
                t.primaryKey("messageID", .integer)
                t.column("channelID", .integer)
                t.column("topic", .text)
                t.column("dmKey", .text)
                t.column("isMention", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "unread_channel", on: "unread", columns: ["channelID", "topic"])
            try db.create(index: "unread_dm", on: "unread", columns: ["dmKey"])
        }

        migrator.registerMigration("v3-groups") { db in
            try db.create(table: "channelGroup") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("icon", .blob)
                t.column("position", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "channelGroupMember") { t in
                t.column("groupID", .text).notNull()
                    .references("channelGroup", onDelete: .cascade)
                t.column("channelID", .integer).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
                t.primaryKey(["groupID", "channelID"])
            }
            try db.create(index: "groupMember_channel", on: "channelGroupMember", columns: ["channelID"])
        }

        migrator.registerMigration("v4-polls") { db in
            // A poll is an append-only log, so this is the record and any tally derived from
            // it is a cache. The primary key on the submessage's own id makes applying the
            // same event twice a no-op, which happens routinely: once from GET /messages,
            // once from the event queue.
            try db.create(table: "submessage") { t in
                t.primaryKey("id", .integer)
                t.column("messageID", .integer).notNull()
                    .references("message", onDelete: .cascade)
                t.column("senderID", .integer).notNull()
                t.column("msgType", .text).notNull()
                t.column("content", .text).notNull()
            }
            try db.create(index: "submessage_message", on: "submessage", columns: ["messageID"])

            try db.alter(table: "message") { t in
                t.add(column: "isWidget", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v5-channel-mode") { db in
            try db.alter(table: "channel") { t in
                t.add(column: "detectedForum", .boolean).notNull().defaults(to: false)
                t.add(column: "modeOverride", .integer)
            }
        }

        migrator.registerEmojiMigration()

        registerPersonalShapeMigration(&migrator)
        registerHidingMigration(&migrator)
        registerOrderingMigration(&migrator)
        registerMutedTopicMigration(&migrator)
        registerChannelNotificationMigration(&migrator)

        return migrator
    }

    // MARK: writes

    public func replaceChannels(_ subscriptions: [Subscription]) throws {
        try writer.write { db in
            let keep = Set(subscriptions.map(\.stream_id))
            for existing in try ChannelRecord.fetchAll(db) where !keep.contains(existing.id) {
                try existing.delete(db)
            }
            for subscription in subscriptions {
                // Only the columns the server owns. Saving the whole record would carry
                // the viewer's own columns along as the defaults the API knows nothing
                // about, so every sync erased the forum/chat choice and the detector's
                // cached answer with it.
                try db.execute(
                    sql: """
                        INSERT INTO channel (
                            id, name, description, color, isRestricted, isMuted, pinned, pushNotifications
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            name = excluded.name,
                            description = excluded.description,
                            color = excluded.color,
                            isRestricted = excluded.isRestricted,
                            isMuted = excluded.isMuted,
                            pinned = excluded.pinned,
                            pushNotifications = excluded.pushNotifications
                        """,
                    arguments: [
                        subscription.stream_id, subscription.name, subscription.description,
                        subscription.color, subscription.isRestricted,
                        subscription.is_muted ?? false, subscription.pin_to_top ?? false,
                        subscription.push_notifications,
                    ]
                )
            }
        }
    }

    public func saveTopics(_ topics: [ChannelTopic], inChannel id: Int) throws {
        try writer.write { db in
            for topic in topics {
                try TopicRecord(channelID: id, name: topic.name, maxMessageID: topic.max_id).save(db)
            }
        }
    }

    public func saveUsers(_ users: [ZulipUser]) throws {
        try writer.write { db in
            for user in users { try UserRecord(from: user).save(db) }
        }
    }

    public func save(messages: [ZulipMessage], selfUserID: Int) throws {
        try writer.write { db in
            for message in messages {
                try Self.write(message, selfUserID: selfUserID, in: db)
            }
        }
    }

    static func write(_ message: ZulipMessage, selfUserID: Int, in db: Database) throws {
        try MessageRecord(from: message, selfUserID: selfUserID).save(db)
        try ReactionRecord
            .filter(Column("messageID") == message.id)
            .deleteAll(db)
        for reaction in message.reactions {
            try ReactionRecord(messageID: message.id, reaction: reaction).save(db)
        }
        // Saved rather than replaced: the fetched array and the event queue each carry part
        // of the log, and a refetch must not undo an event that arrived while it was in flight.
        for submessage in message.submessages ?? [] {
            try SubmessageRecord(from: submessage).save(db)
        }
        // A DM's participants are the only place some users appear, so they are learned here.
        for participant in message.dmParticipants where try UserRecord.fetchOne(db, key: participant.id) == nil {
            try UserRecord(id: participant.id, fullName: participant.full_name, email: participant.email).save(db)
        }
        if try UserRecord.fetchOne(db, key: message.sender_id) == nil {
            try UserRecord(
                id: message.sender_id,
                fullName: message.sender_full_name,
                email: message.sender_email,
                avatarURL: message.avatar_url
            ).save(db)
        }
        if message.isChannelMessage, let channelID = message.stream_id {
            let existing = try TopicRecord
                .filter(Column("channelID") == channelID && Column("name") == message.subject)
                .fetchOne(db)
            if existing == nil || existing!.maxMessageID < message.id {
                try TopicRecord(channelID: channelID, name: message.subject, maxMessageID: message.id).save(db)
            }
        }
    }

    public func syncState() throws -> SyncStateRecord? {
        try writer.read { db in try SyncStateRecord.fetchOne(db, key: 1) }
    }

    public func saveSyncState(queueID: String?, lastEventID: Int) throws {
        try writer.write { db in
            try SyncStateRecord(queueID: queueID, lastEventID: lastEventID).save(db)
        }
    }

    public func clearAll() throws {
        try writer.write { db in
            for table in [
                "promotedTopic", "channelGroupMember", "channelGroup",
                "submessage", "reaction", "message", "topic", "channel", "user", "syncState", "unread",
                "realmEmoji", "serverEmojiData", "userGroup", "channelSubscriber", "mutedTopic", "topicPolicy",
                "chosenFollow",
            ] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }
}

// MARK: - Unread state

extension ZuluStore {

    /// Replaces the unread set with the server's. Anything the server does not list is read,
    /// including messages marked read on another device while this one was away.
    public func replaceUnread(_ unread: UnreadMessages, selfUserID: Int) throws {
        let mentions = Set(unread.mentions)
        try writer.write { db in
            try db.execute(sql: "DELETE FROM unread")

            for channel in unread.streams {
                for id in channel.unread_message_ids {
                    try UnreadRecord(
                        messageID: id, channelID: channel.stream_id, topic: channel.topic,
                        isMention: mentions.contains(id)
                    ).save(db)
                }
            }
            for conversation in unread.pms {
                let key = MessageRecord.dmKey(
                    for: [conversation.other_user_id], selfUserID: selfUserID
                )
                for id in conversation.unread_message_ids {
                    try UnreadRecord(messageID: id, dmKey: key, isMention: mentions.contains(id))
                        .save(db)
                }
            }
            for group in unread.huddles {
                // Already sorted and already includes the current user.
                for id in group.unread_message_ids {
                    try UnreadRecord(
                        messageID: id, dmKey: group.user_ids_string, isMention: mentions.contains(id)
                    ).save(db)
                }
            }
        }
    }

    /// A message that arrives while the queue is live starts unread unless the server says
    /// otherwise, or unless it is the viewer's own.
    public func noteArrival(of message: ZulipMessage, selfUserID: Int) throws {
        guard !message.isRead, message.sender_id != selfUserID else { return }
        try writer.write { db in
            try UnreadRecord(
                messageID: message.id,
                channelID: message.isChannelMessage ? message.stream_id : nil,
                topic: message.isChannelMessage ? message.subject : nil,
                dmKey: message.isChannelMessage
                    ? nil
                    : MessageRecord.dmKey(
                        for: message.dmParticipants.map(\.id), selfUserID: selfUserID
                    ),
                isMention: message.isMentioned
            ).save(db)
        }
    }

    public func clearUnread(ids: [Int]) throws {
        guard !ids.isEmpty else { return }
        try writer.write { db in
            try UnreadRecord.filter(ids.contains(Column("messageID"))).deleteAll(db)
        }
    }

    public func markEverythingRead() throws {
        try writer.write { db in
            try UnreadRecord.deleteAll(db)
            try MessageRecord.updateAll(db, Column("isRead").set(to: true))
        }
    }

    /// Everything still unread in one conversation, however far back it goes. Reaching the
    /// live edge of a conversation means you are done with it, not that you are done with
    /// the dozen messages that happened to be drawn.
    public func unreadIDs(inChannel channelID: Int, topic: String) throws -> [Int] {
        try writer.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT messageID FROM unread WHERE channelID = ? AND topic = ?",
                arguments: [channelID, topic]
            )
        }
    }

    /// Every unread message in a channel across all of its topics, for clearing a whole
    /// channel from the sidebar without opening each conversation in it.
    public func unreadIDs(inChannel channelID: Int) throws -> [Int] {
        try writer.read { db in
            try Int.fetchAll(
                db, sql: "SELECT messageID FROM unread WHERE channelID = ?", arguments: [channelID]
            )
        }
    }

    public func unreadIDs(inDM key: String) throws -> [Int] {
        try writer.read { db in
            try Int.fetchAll(
                db, sql: "SELECT messageID FROM unread WHERE dmKey = ?", arguments: [key]
            )
        }
    }

    public func unreadIDs(limit: Int = 1000) throws -> [Int] {
        try writer.read { db in
            try Int.fetchAll(db, sql: "SELECT messageID FROM unread ORDER BY messageID LIMIT ?", arguments: [limit])
        }
    }
}
