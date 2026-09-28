import Foundation
import ZuluEmoji

/// `:` — the same catalogue and the same ranking the emoji picker draws from.
public struct EmojiAutocompleteSource: AutocompleteSource {
    public let trigger: Character = ":"
    public let rankCount = EmojiQuery.rankCount

    private let catalogue: EmojiCatalogue

    public init(catalogue: EmojiCatalogue) {
        self.catalogue = catalogue
    }

    /// `::` is not a query — the second colon closes the first, and treating it as a
    /// trigger makes typing a bare `:` in prose flicker the box open.
    public func allows(precedingCharacter: Character) -> Bool { precedingCharacter != ":" }

    public func accepts(query: Substring) -> Bool {
        // A bare colon matches everything, which is noise rather than help.
        guard let first = query.first else { return false }
        // `:P`, `:)` and `:-p` are emoticons being typed, not emoji being searched.
        // Zulip's own rule is that the first character must be `+` or lowercase.
        guard first == "+" || (first.isLetter && !first.isUppercase) else { return false }
        return query.allSatisfy { $0 == "_" || $0 == "-" || $0 == "+" || $0.isLetter || $0.isNumber }
    }

    public func suggestions(
        for query: String,
        in context: ComposeContext
    ) -> [(element: AutocompleteSuggestion, rank: Int)] {
        catalogue.ranked(query).map { (suggestion(for: $0.element), $0.rank) }
    }

    private func suggestion(for emoji: Emoji) -> AutocompleteSuggestion {
        AutocompleteSuggestion(
            id: emoji.id,
            title: ":\(emoji.name):",
            subtitle: nil,
            icon: emoji.glyph.map { .glyph($0) } ?? .image(emoji.imageURL ?? emoji.stillURL ?? ""),
            insertion: ComposeMarkup.emoji(named: emoji.name),
            // Matching zulip-flutter: an emoji is usually followed by punctuation or
            // another emoji, and a forced space there is more often wrong than right.
            insertTrailingSpace: false
        )
    }
}
