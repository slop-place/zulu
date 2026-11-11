import Foundation

/// A link to a place in the realm, as Zulip writes them into messages: a channel, a
/// topic, a direct message, or one message in any of those.
///
/// Anything else a narrow can say (a search, a sender, a negated term) is not a place
/// the app can open, so such a link reads as nil and is left to the browser.
public struct NarrowLink: Equatable, Sendable {
    public enum Place: Equatable, Sendable {
        case channel(Int)
        case topic(channelID: Int, name: String)
        /// The other people in the conversation, or only the viewer in notes to self.
        case dm(userIDs: [Int])
    }

    /// Nil only for a link to a message that names nothing else.
    public let place: Place?
    public let messageID: Int?

    public init(place: Place?, messageID: Int? = nil) {
        self.place = place
        self.messageID = messageID
    }

    private static let narrowPrefix = "narrow/"

    /// Reads `url` as a link into `realm`. A link written relative to the realm counts.
    public init?(_ url: URL, realm: URL) {
        let absolute = url.absoluteURL
        guard absolute.host() == realm.host(),
              let fragment = absolute.fragment(percentEncoded: true),
              fragment.hasPrefix(Self.narrowPrefix)
        else { return nil }
        self.init(narrow: String(fragment.dropFirst(Self.narrowPrefix.count)))
    }

    /// The operators Zulip has used for each term over the years, all still in old messages.
    private enum Operator {
        static let channel: Set = ["channel", "stream"]
        static let topic: Set = ["topic", "subject"]
        static let dm: Set = ["dm", "pm-with"]
        static let message: Set = ["near", "with", "id"]
    }

    /// `narrow` is the part after `#narrow/`: operator and operand, in turns.
    init?(narrow: String) {
        let parts = narrow.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count.isMultiple(of: 2) else { return nil }

        var channelID: Int?
        var topic: String?
        var dmUserIDs: [Int]?
        var messageID: Int?
        for pair in stride(from: 0, to: parts.count, by: 2) {
            let name = parts[pair], operand = parts[pair + 1]
            if Operator.channel.contains(name) {
                guard let id = Self.leadingIDs(of: operand)?.only else { return nil }
                channelID = id
            } else if Operator.topic.contains(name) {
                guard let decoded = Self.decodeHashComponent(operand) else { return nil }
                topic = decoded
            } else if Operator.dm.contains(name) {
                guard let ids = Self.leadingIDs(of: operand) else { return nil }
                dmUserIDs = ids
            } else if Operator.message.contains(name) {
                guard let id = Int(operand) else { return nil }
                messageID = id
            } else {
                return nil
            }
        }

        let place: Place?
        switch (channelID, topic, dmUserIDs) {
        case (let channel?, let topic?, nil): place = .topic(channelID: channel, name: topic)
        case (let channel?, nil, nil): place = .channel(channel)
        case (nil, nil, let ids?): place = .dm(userIDs: ids)
        case (nil, nil, nil) where messageID != nil: place = nil
        // A topic with no channel, or a channel and a DM together, is no one place.
        default: return nil
        }
        self.init(place: place, messageID: messageID)
    }

    /// Channels are written `12-core-infra-meta` and conversations `8,12-group`: the ids
    /// up to the first dash, then a readable name nothing depends on.
    private static func leadingIDs(of operand: String) -> [Int]? {
        let ids = operand.prefix { $0 != "-" }.split(separator: ",").map { Int($0) }
        guard !ids.isEmpty, !ids.contains(nil) else { return nil }
        return ids.compactMap { $0 }
    }

    /// Zulip percent-encodes a term and then writes every `%` as `.`, so a URL never
    /// gets the chance to decode it on the way: `.20` is a space and `.2E` a dot.
    static func decodeHashComponent(_ component: String) -> String? {
        component.replacingOccurrences(of: ".", with: "%").removingPercentEncoding
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
