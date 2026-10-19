import Testing
@testable import ZuluMarkup

struct MessageAttachmentTests {

    @Test func uploadLinkOnItsOwnLineBecomesAnAttachment() {
        let html = #"<p><a href="/user_uploads/2/ab/xyz/report.pdf">report.pdf</a></p>"#
        #expect(MessageMarkup.blocks(from: html) == [
            .attachment(MessageAttachment(path: "/user_uploads/2/ab/xyz/report.pdf", title: "report.pdf")!),
        ])
    }

    @Test func severalUploadsInOneParagraphEachBecomeAnAttachment() {
        let html = #"<p><a href="/user_uploads/2/a/notes.txt">notes.txt</a><br>"#
            + "\n" + #"<a href="/user_uploads/2/b/data.zip">data.zip</a></p>"#
        let paths = MessageMarkup.blocks(from: html).compactMap { block -> String? in
            guard case .attachment(let attachment) = block else { return nil }
            return attachment.path
        }
        #expect(paths == ["/user_uploads/2/a/notes.txt", "/user_uploads/2/b/data.zip"])
    }

    @Test func uploadLinkInsideASentenceStaysALink() {
        let html = #"<p>see <a href="/user_uploads/2/a/report.pdf">this</a> first</p>"#
        #expect(MessageMarkup.blocks(from: html) == [.paragraph([
            InlineSpan(text: "see "),
            InlineSpan(text: "this", link: "/user_uploads/2/a/report.pdf"),
            InlineSpan(text: " first"),
        ])])
    }

    /// Verbatim shape from zulip.futo.org: the upload's link, then its preview.
    @Test func previewedImageIsNotAlsoAnAttachment() {
        let html = #"<p><a href="/user_uploads/2/b5/Kj/image.jpeg">image.jpeg</a></p>"#
            + "\n"
            + #"<div class="message_inline_image"><a href="/user_uploads/2/b5/Kj/image.jpeg" title="image.jpeg"><img src="/user_uploads/thumbnail/2/b5/Kj/image.jpeg/840x560.webp"></a></div>"#
        #expect(MessageMarkup.blocks(from: html) == [.image(
            source: "/user_uploads/thumbnail/2/b5/Kj/image.jpeg/840x560.webp",
            link: "/user_uploads/2/b5/Kj/image.jpeg",
            alt: "image.jpeg"
        )])
    }

    @Test func onlyRealmUploadsAreAttachments() {
        #expect(MessageAttachment(path: "/user_uploads/2/a/x.pdf", title: nil) != nil)
        #expect(MessageAttachment(path: "/user_uploads/thumbnail/2/a/x.png/840x560.webp", title: nil) == nil)
        #expect(MessageAttachment(path: "https://example.com/user_uploads/x.pdf", title: nil) == nil)
        #expect(MessageAttachment(path: "#narrow/channel/1", title: nil) == nil)
    }

    @Test func nameFallsBackToTheDecodedFileName() {
        #expect(MessageAttachment(path: "/user_uploads/2/a/My%20Notes.txt", title: " ")?.name == "My Notes.txt")
        #expect(MessageAttachment(path: "/user_uploads/2/a/x.txt", title: "Renamed")?.name == "Renamed")
    }

    @Test func extensionComesFromThePathNotTheName() {
        let attachment = MessageAttachment(path: "/user_uploads/2/a/Slides.KEY", title: "deck")
        #expect(attachment?.fileExtension == "key")
        #expect(MessageAttachment(path: "/user_uploads/2/a/Makefile", title: nil)?.fileExtension == "")
    }

    @Test(arguments: [
        ("pdf", AttachmentKind.pdf),
        ("png", .image),
        ("mp4", .video),
        ("mov", .video),
        ("mp3", .audio),
        ("zip", .archive),
        ("xlsx", .spreadsheet),
        ("pptx", .presentation),
        ("swift", .code),
        ("txt", .text),
        ("", .other),
        ("notarealextension", .other),
    ])
    func kindFollowsTheExtension(fileExtension: String, kind: AttachmentKind) {
        #expect(AttachmentKind(fileExtension: fileExtension) == kind)
    }
}
