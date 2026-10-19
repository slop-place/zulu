import Foundation

/// Every emoji this realm can express, from all three of Zulip's tables, with one
/// ranking used by both the picker and the `:` autocomplete.
///
/// The catalogue is a value, rebuilt whenever the realm's custom emoji change or the
/// server's unicode table finally arrives. Nothing in it is mutable, so a view can hold
/// one and a background fetch can build the next without either waiting on the other.
public struct EmojiCatalogue: Sendable, Equatable {

    public static let empty = EmojiCatalogue()

    /// Every emoji that can be typed today, pre-ordered. Ranking is a stable sort over
    /// this list, so this order is what decides ties: popular first, then unicode,
    /// then the realm's own.
    public let candidates: [Emoji]

    /// Name to emoji, already resolved in the server's precedence order, so a lookup
    /// here agrees with what the server will render.
    private let byName: [String: Emoji]

    /// Keyed by emoji code, deactivated emoji included. A reaction on a since-retired
    /// emoji still has to draw, which is why this is not the same set as `candidates`.
    private let realmByCode: [String: RealmEmojiItem]

    private let popular: Set<String>

    public init(unicode: ServerEmojiData? = nil, realmEmoji: [RealmEmojiItem] = []) {
        let active = realmEmoji.filter { !$0.deactivated }
        // An active realm emoji shadows the unicode emoji of the same name, so the
        // shadowed name is removed from the unicode entry outright — otherwise the
        // picker would offer a name the server resolves to something else.
        let shadowed = Set(active.map(\.name))
        let realmClaimsZulip = shadowed.contains(EmojiCode.zulipExtraName)

        var unicodeEmoji: [Emoji] = []
        // The server sends a JSON object and Swift dictionaries have no order, so the
        // codes are sorted to make the catalogue — and every tie broken by it —
        // identical on every launch. Zulip publishes no category data over its API,
        // so codepoint order is the only grouping available.
        for code in (unicode?.codeToNames.keys).map({ $0.sorted() }) ?? [] {
            var names = unicode?.codeToNames[code] ?? []
            names.removeAll { shadowed.contains($0) || $0 == EmojiCode.zulipExtraName }
            guard let canonical = names.first else { continue }
            unicodeEmoji.append(Emoji(
                kind: .unicode,
                code: code,
                name: canonical,
                aliases: Array(names.dropFirst())
            ))
        }

        let popularCodes = Set(EmojiCode.popularCodes)
        let byCode = Dictionary(unicodeEmoji.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        let popularEmoji = EmojiCode.popularCodes.compactMap { byCode[$0] }

        let realmCandidates = active.map {
            Emoji(
                kind: .realm,
                code: $0.code,
                name: $0.name,
                imageURL: $0.sourceURL,
                stillURL: $0.stillURL
            )
        }
        let zulipExtra = Emoji(
            kind: .zulipExtra,
            code: EmojiCode.zulipExtraName,
            name: EmojiCode.zulipExtraName,
            imageURL: EmojiCode.zulipExtraImageURL
        )

        candidates = popularEmoji
            + unicodeEmoji.filter { !popularCodes.contains($0.code) }
            + realmCandidates
            + (realmClaimsZulip ? [] : [zulipExtra])

        // Zulip's own resolution order, from `get_emoji_data`: active realm emoji, then
        // `:zulip:`, then the unicode table. Anything else is left as literal text.
        var names: [String: Emoji] = [:]
        for emoji in realmCandidates { names[emoji.name] = emoji }
        if !realmClaimsZulip { names[EmojiCode.zulipExtraName] = zulipExtra }
        for emoji in unicodeEmoji {
            for name in emoji.allNames where names[name] == nil { names[name] = emoji }
        }
        byName = names

        realmByCode = Dictionary(realmEmoji.map { ($0.code, $0) }, uniquingKeysWith: { _, last in last })
        popular = popularCodes
        unicodeCount = unicodeEmoji.count
    }

    /// False until the server's table has been fetched. `:zulip:` and the realm's own
    /// emoji are always present, so an empty candidate list is not the same question.
    public var hasUnicodeTable: Bool { unicodeCount > 0 }

    private let unicodeCount: Int

    /// What the composer's `:name:` will turn into when the server renders it.
    public func resolve(name: String) -> Emoji? { byName[name] }

    /// How to draw a reaction, which names an emoji by type and code rather than by name.
    ///
    /// Every failure resolves to the literal `:name:` instead of dropping the reaction,
    /// which is what the server's own markdown does with a name it cannot resolve.
    public func display(kind: EmojiKind, code: String, name: String) -> EmojiDisplay {
        switch kind {
        case .unicode:
            guard let glyph = EmojiCode.glyph(for: code) else { return .text(":\(name):") }
            return .glyph(glyph)
        case .realm:
            guard let item = realmByCode[code] else { return .text(":\(name):") }
            return .image(url: item.sourceURL, still: item.stillURL)
        case .zulipExtra:
            return .image(url: EmojiCode.zulipExtraImageURL, still: nil)
        }
    }

    public func display(reactionType: String, code: String, name: String) -> EmojiDisplay {
        guard let kind = EmojiKind(rawValue: reactionType) else { return .text(":\(name):") }
        return display(kind: kind, code: code, name: name)
    }

    /// Every match for a query, each with the bucket it belongs in.
    ///
    /// An empty query matches everything at `prefix` quality, which is what makes the
    /// picker and the `:` autocomplete one piece of code: with nothing typed the ranking
    /// degrades to popular emoji, then the realm's own, then everything else.
    public func ranked(_ rawQuery: String) -> [(element: Emoji, rank: Int)] {
        let query = EmojiQuery(rawQuery)
        var results: [(element: Emoji, rank: Int)] = []
        results.reserveCapacity(candidates.count)
        for emoji in candidates {
            guard let quality = query.quality(of: emoji) else { continue }
            results.append((emoji, EmojiQuery.rank(
                quality: quality,
                isPopular: popular.contains(emoji.code) && emoji.kind == .unicode,
                isCustom: emoji.isCustom
            )))
        }
        return results
    }

    public func search(_ rawQuery: String, limit: Int? = nil) -> [Emoji] {
        let sorted = Ranked.sorted(ranked(rawQuery), buckets: EmojiQuery.rankCount)
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }
}

/// A query typed after `:`, or into the picker's search field.
public struct EmojiQuery: Sendable, Equatable {
    /// Ranks, best first. Popular and custom emoji are lifted above plain unicode ones
    /// at the same match quality — this table is zulip-flutter's, and is the whole of
    /// "realm custom emoji first".
    public static let rankCount = 9

