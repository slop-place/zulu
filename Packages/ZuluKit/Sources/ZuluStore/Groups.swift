import Foundation
import GRDB
import ZulipAPI

/// A user-made folder of channels — the "server" in the Discord-shaped rail. Zulip has no
/// such concept, so this is entirely Zulu's, which is why it syncs between the user's own
/// devices rather than living on the Zulip server.
public struct ChannelGroupRecord: Codable, FetchableRecord, PersistableRecord, Sendable,
    Identifiable, Equatable
{
    public static let databaseTableName = "channelGroup"

    public var id: String
    public var name: String
    /// A user-supplied image. Absent means the rail draws initials instead.
    public var icon: Data?
    public var position: Int

    public init(id: String = UUID().uuidString, name: String, icon: Data? = nil, position: Int) {
        self.id = id
        self.name = name
        self.icon = icon
        self.position = position
    }

    /// Up to two letters, taken from word starts, for the rail's fallback.
    public var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init)
        return letters.joined().uppercased()
    }
}

public struct ChannelGroupMemberRecord: Codable, FetchableRecord, PersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "channelGroupMember"

    public var groupID: String
    public var channelID: Int
    public var position: Int

    public init(groupID: String, channelID: Int, position: Int) {
        self.groupID = groupID
        self.channelID = channelID
        self.position = position
    }
}

/// A group with the counts the rail needs.
public struct ChannelGroupSummary: Decodable, FetchableRecord, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var icon: Data?
    public var position: Int
    public var channelCount: Int
    public var unreadCount: Int
    public var mentionCount: Int

    public var initials: String {
        ChannelGroupRecord(id: id, name: name, position: position).initials
    }
}

extension ZuluStore {

    /// An unread belongs to the group its row sits in: a promoted topic's own group,
    /// otherwise its channel's.
    static func unreadIsFiled(in group: String) -> String {
        """
        ((\(TopicMuting.unreadIsNotPromoted)
          AND u.channelID IN (SELECT channelID FROM channelGroupMember m WHERE m.groupID = \(group)))
         OR EXISTS (SELECT 1 FROM promotedTopic pt
                     WHERE pt.channelID = u.channelID AND pt.topic = u.topic AND pt.groupID = \(group)))
        """
    }

    public func observeGroups() -> ValueObservation<ValueReducers.Fetch<[ChannelGroupSummary]>> {
        ValueObservation.tracking { db in
            try ChannelGroupSummary.fetchAll(db, sql: """
                SELECT g.id, g.name, g.icon, g.position,
                       (SELECT COUNT(*) FROM channelGroupMember m WHERE m.groupID = g.id) AS channelCount,
                       (SELECT COUNT(*) FROM unread u
                         JOIN channel hc ON hc.id = u.channelID
                         -- A hidden channel keeps its mentions but stops contributing
                         -- an unread dot, or hiding a noisy channel would leave a dot
                         -- that can never be cleared.
                         WHERE hc.hidden = 0
                           AND \(TopicMuting.unreadIsVisible)
                           AND \(Self.unreadIsFiled(in: "g.id"))) AS unreadCount,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.isMention = 1
                           AND \(Self.unreadIsFiled(in: "g.id"))) AS mentionCount
                  FROM channelGroup g
                 ORDER BY g.position, g.name COLLATE NOCASE
                """)
        }
    }

    /// Channels in one group, or — passing `nil` — the ones no group has claimed, so a
    /// channel is never invisible just because it has not been filed yet.
    public func observeChannels(inGroup groupID: String?)
        -> ValueObservation<ValueReducers.Fetch<[ChannelSummary]>>
    {
        let (membership, arguments) = Self.membership(inGroup: groupID)
        return ValueObservation.tracking { db in
            try ChannelSummary.fetchAll(db, sql: """
                SELECT \(Self.sidebarRowColumns)
                  FROM channel c
                 WHERE \(membership)
                   AND \(ChannelVisibility.clause)
                 ORDER BY c.pinned DESC, c.position IS NULL, c.position, c.name COLLATE NOCASE
                """, arguments: arguments)
        }
    }

