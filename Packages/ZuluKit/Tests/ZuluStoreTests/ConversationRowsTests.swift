import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

@MainActor
struct ConversationRowsTests {

    private func store() throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        let json = #"[{"stream_id": 7, "name": "engineering"}]"#
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        try store.writer.write { db in
            try Self.message(1, topic: "deploys").insert(db)
            try Self.message(2, topic: "lunch").insert(db)
            try ReactionRecord(
                messageID: 1, emojiName: "+1", emojiCode: "1f44d", reactionType: "unicode_emoji", userID: 5
            ).insert(db)
            try ReactionRecord(
                messageID: 2, emojiName: "heart", emojiCode: "2764", reactionType: "unicode_emoji", userID: 5
            ).insert(db)
        }
        return store
    }

    private static func message(_ id: Int, topic: String) -> MessageRecord {
        MessageRecord(
            id: id, channelID: 7, topic: topic, dmKey: nil, senderID: 5, senderName: "Ada",
            senderAvatar: nil, renderedContent: "<p>hi</p>", timestamp: id, isRead: true,
            isMentioned: false, editedAt: nil, isWidget: false
        )
    }

    private func firstValue<T>(_ stream: AsyncValueObservation<T>) async throws -> T? {
        for try await value in stream { return value }
        return nil
    }

    @Test func aConversationCarriesOnlyItsOwnReactions() async throws {
        let store = try store()

        let rows = try await firstValue(
            store.observeConversation(channelID: 7, topic: "deploys").values(in: store.writer)
        )

        #expect(rows?.messages.map(\.id) == [1])
        #expect(rows?.reactions.map(\.messageID) == [1])
    }

    @Test func aForumRowKnowsWhenItsGeneralChatHasARowOfItsOwn() async throws {
        let store = try store()
        try await store.writer.write { db in
            try TopicRecord(channelID: 7, name: "general chat", maxMessageID: 3).insert(db)
            // Promoting a channel's only topic absorbs the channel's row.
            try TopicRecord(channelID: 7, name: "deploys", maxMessageID: 1).insert(db)
        }
        try store.promote(topic: "general chat", inChannel: 7)

        let rows = try await firstValue(store.observeSidebar(in: .ungrouped).values(in: store.writer))
        let channel = try #require(rows?.channels.first)

        #expect(channel.generalChatName == "general chat")
        #expect(channel.generalChatIsPromoted == true)
        #expect(rows?.promoted.map(\.topic) == ["general chat"])
    }

    @Test func aChannelWithoutAGeneralChatStillNamesTheOneItWouldOpen() async throws {
        let store = try store()

        let rows = try await firstValue(store.observeSidebar(in: .ungrouped).values(in: store.writer))
        let channel = try #require(rows?.channels.first)

        #expect(channel.generalChatTopic == nil)
        #expect(channel.generalChatName == "general chat")
        #expect(channel.generalChatIsPromoted == false)
    }
}
