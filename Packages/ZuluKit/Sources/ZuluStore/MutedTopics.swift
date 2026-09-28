import Foundation
import GRDB
import ZulipAPI

/// A topic the viewer muted on the server. Zulip owns this, so the table only mirrors
/// `user_topics` and is replaced wholesale on every register.
public struct MutedTopicRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "mutedTopic"

    public var channelID: Int
    public var topic: String

    public init(channelID: Int, topic: String) {
        self.channelID = channelID
        self.topic = topic
    }
}

/// SQL fragments that keep a muted topic out of lists and unread counts. Mentions are
/// counted regardless, because Zulip still delivers a personal mention from a muted topic.
enum TopicMuting {
    static func isNotMuted(channel: String, topic: String) -> String {
        "NOT EXISTS (SELECT 1 FROM mutedTopic mt WHERE mt.channelID = \(channel) AND mt.topic = \(topic))"
    }

    static let unreadIsVisible = isNotMuted(channel: "u.channelID", topic: "u.topic")

    /// A promoted topic reports its unreads on its own sidebar row, so its channel does
    /// not light up for them as well.
    static let unreadIsNotPromoted = """
        NOT EXISTS (SELECT 1 FROM promotedTopic pt WHERE pt.channelID = u.channelID AND pt.topic = u.topic)
        """
}

extension ZuluStore {

    static func registerMutedTopicMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v11-muted-topics") { db in
            // No foreign key to `channel`: the server lists mutes in channels the viewer
            // has since left, and they come back into force on resubscribing.
            try db.create(table: "mutedTopic") { t in
                t.column("channelID", .integer).notNull()
                // Zulip treats topic names case-insensitively when matching a mute.
                t.column("topic", .text).notNull().collate(.nocase)
                t.primaryKey(["channelID", "topic"])
            }
        }
    }

    public func replaceMutedTopics(_ userTopics: [UserTopic]) throws {
        try writer.write { db in
            try MutedTopicRecord.deleteAll(db)
            try TopicPolicyRecord.deleteAll(db)
            for userTopic in userTopics {
                guard let policy = userTopic.policy else { continue }
                try Self.setTopicPolicy(policy, topic: userTopic.topic_name, inChannel: userTopic.stream_id, db)
                if policy == .muted {
                    try MutedTopicRecord(channelID: userTopic.stream_id, topic: userTopic.topic_name).save(db)
                }
            }
        }
    }

    public func apply(_ userTopic: UserTopic) throws {
        try setTopicPolicy(userTopic.policy ?? .inherit, topic: userTopic.topic_name, inChannel: userTopic.stream_id)
    }

    public func setMuted(_ muted: Bool, topic: String, inChannel channelID: Int) throws {
        try writer.write { db in
            if muted {
                try MutedTopicRecord(channelID: channelID, topic: topic).save(db)
            } else {
                try MutedTopicRecord
                    .filter(Column("channelID") == channelID && Column("topic") == topic)
                    .deleteAll(db)
            }
        }
    }

    public func isMuted(topic: String, inChannel channelID: Int) throws -> Bool {
        try writer.read { db in
            try MutedTopicRecord
                .filter(Column("channelID") == channelID && Column("topic") == topic)
                .fetchCount(db) > 0
        }
    }

    public func observeMutedTopics(inChannel channelID: Int)
        -> ValueObservation<ValueReducers.Fetch<[MutedTopicRecord]>>
    {
        ValueObservation.tracking { db in
            try MutedTopicRecord
                .filter(Column("channelID") == channelID)
                .order(Column("topic"))
                .fetchAll(db)
        }
    }
}
