import Foundation
import Testing
import ZulipAPI
@testable import ZuluStore

@MainActor
struct ChannelNotificationTests {

    private func subscriptions(isMuted: Bool, push: String) throws -> [Subscription] {
        let json = """
            [{"stream_id": 7, "name": "engineering", "is_muted": \(isMuted), "push_notifications": \(push)}]
            """
        return try JSONDecoder().decode([Subscription].self, from: Data(json.utf8))
    }

    @Test(arguments: [
        (false, "true", NotificationLevel.all),
        (false, "false", .mentions),
        (false, "null", .mentions),
        (true, "true", .muted),
    ])
    func levelFollowsTheSubscription(isMuted: Bool, push: String, expected: NotificationLevel) throws {
        let store = try ZuluStore(url: nil)
        try store.replaceChannels(subscriptions(isMuted: isMuted, push: push))

        #expect(try store.notificationLevel(forChannel: 7) == expected)
    }

    @Test(arguments: NotificationLevel.allCases)
    func aLevelSetLocallyReadsBack(level: NotificationLevel) throws {
        let store = try ZuluStore(url: nil)
        try store.replaceChannels(subscriptions(isMuted: false, push: "null"))

        try store.setNotificationLevel(level, forChannel: 7)

        #expect(try store.notificationLevel(forChannel: 7) == level)
    }

    @Test func anUnknownChannelHasNoLevel() throws {
        let store = try ZuluStore(url: nil)
        #expect(try store.notificationLevel(forChannel: 99) == nil)
    }
}

@MainActor
struct NotificationLevelResolutionTests {

    private func store(channels: [Int]) throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        let json = "[" + channels.map { #"{"stream_id": \#($0), "name": "c\#($0)"}"# }.joined(separator: ",") + "]"
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        return store
    }

    @Test func aChannelFollowsItsGroup() throws {
        let store = try store(channels: [7])
        let group = try store.createGroup(name: "Work")
        try store.setChannels([7], inGroup: group.id)
        try store.setNotificationLevel(.muted, forGroup: group.id)

        #expect(try store.effectiveNotificationLevel(forChannel: 7) == .muted)
        #expect(try store.channelsFollowing(group: group.id) == [7])
    }

    @Test func aChannelsOwnLevelBeatsItsGroup() throws {
        let store = try store(channels: [7, 8])
        let group = try store.createGroup(name: "Work")
        try store.setChannels([7, 8], inGroup: group.id)
        try store.setNotificationLevel(.muted, forGroup: group.id)
        try store.setNotificationOverride(.all, forChannel: 7)

        #expect(try store.effectiveNotificationLevel(forChannel: 7) == .all)
        #expect(try store.channelsFollowing(group: group.id) == [8])
    }

    @Test func anUngroupedChannelWithNoChoiceHasNoLevel() throws {
        let store = try store(channels: [7])
        #expect(try store.effectiveNotificationLevel(forChannel: 7) == nil)
    }

    @Test(arguments: NotificationLevel.allCases)
    func aTopicLevelRoundTripsThroughItsPolicy(level: NotificationLevel) throws {
        let store = try store(channels: [7])
        try store.setTopicLevel(level, topic: "lunch", inChannel: 7)

        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == level)
        #expect(try store.isMuted(topic: "lunch", inChannel: 7) == (level == .muted))
    }

    @Test func inheritingClearsTheTopic() throws {
        let store = try store(channels: [7])
        try store.setTopicPolicy(.followed, topic: "lunch", inChannel: 7)
        try store.apply(UserTopic(stream_id: 7, topic_name: "lunch", visibility_policy: 0))

        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == nil)
    }

    /// Whoever followed it, Zulip or you on the web, a followed topic hears every message
    /// on every client. Showing anything else here is how the phone and the menu disagreed.
    @Test func aFollowFromZulipIsAllMessages() throws {
        let store = try store(channels: [7])
        try store.replaceMutedTopics([
            UserTopic(stream_id: 7, topic_name: "Lunch", visibility_policy: TopicVisibilityPolicy.followed.rawValue),
        ])

        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == .all)
    }

    @Test func levelsTravelWithThePersonalShape() throws {
        let source = try store(channels: [7])
        let group = try source.createGroup(name: "Work")
        try source.setNotificationLevel(.mentions, forGroup: group.id)
        try source.setNotificationOverride(.all, forChannel: 7)

        let target = try store(channels: [7])
        try target.apply(source.localPersonalShape().shape)

        #expect(try target.notificationLevel(forGroup: group.id) == .mentions)
        #expect(try target.notificationOverride(forChannel: 7) == .all)
    }

    @Test func aDocumentFromAnOlderBuildStillReads() throws {
        let json = #"{"groups": [], "promotions": [], "followedTopics": [{"channelID": 7, "topic": "lunch"}]}"#
        let shape = try JSONDecoder().decode(PersonalShape.self, from: Data(json.utf8))
        #expect(shape.isEmpty)
    }
}

/// zulu-notifyd runs the same file, so a push and a banner can never disagree.
struct NotificationRuleTests {

    struct RuleCase: Decodable {
        let name: String
        let direct: Bool
        let own: Bool
        let senderMuted: Bool
        let flags: [String]
        let channelMuted: Bool
        let channelPush: Bool?
        let topicPolicy: String
        let directMessages: Bool
        let mentions: Bool
        let level: String?
        let notify: Bool
    }

    private static let policies: [String: TopicVisibilityPolicy] = [
        "inherit": .inherit, "muted": .muted, "unmuted": .unmuted, "followed": .followed,
    ]
    private static let levels: [String: NotificationLevel] = ["all": .all, "mentions": .mentions, "muted": .muted]

    private static func cases() throws -> [RuleCase] {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "spec/notification-rules.json"))
        struct File: Decodable { let cases: [RuleCase] }
        return try JSONDecoder().decode(File.self, from: data).cases
    }

    @Test func everySharedCaseHolds() throws {
        let cases = try Self.cases()
        #expect(!cases.isEmpty)
        // The apps do not know who you have muted yet, so those cases are the service's.
        for rule in cases where !rule.senderMuted {
            let policy = try #require(Self.policies[rule.topicPolicy])
            let level = rule.direct ? nil : NotificationLevel(
                topicPolicy: policy, channelIsMuted: rule.channelMuted, channelPushNotifications: rule.channelPush
            )
            #expect(level == rule.level.flatMap { Self.levels[$0] }, "\(rule.name)")

            let allowed = NotificationRule(directMessages: rule.directMessages, mentions: rule.mentions)
                .allows(flags: rule.flags, isOwn: rule.own, level: level)
            #expect(allowed == rule.notify, "\(rule.name)")
        }
    }
}
