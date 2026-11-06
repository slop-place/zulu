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

    @Test func attachedFileMatchesTheServer() {
        let server = #"<p><a href="/user_uploads/2/ab/notes.pdf">notes.pdf</a></p>"#
        #expect(pending("[notes.pdf](/user_uploads/2/ab/notes.pdf)") == MessageMarkup.blocks(from: server))
    }

    /// The server's copy points at a thumbnail it makes later; until then the upload
    /// itself is drawn, from bytes this device already holds.
    @Test func attachedPictureIsDrawnFromTheUpload() {
        let path = "/user_uploads/2/ab/cat.gif"
        let server = #"<p><img alt="cat.gif" class="inline-image" data-original-dimensions="480x270" data-original-src="/user_uploads/2/ab/cat.gif" src="/user_uploads/thumbnail/2/ab/cat.gif/840x560-anim.webp"></p>"#
        guard case .image(_, let serverLink, let serverAlt, _)? = MessageMarkup.blocks(from: server).first else {
            Issue.record("server HTML did not parse to an image")
            return
        }
        #expect(pending("look\n\n![cat.gif](\(path))") == [
            .paragraph([InlineSpan(text: "look")]),
            .image(source: path, link: serverLink, alt: serverAlt),
        ])
    }

    @Test func bracketsInOneNameKeepEveryPictureDrawn() {
        let first = "/user_uploads/2/ab/cat.gif"
        let second = "/user_uploads/2/cd/scan%20%5Bfinal%5D.gif"
        #expect(pending("![cat.gif](\(first))\n![scan [final].gif](\(second))") == [
            .image(source: first, link: first, alt: "cat.gif"),
            .image(source: second, link: second, alt: "scan [final].gif"),
        ])
    }

    @Test func escapedBracketInANameKeepsThePictureDrawn() {
        let path = "/user_uploads/2/ab/scan.gif"
        #expect(pending(#"![scan \[final.gif](\#(path))"#) == [
            .image(source: path, link: path, alt: "scan [final.gif"),
        ])
    }

    @Test func linkToAnotherSiteStaysInTheText() {
        let blocks = pending("[site](https://example.com/a.png)")
        #expect(blocks == [.paragraph([InlineSpan(text: "site", link: "https://example.com/a.png")])])
    }
}
