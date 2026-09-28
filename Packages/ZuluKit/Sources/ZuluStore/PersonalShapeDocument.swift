import Foundation
import GRDB

/// Everything the viewer has arranged for themselves, as one document that can travel
/// between their devices: groups, filing, channel aliases and modes, hiding, order, and
/// promoted topics. Group icons stay on the device that chose them.
public struct PersonalShape: Codable, Equatable, Sendable {

    public struct Group: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var position: Int
        /// A `NotificationLevel` for every channel in the group without its own.
        public var notificationLevel: Int? = nil
    }

    public struct Member: Codable, Equatable, Sendable {
        public var groupID: String
        public var channelID: Int
        public var position: Int
    }

    public struct ChannelPreference: Codable, Equatable, Sendable {
        public var channelID: Int
        public var alias: String?
        public var hidden: Bool
        public var modeOverride: Int?
        public var position: Int?
        /// A `NotificationLevel` chosen for this channel. Nil follows its group.
        public var notificationOverride: Int? = nil
    }

    public struct Promotion: Codable, Equatable, Sendable {
        public var channelID: Int
        public var topic: String
        public var groupID: String?
        public var position: Int
        public var alias: String?
    }

    public var groups: [Group] = []
    public var members: [Member] = []
    public var channels: [ChannelPreference] = []
    public var promotions: [Promotion] = []

    public init(
        groups: [Group] = [], members: [Member] = [],
        channels: [ChannelPreference] = [], promotions: [Promotion] = []
    ) {
        self.groups = groups
        self.members = members
        self.channels = channels
        self.promotions = promotions
    }

    /// Every part is optional, so a document written before a part existed still reads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = try container.decodeIfPresent([Group].self, forKey: .groups) ?? []
        members = try container.decodeIfPresent([Member].self, forKey: .members) ?? []
        channels = try container.decodeIfPresent([ChannelPreference].self, forKey: .channels) ?? []
        promotions = try container.decodeIfPresent([Promotion].self, forKey: .promotions) ?? []
    }

    public var isEmpty: Bool {
        groups.isEmpty && members.isEmpty && channels.isEmpty && promotions.isEmpty
    }

    /// One order for every copy, so two documents holding the same arrangement compare equal
    /// however they were assembled.
    public func normalized() -> PersonalShape {
        PersonalShape(
            groups: groups.sorted { $0.id < $1.id },
            members: members.sorted { ($0.channelID, $0.groupID) < ($1.channelID, $1.groupID) },
            channels: channels.sorted { $0.channelID < $1.channelID },
            promotions: promotions.sorted { ($0.channelID, $0.topic) < ($1.channelID, $1.topic) }
        )
    }
}

/// This device's arrangement, plus which channels it actually holds. A device only has an
/// opinion about channels it knows; everything else in a remote document belongs to some
/// other device and is passed along untouched.
public struct LocalPersonalShape: Equatable, Sendable {
    public var shape: PersonalShape
    public var knownChannelIDs: Set<Int>

    public init(shape: PersonalShape, knownChannelIDs: Set<Int>) {
        self.shape = shape
        self.knownChannelIDs = knownChannelIDs
    }

    public func document(carryingOver remote: PersonalShape?) -> PersonalShape {
        var document = shape
        if let remote {
            let groupIDs = Set(shape.groups.map(\.id))
            document.channels += remote.channels.filter { !knownChannelIDs.contains($0.channelID) }
            document.promotions += remote.promotions
                .filter { !knownChannelIDs.contains($0.channelID) }
                .map { promotion in
                    var promotion = promotion
                    // Its group was deleted here, which unfiles it just as it would have
                    // been had this device held it at the time.
                    promotion.groupID = promotion.groupID.flatMap { groupIDs.contains($0) ? $0 : nil }
                    return promotion
                }
        }
        return document.normalized()
    }
}

extension ZuluStore {

    public func localPersonalShape() throws -> LocalPersonalShape {
        try writer.read(Self.localPersonalShape)
    }

