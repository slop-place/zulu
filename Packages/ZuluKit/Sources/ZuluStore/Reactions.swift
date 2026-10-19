import Foundation
import GRDB

/// One chip: everyone who reacted to a message with the same emoji.
///
/// Keyed by `(reactionType, emojiCode)`, which is what the server's own uniqueness
/// constraint uses. `angry` and `angry_face` are one emoji under two names, and an older
/// client may have submitted either, so grouping by name splits one chip into two.
public struct ReactionGroup: Sendable, Equatable, Identifiable {
    public let reactionType: String
    public let emojiCode: String
    /// What the chip shows and what adding to it sends. Picked by how many reactors used
    /// it rather than by row order, so the chip does not rename itself as people come and go.
    public let emojiName: String
    public let userIDs: [Int]
    public let includesSelf: Bool

    public var id: String { "\(reactionType):\(emojiCode)" }
    public var count: Int { userIDs.count }

    public init(
        reactionType: String, emojiCode: String, emojiName: String,
        userIDs: [Int], includesSelf: Bool
    ) {
        self.reactionType = reactionType
        self.emojiCode = emojiCode
        self.emojiName = emojiName
        self.userIDs = userIDs
        self.includesSelf = includesSelf
    }
}

/// Which way a tap moves a reaction, and the exact triple to send either way.
///
/// Named rather than worked out again at the call site, so the optimistic local write and
/// the request that follows it cannot disagree about which direction the toggle went.
public struct ReactionToggle: Sendable, Equatable {
    public let adds: Bool
    public let emojiName: String
    public let emojiCode: String
    public let reactionType: String
}

extension ReactionGroup {

    /// Groups in first-appearance order, so a chip keeps its place while other people react.
    ///
    /// Pass the records in the order they were written and that order is the order the
    /// reactions arrived in.
    public static func group(_ records: [ReactionRecord], selfUserID: Int?) -> [ReactionGroup] {
        var order: [String] = []
        var rows: [String: [ReactionRecord]] = [:]

        for record in records {
            let key = "\(record.reactionType):\(record.emojiCode)"
            if rows[key] == nil { order.append(key) }
            rows[key, default: []].append(record)
        }

        return order.compactMap { key in
            guard let group = rows[key], let first = group.first else { return nil }
            return ReactionGroup(
                reactionType: first.reactionType,
                emojiCode: first.emojiCode,
                emojiName: displayName(among: group),
                userIDs: group.map(\.userID).sorted(),
                includesSelf: selfUserID.map { me in group.contains { $0.userID == me } } ?? false
            )
        }
    }

    /// Ties break alphabetically rather than by row order, so two people reacting under
    /// two aliases still name the chip the same way on every device.
    private static func displayName(among records: [ReactionRecord]) -> String {
        var counts: [String: Int] = [:]
        for record in records { counts[record.emojiName, default: 0] += 1 }
        return counts.max { left, right in
            left.value == right.value ? left.key > right.key : left.value < right.value
        }?.key ?? ""
    }

    /// What tapping this emoji should do, whether or not a chip for it exists yet.
    ///
    /// Removal sends the name the reaction was stored under: the server matches on the
    /// code, but it still rejects a name that does not resolve to that code.
    public static func toggle(
        emojiName: String, emojiCode: String, reactionType: String,
        in records: [ReactionRecord], by userID: Int
    ) -> ReactionToggle {
        let mine = records.first {
            $0.reactionType == reactionType && $0.emojiCode == emojiCode && $0.userID == userID
        }
        return ReactionToggle(
            adds: mine == nil,
            emojiName: mine?.emojiName ?? emojiName,
            emojiCode: emojiCode,
            reactionType: reactionType
        )
    }
}

/// How often one emoji is reacted with across everything stored, which is how the quick
/// row learns what this realm actually reaches for.
public struct ReactionTally: Decodable, FetchableRecord, Sendable, Equatable, Identifiable {
    public var reactionType: String
    public var emojiCode: String
    public var emojiName: String
    public var uses: Int

    public var id: String { "\(reactionType):\(emojiCode)" }
}

// MARK: - The viewer's own history

