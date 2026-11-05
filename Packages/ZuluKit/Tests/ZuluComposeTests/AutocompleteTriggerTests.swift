import Testing
import ZuluEmoji
@testable import ZuluCompose

private let engine = AutocompleteEngine(sources: [
    EmojiAutocompleteSource(catalogue: .empty),
    ChannelAutocompleteSource(channels: []),
    MentionAutocompleteSource(people: [], groups: []),
])

private func query(_ text: String) -> ActiveQuery? {
    engine.activeQuery(in: text, cursor: text.endIndex)
}

struct AutocompleteTriggerTests {

    @Test func eachTriggerOpensItsOwnSource() {
        #expect(query("#des")?.trigger == "#")
        #expect(query(":smi")?.trigger == ":")
        #expect(query("@ada")?.trigger == "@")
    }

    @Test func everythingAfterTheTriggerIsTheQuery() {
        #expect(query("hello #design te")?.query == "design te")
        #expect(query("@Ada Lov")?.query == "Ada Lov")
    }

    // MARK: word boundaries

    /// A trigger mid-word is someone typing an email address or a URL fragment, not
    /// opening a box.
    @Test(arguments: ["ada@example", "issue#42", "time:30"])
    func aTriggerInsideAWordIsNotATrigger(text: String) {
        #expect(query(text) == nil)
    }

    /// The characters that may precede a trigger are wider than whitespace: Zulip's own
    /// rule admits brackets and quotes, so `(@ali` opens the box just as `@ali` does.
    @Test(arguments: ["(@ali", "\"@ali", "[@ali", "<@ali", "\n@ali", "/@ali"])
    func punctuationBeforeATriggerStillOpensTheBox(text: String) {
        #expect(query(text)?.query == "ali")
    }

    @Test func theRightmostTriggerWins() {
        #expect(query("#design :smi")?.trigger == ":")
    }

    // MARK: what closes the box

    @Test func aSpaceEndsAnEmojiQueryButNotAMention() {
        #expect(query(":smile ") == nil)
        #expect(query("@Ada Lovelace")?.query == "Ada Lovelace")
    }

    /// Emoticons are not emoji searches: `:P`, `:)`, `:-p` and `:3` stay closed.
    @Test(arguments: [":", ":)", ":P", ":-p", ":1", ":3", ": smile"])
    func emoticonsDoNotOpenTheEmojiBox(text: String) {
        #expect(query(text) == nil)
    }

    @Test(arguments: [":10", ":100", ":1234", "nice :10"])
    func numberedEmojiNamesOpenTheEmojiBox(text: String) {
        #expect(query(text)?.trigger == ":")
    }

    @Test func aDoubleColonIsNotAQuery() {
        #expect(query("::smile") == nil)
    }

    @Test func aBareHashListsNothing() {
        #expect(query("#") == nil)
        #expect(query("# ") == nil)
    }

    /// A bare `@` is the one trigger that opens with nothing typed, because listing
    /// everyone is what someone means by it.
    @Test func aBareAtSignListsEveryone() {
        #expect(query("@")?.query == "")
    }

    @Test func aSecondAtSignClosesTheMentionBox() {
        #expect(query("@ada@exam") == nil)
    }

    @Test func aCompletedMentionIsNoLongerAQuery() {
        #expect(query("@**Ada Lovelace**") == nil)
    }

    /// Bounded so a long draft is not rescanned from the top on every keystroke; past
    /// that the trigger is too far back to still be one.
    @Test func aTriggerBeyondTheLookbackIsIgnored() {
        let long = "@" + String(repeating: "a", count: 200)
        #expect(query(long) == nil)
    }

    // MARK: replacing the query

    @Test func selectingReplacesTheTriggerAndTheQuery() {
        let text = "hey #des"
        let active = query(text)!
        let suggestion = AutocompleteSuggestion(
            id: "x", title: "design", icon: .symbol("number"), insertion: "#**design**"
        )
        let result = engine.apply(suggestion, to: text, replacing: active)
        #expect(result.text == "hey #**design** ")
        #expect(result.cursor == result.text.endIndex)
    }

    @Test func textAfterTheCursorIsLeftAlone() {
        let text = "hey #des and more"
        let cursor = text.index(text.startIndex, offsetBy: 8)
        let active = engine.activeQuery(in: text, cursor: cursor)!
        #expect(active.query == "des")

        let suggestion = AutocompleteSuggestion(
            id: "x", title: "design", icon: .symbol("number"), insertion: "#**design**"
        )
        #expect(engine.apply(suggestion, to: text, replacing: active).text
            == "hey #**design**  and more")
    }

    @Test func emojiAreInsertedWithoutATrailingSpace() {
        let source = EmojiAutocompleteSource(catalogue: EmojiCatalogue(
            realmEmoji: [RealmEmojiItem(code: "3", name: "party_parrot", sourceURL: "/x.png")]
        ))
        let engine = AutocompleteEngine(sources: [source])
        let text = "nice :par"
        let active = engine.activeQuery(in: text, cursor: text.endIndex)!
        let suggestion = engine.suggestions(for: active, in: ComposeContext()).first!
        #expect(engine.apply(suggestion, to: text, replacing: active).text == "nice :party_parrot:")
    }

    @Test func typingTheStartOfOneHundredSuggestsIt() {
        let source = EmojiAutocompleteSource(catalogue: EmojiCatalogue(
            unicode: ServerEmojiData(codeToNames: ["1f4af": ["100"], "1f522": ["1234"]])
        ))
        let engine = AutocompleteEngine(sources: [source])
        let text = "nice :10"
        let active = engine.activeQuery(in: text, cursor: text.endIndex)!
        let suggestions = engine.suggestions(for: active, in: ComposeContext())
        #expect(suggestions.map(\.title) == [":100:"])
        #expect(engine.apply(suggestions[0], to: text, replacing: active).text == "nice :100:")
    }
}
