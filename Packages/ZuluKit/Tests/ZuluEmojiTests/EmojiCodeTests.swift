import Testing
@testable import ZuluEmoji

struct EmojiCodeTests {

    @Test func simpleEmojiIsItsCodepoint() {
        #expect(EmojiCode.code(for: "\u{1F44D}") == "1f44d")
        #expect(EmojiCode.glyph(for: "1f44d") == "\u{1F44D}")
    }

    /// The single most common way to get an emoji code wrong: Zulip strips the emoji
    /// presentation selector, and the server rejects `2764-fe0f` outright.
    @Test func variationSelectorIsStripped() {
        #expect(EmojiCode.code(for: "\u{2764}\u{FE0F}") == "2764")
        #expect(EmojiCode.code(for: "\u{2764}") == "2764")
    }

    @Test func codepointsAreZeroPaddedToFour() {
        #expect(EmojiCode.code(for: "#\u{20E3}") == "0023-20e3")
    }

    @Test func flagsAreARegionalIndicatorPair() {
        #expect(EmojiCode.code(for: "\u{1F1FA}\u{1F1F8}") == "1f1fa-1f1f8")
        #expect(EmojiCode.glyph(for: "1f1fa-1f1f8") == "\u{1F1FA}\u{1F1F8}")
    }

    @Test func zeroWidthJoinersSurvive() {
        let phoenix = "\u{1F426}\u{200D}\u{1F525}"
        #expect(EmojiCode.code(for: phoenix) == "1f426-200d-1f525")

        let running = "\u{1F3C3}\u{200D}\u{2640}\u{FE0F}\u{200D}\u{27A1}\u{FE0F}"
        #expect(EmojiCode.code(for: running) == "1f3c3-200d-2640-200d-27a1")
        #expect(EmojiCode.glyph(for: "1f3c3-200d-2640-200d-27a1") == running)
    }

    @Test func textDefaultGlyphGetsEmojiPresentation() {
        #expect(EmojiCode.glyph(for: "2764") == "\u{2764}\u{FE0F}")
        #expect(EmojiCode.glyph(for: "263a") == "\u{263A}\u{FE0F}")
    }

    @Test func emojiDefaultGlyphIsUnchanged() {
        #expect(EmojiCode.glyph(for: "1f525") == "\u{1F525}")
    }

    @Test func existingSelectorIsNotDoubled() {
        #expect(EmojiCode.glyph(for: "2764-fe0f-200d-1f525") == "\u{2764}\u{FE0F}\u{200D}\u{1F525}")
    }

    @Test func zeroWidthJoinedHeartIsQualified() {
        #expect(EmojiCode.glyph(for: "2764-200d-1f525") == "\u{2764}\u{FE0F}\u{200D}\u{1F525}")
    }

    @Test func keycapSelectorSitsBeforeTheCap() {
        #expect(EmojiCode.glyph(for: "0023-20e3") == "#\u{FE0F}\u{20E3}")
    }

    @Test func skinToneNeedsNoSelector() {
        #expect(EmojiCode.glyph(for: "270c-1f3fb") == "\u{270C}\u{1F3FB}")
    }

    @Test func codeRoundTripsThroughGlyph() {
        let code = EmojiCode.code(for: "\u{2764}\u{FE0F}")!
        #expect(EmojiCode.code(for: EmojiCode.glyph(for: code)!) == code)
    }

    @Test func nonsenseCodeDoesNotDecode() {
        #expect(EmojiCode.glyph(for: "zzzz") == nil)
        #expect(EmojiCode.glyph(for: "") == nil)
        // Beyond the Unicode range.
        #expect(EmojiCode.glyph(for: "ffffffff") == nil)
    }
}
