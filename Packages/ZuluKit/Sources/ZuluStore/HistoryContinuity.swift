import Foundation
import GRDB
import ZulipAPI

/// One conversation, as its stored history is kept.
public enum StoredConversation: Hashable, Sendable {
    case topic(channelID: Int, name: String)
    case dm(key: String)

    init?(_ message: MessageRecord) {
        if let dmKey = message.dmKey {
            self = .dm(key: dmKey)
        } else if let channelID = message.channelID, let topic = message.topic {
            self = .topic(channelID: channelID, name: topic)
        } else {
            return nil
        }
    }

    /// The rows of `alias` that belong to this conversation.
    func rows(_ alias: String) -> SQL {
        switch self {
        case .topic(let channelID, let name):
            SQL(sql: "\(alias).channelID = ? AND \(alias).topic = ? AND \(alias).dmKey IS NULL", arguments: [channelID, name])
        case .dm(let key):
            SQL(sql: "\(alias).dmKey = ?", arguments: [key])
        }
    }

    var columns: StatementArguments {
        switch self {
        case .topic(let channelID, let name): [channelID, name, nil]
        case .dm(let key): [nil, nil, key]
        }
    }
}

/// Part of one conversation's history as the server returned it: every message the
/// conversation has from `from` through `through`.
public struct HistoryStretch: Sendable {
    public enum End: Sendable, Equatable {
        case message(Int)
        /// The newest message when it was fetched. Only the event queue that was current
        /// then delivers everything after it, so a stretch fetched under another queue
        /// vouches for no more than its own messages.
        case newest(queueID: String?)
    }

    public var conversation: StoredConversation
    public var messages: [ZulipMessage]
    /// `nil` when the stretch reaches back to the conversation's first message.
    public var from: Int?
    public var through: End

    public init(conversation: StoredConversation, messages: [ZulipMessage], from: Int?, through: End) {
        self.conversation = conversation
        self.messages = messages
        self.from = from
        self.through = through
    }

    /// A page fetched back from the newest message.
    public init(newest page: MessagesPage, in conversation: StoredConversation, queueID: String?) {
        self.init(
            conversation: conversation, messages: page.messages,
            from: page.reachesOldest ? nil : page.messages.map(\.id).min(),
            through: .newest(queueID: queueID)
        )
    }

    /// A page fetched back from just before `anchor`.
    public init(before anchor: Int, page: MessagesPage, in conversation: StoredConversation) {
        self.init(
            conversation: conversation, messages: page.messages,
            from: page.reachesOldest ? nil : page.messages.map(\.id).min() ?? anchor,
            through: .message(anchor - 1)
        )
    }

    /// Splits a page of the newest messages across every conversation into each one's
    /// newest stretch. A conversation's stretch starts where the page does, not at its own
    /// first message: nothing of it between the two exists.
    public static func newest(across page: MessagesPage, queueID: String?, selfUserID: Int) -> [HistoryStretch] {
        let from = page.reachesOldest ? nil : page.messages.map(\.id).min()
        let byConversation = Dictionary(grouping: page.messages) {
            StoredConversation(MessageRecord(from: $0, selfUserID: selfUserID))
        }
        return byConversation.compactMap { conversation, messages in
            conversation.map {
                HistoryStretch(conversation: $0, messages: messages, from: from, through: .newest(queueID: queueID))
            }
        }
    }
}

extension MessagesPage {
    /// Retention having removed what came before counts as the start: nothing older can
    /// be fetched.
    var reachesOldest: Bool { found_oldest || (history_limited ?? false) }
}

/// A conversation's stored messages are its history only back to its newest gap. Below a
/// gap they are kept, but not shown or paged through until a fetch shows they lead up to
/// what is above it.
extension ZuluStore {

