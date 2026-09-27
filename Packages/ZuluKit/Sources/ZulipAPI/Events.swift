import Foundation

public struct RegisterResponse: Decodable, Sendable {
    public let queue_id: String?
    public let last_event_id: Int
    public let zulip_feature_level: Int?
    public let subscriptions: [Subscription]?
    public let realm_users: [ZulipUser]?
    public let max_message_length: Int?
    public let unread_msgs: UnreadMessages?
    /// Where the unicode emoji table is served, added at feature level 140. A static
    /// file on the server's own origin, so it is fetched without credentials.
    public let server_emoji_data_url: String?
    /// Keyed by stringified emoji id. `:zulip:` is never in here and has to be
    /// synthesized by the client.
    public let realm_emoji: [String: RealmEmoji]?
    public let realm_user_groups: [RealmUserGroup]?
    public let user_topics: [UserTopic]?
}

/// Only the events Zulu acts on today. Anything else decodes to `.other` and is skipped,
/// which is also how the client survives a server newer than it is.
public enum ZulipEvent: Sendable {
    /// `localID` is set only on the queue that sent the message, and only when the send
    /// carried one.
    case message(ZulipMessage, localID: String?)
    case updateMessage(id: Int, renderedContent: String?, editedAt: Int?)
    case deleteMessage(ids: [Int])
    /// `all` means every message the user has, and comes with no ids.
    case flags(operation: String, flag: String, messageIDs: [Int], all: Bool)
    case reaction(added: Bool, messageID: Int, reaction: Reaction)
    case submessage(Submessage)
    case subscriptionsChanged
    /// The realm's whole emoji map, which is how the legacy event reports any change to
    /// any one of them.
    case realmEmojiChanged([String: RealmEmoji])
    case userGroupsChanged
    case userTopic(UserTopic)
    case typing(TypingEvent)
    case heartbeat
    case other(String)

    public var eventType: String {
        switch self {
        case .message: "message"
        case .updateMessage: "update_message"
        case .deleteMessage: "delete_message"
        case .flags: "update_message_flags"
        case .reaction: "reaction"
        case .submessage: "submessage"
        case .subscriptionsChanged: "subscription"
        case .realmEmojiChanged: "realm_emoji"
        case .userGroupsChanged: "user_group"
        case .userTopic: "user_topic"
        case .typing: "typing"
        case .heartbeat: "heartbeat"
        case .other(let name): name
        }
    }
}

struct EventEnvelope: Decodable {
    let id: Int
    let type: String
    let message: ZulipMessage?
    let message_id: Int?
    let message_ids: [Int]?
    /// `update_message_flags` names its ids `messages`, not `message_ids`.
    let messages: [Int]?
    let all: Bool?
    let rendered_content: String?
    let edit_timestamp: Int?
    let operation: String?
    let op: String?
    let flag: String?
    let emoji_name: String?
    let emoji_code: String?
    let reaction_type: String?
    let user_id: Int?
    let submessage_id: Int?
    let sender_id: Int?
    let msg_type: String?
    let content: String?
    let realm_emoji: [String: RealmEmoji]?
    let stream_id: Int?
    let topic_name: String?
    let visibility_policy: Int?
    let sender: TypingUser?
    let recipients: [TypingUser]?
    let topic: String?
    let local_message_id: LenientString?

    func decoded() -> ZulipEvent {
        switch type {
        case "message":
            if let message { return .message(message, localID: local_message_id.flatMap(\.value)) }
        case "update_message":
            if let id = message_id {
                return .updateMessage(id: id, renderedContent: rendered_content, editedAt: edit_timestamp)
            }
        case "delete_message":
            return .deleteMessage(ids: message_ids ?? [message_id].compactMap { $0 })
        case "update_message_flags":
            if let flag, let ids = messages {
                return .flags(
                    operation: operation ?? op ?? "add", flag: flag, messageIDs: ids, all: all ?? false
                )
            }
        case "reaction":
            if let messageID = message_id, let name = emoji_name, let code = emoji_code,
               let kind = reaction_type, let user = user_id {
                return .reaction(
                    added: (op ?? operation) == "add",
                    messageID: messageID,
                    reaction: Reaction(emoji_name: name, emoji_code: code, reaction_type: kind, user_id: user)
                )
            }
        case "submessage":
            // The event calls the submessage's own id `submessage_id` and reserves `id` for
            // the event queue. A message's `submessages` array calls the same value `id`,
            // so the two are reconciled here rather than anywhere downstream.
            if let submessageID = submessage_id, let messageID = message_id,
               let sender = sender_id, let kind = msg_type, let content {
                return .submessage(Submessage(
                    id: submessageID, message_id: messageID, sender_id: sender,
                    msg_type: kind, content: content
                ))
            }
        case "subscription", "stream":
            return .subscriptionsChanged
        case "realm_emoji":
            // Without the `individual_emoji_changes` capability the server only ever
            // sends the whole map, so there is nothing finer to handle.
            if let realm_emoji { return .realmEmojiChanged(realm_emoji) }
        case "user_group":
            return .userGroupsChanged
        case "user_topic":
            if let stream_id, let topic_name, let visibility_policy {
                return .userTopic(UserTopic(
                    stream_id: stream_id, topic_name: topic_name, visibility_policy: visibility_policy
                ))
            }
        case "typing":
            if let op = op.flatMap(TypingOp.init(rawValue:)), let sender {
                return .typing(TypingEvent(
                    op: op, senderID: sender.user_id, channelID: stream_id, topic: topic,
                    recipientIDs: recipients?.map(\.user_id) ?? []
                ))
            }
        case "heartbeat":
            return .heartbeat
        default:
            break
        }
        return .other(type)
    }
}