    let normalized: String
    let words: [Substring]
    /// Set when the person typed or pasted the emoji itself rather than its name.
    let glyph: String?

    public init(_ raw: String) {
        // Spaces become underscores because that is how Zulip spells emoji names, so
        // "thumbs up" finds `thumbs_up`.
        let spaced = raw.replacingOccurrences(of: " ", with: "_")
        normalized = MatchText.normalized(spaced)
        words = MatchText.words(normalized)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        glyph = trimmed.isEmpty ? nil : EmojiCode.unqualified(trimmed)
    }

    public func quality(of emoji: Emoji) -> MatchQuality? {
        // A pasted glyph carries no variation selector by the time it is compared, so
        // `❤️` finds `2764` — the case web gets wrong.
        if let glyph, emoji.glyph.map(EmojiCode.unqualified) == glyph { return .exact }

        var best: MatchQuality?
        for name in emoji.allNames {
            guard let quality = MatchText.quality(
                query: normalized,
                queryWords: words,
                name: MatchText.normalized(name),
                looseSeparator: "_"
            ) else { continue }
            if best == nil || quality < best! { best = quality }
            if best == .exact { break }
        }
        return best
    }

    public static func rank(quality: MatchQuality, isPopular: Bool, isCustom: Bool) -> Int {
        switch quality {
        case .exact: 0
        case .prefix: isPopular ? 1 : isCustom ? 3 : 5
        case .wordAligned: isPopular ? 2 : isCustom ? 4 : 6
        case .other: isCustom ? 7 : 8
        }
    }
}
