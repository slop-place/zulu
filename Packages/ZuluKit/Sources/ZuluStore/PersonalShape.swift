import Foundation
import GRDB

/// A topic the viewer has lifted out of its channel to sit at channel level.
///
/// Zulip has no such concept, so like channel groups this is entirely the viewer's. A
/// promotion is a reference to a topic *name*, and Zulip topics are mutable in a way
/// channels are not — they get renamed, moved, and resolved — so a promotion has to
/// tolerate its target moving out from under it.
public struct PromotedTopicRecord: Codable, FetchableRecord, PersistableRecord, Sendable,
    Identifiable, Equatable
{
    public static let databaseTableName = "promotedTopic"

    public var channelID: Int
    public var topic: String
    /// A promoted topic can be filed away from its own channel — that is much of the point,
    /// since the reason to promote one is to put it where you actually look.
    public var groupID: String?
    public var position: Int

    public var id: String { "\(channelID)\u{1F}\(topic)" }

    public init(channelID: Int, topic: String, groupID: String? = nil, position: Int = 0) {
        self.channelID = channelID
        self.topic = topic
        self.groupID = groupID
        self.position = position
    }
}

/// A promoted topic with the counts and names the sidebar needs.
public struct PromotedTopicSummary: Decodable, FetchableRecord, Sendable, Identifiable, Equatable {
    public var channelID: Int
    public var topic: String
    public var groupID: String?
    public var channelName: String
    /// Taken from the parent channel: a promoted topic is exactly as private as the
    /// channel it came out of.
    public var isRestricted: Bool
    public var unreadCount: Int
    public var mentionCount: Int
    /// On the same scale as `ChannelSummary.position`: a promoted topic and a channel
    /// sit in one sidebar, so they are ordered against each other, not separately.
    public var position: Int?

    public var id: String { "\(channelID)\u{1F}\(topic)" }
    /// The name you gave it, or the topic itself. Promoting `general chat` out of a
    /// channel gives a top-level row whose real name says nothing, which is exactly when
    /// an alias earns its place.
    public var displayName: String
}

extension ZuluStore {

    static func registerPersonalShapeMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8-personal-shape") { db in
            try db.alter(table: "channel") { t in
                // A name only this viewer sees. The server's name stays in `name`, because
                // a mention has to emit the real one to produce a working link.
                t.add(column: "alias", .text)
            }
            try db.create(table: "promotedTopic") { t in
                t.column("channelID", .integer).notNull()
                    .references("channel", onDelete: .cascade)
                t.column("topic", .text).notNull()
                t.column("groupID", .text).references("channelGroup", onDelete: .setNull)
                t.column("position", .integer).notNull().defaults(to: 0)
                t.primaryKey(["channelID", "topic"])
            }
        }
    }

    // MARK: aliases

    /// `nil` restores the server's own name.
    public func setAlias(_ alias: String?, forChannel id: Int) throws {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.write { db in
            try db.execute(
                sql: "UPDATE channel SET alias = ? WHERE id = ?",
                arguments: [(trimmed?.isEmpty ?? true) ? nil : trimmed, id]
            )
        }
    }

    public func alias(forChannel id: Int) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT alias FROM channel WHERE id = ?", arguments: [id])
        }
    }

    // MARK: promotions

    /// A promotion with no group named inherits the channel's own, so a topic lifted
    /// out of a grouped channel stays where that channel lives instead of vanishing
    /// into the unfiled pile the viewer is not looking at.
    public func promote(topic: String, inChannel channelID: Int, toGroup groupID: String? = nil) throws {
        try writer.write { db in
            let group = try groupID ?? String.fetchOne(
                db,
                sql: "SELECT groupID FROM channelGroupMember WHERE channelID = ?",
                arguments: [channelID]
            )
            let next = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(position), -1) + 1 FROM (
                    SELECT position FROM promotedTopic
                    UNION ALL SELECT position FROM channel
                )
                """) ?? 0
            try PromotedTopicRecord(
                channelID: channelID, topic: topic, groupID: group, position: next
            ).save(db)
        }
    }

    public func demote(topic: String, inChannel channelID: Int) throws {
        try writer.write { db in
            try PromotedTopicRecord
                .filter(Column("channelID") == channelID && Column("topic") == topic)
                .deleteAll(db)
        }
    }

    public func isPromoted(topic: String, inChannel channelID: Int) throws -> Bool {
        try writer.read { db in
            try PromotedTopicRecord
                .filter(Column("channelID") == channelID && Column("topic") == topic)
                .fetchCount(db) > 0
        }
    }

    /// Every promotion, whichever group it is filed in, for surfaces that search the whole
    /// sidebar at once rather than one section of it.
    public func promotedTopics() throws -> [PromotedTopicRecord] {
        try writer.read { db in try PromotedTopicRecord.fetchAll(db) }
    }

    /// A promotion follows its topic when the server renames it. Without this the entry
    /// would quietly point at a name nobody uses any more.
    public func renamePromotedTopic(inChannel channelID: Int, from old: String, to new: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE OR REPLACE promotedTopic SET topic = ? WHERE channelID = ? AND topic = ?",
                arguments: [new, channelID, old]
            )
        }
    }

    /// Promotions whose topic no longer exists are dropped rather than left as dead rows in
    /// the sidebar. Called after a channel's topics are refetched, when the truth is known.
    public func pruneVanishedPromotions(inChannel channelID: Int) throws {
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM promotedTopic
                 WHERE channelID = ?
                   AND topic NOT IN (SELECT name FROM topic WHERE channelID = ?)
                """, arguments: [channelID, channelID])
        }
    }

    /// The promoted topics in one group, or — passing `nil` — the ones no group has claimed.
    public func observePromotedTopics(inGroup groupID: String?)
        -> ValueObservation<ValueReducers.Fetch<[PromotedTopicSummary]>>
    {
        let membership = groupID == nil ? "p.groupID IS NULL" : "p.groupID = ?"
        let arguments: StatementArguments = groupID.map { [$0] } ?? []

        return ValueObservation.tracking { db in
            try PromotedTopicSummary.fetchAll(db, sql: """
                SELECT p.channelID, p.topic, p.groupID,
                       COALESCE(p.alias, NULLIF(p.topic, ''), 'general chat') AS displayName,
                       COALESCE(c.alias, c.name) AS channelName,
                       c.isRestricted,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.channelID = p.channelID AND u.topic = p.topic) AS unreadCount,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.channelID = p.channelID AND u.topic = p.topic
                           AND u.isMention = 1) AS mentionCount,
                       p.position
                  FROM promotedTopic p
                  JOIN channel c ON c.id = p.channelID
                 WHERE \(membership)
                   AND \(TopicMuting.isNotMuted(channel: "p.channelID", topic: "p.topic"))
                 ORDER BY p.position
                """, arguments: arguments)
        }
    }

    public func setGroup(_ groupID: String?, forPromotedTopic topic: String, inChannel channelID: Int) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE promotedTopic SET groupID = ? WHERE channelID = ? AND topic = ?",
                arguments: [groupID, channelID, topic]
            )
        }
    }
}

