import Testing
import ZuluEmoji
@testable import ZuluMarkup

/// A pending message must parse to what the server's copy will, or the row visibly
/// changes when the real message replaces it.
struct PendingMarkupTests {

    private static let hundred = Emoji(kind: .unicode, code: "1f4af", name: "100")
    private static let party = Emoji(kind: .realm, code: "7", name: "party", imageURL: "/user_avatars/2/emoji/images/7.gif")

    private static func lookup(_ name: String) -> Emoji? {
        [hundred, party].first { $0.name == name }
    }

    private func pending(_ text: String, replyingTo reply: PendingMarkup.Reply? = nil) -> [MessageBlock] {
        PendingMarkup.blocks(of: text, replyingTo: reply, emoji: Self.lookup)
    }

    @Test func unicodeEmojiMatchesTheServer() {
        let server = #"<p>nice <span aria-label="100" class="emoji emoji-1f4af" role="img" title="100">:100:</span></p>"#
        #expect(pending("nice :100:") == MessageMarkup.blocks(from: server))
    }

    @Test func emojiOnlyMessageIsStillDrawnLarge() {
        #expect(MessageMarkup.isEmojiOnly(pending(":100:")))
    }

    @Test func customEmojiMatchesTheServer() {
        let server = #"<p><img alt=":party:" class="emoji" src="/user_avatars/2/emoji/images/7.gif" title="party"> time</p>"#
        #expect(pending(":party: time") == MessageMarkup.blocks(from: server))
    }

    @Test func unknownEmojiNameStaysAsTyped() {
        #expect(pending("a :nope: b") == [.paragraph([InlineSpan(text: "a :nope: b")])])
    }

    @Test func emojiInsideCodeStaysAsTyped() {
        #expect(pending("`:100:`") == [.paragraph([InlineSpan(text: ":100:", code: true)])])
    }

    private static let replyHeader = ##"<p><span class="user-mention silent" data-user-id="2323">Brandon Wees</span> <a href="#narrow/channel/108/near/498801">said</a>:</p>"##

    private func reply(quoting original: String) -> PendingMarkup.Reply {
        PendingMarkup.Reply(
            author: "Brandon Wees", authorID: 2323, messageID: 498801,
            quoted: MessageMarkup.blocks(from: original)
        )
    }

    @Test func replyIsDrawnAsAReplyStraightAway() {
        let original = "<p>the original words</p>"
        let server = Self.replyHeader + "<blockquote>\(original)</blockquote><p>Thanks</p>"
        #expect(pending("Thanks", replyingTo: reply(quoting: original)) == MessageMarkup.blocks(from: server))
    }

    @Test func quotedListKeepsItsShape() {
        let original = "<ul>\n<li>first</li>\n<li>second</li>\n</ul>"
        let server = Self.replyHeader + "<blockquote>\n\(original)\n</blockquote>\n<p>Thanks</p>"
        #expect(pending("Thanks", replyingTo: reply(quoting: original)) == MessageMarkup.blocks(from: server))
    }

    @Test func quotedCustomEmojiAndImageSurvive() {
        let original = #"<p><img alt=":party:" class="emoji" src="/user_avatars/2/emoji/images/7.gif" title="party"> look</p><div class="message_inline_image"><a href="/user_uploads/2/ab/cat.png" title="cat.png"><img src="/user_uploads/thumbnail/2/ab/cat.png/840x560.webp"></a></div>"#
        let server = Self.replyHeader + "<blockquote>\(original)</blockquote><p>Thanks</p>"
        #expect(pending("Thanks", replyingTo: reply(quoting: original)) == MessageMarkup.blocks(from: server))
    }

    @Test func inlineStylingMatchesTheServer() {
        let server = "<p>a <strong>bold</strong> and <em>soft</em></p>\n<p>next</p>"
        #expect(pending("a **bold** and *soft*\n\nnext") == MessageMarkup.blocks(from: server))
    }
}
