import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

/// A conversation opens on its newest page of stored messages, reaching back to where it
/// opens, rather than on everything stored: every row it shows is measured before it draws.
@MainActor
struct ConversationWindowTests {
    private static let firstID = 1000
    private static let stored = 200
    private static let newest = 50
    private static let context = 5
    private static var lastID: Int { firstID + stored - 1 }

    private func store() throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        let json = #"[{"stream_id": 7, "name": "engineering"}]"#
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        try store.writer.write { db in
            for id in Self.firstID...Self.lastID {
                try db.execute(sql: """
                    INSERT INTO message (id, channelID, topic, dmKey, senderID, senderName, renderedContent, timestamp, isRead)
                    VALUES (?, 7, 'deploys', NULL, 2, 'Ana', '<p>a</p>', ?, 1)
                    """, arguments: [id, id])
                try db.execute(sql: """
                    INSERT INTO reaction (messageID, emojiName, emojiCode, reactionType, userID)
                    VALUES (?, 'tada', '1f389', 'unicode_emoji', 2)
                    """, arguments: [id])
            }
        }
        return store
    }

    private func markUnread(_ store: ZuluStore, _ id: Int) throws {
        try store.writer.write { db in
            try db.execute(sql: "UPDATE message SET isRead = 0 WHERE id = ?", arguments: [id])
        }
    }

    private func windowStart(_ store: ZuluStore, openingAt target: Int? = nil) throws -> Int? {
        try store.windowStart(
            channelID: 7, topic: "deploys", openingAt: target, newest: Self.newest, context: Self.context
        )
    }

    @Test func nothingUnreadOpensOnTheNewestPage() throws {
        #expect(try windowStart(store()) == Self.lastID - Self.newest + 1)
    }

    @Test func reachesBackToTheFirstUnread() throws {
        let store = try store()
        let firstUnread = Self.firstID + 20
        try markUnread(store, firstUnread)
        try markUnread(store, Self.lastID)
        #expect(try windowStart(store) == firstUnread - Self.context)
    }

    @Test func reachesBackToTheMessageAskedFor() throws {
        let store = try store()
        try markUnread(store, Self.firstID + 10)
        let target = Self.firstID + 100
        #expect(try windowStart(store, openingAt: target) == target - Self.context)
    }

    @Test func nothingStoredHasNoWindow() throws {
        let store = try store()
        #expect(try store.windowStart(dmKey: "2", openingAt: nil, newest: Self.newest, context: Self.context) == nil)
    }

    @Test func pagesBackThroughWhatIsStored() throws {
        let store = try store()
        let page = 50
        #expect(try store.pageStart(channelID: 7, topic: "deploys", before: Self.firstID + 120, count: page)
            == Self.firstID + 70)
        #expect(try store.pageStart(channelID: 7, topic: "deploys", before: Self.firstID + 10, count: page)
            == Self.firstID)
        #expect(try store.pageStart(channelID: 7, topic: "deploys", before: Self.firstID, count: page) == nil)
    }

    @Test func observesOnlyTheWindow() throws {
        let store = try store()
        let start = Self.lastID - Self.newest + 1
        var rows: ConversationRows?
        let observation = store.observeConversation(channelID: 7, topic: "deploys", from: start)
            .start(in: store.writer, scheduling: .immediate, onError: { _ in }) { rows = $0 }
        defer { observation.cancel() }
        #expect(rows?.messages.map(\.id) == Array(start...Self.lastID))
        #expect(Set(rows?.reactions.map(\.messageID) ?? []) == Set(start...Self.lastID))
    }
}
