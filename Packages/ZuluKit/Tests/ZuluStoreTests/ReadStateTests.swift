import Foundation
import GRDB
import Testing
@testable import ZuluStore

struct ReadStateTests {

    @Test func markingEverythingReadClearsEveryConversation() throws {
        let store = try ZuluStore(url: nil)
        try store.writer.write { db in
            try db.execute(sql: "INSERT INTO unread (messageID, channelID, topic, isMention) VALUES (1, 7, 'lunch', 0)")
            try db.execute(sql: "INSERT INTO unread (messageID, dmKey, isMention) VALUES (2, '8,10', 1)")
        }

        try store.markEverythingRead()

        #expect(try store.unreadIDs().isEmpty)
    }
}
