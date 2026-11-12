import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

/// A conversation's stored history is one run back from its newest message. Whatever is
/// stored below a stretch that does not reach it stays out of sight until a fetch joins
/// the two, so scrolling back never jumps over messages that were never fetched.
@MainActor
struct HistoryGapTests {
    private static let channel = 7
    private static let topic = "deploys"
    private static let page = 50
    private static let liveQueue = "queue-now"
    private static let earlierQueue = "queue-before"
    private let conversation = StoredConversation.topic(channelID: channel, name: topic)

    private func messageJSON(_ id: Int, inTopic topic: String) -> String {
        """
        {"id": \(id), "sender_id": 2, "sender_full_name": "Ana", "sender_email": "",
         "type": "stream", "stream_id": \(Self.channel), "subject": "\(topic)",
         "content": "<p>a</p>", "content_type": "text/html",
         "timestamp": \(id), "is_me_message": false, "reactions": [], "flags": ["read"],
         "display_recipient": "engineering"}
        """
    }

    private func message(_ id: Int) throws -> ZulipMessage {
        try JSONDecoder().decode(ZulipMessage.self, from: Data(messageJSON(id, inTopic: Self.topic).utf8))
    }

    private func page(_ ids: ClosedRange<Int>, reachesOldest: Bool = false, inTopic topic: String = topic) throws
        -> MessagesPage
    {
        let messages = ids.map { messageJSON($0, inTopic: topic) }
        let json = """
            {"messages": [\(messages.joined(separator: ","))], "found_oldest": \(reachesOldest),
             "found_newest": true, "history_limited": false}
            """
        return try JSONDecoder().decode(MessagesPage.self, from: Data(json.utf8))
    }

    /// `stored` saved as the conversation's whole history, under the live queue.
    private func store(storing stored: ClosedRange<Int>) throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        let json = #"[{"stream_id": 7, "name": "engineering"}]"#
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        try store.saveSyncState(queueID: Self.earlierQueue, lastEventID: 0)
        try store.save(
            HistoryStretch(newest: page(stored, reachesOldest: true), in: conversation, queueID: Self.earlierQueue),
            selfUserID: 1
        )
        try store.saveSyncState(queueID: Self.liveQueue, lastEventID: 0)
        return store
    }

    private func saveNewest(_ ids: ClosedRange<Int>, to store: ZuluStore, queueID: String = liveQueue) throws {
        try store.save(HistoryStretch(newest: page(ids), in: conversation, queueID: queueID), selfUserID: 1)
    }

    private func pageStart(_ store: ZuluStore, before id: Int) throws -> Int? {
        try store.pageStart(channelID: Self.channel, topic: Self.topic, before: id, count: Self.page)
    }

    private func shown(_ store: ZuluStore, from start: Int? = nil) throws -> [Int] {
        var rows: ConversationRows?
        let observation = store.observeConversation(channelID: Self.channel, topic: Self.topic, from: start)
            .start(in: store.writer, scheduling: .immediate, onError: { _ in }) { rows = $0 }
        defer { observation.cancel() }
        return rows?.messages.map(\.id) ?? []
    }

    @Test func newestPageThatMissesTheStoreStartsTheHistory() throws {
        let store = try store(storing: 1...100)
        try saveNewest(501...600, to: store)
        #expect(try pageStart(store, before: 501) == nil)
        #expect(try shown(store, from: 51) == Array(501...600))
        #expect(try store.windowStart(channelID: Self.channel, topic: Self.topic, openingAt: nil, newest: 200, context: 0)
            == 501)
        #expect(try !store.holdsInHistory(100))
    }

    @Test func newestPageThatOverlapsTheStoreJoinsIt() throws {
        let store = try store(storing: 1...100)
        try saveNewest(51...150, to: store)
        #expect(try pageStart(store, before: 101) == 51)
        #expect(try shown(store) == Array(1...150))
    }

    @Test func pagingBackAcrossAGapJoinsWhatIsBelowIt() throws {
        let store = try store(storing: 1...100)
        try saveNewest(301...400, to: store)
        try store.save(HistoryStretch(before: 301, page: page(201...300), in: conversation), selfUserID: 1)
        #expect(try pageStart(store, before: 201) == nil)
        try store.save(HistoryStretch(before: 201, page: page(91...200), in: conversation), selfUserID: 1)
        #expect(try shown(store) == Array(1...400))
    }

    @Test func reachingTheFirstMessageClosesTheGap() throws {
        let store = try store(storing: 1...100)
        try saveNewest(301...400, to: store)
        try store.save(HistoryStretch(before: 301, page: page(150...300, reachesOldest: true), in: conversation),
                       selfUserID: 1)
        #expect(try store.holdsInHistory(1))
    }

    @Test func firstLiveMessageAfterAMissedStretchStartsTheHistory() throws {
        let store = try store(storing: 1...100)
        try store.saveArrival(message(600), selfUserID: 1)
        #expect(try shown(store) == [600])
        try store.saveArrival(message(601), selfUserID: 1)
        #expect(try shown(store) == [600, 601])
    }

    @Test func liveMessagesAfterTheNewestPageJoinIt() throws {
        let store = try store(storing: 1...100)
        try saveNewest(51...150, to: store)
        try store.saveArrival(message(600), selfUserID: 1)
        #expect(try shown(store) == Array(1...150) + [600])
    }

    @Test func newestPageFromAnEarlierQueueDoesNotVouchForWhatCameAfterIt() throws {
        let store = try store(storing: 1...100)
        try store.saveArrival(message(700), selfUserID: 1)
        try saveNewest(51...150, to: store, queueID: Self.earlierQueue)
        #expect(try shown(store) == [700])
        try store.saveArrival(message(701), selfUserID: 1)
        #expect(try shown(store) == [700, 701])
    }

    @Test func aStretchBelowTheHistoryThatDoesNotReachItStaysApart() throws {
        let store = try store(storing: 500...600)
        try store.save(
            HistoryStretch(conversation: conversation, messages: (100...150).map(message), from: 100, through: .message(150)),
            selfUserID: 1
        )
        #expect(try pageStart(store, before: 500) == nil)
    }

    @Test func aGapKeepsTheConversationFromOpeningOnWhatIsBelowIt() throws {
        let store = try store(storing: 1...100)
        try store.saveArrival(message(600), selfUserID: 1)
        #expect(try !store.canOpenFromStore(channelID: Self.channel, topic: Self.topic))
    }

    @Test func newestAcrossConversationsExtendsOnlyHistoryItReaches() throws {
        let store = try store(storing: 1...100)
        let recent = try page(90...120)
        let stretches = HistoryStretch.newest(across: recent, queueID: Self.liveQueue, selfUserID: 1)
        let stale = try HistoryStretch.newest(across: page(90...120, inTopic: "lunch"), queueID: Self.liveQueue, selfUserID: 1)
        try store.extendHistory(with: stretches + stale, selfUserID: 1)
        #expect(try shown(store) == Array(1...120))
        #expect(try store.pageStart(channelID: Self.channel, topic: "lunch", before: .max, count: Self.page) == nil)
        try store.saveArrival(message(700), selfUserID: 1)
        #expect(try shown(store) == Array(1...120) + [700])
    }
}
