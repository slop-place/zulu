import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

@MainActor
struct PersonalShapeTests {


    /// One value out of an observation. `first(where:)` on the stream trips Swift 6's
    /// sendability checks in a `@MainActor` test; a plain loop does not.
    private func firstValue<T>(_ stream: AsyncValueObservation<T>) async throws -> T? {
        for try await value in stream { return value }
        return nil
    }
    private func makeStore() throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        try store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO channel (id, name, isRestricted, isMuted, pinned, detectedForum)
                VALUES (7, 'engineering', 0, 0, 0, 1)
                """)
            for (name, maxID) in [("flaky tests", 100), ("standup", 90), ("old thread", 50)] {
                try db.execute(
                    sql: "INSERT INTO topic (channelID, name, maxMessageID) VALUES (7, ?, ?)",
                    arguments: [name, maxID]
                )
            }
        }
        return store
    }

    @Test func anAliasReplacesTheNameInTheSidebar() throws {
        let store = try makeStore()
        try store.setAlias("Eng", forChannel: 7)

        let channels = try store.writer.read { db in
            try ChannelSummary.fetchAll(db, sql: """
                SELECT c.id, COALESCE(c.alias, c.name) AS name, c.isRestricted, c.isMuted,
                       c.pinned, COALESCE(c.modeOverride, c.detectedForum) AS isForum,
                       0 AS topicCount, 0 AS unreadCount, 0 AS generalChatUnreadCount,
                       0 AS mentionCount, 0 AS generalChatMentionCount
                  FROM channel c
                """)
        }
        #expect(channels.first?.name == "Eng")
    }

    /// The server's own name has to survive, because a mention must emit the real one.
    @Test func theRealNameIsStillThereUnderTheAlias() throws {
        let store = try makeStore()
        try store.setAlias("Eng", forChannel: 7)

        let real = try store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM channel WHERE id = 7")
        }
        #expect(real == "engineering")
        #expect(try store.alias(forChannel: 7) == "Eng")
    }

    @Test func clearingAnAliasRestoresTheServerName() throws {
        let store = try makeStore()
        try store.setAlias("Eng", forChannel: 7)
        try store.setAlias(nil, forChannel: 7)
        #expect(try store.alias(forChannel: 7) == nil)
    }

    @Test func whitespaceOnlyAliasIsNoAlias() throws {
        let store = try makeStore()
        try store.setAlias("   ", forChannel: 7)
        #expect(try store.alias(forChannel: 7) == nil)
    }

    /// The working answer from the ticket: promoted topics leave the forum list, so they
    /// are never shown twice and their unread is never counted twice.
    @Test func aPromotedTopicLeavesTheForumListBeneathItsChannel() async throws {
        let store = try makeStore()
        try store.promote(topic: "standup", inChannel: 7)

        let topics = try await firstValue(
            store.observeTopics(inChannel: 7).values(in: store.writer)
        ) ?? []
        #expect(topics.map(\.name).sorted() == ["flaky tests", "old thread"])
    }

    @Test func aPromotedTopicCanBeFiledAwayFromItsChannel() async throws {
        let store = try makeStore()
        try await store.writer.write { db in
            try db.execute(
                sql: "INSERT INTO channelGroup (id, name, position) VALUES ('g1', 'School', 0)"
            )
        }
        try store.promote(topic: "standup", inChannel: 7, toGroup: "g1")

        let inGroup = try await firstValue(
            store.observePromotedTopics(inGroup: "g1").values(in: store.writer)
        ) ?? []
        let unfiled = try await firstValue(
            store.observePromotedTopics(inGroup: nil).values(in: store.writer)
        ) ?? []

        #expect(inGroup.map(\.topic) == ["standup"])
        #expect(unfiled.isEmpty)
    }

    @Test func aPromotionFollowsTheTopicWhenItIsRenamed() throws {
        let store = try makeStore()
        try store.promote(topic: "standup", inChannel: 7)
        try store.renamePromotedTopic(inChannel: 7, from: "standup", to: "daily standup")

        #expect(try store.isPromoted(topic: "daily standup", inChannel: 7))
        #expect(try store.isPromoted(topic: "standup", inChannel: 7) == false)
    }

    /// A promotion is a reference to a name. When the name stops existing the entry goes,
    /// rather than sitting dead in the sidebar.
    @Test func aPromotionWhoseTopicVanishedIsPruned() throws {
        let store = try makeStore()
        try store.promote(topic: "standup", inChannel: 7)
        try store.promote(topic: "flaky tests", inChannel: 7)

        try store.writer.write { db in
            try db.execute(sql: "DELETE FROM topic WHERE channelID = 7 AND name = 'standup'")
        }
        try store.pruneVanishedPromotions(inChannel: 7)

        #expect(try store.isPromoted(topic: "standup", inChannel: 7) == false)
        #expect(try store.isPromoted(topic: "flaky tests", inChannel: 7))
    }

    @Test func demotingPutsTheTopicBackInTheForumList() async throws {
        let store = try makeStore()
        try store.promote(topic: "standup", inChannel: 7)
        try store.demote(topic: "standup", inChannel: 7)

        let topics = try await firstValue(
            store.observeTopics(inChannel: 7).values(in: store.writer)
        ) ?? []
        #expect(topics.count == 3)
    }
}

@MainActor
struct HidingAndAbsorptionTests {

    private func firstValue<T>(_ stream: AsyncValueObservation<T>) async throws -> T? {
        for try await value in stream { return value }
        return nil
    }

    private func makeStore(topics: [String]) throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        try store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO channel (id, name, isRestricted, isMuted, pinned, detectedForum, hidden)
                VALUES (7, 'engineering', 0, 0, 0, 1, 0)
                """)
            for (index, name) in topics.enumerated() {
                try db.execute(
                    sql: "INSERT INTO topic (channelID, name, maxMessageID) VALUES (7, ?, ?)",
                    arguments: [name, 100 - index]
                )
            }
        }
        return store
    }

    private func visibleChannels(_ store: ZuluStore) async throws -> [ChannelSummary] {
        try await firstValue(store.observeChannels().values(in: store.writer)) ?? []
    }

    /// Promoting the last topic leaves nothing beneath the channel but its own promoted
    /// topic one level up, so the channel steps aside.
    @Test func promotingTheOnlyTopicAbsorbsTheChannel() async throws {
        let store = try makeStore(topics: ["general chat"])
        #expect(try await visibleChannels(store).count == 1)

        try store.promote(topic: "general chat", inChannel: 7)
        #expect(try await visibleChannels(store).isEmpty)
    }

    /// The channel comes back on its own, and the promotion is left alone.
    @Test func aNewTopicBringsAnAbsorbedChannelBack() async throws {
        let store = try makeStore(topics: ["general chat"])
        try store.promote(topic: "general chat", inChannel: 7)

        try await store.writer.write { db in
            try db.execute(
                sql: "INSERT INTO topic (channelID, name, maxMessageID) VALUES (7, 'new thread', 200)"
            )
        }

        #expect(try await visibleChannels(store).count == 1)
        #expect(try store.isPromoted(topic: "general chat", inChannel: 7))
    }

    @Test func promotingSomeButNotAllTopicsLeavesTheChannel() async throws {
        let store = try makeStore(topics: ["one", "two"])
        try store.promote(topic: "one", inChannel: 7)
        #expect(try await visibleChannels(store).count == 1)
    }

    /// A channel with no topics at all has not been absorbed by anything.
    @Test func anEmptyChannelIsStillListed() async throws {
        let store = try makeStore(topics: [])
        #expect(try await visibleChannels(store).count == 1)
    }

    @Test func hidingRemovesAChannelFromTheList() async throws {
        let store = try makeStore(topics: ["one"])
        try store.setHidden(true, forChannel: 7)

        #expect(try await visibleChannels(store).isEmpty)
        let hidden = try await firstValue(store.observeHiddenChannels().values(in: store.writer)) ?? []
        #expect(hidden.map(\.id) == [7])
    }

    @Test func unhidingPutsItBack() async throws {
        let store = try makeStore(topics: ["one"])
        try store.setHidden(true, forChannel: 7)
        try store.setHidden(false, forChannel: 7)
        #expect(try await visibleChannels(store).count == 1)
    }

    private func mentionedHidden(_ store: ZuluStore, inGroup group: String? = nil) async throws -> [ChannelSummary] {
        try await firstValue(store.observeMentionedHiddenChannels(inGroup: group).values(in: store.writer)) ?? []
    }

    private func addUnread(_ messageID: Int, isMention: Bool, to store: ZuluStore) throws {
        try store.writer.write { db in
            try db.execute(
                sql: "INSERT INTO unread (messageID, channelID, topic, isMention) VALUES (?, 7, 'one', ?)",
                arguments: [messageID, isMention]
            )
        }
    }

    /// The rail counts a hidden channel's mentions, so the channel surfaces to be opened.
    @Test func aHiddenChannelWithAMentionSurfaces() async throws {
        let store = try makeStore(topics: ["one"])
        try store.setHidden(true, forChannel: 7)
        try addUnread(1, isMention: true, to: store)

        #expect(try await visibleChannels(store).isEmpty)
        #expect(try await mentionedHidden(store).map(\.id) == [7])
    }

    @Test func aHiddenChannelWithOnlyPlainUnreadsStaysHidden() async throws {
        let store = try makeStore(topics: ["one"])
        try store.setHidden(true, forChannel: 7)
        try addUnread(1, isMention: false, to: store)
        #expect(try await mentionedHidden(store).isEmpty)
    }

    @Test func aVisibleChannelWithAMentionIsNotListedAsHidden() async throws {
        let store = try makeStore(topics: ["one"])
        try addUnread(1, isMention: true, to: store)
        #expect(try await mentionedHidden(store).isEmpty)
    }

    /// It surfaces in the group it is filed in, not in the unfiled pile.
    @Test func aMentionedHiddenChannelSurfacesInItsOwnGroup() async throws {
        let store = try makeStore(topics: ["one"])
        let group = try store.createGroup(name: "Work")
        try store.setChannels([7], inGroup: group.id)
        try store.setHidden(true, forChannel: 7)
        try addUnread(1, isMention: true, to: store)

        #expect(try await mentionedHidden(store).isEmpty)
        #expect(try await mentionedHidden(store, inGroup: group.id).map(\.id) == [7])
    }

    /// The alias is what makes a promoted `general chat` mean anything at the top level.
    @Test func aPromotedTopicShowsItsOwnAlias() async throws {
        let store = try makeStore(topics: ["general chat"])
        try store.promote(topic: "general chat", inChannel: 7)
        try store.setAlias("Off-topic", forPromotedTopic: "general chat", inChannel: 7)

        let promoted = try await firstValue(
            store.observePromotedTopics(inGroup: nil).values(in: store.writer)
        ) ?? []
        #expect(promoted.first?.displayName == "Off-topic")
    }

    @Test func aPromotedTopicWithoutAnAliasShowsItsTopic() async throws {
        let store = try makeStore(topics: ["standup"])
        try store.promote(topic: "standup", inChannel: 7)

        let promoted = try await firstValue(
            store.observePromotedTopics(inGroup: nil).values(in: store.writer)
        ) ?? []
        #expect(promoted.first?.displayName == "standup")
    }
}