    public func observeLocalPersonalShape() -> ValueObservation<ValueReducers.Fetch<LocalPersonalShape>> {
        ValueObservation.tracking(Self.localPersonalShape)
    }

    static func localPersonalShape(_ db: Database) throws -> LocalPersonalShape {
        let groups = try Row.fetchAll(
            db, sql: "SELECT id, name, position, notificationLevel FROM channelGroup"
        ).map {
            PersonalShape.Group(
                id: $0["id"], name: $0["name"], position: $0["position"],
                notificationLevel: $0["notificationLevel"]
            )
        }
        let members = try ChannelGroupMemberRecord.fetchAll(db).map {
            PersonalShape.Member(groupID: $0.groupID, channelID: $0.channelID, position: $0.position)
        }
        let channels = try Row.fetchAll(db, sql: """
            SELECT id, alias, hidden, modeOverride, position, notificationOverride FROM channel
             WHERE alias IS NOT NULL OR hidden = 1 OR modeOverride IS NOT NULL OR position IS NOT NULL
                OR notificationOverride IS NOT NULL
            """).map {
            PersonalShape.ChannelPreference(
                channelID: $0["id"], alias: $0["alias"], hidden: $0["hidden"],
                modeOverride: $0["modeOverride"], position: $0["position"],
                notificationOverride: $0["notificationOverride"]
            )
        }
        let promotions = try Row.fetchAll(
            db, sql: "SELECT channelID, topic, groupID, position, alias FROM promotedTopic"
        ).map {
            PersonalShape.Promotion(
                channelID: $0["channelID"], topic: $0["topic"], groupID: $0["groupID"],
                position: $0["position"], alias: $0["alias"]
            )
        }
        let known = try Set(Int.fetchAll(db, sql: "SELECT id FROM channel"))

        return LocalPersonalShape(
            shape: PersonalShape(
                groups: groups, members: members, channels: channels, promotions: promotions
            ).normalized(),
            knownChannelIDs: known
        )
    }

    /// Makes this device match the document. Channels this device does not hold yet are
    /// skipped; applying the same document again once they arrive fills them in.
    public func apply(_ shape: PersonalShape) throws {
        try writer.write { db in
            let groupIDs = shape.groups.map(\.id)
            try ChannelGroupRecord.filter(!groupIDs.contains(Column("id"))).deleteAll(db)
            for group in shape.groups {
                // Upserted rather than replaced, so the icon this device chose survives.
                try db.execute(
                    sql: """
                        INSERT INTO channelGroup (id, name, position, notificationLevel) VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            name = excluded.name,
                            position = excluded.position,
                            notificationLevel = excluded.notificationLevel
                        """,
                    arguments: [group.id, group.name, group.position, group.notificationLevel]
                )
            }

            try ChannelGroupMemberRecord.deleteAll(db)
            for member in shape.members where groupIDs.contains(member.groupID) {
                try ChannelGroupMemberRecord(
                    groupID: member.groupID, channelID: member.channelID, position: member.position
                ).insert(db)
            }

            try db.execute(sql: """
                UPDATE channel SET alias = NULL, hidden = 0, modeOverride = NULL, position = NULL,
                                   notificationOverride = NULL
                """)
            for preference in shape.channels {
                try db.execute(
                    sql: """
                        UPDATE channel SET alias = ?, hidden = ?, modeOverride = ?, position = ?,
                                           notificationOverride = ?
                         WHERE id = ?
                        """,
                    arguments: [
                        preference.alias, preference.hidden, preference.modeOverride,
                        preference.position, preference.notificationOverride, preference.channelID,
                    ]
                )
            }

            try PromotedTopicRecord.deleteAll(db)
            let known = try Set(Int.fetchAll(db, sql: "SELECT id FROM channel"))
            for promotion in shape.promotions where known.contains(promotion.channelID) {
                try db.execute(
                    sql: """
                        INSERT INTO promotedTopic (channelID, topic, groupID, position, alias)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        promotion.channelID, promotion.topic,
                        promotion.groupID.flatMap { groupIDs.contains($0) ? $0 : nil },
                        promotion.position, promotion.alias,
                    ]
                )
            }
        }
    }
}