extension ZuluStore {

    static func registerHidingMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9-hiding") { db in
            try db.alter(table: "channel") { t in
                // Hidden is this viewer's filing decision and nothing more: the channel is
                // still subscribed, still notifies, and still counts its mentions.
                t.add(column: "hidden", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "promotedTopic") { t in
                t.add(column: "alias", .text)
            }
        }
    }

    /// Zulip's own pin. The server's copy replaces this on the next sync, so a pin made on
    /// the web shows up here too.
    public func setPinned(_ pinned: Bool, forChannel id: Int) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE channel SET pinned = ? WHERE id = ?", arguments: [pinned, id]
            )
        }
    }

    public func setHidden(_ hidden: Bool, forChannel id: Int) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE channel SET hidden = ? WHERE id = ?", arguments: [hidden, id]
            )
        }
    }

    public func setAlias(_ alias: String?, forPromotedTopic topic: String, inChannel channelID: Int) throws {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.write { db in
            try db.execute(
                sql: "UPDATE promotedTopic SET alias = ? WHERE channelID = ? AND topic = ?",
                arguments: [(trimmed?.isEmpty ?? true) ? nil : trimmed, channelID, topic]
            )
        }
    }

    public func observeHiddenChannels()
        -> ValueObservation<ValueReducers.Fetch<[ChannelSummary]>>
    {
        ValueObservation.tracking { db in
            try ChannelSummary.fetchAll(db, sql: """
                SELECT \(Self.sidebarRowColumns)
                  FROM channel c
                 WHERE c.hidden = 1
                 ORDER BY name COLLATE NOCASE
                """)
        }
    }
}

/// The SQL fragment that decides whether a channel earns a row in the sidebar.
///
/// A channel drops out when it is hidden, and also when every topic it has is promoted —
/// promoting the last one absorbs the channel, since there would be nothing left beneath
/// it but its own promoted topic sitting one level up. It comes back on its own the moment
/// someone starts a new topic, without disturbing the promotion.
enum ChannelVisibility {
    static let clause = """
        c.hidden = 0
          AND NOT (
                (SELECT COUNT(*) FROM topic t WHERE t.channelID = c.id) > 0
            AND (SELECT COUNT(*) FROM topic t WHERE t.channelID = c.id)
                = (SELECT COUNT(*) FROM promotedTopic p WHERE p.channelID = c.id)
          )
        """
}

extension ZuluStore {

    static func registerOrderingMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v10-channel-order") { db in
            // Null means "no opinion", which sorts after everything the viewer has placed
            // and falls back to alphabetical among themselves.
            try db.alter(table: "channel") { t in
                t.add(column: "position", .integer)
            }
        }
    }

    /// Writes an explicit order for exactly the rows listed, leaving everything else
    /// unplaced. Channels and promoted topics share one sequence because they share one
    /// sidebar — a promoted topic is a top-level row, not an appendix to the channel list.
    public func reorderSidebar(_ slots: [SidebarSlot]) throws {
        try writer.write { db in
            for (index, slot) in slots.enumerated() {
                switch slot {
                case .channel(let id):
                    try db.execute(
                        sql: "UPDATE channel SET position = ? WHERE id = ?",
                        arguments: [index, id]
                    )
                case .promotedTopic(let channelID, let topic):
                    try db.execute(
                        sql: """
                            UPDATE promotedTopic SET position = ?
                             WHERE channelID = ? AND topic = ?
                            """,
                        arguments: [index, channelID, topic]
                    )
                }
            }
        }
    }

}

/// One draggable row in the sidebar. Forum topics are absent on purpose: they hang under
/// their channel and move with it.
public enum SidebarSlot: Hashable, Sendable {
    case channel(Int)
    case promotedTopic(channelID: Int, topic: String)
}
