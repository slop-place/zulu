import Foundation
import Testing
@testable import ZuluStore

/// The quick-reaction row is the viewer's own habits, kept on this device, leaning
/// hard towards what they reached for lately.
@MainActor
struct ReactionHistoryTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func react(_ store: ZuluStore, _ code: String, name: String? = nil, daysAgo: Double, times: Int = 1) throws {
        for _ in 0..<times {
            try store.recordReaction(
                emojiName: name ?? code, emojiCode: code, reactionType: "unicode_emoji",
                at: now.addingTimeInterval(-daysAgo * day)
            )
        }
    }

    @Test func oneUseTodayOutranksFiveUsesLastMonth() throws {
        let store = try ZuluStore(url: nil)
        try react(store, "old", daysAgo: 30, times: 5)
        try react(store, "new", daysAgo: 0)
        #expect(try store.recentReactions(limit: 5, now: now).map(\.emojiCode) == ["new", "old"])
    }

    @Test func repeatedUseStillCountsAmongRecentOnes() throws {
        let store = try ZuluStore(url: nil)
        try react(store, "once", daysAgo: 0)
        try react(store, "often", daysAgo: 0.5, times: 4)
        let recent = try store.recentReactions(limit: 5, now: now)
        #expect(recent.map(\.emojiCode) == ["often", "once"])
        #expect(recent[0].uses == 4)
    }

    @Test func theNameFollowsTheLatestUse() throws {
        let store = try ZuluStore(url: nil)
        try react(store, "1f44d", name: "+1", daysAgo: 1)
        try react(store, "1f44d", name: "thumbs_up", daysAgo: 0)
        #expect(try store.recentReactions(limit: 5, now: now).first?.emojiName == "thumbs_up")
    }

    @Test func ownReactionsOnStoredMessagesAreNewestFirst() throws {
        let store = try ZuluStore(url: nil)
        try store.writer.write { db in
            for id in [1, 2, 3] {
                try db.execute(sql: """
                    INSERT INTO message (id, channelID, topic, senderID, senderName, renderedContent, timestamp)
                    VALUES (?, 7, 't', 2, 'Ana', '<p>x</p>', 1000)
                    """, arguments: [id])
            }
            try db.execute(sql: """
                INSERT INTO reaction (messageID, emojiName, emojiCode, reactionType, userID) VALUES
                (1, 'heart', '2764', 'unicode_emoji', 9),
                (2, '+1', '1f44d', 'unicode_emoji', 9),
                (3, 'tada', '1f389', 'unicode_emoji', 4)
                """)
        }
        #expect(try store.ownReactions(by: 9, limit: 5).map(\.emojiCode) == ["1f44d", "2764"])
    }
}