    /// Hidden channels in a group that have a mention waiting. A hidden channel keeps
    /// counting its mentions on the rail, so the row that answers that count has to be
    /// somewhere to open; it leaves again once the mention is read.
    public func observeMentionedHiddenChannels(inGroup groupID: String?)
        -> ValueObservation<ValueReducers.Fetch<[ChannelSummary]>>
    {
        let (membership, arguments) = Self.membership(inGroup: groupID)
        return ValueObservation.tracking { db in
            try ChannelSummary.fetchAll(db, sql: """
                SELECT * FROM (
                    SELECT \(Self.sidebarRowColumns)
                      FROM channel c
                     WHERE \(membership)
                       AND c.hidden = 1
                )
                 WHERE mentionCount > 0
                 ORDER BY name COLLATE NOCASE
                """, arguments: arguments)
        }
    }

    private static func membership(inGroup groupID: String?) -> (String, StatementArguments) {
        let membership = groupID == nil
            ? "c.id NOT IN (SELECT channelID FROM channelGroupMember)"
            : "c.id IN (SELECT channelID FROM channelGroupMember WHERE groupID = ?)"
        return (membership, groupID.map { [$0] } ?? [])
    }

    /// A sidebar row's columns, aliased as `c`. Unreads in promoted topics belong to the
    /// promoted row and are left out here.
    static let sidebarRowColumns = """
        c.id, COALESCE(c.alias, c.name) AS name, c.isRestricted, c.isMuted, c.pinned,
        COALESCE(c.modeOverride, c.detectedForum) AS isForum,
        (SELECT COUNT(*) FROM topic t WHERE t.channelID = c.id) AS topicCount,
        (SELECT COUNT(*) FROM unread u
          WHERE u.channelID = c.id AND \(TopicMuting.unreadIsVisible)
            AND \(TopicMuting.unreadIsNotPromoted)) AS unreadCount,
        (SELECT COUNT(*) FROM unread u
          WHERE u.channelID = c.id AND \(TopicMuting.unreadIsVisible)
            AND \(TopicMuting.unreadIsNotPromoted)
            AND \(GeneralChat.unreadIsGeneralChat)) AS generalChatUnreadCount,
        (SELECT COUNT(*) FROM unread u
          WHERE u.channelID = c.id AND u.isMention = 1
            AND \(TopicMuting.unreadIsNotPromoted)) AS mentionCount,
        (SELECT COUNT(*) FROM unread u
          WHERE u.channelID = c.id AND u.isMention = 1
            AND \(TopicMuting.unreadIsNotPromoted)
            AND \(GeneralChat.unreadIsGeneralChat)) AS generalChatMentionCount,
        c.position
        """

    public func groups() throws -> [ChannelGroupRecord] {
        try writer.read { db in
            try ChannelGroupRecord.order(Column("position")).fetchAll(db)
        }
    }

    public func channelIDs(inGroup id: String) throws -> [Int] {
        try writer.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT channelID FROM channelGroupMember WHERE groupID = ? ORDER BY position",
                arguments: [id]
            )
        }
    }

    @discardableResult
    public func createGroup(name: String) throws -> ChannelGroupRecord {
        try writer.write { db in
            let next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM channelGroup") ?? 0
            let group = ChannelGroupRecord(name: name, position: next)
            try group.insert(db)
            return group
        }
    }

    public func updateGroup(id: String, name: String? = nil, icon: Data?? = nil) throws {
        try writer.write { db in
            guard var group = try ChannelGroupRecord.fetchOne(db, key: id) else { return }
            if let name { group.name = name }
            if let icon { group.icon = icon }
            try group.update(db)
        }
    }

    public func deleteGroup(id: String) throws {
        try writer.write { db in
            try ChannelGroupMemberRecord.filter(Column("groupID") == id).deleteAll(db)
            try ChannelGroupRecord.filter(Column("id") == id).deleteAll(db)
        }
    }

    public func reorderGroups(ids: [String]) throws {
        try writer.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE channelGroup SET position = ? WHERE id = ?", arguments: [index, id]
                )
            }
        }
    }

    /// A channel belongs to at most one group, so filing it into a new one removes it from
    /// wherever it was. Two groups both claiming a channel would make unread counts lie.
    public func setChannels(_ channelIDs: [Int], inGroup groupID: String) throws {
        try writer.write { db in
            try ChannelGroupMemberRecord.filter(Column("groupID") == groupID).deleteAll(db)
            for (index, channelID) in channelIDs.enumerated() {
                try ChannelGroupMemberRecord
                    .filter(Column("channelID") == channelID)
                    .deleteAll(db)
                try ChannelGroupMemberRecord(
                    groupID: groupID, channelID: channelID, position: index
                ).insert(db)
            }
        }
    }
}
