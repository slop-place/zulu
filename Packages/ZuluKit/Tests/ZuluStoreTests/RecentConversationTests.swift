import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

/// The Recent view lists topics and direct messages together, newest first, and leaves
/// out what the viewer has muted or hidden.
@MainActor
struct RecentConversationTests {

    private func store() throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        let json = #"""
        [{"stream_id": 7, "name": "engineering"},
         {"stream_id": 8, "name": "noise", "is_muted": true},
         {"stream_id": 9, "name": "secret"}]
        """#
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        try store.setHidden(true, forChannel: 9)
        try store.writer.write { db in
            for (channel, name, maxMessageID) in [(7, "deploys", 10), (7, "lunch", 30), (8, "spam", 40), (9, "plans", 50)] {
                try db.execute(
                    sql: "INSERT INTO topic (channelID, name, maxMessageID) VALUES (?, ?, ?)",
                    arguments: [channel, name, maxMessageID]
                )
            }
            try db.execute(sql: """
                INSERT INTO message (id, channelID, topic, dmKey, senderID, senderName, renderedContent, timestamp)
                VALUES (10, 7, 'deploys', NULL, 2, 'Ana', '<p>shipping</p>', 1000),
                       (20, NULL, NULL, '2', 2, 'Ana', '<p>hi</p>', 2000),
                       (30, 7, 'lunch', NULL, 3, 'Bo', '<p>tacos</p>', 3000)
                """)
            try db.execute(
                sql: "INSERT INTO unread (messageID, channelID, topic, isMention) VALUES (30, 7, 'lunch', 1)"
            )
        }
        return store
    }

    private func recent(_ store: ZuluStore) async throws -> [RecentConversation] {
        for try await rows in store.observeRecentConversations().values(in: store.writer) {
            return rows
        }
        throw CancellationError()
    }

    @Test func newestConversationComesFirstAcrossTopicsAndDMs() async throws {
        let rows = try await recent(try store())
        #expect(rows.map(\.id) == ["c:7/lunch", "d:2", "c:7/deploys"])
        #expect(rows[0].lastSender == "Bo")
        #expect(rows[0].unreadCount == 1)
        #expect(rows[0].mentionCount == 1)
        #expect(rows[1].isDirect)
        #expect(rows[1].lastContent == "<p>hi</p>")
    }

    @Test func mutedAndHiddenChannelsStayOut() async throws {
        let rows = try await recent(try store())
        #expect(!rows.contains { $0.channelID == 8 })
        #expect(!rows.contains { $0.channelID == 9 })
    }

    @Test func aMutedTopicStaysOut() async throws {
        let store = try store()
        try store.setMuted(true, topic: "lunch", inChannel: 7)
        let rows = try await recent(store)
        #expect(!rows.contains { $0.topic == "lunch" })
    }
}
