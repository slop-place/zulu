import Foundation

public struct Reaction: Decodable, Sendable, Equatable, Hashable {
    public let emoji_name: String
    public let emoji_code: String
    public let reaction_type: String
    public let user_id: Int

    /// Aliases share a code but not a name, so grouping by name would double-count.
    public var groupingKey: String { "\(reaction_type):\(emoji_code)" }
}

/// One entry in a message's widget log. `content` is a JSON document carried as a string,
/// and its schema depends on where in the log the entry sits: the lowest id declares the
/// widget, everything after it is an event.
public struct Submessage: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let message_id: Int
    /// Whoever added this entry, not necessarily the message's sender.
    public let sender_id: Int
    public let msg_type: String
    public let content: String

    public init(id: Int, message_id: Int, sender_id: Int, msg_type: String, content: String) {
        self.id = id
        self.message_id = message_id
        self.sender_id = sender_id
        self.msg_type = msg_type
        self.content = content
    }
}

public struct DisplayRecipient: Decodable, Sendable, Equatable {
    public let id: Int
    public let email: String?
    public let full_name: String
}

public enum MessageFlag {
    public static let read = "read"
}

/// How a message addresses you, from the flags the server sets. The text is never
/// re-read: a wildcard inside a code block, or a silent mention, sets no flag.
public enum Mention: Sendable, Equatable {
    case none
    /// `@all`, `@topic` and the like.
    case wildcard
    /// You, or a group you are in. Only this gets through a mute.
    case personal

    private static let personalFlag = "mentioned"
    /// `wildcard_mentioned` is what servers before feature level 224 send for both.
    private static let wildcardFlags: Set = ["stream_wildcard_mentioned", "topic_wildcard_mentioned", "wildcard_mentioned"]

    public init(flags: [String]) {
        if flags.contains(Self.personalFlag) {
            self = .personal
        } else if flags.contains(where: Self.wildcardFlags.contains) {
            self = .wildcard
        } else {
            self = .none
        }
    }
}

public struct ZulipMessage: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let sender_id: Int
    public let sender_full_name: String
    public let sender_email: String
    public let type: String
    /// Rendered HTML, since requests set `apply_markdown`.
    public let content: String
    public let content_type: String
    /// The topic. Still spelled `subject` on the wire; empty for direct messages.
    public let subject: String
    public let timestamp: Int
    public let stream_id: Int?
    public let avatar_url: String?
    public let is_me_message: Bool
    public let reactions: [Reaction]
    public let flags: [String]?
    public let last_edit_timestamp: Int?
    /// Present on both `GET /messages` and the `message` event, so a poll never needs a
    /// fetch of its own. Optional because the field is documented as experimental.
    public let submessages: [Submessage]?

    /// A channel name for channel messages, the participant list for DMs.
    public let display_recipient: DisplayRecipientField?

    public var isChannelMessage: Bool { type == "stream" }
    /// The server leaves the raw `/poll` text in `content` and renders it as an ordinary
    /// paragraph, so a message carrying a widget has to be drawn from the log instead.
    public var hasWidget: Bool { submessages?.contains { $0.msg_type == "widget" } ?? false }
    public var isRead: Bool { flags?.contains(MessageFlag.read) ?? false }
    public var mention: Mention { Mention(flags: flags ?? []) }
    public var isMentioned: Bool { mention != .none }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    public var dmParticipants: [DisplayRecipient] {
        if case .users(let users) = display_recipient { return users }
        return []
    }

    public var channelName: String? {
        if case .channel(let name) = display_recipient { return name }
        return nil
    }
}

/// One wire field with two shapes: a channel name, or the people in a DM.
public enum DisplayRecipientField: Decodable, Sendable, Equatable {
    case channel(String)
    case users([DisplayRecipient])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self = .channel(name)
        } else {
            self = .users(try container.decode([DisplayRecipient].self))
        }
    }
}

public struct Subscription: Decodable, Sendable, Equatable, Identifiable {
    public let stream_id: Int
    public let name: String
    public let description: String?
    public let color: String?
    public let invite_only: Bool?
    public let is_muted: Bool?
    public let pin_to_top: Bool?
    public let desktop_notifications: Bool?
    public let push_notifications: Bool?
    public let is_web_public: Bool?
    /// Only present when the request asked for subscribers. Used to rank the people in
    /// a channel's `@` list above everyone else.
    public let subscribers: [Int]?

    public var id: Int { stream_id }
    public var isRestricted: Bool { invite_only ?? false }
}

public struct ChannelTopic: Decodable, Sendable, Equatable, Identifiable {
    public let name: String
    public let max_id: Int

    public var id: String { name }
}

public struct ZulipUser: Decodable, Sendable, Equatable, Identifiable {
    public let user_id: Int
    public let full_name: String
    public let email: String?
    public let avatar_url: String?
    public let is_bot: Bool?
    public let is_active: Bool?
    public let role: Int?

    public var id: Int { user_id }
}

/// A narrow filter. Zulip accepts the object form on every modern server.
public struct NarrowFilter: Encodable, Sendable, Equatable {
    public let operator_: String
    public let operand: Operand
    public let negated: Bool

    public enum Operand: Encodable, Sendable, Equatable {
        case text(String)
        case number(Int)
        case numbers([Int])

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .numbers(let values): try container.encode(values)
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case operator_ = "operator"
        case operand, negated
    }

    public init(_ operator_: String, _ operand: Operand, negated: Bool = false) {
        self.operator_ = operator_
        self.operand = operand
        self.negated = negated
    }

    public static func channel(_ id: Int) -> NarrowFilter { .init("channel", .number(id)) }
    public static func topic(_ name: String) -> NarrowFilter { .init("topic", .text(name)) }
    public static func dm(_ userIDs: [Int]) -> NarrowFilter { .init("dm", .numbers(userIDs)) }
}

extension NarrowFilter {
    /// `is:dm` replaced `is:private` at feature level 177.
    public static let directMessages = NarrowFilter("is", .text("dm"))
}
