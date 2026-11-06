import Foundation
import ZuluEmoji

/// The blocks a message is drawn with before the server has rendered it, built to match
/// what the server will send back so nothing on screen changes when its copy lands.
public enum PendingMarkup {

    public struct Reply: Sendable, Equatable {
        public let author: String
        public let authorID: Int?
        public let messageID: Int
        public let quoted: [MessageBlock]

        public init(author: String, authorID: Int?, messageID: Int, quoted: [MessageBlock]) {
            self.author = author
            self.authorID = authorID
            self.messageID = messageID
            self.quoted = quoted
        }
    }


    /// Inline markdown only; block syntax other than paragraphs is left to the server.
    public static func blocks(
        of text: String, replyingTo reply: Reply?, emoji: (String) -> Emoji?
    ) -> [MessageBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let paragraphs: [MessageBlock] = text.split(separator: /\n[ \t]*\n\s*/).flatMap { paragraph in
            if let uploads = uploads(in: paragraph) { return uploads }
            let raw = String(paragraph)
            let parsed = (try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw)
            return [.paragraph(spans(of: parsed).flatMap { withEmoji($0, emoji: emoji) })]
        }
        guard let reply else { return paragraphs }
        return [.quotedReply(
            author: reply.author, authorID: reply.authorID, messageID: reply.messageID, quoted: reply.quoted
        )] + paragraphs
    }

    private static let imageMarker: Character = "!"
    private static let textOpen: Character = "["
    private static let textClose: Character = "]"

    /// A paragraph of nothing but upload links, as the composer writes attached files.
    /// A picture is drawn from the upload itself, since the server has not made its
    /// thumbnail yet.
    private static func uploads(in paragraph: Substring) -> [MessageBlock]? {
        let lines = paragraph.split(separator: "\n")
        let blocks = lines.compactMap { line -> MessageBlock? in
            guard let link = uploadLink(in: line.trimmingCharacters(in: .whitespaces)[...]) else { return nil }
            if link.isImage { return .image(source: link.path, link: link.path, alt: link.name) }
            return MessageAttachment(path: link.path, title: link.name).map(MessageBlock.attachment)
        }
        return !blocks.isEmpty && blocks.count == lines.count ? blocks : nil
    }

    /// `[name](path)` or `![name](path)`. Markdown lets a name hold brackets as long as
    /// they pair up, as in `scan [final].gif`.
    private static func uploadLink(in line: Substring) -> (isImage: Bool, name: String, path: String)? {
        let isImage = line.first == imageMarker
        let rest = isImage ? line.dropFirst() : line
        guard rest.first == textOpen else { return nil }
        var depth = 0
        var close: Substring.Index?
        for index in rest.indices {
            switch rest[index] {
            case textOpen: depth += 1
            case textClose: depth -= 1
            default: continue
            }
            if depth == 0 { close = index; break }
        }
        guard let close,
              let target = rest[rest.index(after: close)...].wholeMatch(of: /\(([^)\s]+)\)/)
        else { return nil }
        let path = String(target.1)
        guard MessageAttachment.isUpload(path) else { return nil }
        return (isImage, String(rest[rest.index(after: rest.startIndex)..<close]), path)
    }

    private static func spans(of text: AttributedString) -> [InlineSpan] {
        text.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            return InlineSpan(
                text: String(text[run.range].characters),
                bold: intent.contains(.stronglyEmphasized),
                italic: intent.contains(.emphasized),
                code: intent.contains(.code),
                strikethrough: intent.contains(.strikethrough),
                link: run.link?.absoluteString
            )
        }
    }

    /// Splits `:name:` out of a span the way the server swaps it for the emoji. Names the
    /// catalogue does not know stay as typed, which is what the server does too.
    private static func withEmoji(_ span: InlineSpan, emoji: (String) -> Emoji?) -> [InlineSpan] {
        guard !span.code else { return [span] }
        var output: [InlineSpan] = []
        var rest = span.text[...]
        while let match = rest.firstMatch(of: /:([A-Za-z0-9_+\-]+):/) {
            let name = String(match.output.1)
            guard let resolved = emoji(name), let replacement = replacement(for: resolved, typed: name, in: span)
            else {
                output.append(styled(span, String(rest[..<match.range.upperBound])))
                rest = rest[match.range.upperBound...]
                continue
            }
            output.append(styled(span, String(rest[..<match.range.lowerBound])))
            output.append(replacement)
            rest = rest[match.range.upperBound...]
        }
        output.append(styled(span, String(rest)))
        return merged(output.filter { !$0.text.isEmpty })
    }

    private static func replacement(for emoji: Emoji, typed name: String, in span: InlineSpan) -> InlineSpan? {
        var replacement = span
        replacement.emojiName = name
        if let glyph = emoji.glyph {
            replacement.text = glyph
        } else if let url = emoji.imageURL {
            replacement.text = emoji.insertion
            replacement.emojiURL = url
        } else {
            return nil
        }
        return replacement
    }

    private static func styled(_ span: InlineSpan, _ text: String) -> InlineSpan {
        var copy = span
        copy.text = text
        return copy
    }

    /// A name the catalogue did not know is split off on its own, and would otherwise
    /// leave a paragraph in more pieces than the server's copy parses into.
    private static func merged(_ spans: [InlineSpan]) -> [InlineSpan] {
        var output: [InlineSpan] = []
        for span in spans {
            if var last = output.last, styled(last, "") == styled(span, "") {
                last.text += span.text
                output[output.count - 1] = last
            } else {
                output.append(span)
            }
        }
        return output
    }
}
