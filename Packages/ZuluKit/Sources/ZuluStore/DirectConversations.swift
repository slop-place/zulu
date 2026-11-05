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
                try Self.noteDirectConversation(
                    MessageRecord.dmKey(for: conversation.user_ids, selfUserID: selfUserID),
                    messageID: conversation.max_message_id,
                    in: db
                )
            }
        }
    }

    static func noteDirectConversation(_ dmKey: String, messageID: Int, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO dmConversation (dmKey, maxMessageID) VALUES (?, ?)
            ON CONFLICT(dmKey) DO UPDATE SET maxMessageID = MAX(maxMessageID, excluded.maxMessageID)
            """, arguments: [dmKey, messageID])
    }
}