extension ZuluStore {
    /// Every emoji the viewer has reacted with from this device, so the quick row can be
    /// their own habits rather than the realm's. Never synced: it is a preference, and
    /// the server has no slot for one.
    static func registerReactionHistoryMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v16-reaction-history") { db in
            try db.create(table: "reactionHistory") { t in
                t.column("reactionType", .text).notNull()
                t.column("emojiCode", .text).notNull()
                t.column("emojiName", .text).notNull()
                t.column("uses", .integer).notNull().defaults(to: 0)
                t.column("lastUsedAt", .integer).notNull()
                // Uses, each worth less the older it is: see `recordReaction`.
                t.column("score", .double).notNull().defaults(to: 0)
                t.primaryKey(["reactionType", "emojiCode"])
            }
        }
    }

    /// How fast a use fades. Something reacted with once today outranks something
    /// reacted with five times a month ago; something reacted with daily stays near the
    /// top through a quiet week.
    static let reactionHalfLife: TimeInterval = 2 * 24 * 60 * 60

    static func decayedScore(_ score: Double, from lastUsedAt: Int, to now: Date) -> Double {
        let age = max(0, now.timeIntervalSince1970 - TimeInterval(lastUsedAt))
        return score * pow(0.5, age / reactionHalfLife)
    }

    public func recordReaction(emojiName: String, emojiCode: String, reactionType: String, at date: Date = .now) throws {
        try writer.write { db in
            let previous = try Row.fetchOne(db, sql: """
                SELECT score, lastUsedAt FROM reactionHistory WHERE reactionType = ? AND emojiCode = ?
                """, arguments: [reactionType, emojiCode])
            let carried = previous.map { Self.decayedScore($0["score"], from: $0["lastUsedAt"], to: date) } ?? 0
            try db.execute(sql: """
                INSERT INTO reactionHistory (reactionType, emojiCode, emojiName, uses, lastUsedAt, score)
                VALUES (?, ?, ?, 1, ?, ?)
                ON CONFLICT (reactionType, emojiCode) DO UPDATE
                   SET uses = uses + 1, lastUsedAt = excluded.lastUsedAt,
                       emojiName = excluded.emojiName, score = excluded.score
                """, arguments: [reactionType, emojiCode, emojiName, Int(date.timeIntervalSince1970), carried + 1])
        }
    }

    /// The viewer's reactions, the ones that matter now first: a recent use counts for
    /// much more than an old one, and repeated use still counts. Sorted here rather
    /// than in SQL, because the table is a few dozen rows and SQLite has no `pow`.
    public func recentReactions(limit: Int, now: Date = .now) throws -> [ReactionTally] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT reactionType, emojiCode, emojiName, uses, lastUsedAt, score FROM reactionHistory
                """)
            return try rows
                .map { row in
                    (tally: try ReactionTally(row: row), weight: Self.decayedScore(row["score"], from: row["lastUsedAt"], to: now))
                }
                .sorted { $0.weight > $1.weight }
                .prefix(limit)
                .map(\.tally)
        }
    }

    /// The viewer's reactions on the messages held locally, newest first: history from
    /// before this device started keeping its own.
    public func ownReactions(by userID: Int, limit: Int) throws -> [ReactionTally] {
        try writer.read { db in
            try ReactionTally.fetchAll(db, sql: """
                SELECT r.reactionType, r.emojiCode, r.emojiName, COUNT(*) AS uses,
                       MAX(r.messageID) AS latest
                  FROM reaction r
                 WHERE r.userID = ?
                 GROUP BY r.reactionType, r.emojiCode
                 ORDER BY latest DESC
                 LIMIT ?
                """, arguments: [userID, limit])
        }
    }
}

extension ReactionRecord {
    public init(messageID: Int, emojiName: String, emojiCode: String, reactionType: String, userID: Int) {
        self.messageID = messageID
        self.emojiName = emojiName
        self.emojiCode = emojiCode
        self.reactionType = reactionType
        self.userID = userID
    }
}

extension ZuluStore {

    /// Rows in the order they were written, which is the order the reactions happened:
    /// a message's payload lists them chronologically and events arrive in sequence.
    public func observeReactions(forMessage id: Int)
        -> ValueObservation<ValueReducers.Fetch<[ReactionRecord]>>
    {
        ValueObservation.tracking { db in
            try ReactionRecord.fetchAll(
                db, sql: "SELECT * FROM reaction WHERE messageID = ? ORDER BY rowid", arguments: [id]
            )
        }
    }

    public func reactionGroups(forMessage id: Int, selfUserID: Int?) throws -> [ReactionGroup] {
        let records = try writer.read { db in
            try ReactionRecord.fetchAll(
                db, sql: "SELECT * FROM reaction WHERE messageID = ? ORDER BY rowid", arguments: [id]
            )
        }
        return ReactionGroup.group(records, selfUserID: selfUserID)
    }

    /// The emoji this realm reacts with most, most-used first.
    ///
    /// The inner select picks each emoji's most-used alias, because the outer grouping is
    /// by code and a code has no one name.
    public func popularReactions(limit: Int = 8) throws -> [ReactionTally] {
        try writer.read { db in
            try ReactionTally.fetchAll(db, sql: """
                SELECT r.reactionType, r.emojiCode, COUNT(*) AS uses,
                       (SELECT alias.emojiName FROM reaction alias
                         WHERE alias.reactionType = r.reactionType
                           AND alias.emojiCode = r.emojiCode
                         GROUP BY alias.emojiName
                         ORDER BY COUNT(*) DESC, alias.emojiName
                         LIMIT 1) AS emojiName
                  FROM reaction r
                 GROUP BY r.reactionType, r.emojiCode
                 ORDER BY uses DESC, r.emojiCode
                 LIMIT ?
                """, arguments: [limit])
        }
    }

    /// Applies a reaction locally before the server has confirmed it. The event queue
    /// echoes the same change back, and both writes are keyed the same way, so the echo
    /// lands on top of this without duplicating it.
    public func setReaction(
        onMessage id: Int, emojiName: String, emojiCode: String, reactionType: String,
        userID: Int, present: Bool
    ) throws {
        try writer.write { db in
            if present {
                try ReactionRecord(
                    messageID: id, emojiName: emojiName, emojiCode: emojiCode,
                    reactionType: reactionType, userID: userID
                ).save(db)
            } else {
                try ReactionRecord
                    .filter(Column("messageID") == id
                        && Column("emojiCode") == emojiCode
                        && Column("reactionType") == reactionType
                        && Column("userID") == userID)
                    .deleteAll(db)
            }
        }
    }
}

extension ZuluStore {
    /// Every reaction in the store, for one observation per conversation rather than one
    /// per visible message. The table holds only reactions on messages we already have, so
    /// it stays small, and grouping in memory is cheaper than a query per row.
    public func observeAllReactions()
        -> ValueObservation<ValueReducers.Fetch<[ReactionRecord]>>
    {
        ValueObservation.tracking { db in
            try ReactionRecord.fetchAll(db, sql: "SELECT * FROM reaction ORDER BY rowid")
        }
    }
}