/// Channels and promoted topics are both top-level sidebar rows, so their positions have
/// to come from one sequence rather than two that happen to start at the same number.
@MainActor
struct SidebarOrderTests {

    private func makeStore() throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        try store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO channel (id, name, isRestricted, isMuted, pinned, detectedForum)
                VALUES (7, 'engineering', 0, 0, 0, 1), (8, 'design', 0, 0, 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO topic (channelID, name, maxMessageID) VALUES (7, 'standup', 90)
                """)
        }
        return store
    }

    private func position(ofChannel id: Int, in store: ZuluStore) throws -> Int? {
        try store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT position FROM channel WHERE id = ?", arguments: [id])
        }
    }

    private func position(ofTopic topic: String, in store: ZuluStore) throws -> Int? {
        try store.writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT position FROM promotedTopic WHERE topic = ?", arguments: [topic]
            )
        }
    }

    @Test func aPromotedTopicCanSitBetweenTwoChannels() throws {
        let store = try makeStore()
        try store.promote(topic: "standup", inChannel: 7)

        let order: [SidebarSlot] = [
            .channel(8), .promotedTopic(channelID: 7, topic: "standup"), .channel(7),
        ]
        try store.reorderSidebar(order)

        #expect(try position(ofChannel: 8, in: store) == 0)
        #expect(try position(ofTopic: "standup", in: store) == 1)
        #expect(try position(ofChannel: 7, in: store) == 2)
    }

    @Test func aNewPromotionLandsBelowEverythingAlreadyPlaced() throws {
        let store = try makeStore()
        try store.reorderSidebar([.channel(8), .channel(7)])

        try store.promote(topic: "standup", inChannel: 7)

        #expect(try position(ofTopic: "standup", in: store) == 2)
    }
}
