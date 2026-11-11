import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

/// A row listing a conversation says what was last said in it, and never something
/// older than the place the row is sorted at.
struct ConversationTipTests {

    private let me = 1
    private let channel = 7
    private let topic = "deploys"

    private func store() throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        let json = #"[{"stream_id": 7, "name": "engineering"}]"#
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        return store
    }

    private func message(_ id: Int, from sender: String, saying text: String) throws -> ZulipMessage {
        let json = """
            {"id": \(id), "sender_id": 2, "sender_full_name": "\(sender)", "sender_email": "",
             "type": "stream", "stream_id": \(channel), "subject": "\(topic)",
             "content": "<p>\(text)</p>", "content_type": "text/html",
             "timestamp": \(id), "is_me_message": false, "reactions": [], "flags": [],
             "display_recipient": "engineering"}
            """
        return try JSONDecoder().decode(ZulipMessage.self, from: Data(json.utf8))
    }

    /// What the server's topic list says about the topic.
    private func topicListing(newest maxID: Int) throws -> ChannelTopic {
        let json = #"{"name": "\#(topic)", "max_id": \#(maxID)}"#
        return try JSONDecoder().decode(ChannelTopic.self, from: Data(json.utf8))
    }

    private func topicRow(_ store: ZuluStore) async throws -> TopicSummary? {
        for try await rows in store.observeTopics(inChannel: channel).values(in: store.writer) {
            return rows.first
        }
        return nil
    }

    private func recentRow(_ store: ZuluStore) async throws -> RecentConversation? {
        for try await rows in store.observeRecentConversations().values(in: store.writer) {
            return rows.first
        }
        return nil
    }

    private func history(_ store: ZuluStore) async throws -> [Int] {
        for try await rows in store.observeConversation(channelID: channel, topic: topic).values(in: store.writer) {
            return rows.messages.map(\.id)
        }
        return []
    }

    @Test func aRowBehindTheServersNewestShowsNothingRatherThanSomethingOld() async throws {
        let store = try store()
        try store.save(messages: [message(10, from: "Ana", saying: "old")], selfUserID: me)
        try store.saveTopics([try topicListing(newest: 50)], inChannel: channel)

        let row = try #require(try await topicRow(store))
        #expect(row.maxMessageID == 50)
        #expect(row.lastSender == nil)
        #expect(row.lastTimestamp == nil)
    }

    @Test func aFetchedNewestMessageFillsTheRowWithoutJoiningTheHistory() async throws {
        let store = try store()
        try store.save(messages: [message(10, from: "Ana", saying: "old")], selfUserID: me)
        try store.saveTopics([try topicListing(newest: 50)], inChannel: channel)

        try store.saveTips([message(50, from: "Bo", saying: "new")], selfUserID: me)

        let row = try #require(try await recentRow(store))
        #expect(row.lastSender == "Bo")
        #expect(row.lastContent == "<p>new</p>")
        #expect(row.lastTimestamp == 50)
        #expect(try await history(store) == [10])
    }

    @Test func aTipNewerThanTheTopicListMovesTheRowUp() async throws {
        let store = try store()
        try store.saveTopics([try topicListing(newest: 50)], inChannel: channel)

        try store.saveTips([message(80, from: "Bo", saying: "newer")], selfUserID: me)

        let row = try #require(try await topicRow(store))
        #expect(row.maxMessageID == 80)
        #expect(row.lastSender == "Bo")
    }

    @Test func anEditReachesTheRow() async throws {
        let store = try store()
        try store.saveTips([message(50, from: "Bo", saying: "typo")], selfUserID: me)

        try store.updateRenderedContent(id: 50, html: "<p>fixed</p>")

        #expect(try await recentRow(store)?.lastContent == "<p>fixed</p>")
    }

    @Test func deletingTheNewestFallsBackToTheHistory() async throws {
        let store = try store()
        try store.save(
            messages: [message(10, from: "Ana", saying: "first"), message(20, from: "Bo", saying: "second")],
            selfUserID: me
        )

        try store.deleteMessages(ids: [20])
        try store.saveTopics([try topicListing(newest: 10)], inChannel: channel)

        let row = try #require(try await recentRow(store))
        #expect(row.lastSender == "Ana")
        #expect(row.lastContent == "<p>first</p>")
    }
}
