import Foundation

public struct MessagesPage: Decodable, Sendable {
    public let messages: [ZulipMessage]
    public let found_oldest: Bool
    public let found_newest: Bool
    /// The realm's retention policy truncated the old end. Distinct from `found_oldest`.
    public let history_limited: Bool?
    public let anchor: Int?
}

private struct SubscriptionsResponse: Decodable { let subscriptions: [Subscription] }
private struct TopicsResponse: Decodable { let topics: [ChannelTopic] }
private struct SendMessageResponse: Decodable { let id: Int }
private enum SubscriptionProperty: String, Encodable {
    case isMuted = "is_muted"
    case pushNotifications = "push_notifications"
    case desktopNotifications = "desktop_notifications"
    case pinToTop = "pin_to_top"
}
private struct SubscriptionPropertyChange: Encodable {
    let stream_id: Int
    let property: SubscriptionProperty
    let value: Bool
}

extension ZulipClient {

    public enum Anchor: Sendable {
        case newest, oldest, firstUnread
        case id(Int)

        var wire: String {
            switch self {
            case .newest: "newest"
            case .oldest: "oldest"
            case .firstUnread: "first_unread"
            case .id(let value): String(value)
            }
        }
    }

    public func subscriptions() async throws -> [Subscription] {
        let response: SubscriptionsResponse = try await send(
            .get, "users/me/subscriptions", parameters: ["include_subscribers": "true"]
        )
        return response.subscriptions
    }

    /// Both push and desktop follow the one choice, so the phone and the Mac agree on
    /// how loud a channel is.
    public func setNotificationProperties(
        isMuted: Bool, notify: Bool, inChannel channelID: Int
    ) async throws {
        let changes = [
            SubscriptionPropertyChange(stream_id: channelID, property: .isMuted, value: isMuted),
            SubscriptionPropertyChange(stream_id: channelID, property: .pushNotifications, value: notify),
            SubscriptionPropertyChange(stream_id: channelID, property: .desktopNotifications, value: notify),
        ]
        _ = try await raw(.post, "users/me/subscriptions/properties", parameters: [
            "subscription_data": Self.json(changes),
        ])
    }

    /// Zulip's own "Pin to top", so a channel pinned here is pinned in every Zulip client.
    public func setPinned(_ pinned: Bool, inChannel channelID: Int) async throws {
        let change = SubscriptionPropertyChange(stream_id: channelID, property: .pinToTop, value: pinned)
        _ = try await raw(.post, "users/me/subscriptions/properties", parameters: [
            "subscription_data": Self.json([change]),
        ])
    }

    public func topics(inChannel id: Int) async throws -> [ChannelTopic] {
        let response: TopicsResponse = try await send(.get, "users/me/\(id)/topics")
        return response.topics
    }

    public func messages(
        narrow: [NarrowFilter] = [],
        anchor: Anchor = .newest,
        before: Int = 50,
        after: Int = 0,
        includeAnchor: Bool = true
    ) async throws -> MessagesPage {
        try await send(.get, "messages", parameters: [
            "anchor": anchor.wire,
            "include_anchor": includeAnchor ? "true" : "false",
            "num_before": String(before),
            "num_after": String(after),
            "narrow": Self.json(narrow),
            "apply_markdown": "true",
            "client_gravatar": "false",
        ])
    }

    public func sendMessage(
        toChannel id: Int, topic: String, content: String, echo: LocalEcho? = nil
    ) async throws -> Int {
        let response: SendMessageResponse = try await send(
            .post, "messages",
            parameters: Self.channelMessageParameters(channelID: id, topic: topic, content: content, echo: echo)
        )
        return response.id
    }

    public func sendMessage(toUsers ids: [Int], content: String, echo: LocalEcho? = nil) async throws -> Int {
        let response: SendMessageResponse = try await send(
            .post, "messages",
            parameters: Self.directMessageParameters(userIDs: ids, content: content, echo: echo)
        )
        return response.id
    }

    static func channelMessageParameters(
        channelID: Int, topic: String, content: String, echo: LocalEcho?
    ) -> [String: String] {
        ["type": "stream", "to": String(channelID), "topic": topic, "content": content]
            .merging(Self.sendParameters(echo: echo)) { current, _ in current }
    }

    static func directMessageParameters(userIDs: [Int], content: String, echo: LocalEcho?) -> [String: String] {
        ["type": "private", "to": Self.json(userIDs), "content": content]
            .merging(Self.sendParameters(echo: echo)) { current, _ in current }
    }

    /// The server only marks a sender's message read when it recognises the client as an
    /// official app, so Zulu has to ask. Otherwise your own messages arrive unread on your
    /// other devices.
    private static func sendParameters(echo: LocalEcho?) -> [String: String] {
        ["read_by_sender": "true"].merging(echo?.parameters ?? [:]) { current, _ in current }
    }

    /// Appends one event to a message's widget log — a vote, a new option, a new question.
    ///
    /// The route is real and both official mobile clients use it, but it is absent from
    /// Zulip's OpenAPI spec and the subsystem is documented as experimental, so it carries
    /// no stability promise.
    public func sendSubmessage(messageID: Int, content: String, msgType: String = "widget") async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(.post, "submessage", parameters: [
            "message_id": String(messageID),
            "msg_type": msgType,
            "content": content,
        ])
    }

    /// Re-reads the realm's groups. The `user_group` event says a group changed but not
    /// how, and there are seven ops of it, so the list is simply refetched.
    public func userGroups() async throws -> [RealmUserGroup] {
        struct Response: Decodable { let user_groups: [RealmUserGroup] }
        let response: Response = try await send(.get, "user_groups")
        return response.user_groups
    }

    public func markAllRead() async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(.post, "mark_all_as_read")
    }

    /// Fetches an image or file from the realm. Same-origin only: the API key must never
    /// ride along to Gravatar or a preview host.
    public func media(at path: String) async throws -> Data {
        guard path.hasPrefix("/") else { return Data() }
        let url = realmURL.appending(path: String(path.dropFirst()))
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let account {
            let pair = "\(account.email):\(account.apiKey)"
            request.setValue("Basic \(Data(pair.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}

/// Tags a sent message so its echo on this client's event queue says which send it
/// answers, rather than leaving the client to guess from the conversation.
public struct LocalEcho: Sendable, Equatable {
    public let queueID: String
    public let localID: String

    public init(queueID: String, localID: String) {
        self.queueID = queueID
        self.localID = localID
    }

    var parameters: [String: String] {
        ["queue_id": queueID, "local_id": localID]
    }
}
