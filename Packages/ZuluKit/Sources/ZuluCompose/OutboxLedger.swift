import Foundation

public enum DeliveryState: Equatable, Sendable {
    case delivering
    case failed(String)
}

/// Messages sent from this device that have not shown up in their conversation yet, and
/// what is known about each: whether the server took it, and under which id.
///
/// `Payload` is whatever the app needs to redraw and resend the message.
public struct OutboxLedger<Payload: Sendable>: Sendable {
    public struct Entry: Identifiable, Sendable {
        public let id: UUID
        /// A `ConversationKey`, the same string an echo is matched against.
        public let conversation: String
        public let createdAt: Date
        public let payload: Payload
        public fileprivate(set) var state: DeliveryState = .delivering
        /// From the send reply or from the echo, whichever lands first.
        public fileprivate(set) var sentID: Int?
        /// The last attempt named this client's event queue, so its echo will carry
        /// `localID` and needs no guessing.
        public fileprivate(set) var tagged = false

        /// Sent as Zulip's `local_id` and handed back on the echo.
        public var localID: String { id.uuidString }
    }

    public struct Pending: Identifiable, Equatable, Sendable {
        public let entry: Entry
        public let startsGroup: Bool

        public var id: UUID { entry.id }
    }

    /// The newest message already shown, which decides whether the first pending one
    /// opens a group of its own.
    public struct Preceding: Sendable {
        public let senderID: Int
        public let date: Date

        public init(senderID: Int, date: Date) {
            self.senderID = senderID
            self.date = date
        }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public func entry(_ id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    public func entries(in conversation: String) -> [Entry] {
        entries.filter { $0.conversation == conversation }
    }

    @discardableResult
    public mutating func add(_ payload: Payload, in conversation: String, at date: Date, id: UUID = UUID()) -> UUID {
        entries.append(Entry(id: id, conversation: conversation, createdAt: date, payload: payload))
        return id
    }

    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func attempting(_ id: UUID, tagged: Bool) {
        update(id) {
            $0.state = .delivering
            $0.tagged = tagged
        }
    }

    /// Also clears a timeout, since a reply that arrives late is still a success.
    public mutating func sent(_ id: UUID, as messageID: Int) {
        update(id) {
            $0.sentID = messageID
            $0.state = .delivering
        }
    }

    public mutating func failed(_ id: UUID, reason: String) {
        update(id) { $0.state = .failed(reason) }
    }

    /// Ignored once the server has answered: the message went, however slowly.
    public mutating func timedOut(_ id: UUID, reason: String) {
        update(id) {
            guard $0.sentID == nil, $0.state == .delivering else { return }
            $0.state = .failed(reason)
        }
    }

    /// The echo of a message this account sent, from this device or another.
    ///
    /// With a `localID` it names its send exactly. Without one it may still be ours,
    /// sent while the queue was being registered, so it goes to the oldest untagged
    /// send still waiting in that conversation. That lets the pending row step aside as
    /// soon as the real one lands, rather than both showing until the reply arrives.
    public mutating func echoed(messageID: Int, localID: String?, in conversation: String) {
        if let localID {
            // Only the sending queue is told the id, so an unmatched one is a send that
            // has already been settled, never someone else's to claim.
            guard let index = entries.firstIndex(where: { $0.localID == localID }) else { return }
            entries[index].sentID = messageID
            entries[index].state = .delivering
            return
        }
        guard !entries.contains(where: { $0.sentID == messageID }),
              let index = entries.firstIndex(where: {
                  $0.conversation == conversation && $0.sentID == nil && !$0.tagged && $0.state == .delivering
              })
        else { return }
        entries[index].sentID = messageID
    }

    /// Drops what is now in the conversation. Called in the same update that puts it
    /// there, so no frame shows neither the pending row nor the real one.
    public mutating func settle(landed ids: Set<Int>) {
        entries.removeAll { $0.sentID.map(ids.contains) ?? false }
    }

    /// What a conversation should draw under its history: every entry whose real
    /// message is not on screen yet, grouped by the rule the history uses, so a message
    /// keeps its header, or its lack of one, when the real one replaces it.
    public func pending(
        in conversation: String,
        shown: Set<Int>,
        after preceding: Preceding?,
        selfUserID: Int?,
        groupingWindow: TimeInterval
    ) -> [Pending] {
        var previous = preceding
        return entries(in: conversation)
            .filter { $0.sentID.map { !shown.contains($0) } ?? true }
            .map { entry in
                defer { previous = selfUserID.map { Preceding(senderID: $0, date: entry.createdAt) } }
                let continues = previous.map {
                    $0.senderID == selfUserID && entry.createdAt.timeIntervalSince($0.date) < groupingWindow
                } ?? false
                return Pending(entry: entry, startsGroup: !continues)
            }
    }

    private mutating func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }
}

extension OutboxLedger.Entry: Equatable {
    /// The payload never changes once an entry is made, so the id stands in for it.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.state == rhs.state && lhs.sentID == rhs.sentID && lhs.tagged == rhs.tagged
    }
}
