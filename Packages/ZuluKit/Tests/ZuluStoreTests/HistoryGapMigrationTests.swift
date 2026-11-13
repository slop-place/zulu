import GRDB
import Testing
@testable import ZuluStore

/// Upgrading past the migration that drops stored history must not strand the rows that
/// hang off each message, or the store refuses to open and the app signs out.
struct HistoryGapMigrationTests {
    private static let lastMigrationBeforeGaps = "v18-conversation-tips"
    private static let messageID = 520_750

    @Test func upgradesAStoreHoldingReactionsAndPolls() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let database = try DatabaseQueue(configuration: configuration)
        try ZuluStore.migrator.migrate(database, upTo: Self.lastMigrationBeforeGaps)
        try database.write { db in
            try MessageRecord(
                id: Self.messageID, channelID: 1, topic: "memes", senderID: 2, senderName: "Ana",
                renderedContent: "<p>a</p>", timestamp: 0
            ).save(db)
            try ReactionRecord(
                messageID: Self.messageID, emojiName: "kekw", emojiCode: "28",
                reactionType: "realm_emoji", userID: 2323
            ).save(db)
            try SubmessageRecord(
                id: 1, messageID: Self.messageID, senderID: 2, msgType: "widget", content: "{}"
            ).save(db)
        }

        try ZuluStore.migrator.migrate(database)

        let (reactions, submessages) = try database.read { db in
            (try ReactionRecord.fetchCount(db), try SubmessageRecord.fetchCount(db))
        }
        #expect(reactions == 0)
        #expect(submessages == 0)
    }
}
