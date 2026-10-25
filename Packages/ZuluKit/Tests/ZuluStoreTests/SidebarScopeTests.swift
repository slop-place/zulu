import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

/// A list can hold one group, the channels in no group, or every channel.
@MainActor
struct SidebarScopeTests {

    private func store() throws -> (ZuluStore, String) {
        let store = try ZuluStore(url: nil)
        let json = #"""
        [{"stream_id": 1, "name": "alpha"},
         {"stream_id": 2, "name": "bravo"},
         {"stream_id": 3, "name": "charlie"}]
        """#
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        let group = try store.createGroup(name: "Work")
        try store.setChannels([2], inGroup: group.id)
        try store.setHidden(true, forChannel: 3)
        try store.writer.write { db in
            try db.execute(sql: "INSERT INTO unread (messageID, channelID, topic, isMention) VALUES (9, 3, 'ping', 1)")
        }
        return (store, group.id)
    }

    private func names(_ observation: ValueObservation<ValueReducers.Fetch<[ChannelSummary]>>, in store: ZuluStore) async throws -> [String] {
        for try await rows in observation.values(in: store.writer) {
            return rows.map(\.name)
        }
        throw CancellationError()
    }

    @Test func everythingHoldsGroupedAndUngroupedChannels() async throws {
        let (store, _) = try store()
        #expect(try await names(store.observeChannels(in: .everything), in: store) == ["alpha", "bravo"])
    }

    @Test func ungroupedAndGroupStillSplitThem() async throws {
        let (store, group) = try store()
        #expect(try await names(store.observeChannels(in: .ungrouped), in: store) == ["alpha"])
        #expect(try await names(store.observeChannels(in: .group(group)), in: store) == ["bravo"])
    }

    @Test func everythingIncludesAHiddenChannelWithAMention() async throws {
        let (store, _) = try store()
        #expect(try await names(store.observeMentionedHiddenChannels(in: .everything), in: store) == ["charlie"])
    }
}
