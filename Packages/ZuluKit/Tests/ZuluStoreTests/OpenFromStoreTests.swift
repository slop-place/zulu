import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

/// A conversation opens on stored messages only when what the server adds afterwards
/// cannot move what is on screen: with something unread, the first unread message is
/// stored; with nothing unread, a screen's worth is.
@MainActor
struct OpenFromStoreTests {

    private func store(storedInDeploys: Int = 2) throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        let json = #"[{"stream_id": 7, "name": "engineering"}]"#
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        try store.writer.write { db in
            for id in 0..<storedInDeploys {
                try db.execute(sql: """
                    INSERT INTO message (id, channelID, topic, dmKey, senderID, senderName, renderedContent, timestamp)
                    VALUES (?, 7, 'deploys', NULL, 2, 'Ana', '<p>a</p>', ?)
                    """, arguments: [100 + id, 1000 + id])
            }
            for id in 0..<ZuluStore.storedMessagesToOpenOn {
                try db.execute(sql: """
                    INSERT INTO message (id, channelID, topic, dmKey, senderID, senderName, renderedContent, timestamp)
                    VALUES (?, NULL, NULL, '2', 2, 'Ana', '<p>hi</p>', ?)
                    """, arguments: [500 + id, 2000 + id])
            }
        }
        return store
    }

    private func markUnread(_ store: ZuluStore, _ id: Int, dmKey: String? = nil) throws {
        try store.writer.write { db in
            try db.execute(
                sql: "INSERT INTO unread (messageID, channelID, topic, dmKey) VALUES (?, ?, ?, ?)",
                arguments: [id, dmKey == nil ? 7 : nil, dmKey == nil ? "deploys" : nil, dmKey]
            )
        }
    }

    @Test func aScreensWorthWithNothingUnreadOpensAtOnce() throws {
        let store = try store(storedInDeploys: ZuluStore.storedMessagesToOpenOn)
        #expect(try store.canOpenFromStore(channelID: 7, topic: "deploys"))
        #expect(try store.canOpenFromStore(dmKey: "2"))
    }

    @Test func aFewWithNothingUnreadWaitsForTheServer() throws {
        let store = try store(storedInDeploys: 2)
        #expect(try !store.canOpenFromStore(channelID: 7, topic: "deploys"))
    }

    @Test func nothingStoredWaitsForTheServer() throws {
        let store = try store()
        #expect(try !store.canOpenFromStore(channelID: 7, topic: "lunch"))
        #expect(try !store.canOpenFromStore(dmKey: "3"))
    }

    @Test func storedFirstUnreadOpensAtOnceHoweverFewAreStored() throws {
        let store = try store(storedInDeploys: 2)
        try markUnread(store, 101)
        try markUnread(store, 150)
        #expect(try store.canOpenFromStore(channelID: 7, topic: "deploys"))
    }

    @Test func missingFirstUnreadWaitsForTheServer() throws {
        let store = try store(storedInDeploys: ZuluStore.storedMessagesToOpenOn)
        try markUnread(store, 99)
        try markUnread(store, 101)
        #expect(try !store.canOpenFromStore(channelID: 7, topic: "deploys"))
        try markUnread(store, 499, dmKey: "2")
        #expect(try !store.canOpenFromStore(dmKey: "2"))
    }
}