    static func registerHistoryContinuityMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v19-history-gaps") { db in
            // Stored messages before this marked no gaps, and some have them. History is
            // refetched as conversations open. Migrations run with foreign keys off, so
            // the rows hanging off each message do not cascade and go first.
            try db.execute(sql: "DELETE FROM reaction")
            try db.execute(sql: "DELETE FROM submessage")
            try db.execute(sql: "DELETE FROM message")
            try db.create(table: "historyGap") { t in
                t.primaryKey("messageID", .integer)
                t.column("channelID", .integer)
                t.column("topic", .text)
                t.column("dmKey", .text)
            }
            try db.create(index: "historyGap_topic", on: "historyGap", columns: ["channelID", "topic", "messageID"])
            try db.create(index: "historyGap_dm", on: "historyGap", columns: ["dmKey", "messageID"])
            try db.create(table: "liveHistory") { t in
                t.column("channelID", .integer)
                t.column("topic", .text)
                t.column("dmKey", .text)
                t.column("queueID", .text).notNull()
            }
        }
    }

    /// Where `conversation`'s history starts: its newest gap, or 0 with none.
    static func historyFloor(_ conversation: StoredConversation) -> SQL {
        "COALESCE((SELECT MAX(g.messageID) FROM historyGap g WHERE \(conversation.rows("g"))), 0)"
    }

    /// Whether the message in row `m` is in its conversation's history.
    static let rowIsInHistory: SQL = """
        m.id >= COALESCE((SELECT MAX(g.messageID) FROM historyGap g
                           WHERE g.channelID IS m.channelID AND g.topic IS m.topic AND g.dmKey IS m.dmKey), 0)
        """

    public func holdsInHistory(_ messageID: Int) throws -> Bool {
        try holdsAnyInHistory([messageID])
    }

    public func holdsAnyInHistory(_ messageIDs: [Int]) throws -> Bool {
        guard !messageIDs.isEmpty else { return false }
        return try writer.read { db in
            try SQLRequest<Bool>(literal: """
                SELECT EXISTS (SELECT 1 FROM message m WHERE m.id IN \(messageIDs) AND \(Self.rowIsInHistory))
                """).fetchOne(db) ?? false
        }
    }

    public func save(_ stretch: HistoryStretch, selfUserID: Int) throws {
        try writer.write { db in try Self.save(stretch, selfUserID: selfUserID, in: db) }
    }

    public func save(_ stretches: [HistoryStretch], selfUserID: Int) throws {
        try writer.write { db in
            for stretch in stretches { try Self.save(stretch, selfUserID: selfUserID, in: db) }
        }
    }

    /// Saves only the stretches that reach what is already stored, so a conversation
    /// whose stored messages stop short of them gains no gap.
    public func extendHistory(with stretches: [HistoryStretch], selfUserID: Int) throws {
        try writer.write { db in
            for stretch in stretches {
                guard try Self.storedID(.max, in: stretch.conversation, from: stretch.from ?? 0, in: db) != nil
                else { continue }
                try Self.save(stretch, selfUserID: selfUserID, in: db)
            }
        }
    }

    /// A message from the event queue. Once one has arrived, the queue delivers every later
    /// one, but whatever came between the stored messages and it is unknown until the
    /// conversation's newest page is fetched.
    public func saveArrival(_ message: ZulipMessage, selfUserID: Int) throws {
        let record = MessageRecord(from: message, selfUserID: selfUserID)
        guard let conversation = StoredConversation(record) else { return }
        try writer.write { db in
            let queueID = try Self.currentQueueID(in: db)
            let isLive = try queueID != nil && Self.liveQueueID(of: conversation, in: db) == queueID
            if !isLive, try !MessageRecord.exists(db, key: message.id),
               try Self.storedID(.max, in: conversation, before: message.id, in: db) != nil
            {
                try Self.markGap(at: message.id, in: conversation, db)
            }
            try Self.write(message, selfUserID: selfUserID, in: db)
            if let queueID { try Self.markLive(conversation, queueID: queueID, in: db) }
        }
    }

    private static func save(_ stretch: HistoryStretch, selfUserID: Int, in db: Database) throws {
        let conversation = stretch.conversation
        let isLive: Bool
        let through: Int?
        switch stretch.through {
        case .message(let id):
            isLive = false
            through = id
        case .newest(let queueID):
            isLive = try queueID != nil && queueID == currentQueueID(in: db)
            guard isLive || !stretch.messages.isEmpty else { return }
            through = isLive ? nil : stretch.messages.map(\.id).max()
        }
        let from = stretch.from ?? 0

        let reachedBelow = try reachesBelow(from, in: conversation, db)
        let lastBefore = try through.flatMap { try storedID(.max, in: conversation, from: from, through: $0, in: db) }

        try db.execute(literal: """
            DELETE FROM historyGap AS g
             WHERE \(conversation.rows("g")) AND g.messageID > \(from) AND g.messageID <= \(through.map { $0 + 1 } ?? Int.max)
            """)
        for message in stretch.messages { try write(message, selfUserID: selfUserID, in: db) }

        if !reachedBelow, let first = try storedID(.min, in: conversation, from: from, in: db) {
            try markGap(at: first, in: conversation, db)
        }
        if let through,
           let above = try storedID(.min, in: conversation, before: nil, after: through, in: db),
           above > through + 1,
           try storedID(.max, in: conversation, from: from, through: through, in: db) != lastBefore
        {
            try markGap(at: above, in: conversation, db)
        }
        if isLive, let queueID = try currentQueueID(in: db) {
            try markLive(conversation, queueID: queueID, in: db)
        }
    }

    /// Whether a stretch starting at `from` joins what is stored below it: it starts right
    /// after it, or what is stored from `from` on already did.
    private static func reachesBelow(_ from: Int, in conversation: StoredConversation, _ db: Database) throws -> Bool {
        guard let below = try storedID(.max, in: conversation, before: from, in: db) else { return true }
        if below + 1 == from { return true }
        guard let first = try storedID(.min, in: conversation, from: from, in: db) else { return false }
        return try !gapExists(in: conversation, after: below, through: first, db)
    }

    private enum Extreme: String {
        case min = "MIN"
        case max = "MAX"
    }

    private static func storedID(
        _ extreme: Extreme, in conversation: StoredConversation,
        from: Int? = nil, through: Int? = nil, before: Int? = nil, after: Int? = nil, in db: Database
    ) throws -> Int? {
        var bounds: [SQL] = [conversation.rows("m")]
        if let from { bounds.append("m.id >= \(from)") }
        if let through { bounds.append("m.id <= \(through)") }
        if let before { bounds.append("m.id < \(before)") }
        if let after { bounds.append("m.id > \(after)") }
        return try SQLRequest<Int?>(literal: """
            SELECT \(sql: extreme.rawValue)(m.id) FROM message m WHERE \(bounds.joined(separator: " AND "))
            """).fetchOne(db) ?? nil
    }

    private static func gapExists(in conversation: StoredConversation, after low: Int, through high: Int, _ db: Database)
        throws -> Bool
    {
        try SQLRequest<Bool>(literal: """
            SELECT EXISTS (SELECT 1 FROM historyGap g
                            WHERE \(conversation.rows("g")) AND g.messageID > \(low) AND g.messageID <= \(high))
            """).fetchOne(db) ?? false
    }

    private static func markGap(at messageID: Int, in conversation: StoredConversation, _ db: Database) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO historyGap (channelID, topic, dmKey, messageID) VALUES (?, ?, ?, ?)",
            arguments: conversation.columns + [messageID]
        )
    }

    private static func currentQueueID(in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT queueID FROM syncState")
    }

    private static func liveQueueID(of conversation: StoredConversation, in db: Database) throws -> String? {
        try SQLRequest<String>(literal: "SELECT l.queueID FROM liveHistory l WHERE \(conversation.rows("l"))")
            .fetchOne(db)
    }

    private static func markLive(_ conversation: StoredConversation, queueID: String, in db: Database) throws {
        try db.execute(literal: "DELETE FROM liveHistory AS l WHERE \(conversation.rows("l"))")
        try db.execute(
            sql: "INSERT INTO liveHistory (channelID, topic, dmKey, queueID) VALUES (?, ?, ?, ?)",
            arguments: conversation.columns + [queueID]
        )
    }
}
