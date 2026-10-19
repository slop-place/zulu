import Foundation

/// Which of the three tables an emoji lives in. The raw values are Zulip's
/// `reaction_type` wire strings, because a reaction is identified by
/// `(reaction_type, emoji_code)` and never by name.
public enum EmojiKind: String, Sendable, Equatable, Codable {
    case unicode = "unicode_emoji"
    case realm = "realm_emoji"
    /// `:zulip:`, which the server never lists anywhere and every client synthesizes.
    case zulipExtra = "zulip_extra_emoji"
}

/// One entry in the catalogue: a glyph or image, its canonical name, and the aliases
/// that also find it.
public struct Emoji: Sendable, Equatable, Identifiable {
    public let kind: EmojiKind
    /// Dash-separated codepoints for unicode emoji, the realm emoji's id otherwise.
    public let code: String
    /// The canonical name — index 0 of the server's name array, never an alias.
    public let name: String
    public let aliases: [String]
    /// Realm-relative or absolute. Only custom emoji have one.
    public let imageURL: String?
    /// The first frame of an animated custom emoji. Absent on emoji uploaded before
    /// Zulip 5, which the schema does not admit (zulip/zulip#36339).
    public let stillURL: String?

    public init(
        kind: EmojiKind,
        code: String,
        name: String,
        aliases: [String] = [],
        imageURL: String? = nil,
        stillURL: String? = nil
    ) {
        self.kind = kind
        self.code = code
        self.name = name
        self.aliases = aliases
        self.imageURL = imageURL
        self.stillURL = stillURL
    }

    /// A reaction is unique on kind and code, so those name an emoji even when two
    /// tables happen to share a name.
    public var id: String { "\(kind.rawValue):\(code)" }

    /// `:zulip:` is drawn from an image and ranks alongside the realm's own emoji, so
    /// for every purpose but the wire it is a custom emoji.
    public var isCustom: Bool { kind != .unicode }

    public var glyph: String? {
        kind == .unicode ? EmojiCode.glyph(for: code) : nil
    }

    /// What the composer types. Zulip resolves the name at render time, so the name is
    /// the only thing worth inserting — a codepoint would not render at all.
    public var insertion: String { ":\(name):" }

    /// Names in search order: canonical first, so an exact alias never outranks an
    /// exact canonical match.
    public var allNames: [String] { [name] + aliases }
}

/// A custom emoji as the register snapshot and the `realm_emoji` event describe it.
public struct RealmEmojiItem: Sendable, Equatable {
    /// The stringified `RealmEmoji.id`, which is also the reaction's `emoji_code`.
    public let code: String
    public let name: String
    public let sourceURL: String
    public let stillURL: String?
    /// Deactivated emoji stay in the snapshot so old reactions still resolve, and their
    /// names may since have been reused by a different emoji.
    public let deactivated: Bool

    public init(
        code: String,
        name: String,
        sourceURL: String,
        stillURL: String? = nil,
        deactivated: Bool = false
    ) {
        self.code = code
        self.name = name
        self.sourceURL = sourceURL
        self.stillURL = stillURL
        self.deactivated = deactivated
    }
}

/// How to draw an emoji the catalogue was asked about. Every failure lands on `.text`,
/// which is what the server's own markdown does with a name it cannot resolve.
public enum EmojiDisplay: Sendable, Equatable {
    case glyph(String)
    case image(url: String, still: String?)
    case text(String)
}

public enum EmojiCode {
    /// Zulip's own name for `:zulip:`'s image, hardcoded on the server and in both
    /// official clients. There is no registry to look it up in.
    public static let zulipExtraName = "zulip"
    public static let zulipExtraImageURL = "/static/generated/emoji/images/emoji/unicode/zulip.png"

    /// The six the web client falls back on before it has watched anyone react.
    /// Codes, not names: the names differ between server versions.
    public static let popularCodes = ["1f44d", "1f389", "1f642", "2764", "1f6e0", "1f419"]

    /// An emoji presentation selector is never part of a Zulip emoji code: `❤️` is
    /// `2764`, and `2764-fe0f` is rejected outright by the server.
    private static let variationSelector = Unicode.Scalar(0xFE0F)!

    /// The same text with every emoji presentation selector removed, which is the form
    /// every Zulip emoji code is written in.
    public static func unqualified(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != variationSelector }))
    }

    public static func code(for glyph: String) -> String? {
        let scalars = glyph.unicodeScalars.filter { $0 != variationSelector }
        guard !scalars.isEmpty else { return nil }
        return scalars.map { scalar in
            // Zero-padded to four, so the keycap `#` is `0023` and not `23`.
            let hex = String(scalar.value, radix: 16)
            return String(repeating: "0", count: max(0, 4 - hex.count)) + hex
        }.joined(separator: "-")
    }

    private static let textVariationSelector = Unicode.Scalar(0xFE0E)!

    /// The fully qualified glyph. Zulip's codes drop the selector, and without it `2764`
    /// draws as a monochrome text heart on macOS.
    public static func glyph(for code: String) -> String? {
        var scalars: [Unicode.Scalar] = []
        for part in code.split(separator: "-") {
            guard let value = UInt32(part, radix: 16), let scalar = Unicode.Scalar(value) else {
                return nil
            }
            scalars.append(scalar)
        }
        guard !scalars.isEmpty else { return nil }

        var qualified = String.UnicodeScalarView()
        let followers = scalars.dropFirst().map(Optional.some) + [nil]
        for (scalar, next) in zip(scalars, followers) {
            qualified.append(scalar)
            if needsSelector(scalar, before: next) { qualified.append(variationSelector) }
        }
        return String(qualified)
    }

    /// A skin tone modifier already forces emoji presentation on the scalar before it.
    private static func needsSelector(_ scalar: Unicode.Scalar, before next: Unicode.Scalar?) -> Bool {
        guard scalar.properties.isEmoji, !scalar.properties.isEmojiPresentation else { return false }
        guard let next else { return true }
        return next != variationSelector
            && next != textVariationSelector
            && !next.properties.isEmojiModifier
    }
}
