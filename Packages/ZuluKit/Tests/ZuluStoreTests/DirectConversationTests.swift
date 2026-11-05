import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

/// The DM list holds every conversation the server reports, not only those with a
/// fetched message.
struct DirectConversationTests {

    private let me = 1

    private func dm(_ id: Int, with other: Int) throws -> ZulipMessage {
        let json = """
            {"id": \(id), "sender_id": \(other), "sender_full_name": "Ana", "sender_email": "",
             "type": "private", "content": "<p>hi</p>", "content_type": "text/html", "subject": "",
             "timestamp": \(id), "is_me_message": false, "reactions": [], "flags": [],
             "display_recipient": [{"id": \(me), "full_name": "Me", "email": ""},
                                   {"id": \(other), "full_name": "Ana", "email": ""}]}
            """
        return try JSONDecoder().decode(ZulipMessage.self, from: Data(json.utf8))
    }

    private func dms(_ store: ZuluStore) async throws -> [DMSummary] {
        for try await rows in store.observeDMs().values(in: store.writer) {
            return rows
        }
        throw CancellationError()
    }

    @Test func aConversationWithNoFetchedMessagesIsListed() async throws {
        let store = try ZuluStore(url: nil)
        try store.saveDirectConversations([
            RecentDirectConversation(max_message_id: 50, user_ids: [2]),
            RecentDirectConversation(max_message_id: 90, user_ids: [3, 4]),
            RecentDirectConversation(max_message_id: 70, user_ids: []),
        ], selfUserID: me)

        let rows = try await dms(store)
        #expect(rows.map(\.dmKey) == ["1,3,4", "1", "1,2"])
        #expect(rows.allSatisfy { $0.lastContent == nil })
    }

    @Test func aNewerMessageMovesItsConversationUp() async throws {
        let store = try ZuluStore(url: nil)
        try store.saveDirectConversations([
            RecentDirectConversation(max_message_id: 50, user_ids: [2]),
            RecentDirectConversation(max_message_id: 90, user_ids: [3]),
        ], selfUserID: me)
        try store.save(messages: [try dm(100, with: 2)], selfUserID: me)

        let rows = try await dms(store)
        #expect(rows.map(\.dmKey) == ["1,2", "1,3"])
        #expect(rows[0].lastContent == "<p>hi</p>")
    }

    @Test func anOlderSnapshotDoesNotRollAConversationBack() async throws {
        let store = try ZuluStore(url: nil)
        try store.save(messages: [try dm(100, with: 2)], selfUserID: me)
        try store.saveDirectConversations(
            [RecentDirectConversation(max_message_id: 50, user_ids: [2])], selfUserID: me
        )

        let rows = try await dms(store)
        #expect(rows.map(\.lastMessageID) == [100])
    }

    @Test func aSnapshotAfterADeletionLowersTheConversation() async throws {
        let store = try ZuluStore(url: nil)
        try store.saveDirectConversations([
            RecentDirectConversation(max_message_id: 100, user_ids: [2]),
            RecentDirectConversation(max_message_id: 90, user_ids: [3]),
        ], selfUserID: me)
        try store.saveDirectConversations(
            [RecentDirectConversation(max_message_id: 50, user_ids: [2])], selfUserID: me
        )

        let rows = try await dms(store)
        #expect(rows.map(\.dmKey) == ["1,3", "1,2"])
    }

    @Test func deletingTheNewestMessageMovesItsConversationDown() async throws {
        let store = try ZuluStore(url: nil)
        try store.save(messages: [try dm(80, with: 2), try dm(100, with: 2), try dm(90, with: 3)], selfUserID: me)
        try store.deleteMessages(ids: [100])

        let rows = try await dms(store)
        #expect(rows.map(\.dmKey) == ["1,3", "1,2"])
        #expect(rows.map(\.lastMessageID) == [90, 80])
    }

    @Test func deletingTheLastFetchedMessageDropsTheConversation() async throws {
        let store = try ZuluStore(url: nil)
        try store.save(messages: [try dm(100, with: 2), try dm(90, with: 3)], selfUserID: me)
        try store.deleteMessages(ids: [100])

        let rows = try await dms(store)
        #expect(rows.map(\.dmKey) == ["1,3"])
    }
}
