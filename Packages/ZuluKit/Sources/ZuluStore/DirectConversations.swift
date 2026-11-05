import Foundation
import GRDB
import ZulipAPI

/// A DM conversation and its newest message id. The DM list is read from here rather than
/// from the messages, because the newest few hundred DMs can all be with a few people.
public struct DirectConversationRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "dmConversation"

    public var dmKey: String
    public var maxMessageID: Int

    public init(dmKey: String, maxMessageID: Int) {
        self.dmKey = dmKey
        self.maxMessageID = maxMessageID
    }
}

extension ZuluStore {

    static func registerDirectConversationMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17-dm-conversations") { db in
            try db.create(table: "dmConversation") { t in
                t.primaryKey("dmKey", .text)
                t.column("maxMessageID", .integer).notNull()
            }
            try db.execute(sql: """
                INSERT INTO dmConversation (dmKey, maxMessageID)
                SELECT dmKey, MAX(id) FROM message WHERE dmKey IS NOT NULL GROUP BY dmKey
                """)
        }
    }

    public func saveDirectConversations(_ conversations: [RecentDirectConversation], selfUserID: Int) throws {
        try writer.write { db in
            for conversation in conversations {
                let dmKey = MessageRecord.dmKey(for: conversation.user_ids, selfUserID: selfUserID)
                try db.execute(sql: """
                    INSERT INTO dmConversation (dmKey, maxMessageID) VALUES (?, ?)
                    ON CONFLICT(dmKey) DO UPDATE SET maxMessageID = MAX(
                        excluded.maxMessageID,
                        COALESCE((SELECT MAX(id) FROM message WHERE message.dmKey = excluded.dmKey), 0)
                    )
                    """, arguments: [dmKey, conversation.max_message_id])
            }
        }
    }

    static func noteDirectConversation(_ dmKey: String, messageID: Int, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO dmConversation (dmKey, maxMessageID) VALUES (?, ?)
            ON CONFLICT(dmKey) DO UPDATE SET maxMessageID = MAX(maxMessageID, excluded.maxMessageID)
            """, arguments: [dmKey, messageID])
    }

    /// A conversation whose newest message was deleted falls back to its newest remaining
    /// one. With none fetched it is dropped until the next snapshot lists it again.
    static func forgetDeletedDirectMessages(_ ids: [Int], in db: Database) throws {
        guard !ids.isEmpty else { return }
        let deleted = databaseQuestionMarks(count: ids.count)
        try db.execute(sql: """
            DELETE FROM dmConversation
            WHERE maxMessageID IN (\(deleted))
              AND NOT EXISTS (SELECT 1 FROM message WHERE message.dmKey = dmConversation.dmKey)
            """, arguments: StatementArguments(ids))
        try db.execute(sql: """
            UPDATE dmConversation
            SET maxMessageID = (SELECT MAX(id) FROM message WHERE message.dmKey = dmConversation.dmKey)
            WHERE maxMessageID IN (\(deleted))
            """, arguments: StatementArguments(ids))
    }
}
