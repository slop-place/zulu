import Foundation
import GRDB
import ZulipAPI

/// The newest message known in each conversation, for the rows that list conversations.
///
/// Kept apart from the message history: history is stored as it is read, without gaps,
/// while a conversation's newest message is often learned on its own. Stored with the
/// history, it would sit after a gap nothing ever fills.
extension ZuluStore {

    static func registerConversationTipMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v18-conversation-tips") { db in
            try db.create(table: "conversationTip") { t in
                t.column("channelID", .integer)
                t.column("topic", .text)
                t.column("dmKey", .text)
                t.column("messageID", .integer).notNull()
                t.column("senderID", .integer).notNull()
                t.column("senderName", .text).notNull()
                t.column("renderedContent", .text).notNull()
                t.column("timestamp", .integer).notNull()
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX conversationTip_topic ON conversationTip(channelID, topic)
                    WHERE dmKey IS NULL;
                CREATE UNIQUE INDEX conversationTip_dm ON conversationTip(dmKey)
                    WHERE dmKey IS NOT NULL;
                CREATE INDEX conversationTip_message ON conversationTip(messageID);
                """)
            try fillMissingTipsFromHistory(in: db)
        }
    }

    /// A tip behind the conversation's newest id is left out rather than shown: its time
    /// would contradict the order the rows are sorted in.
    static let topicTipJoin = """
        LEFT JOIN conversationTip tip
               ON tip.dmKey IS NULL AND tip.channelID = t.channelID AND tip.topic = t.name
              AND tip.messageID >= t.maxMessageID
        """

    static let dmTipJoin = """
        LEFT JOIN conversationTip tip
               ON tip.dmKey = d.dmKey AND tip.messageID >= d.maxMessageID
        """

    /// Newest messages fetched only to show what each conversation last said. They are
    /// not saved as history.
    public func saveTips(_ messages: [ZulipMessage], selfUserID: Int) throws {
        try writer.write { db in
            for message in messages {
                try Self.noteNewest(MessageRecord(from: message, selfUserID: selfUserID), in: db)
            }
        }
    }

    /// Moves the conversation's newest id and tip forward to `message` if it is newer.
    /// The same message again replaces the tip, so a refetch carries its edits.
    static func noteNewest(_ message: MessageRecord, in db: Database) throws {
        let tip: StatementArguments = [
            message.channelID, message.topic, message.dmKey, message.id,
            message.senderID, message.senderName, message.renderedContent, message.timestamp,
        ]
        if let channelID = message.channelID, let topic = message.topic {
            let existing = try TopicRecord
                .filter(Column("channelID") == channelID && Column("name") == topic)
                .fetchOne(db)
            if existing == nil || existing!.maxMessageID < message.id {
                try TopicRecord(channelID: channelID, name: topic, maxMessageID: message.id).save(db)
            }
            try db.execute(sql: tipUpsert(conflict: "(channelID, topic) WHERE dmKey IS NULL"), arguments: tip)
        } else if let dmKey = message.dmKey {
            try noteDirectConversation(dmKey, messageID: message.id, in: db)
            try db.execute(sql: tipUpsert(conflict: "(dmKey) WHERE dmKey IS NOT NULL"), arguments: tip)
        }
    }

    private static func tipUpsert(conflict target: String) -> String {
        """
        INSERT INTO conversationTip
            (channelID, topic, dmKey, messageID, senderID, senderName, renderedContent, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT\(target) DO UPDATE SET
            messageID = excluded.messageID,
            senderID = excluded.senderID,
            senderName = excluded.senderName,
            renderedContent = excluded.renderedContent,
            timestamp = excluded.timestamp
        WHERE excluded.messageID >= conversationTip.messageID
        """
    }

    static func updateTipContent(messageID: Int, html: String, in db: Database) throws {
        try db.execute(
            sql: "UPDATE conversationTip SET renderedContent = ? WHERE messageID = ?",
            arguments: [html, messageID]
        )
    }

    /// A conversation whose tip was deleted falls back to the newest message in its history.
    static func forgetDeletedTips(_ ids: [Int], in db: Database) throws {
        guard !ids.isEmpty else { return }
        try db.execute(
            sql: "DELETE FROM conversationTip WHERE messageID IN (\(databaseQuestionMarks(count: ids.count)))",
            arguments: StatementArguments(ids)
        )
        try fillMissingTipsFromHistory(in: db)
    }

    private static func fillMissingTipsFromHistory(in db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO conversationTip
                (channelID, topic, dmKey, messageID, senderID, senderName, renderedContent, timestamp)
            SELECT channelID, topic, dmKey, id, senderID, senderName, renderedContent, timestamp
              FROM message
             WHERE id IN (SELECT MAX(id) FROM message GROUP BY channelID, topic, dmKey)
            """)
    }
}
