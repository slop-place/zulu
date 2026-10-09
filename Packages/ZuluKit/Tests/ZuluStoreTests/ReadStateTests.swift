import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

struct ReadStateTests {

    private let me = 1
    private let someoneElse = 2

    private func arriving(_ id: Int, from sender: Int, flags: [String] = []) throws -> ZulipMessage {
        let json = """
            {"id": \(id), "sender_id": \(sender), "sender_full_name": "", "sender_email": "",
             "type": "stream", "content": "", "content_type": "text/html", "subject": "lunch",
             "timestamp": \(id), "stream_id": 7, "is_me_message": false, "reactions": [],
             "flags": \(flags)}
            """
        return try JSONDecoder().decode(ZulipMessage.self, from: Data(json.utf8))
    }

    @Test func aMessageFromSomeoneElseArrivesUnread() throws {
        let store = try ZuluStore(url: nil)
        let message = try arriving(1, from: someoneElse)
        #expect(ZuluStore.startsUnread(message, selfUserID: me))
        try store.noteArrival(of: message, selfUserID: me)
        #expect(try store.unreadIDs() == [1])
    }

    @Test func myOwnMessageNeverArrivesUnread() throws {
        let store = try ZuluStore(url: nil)
        let message = try arriving(1, from: me)
        #expect(!ZuluStore.startsUnread(message, selfUserID: me))
        try store.noteArrival(of: message, selfUserID: me)
        #expect(try store.unreadIDs().isEmpty)
    }

    @Test func aMessageTheServerAlreadyCallsReadArrivesRead() throws {
        let store = try ZuluStore(url: nil)
        let message = try arriving(1, from: someoneElse, flags: ["read"])
        #expect(!ZuluStore.startsUnread(message, selfUserID: me))
        try store.noteArrival(of: message, selfUserID: me)
        #expect(try store.unreadIDs().isEmpty)
    }

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