private struct EventsResponse: Decodable { let events: [EventEnvelope] }

/// The server rejects the whole register if `notification_settings_null` is missing.
struct ClientCapabilities: Encodable {
    /// Off, so a channel that follows the account-wide push setting reports that
    /// setting's value instead of null.
    let notification_settings_null = false
    /// Without it the server drops every typing event that is not a direct message.
    let stream_typing_notifications = true
}

public struct EventBatch: Sendable {
    public let events: [ZulipEvent]
    /// Ids increase but skip, because the server compresses flag events inside the queue.
    /// Track the maximum rather than assuming the next one is `+1`.
    public let lastEventID: Int
}

extension ZulipClient {

    public func register(eventTypes: [String] = [
        "message", "update_message", "delete_message", "update_message_flags",
        "reaction", "submessage", "subscription", "stream", "realm_user", "user_topic",
        "realm_emoji", "user_group", "typing",
    ]) async throws -> RegisterResponse {
        try await send(.post, "register", parameters: [
            "apply_markdown": "true",
            "client_gravatar": "false",
            "slim_presence": "true",
            "event_types": Self.json(eventTypes),
            // unread_msgs is only included when both of these are fetched.
            // `realm` is also what carries server_emoji_data_url.
            "fetch_event_types": Self.json([
                "subscription", "realm_user", "realm", "message", "update_message_flags",
                "realm_emoji", "realm_user_groups", "user_topic",
            ]),
            // Subscriber lists are what let the `@` box put the people in this channel
            // first, which is the ranking rule both official clients agree on.
            "include_subscribers": "true",
            "client_capabilities": Self.json(ClientCapabilities()),
        ])
    }

    /// Long-polls. The server holds the socket open and answers with a heartbeat rather
    /// than an empty array, so the timeout here is deliberately longer than the server's.
    public func events(queueID: String, lastEventID: Int) async throws -> EventBatch {
        let response: EventsResponse = try await send(
            .get, "events",
            parameters: ["queue_id": queueID, "last_event_id": String(lastEventID)],
            timeout: 120
        )
        let highest = response.events.map(\.id).max() ?? lastEventID
        return EventBatch(events: response.events.map { $0.decoded() }, lastEventID: highest)
    }

    public func deleteQueue(queueID: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(.delete, "events", parameters: ["queue_id": queueID])
    }
}

/// The server's view of what is unread. Zulip owns this, not the client: a message read on
/// another device has to show as read here too, so counts come from this rather than from
/// whatever happens to be in the local store.
public struct UnreadMessages: Decodable, Sendable {
    public struct Channel: Decodable, Sendable {
        public let stream_id: Int
        public let topic: String
        public let unread_message_ids: [Int]
    }

    public struct DirectMessage: Decodable, Sendable {
        public let other_user_id: Int
        public let unread_message_ids: [Int]
    }

    public struct GroupDirectMessage: Decodable, Sendable {
        /// Comma-separated, sorted, and includes the current user.
        public let user_ids_string: String
        public let unread_message_ids: [Int]
    }

    public let streams: [Channel]
    public let pms: [DirectMessage]
    public let huddles: [GroupDirectMessage]
    public let mentions: [Int]
    /// True once the server hit its 50,000 cap, meaning older unreads are simply not reported.
    public let old_unreads_missing: Bool?
}

extension ZulipClient {
    public func markRead(messageIDs: [Int]) async throws {
        guard !messageIDs.isEmpty else { return }
        struct Response: Decodable {}
        let _: Response = try await send(.post, "messages/flags", parameters: [
            "messages": Self.json(messageIDs),
            "op": "add",
            "flag": "read",
        ])
    }
}

/// The `local_id` a client sent, handed back on its echo. Documented as a string, but a
/// field of the wrong type must not fail the whole message event, so anything else
/// reads as no id at all.
struct LenientString: Decodable, Equatable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let integer = try? container.decode(Int.self) {
            value = String(integer)
        } else {
            value = nil
        }
    }
}
