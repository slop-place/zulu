import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

/// A channel pinned in Zulip sits at the top of its list, above any order the viewer
/// dragged the rest into.
@MainActor
struct PinnedChannelTests {

    private func store() throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        let json = #"""
        [{"stream_id": 1, "name": "alpha"},
         {"stream_id": 2, "name": "bravo", "pin_to_top": true},
         {"stream_id": 3, "name": "charlie"}]
        """#
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        return store
    }

    private func names(_ store: ZuluStore) async throws -> [String] {
        for try await rows in store.observeChannels(inGroup: nil).values(in: store.writer) {
            return rows.map(\.name)
        }
        throw CancellationError()
    }

    @Test func pinnedChannelComesFirst() async throws {
        #expect(try await names(try store()) == ["bravo", "alpha", "charlie"])
    }

    @Test func pinBeatsADraggedOrder() async throws {
        let store = try store()
        try store.reorderSidebar([.channel(3), .channel(1), .channel(2)])
        #expect(try await names(store) == ["bravo", "charlie", "alpha"])
    }

    @Test func unpinningGoesBackToTheDraggedOrder() async throws {
        let store = try store()
        try store.reorderSidebar([.channel(3), .channel(1), .channel(2)])
        try store.setPinned(false, forChannel: 2)
        try store.setPinned(true, forChannel: 1)
        #expect(try await names(store) == ["alpha", "charlie", "bravo"])
    }
}
