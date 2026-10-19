import Foundation
import ZuluEmoji

/// One run of text with whatever inline styling applies to it.
public struct InlineSpan: Sendable, Equatable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var strikethrough = false
    /// Realm-relative or absolute. Relative links resolve against the realm URL.
    public var link: String?
    /// A realm custom emoji, which Zulip sends as a small image rather than a character.
    public var emojiURL: String?
    /// An @-mention of a person or group.
    public var mention = false
    /// The person an @-mention names, when Zulip told us who they are. Lets a reply
    /// header show their real picture rather than their initials.
    public var mentionedUserID: Int?

    public init(
        text: String, bold: Bool = false, italic: Bool = false, code: Bool = false,
        strikethrough: Bool = false, link: String? = nil, emojiURL: String? = nil,
        mention: Bool = false, mentionedUserID: Int? = nil
    ) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.strikethrough = strikethrough
        self.link = link
        self.emojiURL = emojiURL
        self.mention = mention
        self.mentionedUserID = mentionedUserID
    }
}

/// What a rendered message is made of, once the server's HTML has been read.
public enum MessageBlock: Sendable, Equatable, Identifiable {
    case paragraph([InlineSpan])
    case quote([MessageBlock])
    case codeBlock(language: String?, code: String)
    case bulletList([[InlineSpan]])
    case numberedList([[InlineSpan]])
    /// `source` is the image to display, `link` the full-size target behind it.
    /// `aspectRatio` is width over height where the server told us, so a row can
    /// reserve its height before the bytes arrive and the list never reflows.
    case image(source: String, link: String?, alt: String?, aspectRatio: Double? = nil)
    /// An uploaded file linked on a line of its own.
    case attachment(MessageAttachment)
    /// Zulip's quote-and-reply: an attribution line followed by a blockquote. Kept as one
    /// thing so it can be drawn as a compact reply header rather than a wall of quote.
    case quotedReply(author: String, authorID: Int?, messageID: Int?, quoted: [MessageBlock])

    public var id: String {
        switch self {
        case .paragraph(let spans): "p:" + spans.map(\.text).joined()
        case .quote(let blocks): "q:" + blocks.map(\.id).joined()
        case .codeBlock(let language, let code): "c:\(language ?? "")\(code.prefix(40))"
        case .bulletList(let items): "ul:" + items.flatMap { $0 }.map(\.text).joined()
        case .numberedList(let items): "ol:" + items.flatMap { $0 }.map(\.text).joined()
        case .image(let source, _, _, _): "img:\(source)"
        case .attachment(let attachment): "file:\(attachment.path)"
        case .quotedReply(let author, _, let messageID, _): "reply:\(author):\(messageID ?? 0)"
        }
    }
}

public enum MessageMarkup {

    /// Turns Zulip's `rendered_content` into blocks a native view can lay out.
    ///
    /// Zulip renders markdown server-side and its own clients display that HTML rather
    /// than re-parsing the markdown, so this reads the HTML it actually emits.
    public static func blocks(from html: String) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        collect(HTMLParser.parse(html), into: &blocks)
        return foldQuotedReplies(withoutPreviewedAttachments(blocks))
    }

    /// A message of nothing but emoji, which is drawn large.
    public static func isEmojiOnly(_ blocks: [MessageBlock]) -> Bool {
        guard blocks.count == 1, case .paragraph(let spans)? = blocks.first else { return false }
        let onlyEmoji = spans.allSatisfy { span in
            span.emojiURL != nil
                || (span.link == nil && !span.mention && !span.code
                    && span.text.allSatisfy { $0.isWhitespace || $0.isEmoji })
        }
        let anyEmoji = spans.contains { $0.emojiURL != nil || $0.text.contains(where: \.isEmoji) }
        return onlyEmoji && anyEmoji
    }

    /// Zulip renders quote-and-reply as an attribution paragraph — a silent mention,
    /// a `said` link carrying `/near/<id>` — immediately followed by a blockquote.
    /// Recognising the pair lets the UI draw a one-line reply header instead of
    /// repeating the whole quoted message inline.
    private static func foldQuotedReplies(_ blocks: [MessageBlock]) -> [MessageBlock] {
        var output: [MessageBlock] = []
        var index = 0
        while index < blocks.count {
            if case .paragraph(let spans) = blocks[index],
               index + 1 < blocks.count,
               case .quote(let quoted) = blocks[index + 1],
               let attribution = attribution(from: spans) {
                output.append(.quotedReply(
                    author: attribution.author,
                    authorID: attribution.authorID,
                    messageID: attribution.messageID,
                    quoted: quoted
                ))
                index += 2
                continue
            }
            output.append(blocks[index])
            index += 1
        }
        return output
    }

    private static func attribution(
        from spans: [InlineSpan]
    ) -> (author: String, authorID: Int?, messageID: Int?)? {
        guard let mention = spans.first(where: \.mention) else { return nil }
        guard let link = spans.compactMap(\.link).first(where: { $0.contains("/near/") })
        else { return nil }
        // Nothing but the attribution may be in the line, or it is ordinary prose
        // that happens to quote someone.
        let text = spans.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix(":") else { return nil }
        let id = link.split(separator: "/").last.flatMap { Int($0) }
        return (mention.text.trimmingCharacters(in: .whitespaces), mention.mentionedUserID, id)
    }

    private static func collect(_ nodes: [HTMLNode], into blocks: inout [MessageBlock]) {
        var pending: [InlineSpan] = []

        func flushPending() {
            let trimmed = trim(pending)
            if !trimmed.isEmpty { blocks.append(.paragraph(trimmed)) }
            pending = []
        }

        for node in nodes {
            switch node {
            case .text(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pending.append(contentsOf: inline([node]))
                }

            case .element(let element):
                switch element.name {
                case "p":
                    flushPending()
                    blocks.append(contentsOf: paragraph(element.children))

                case "blockquote":
                    flushPending()
                    var inner: [MessageBlock] = []
                    collect(element.children, into: &inner)
                    inner = withoutPreviewedAttachments(inner)
                    if !inner.isEmpty { blocks.append(.quote(inner)) }

                case "pre":
                    flushPending()
                    blocks.append(codeBlock(from: element))

                case "ul", "ol":
                    flushPending()
                    let items = element.children.compactMap { child -> [InlineSpan]? in
                        guard case .element(let item) = child, item.name == "li" else { return nil }
                        let spans = trim(inline(item.children))
                        return spans.isEmpty ? nil : spans
                    }
                    if !items.isEmpty {
                        blocks.append(element.name == "ul" ? .bulletList(items) : .numberedList(items))
                    }

                case "img":
                    flushPending()
                    if let source = element.attribute("src") {
                        blocks.append(.image(
                        source: source, link: nil, alt: element.attribute("alt"),
                        aspectRatio: Self.aspectRatio(from: element)
                    ))
                    }

                case "div":
                    flushPending()
                    // Zulip wraps previews as
                    // <div class="message_inline_image"><a href=full><img src=thumb></a></div>
                    if element.classes.contains("message_inline_image")
                        || element.classes.contains("message_inline_ref") {
                        if let image = firstImage(in: element.children) {
                            blocks.append(image)
                            continue
                        }
                    }
                    collect(element.children, into: &blocks)

                case "br":
                    pending.append(InlineSpan(text: "\n"))

                case "hr":
                    flushPending()

                case "h1", "h2", "h3", "h4", "h5", "h6":
                    flushPending()
                    var spans = trim(inline(element.children))
                    for index in spans.indices { spans[index].bold = true }
                    if !spans.isEmpty { blocks.append(.paragraph(spans)) }

                default:
                    pending.append(contentsOf: inline([node]))
                }
            }
        }
        flushPending()
    }

    /// A paragraph can carry an uploaded image inline. Zulip marks those `inline-image`
    /// and custom emoji `emoji`, both as `<img>`, so the class decides which is which:
    /// an upload breaks the paragraph into its own block, an emoji stays in the text.
    private static func paragraph(_ nodes: [HTMLNode]) -> [MessageBlock] {
        if let attachments = attachments(in: nodes) { return attachments.map(MessageBlock.attachment) }
        var blocks: [MessageBlock] = []
        var spans: [InlineSpan] = []

        func flush() {
            let trimmed = trim(spans)
            if !trimmed.isEmpty { blocks.append(.paragraph(trimmed)) }
            spans = []
        }

        for node in nodes {
            if case .element(let element) = node,
               element.name == "img",
               !element.classes.contains("emoji") {
                flush()
                if let source = element.attribute("src") {
                    blocks.append(.image(
                        source: source,
                        // The thumbnail is what loads; the original is what a tap opens.
                        link: element.attribute("data-original-src"),
                        alt: element.attribute("alt"),
                        aspectRatio: Self.aspectRatio(from: element)
                    ))
                }
                continue
            }
            spans.append(contentsOf: inline([node]))
        }
        flush()
        return blocks
    }

    /// A paragraph of nothing but upload links, as Zulip writes a file attached in the
    /// composer. A link in the middle of a sentence stays in the sentence.
    private static func attachments(in nodes: [HTMLNode]) -> [MessageAttachment]? {
        var attachments: [MessageAttachment] = []
        for node in nodes {
            switch node {
            case .text(let text):
                guard text.allSatisfy(\.isWhitespace) else { return nil }
            case .element(let element) where element.name == "br":
                continue
            case .element(let element):
                guard element.name == "a",
                      let href = element.attribute("href"),
                      let attachment = MessageAttachment(
                          path: href, title: inline(element.children).map(\.text).joined()
                      )
                else { return nil }
                attachments.append(attachment)
            }
        }
        return attachments.isEmpty ? nil : attachments
    }

    /// Zulip follows an uploaded picture's link with its preview. The preview is the
    /// attachment, so the link is not drawn a second time.
    private static func withoutPreviewedAttachments(_ blocks: [MessageBlock]) -> [MessageBlock] {
        let previewed = Set(blocks.compactMap { block -> String? in
            guard case .image(_, let link, _, _) = block else { return nil }
            return link
        })
        return blocks.filter { block in
            guard case .attachment(let attachment) = block else { return true }
            return !previewed.contains(attachment.path)
        }
    }

    private static func firstImage(in nodes: [HTMLNode]) -> MessageBlock? {
        for node in nodes {
            guard case .element(let element) = node else { continue }
            if element.name == "img", let source = element.attribute("src") {
                return .image(
                    source: source, link: nil, alt: element.attribute("title"),
                    aspectRatio: Self.aspectRatio(from: element)
                )
            }
            if element.name == "a", let href = element.attribute("href"),
               case .image(let source, _, let alt, let ratio)? = firstImage(in: element.children) {
                // The caption sits on the anchor, not the thumbnail.
                return .image(source: source, link: href, alt: element.attribute("title") ?? alt, aspectRatio: ratio)
            }
            if let nested = firstImage(in: element.children) { return nested }
        }
        return nil
    }

    private static func codeBlock(from element: HTMLNode.Element) -> MessageBlock {
        var language: String?
        var code = ""

        func gather(_ nodes: [HTMLNode]) {
            for node in nodes {
                switch node {
                case .text(let text): code += text
                case .element(let child):
                    if child.name == "code" {
                        for className in child.classes where className.hasPrefix("language-") {
                            language = String(className.dropFirst("language-".count))
                        }
                    }
                    gather(child.children)
                }
            }
        }
        gather(element.children)

        while code.hasSuffix("\n") { code.removeLast() }
        return .codeBlock(language: language, code: code)
    }

    /// Flattens an element tree into styled runs.
    private static func inline(_ nodes: [HTMLNode], inherited: InlineSpan = InlineSpan(text: "")) -> [InlineSpan] {
        var spans: [InlineSpan] = []

        for node in nodes {
            switch node {
            case .text(let text):
                var span = inherited
                span.text = inherited.code ? text : text.replacing(/[ \t\n\r\f]+/, with: " ")
                spans.append(span)

            case .element(let element):
                var style = inherited
                if blockElements.contains(element.name) {
                    var span = inherited
                    span.text = String(blockBreak)
                    spans.append(span)
                }
                switch element.name {
                case "strong", "b": style.bold = true
                case "em", "i": style.italic = true
                case "code", "pre": style.code = true
                case "del", "s", "strike": style.strikethrough = true
                case "a": style.link = element.attribute("href")
                case "br":
                    var span = inherited
                    span.text = "\n"
                    spans.append(span)
                    continue
                case "span":
                    // Unicode emoji arrive as <span class="emoji emoji-1f600">:name:</span>.
                    if let emoji = emoji(from: element) {
                        var span = inherited
                        span.text = emoji
                        spans.append(span)
                        continue
                    }
                    if element.classes.contains("user-mention")
                        || element.classes.contains("user-group-mention") {
                        style.mention = true
                        style.mentionedUserID = element.attribute("data-user-id").flatMap(Int.init)
                    }
                case "img":
                    // Realm custom emoji are images. They keep their place in the text and
                    // carry the URL so the renderer can draw the picture rather than `:name:`.
                    if element.classes.contains("emoji") {
                        var span = inherited
                        span.text = element.attribute("title").map { ":\($0):" }
                            ?? element.attribute("alt") ?? ""
                        span.emojiURL = element.attribute("src")
                        if !span.text.isEmpty { spans.append(span) }
                    }
                    continue
                default:
                    break
                }
                spans.append(contentsOf: inline(element.children, inherited: style))
            }
        }
        return merge(spans)
    }

    /// `emoji-1f4f8` carries the codepoint; multi-codepoint emoji join with a dash.
    private static func emoji(from element: HTMLNode.Element) -> String? {
        guard element.classes.contains("emoji") else { return nil }
        guard let codes = element.classes.first(where: { $0.hasPrefix("emoji-") })?
            .dropFirst("emoji-".count)
        else { return nil }
        return EmojiCode.glyph(for: String(codes))
    }

    private static func merge(_ spans: [InlineSpan]) -> [InlineSpan] {
        var merged: [InlineSpan] = []
        for span in spans where !span.text.isEmpty {
            // Compared on styling alone, so adding a field to InlineSpan cannot silently
            // start merging runs that differ in it.
            if var last = merged.last, sameStyle(last, span) {
                last.text += span.text
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private static func sameStyle(_ a: InlineSpan, _ b: InlineSpan) -> Bool {
        var left = a
        var right = b
        left.text = ""
        right.text = ""
        return left == right
    }

    /// Marks where a block element sat inside inline content. It becomes a line break
    /// unless one is already there, so `<li><p>` does not open with two.
    private static let blockBreak: Character = "\u{2029}"

    private static let blockElements: Set<String> = [
        "p", "li", "ul", "ol", "div", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    /// HTML's rules, which the server's markup relies on: whitespace in the source is one
    /// space, and a line never starts with one.
    private static func normalizeWhitespace(_ spans: [InlineSpan]) -> [InlineSpan] {
        var previous: Character = "\n"
        return spans.map { span in
            var span = span
            guard !span.code else {
                previous = span.text.last ?? previous
                return span
            }
            var text = ""
            for character in span.text {
                switch character {
                case " " where previous == " " || previous == "\n":
                    continue
                case blockBreak where previous == "\n":
                    continue
                case "\n", blockBreak:
                    if text.last == " " { text.removeLast() }
                    text.append("\n")
                    previous = "\n"
                default:
                    text.append(character)
                    previous = character
                }
            }
            span.text = text
            return span
        }
    }

    private static func trim(_ spans: [InlineSpan]) -> [InlineSpan] {
        var spans = merge(normalizeWhitespace(merge(spans)))
        while let first = spans.first {
            let trimmed = String(first.text.drop(while: { $0 == "\n" || $0 == " " }))
            if trimmed.isEmpty { spans.removeFirst() } else {
                spans[0].text = trimmed
                break
            }
        }
        while let last = spans.last {
            var text = last.text
            while text.hasSuffix("\n") || text.hasSuffix(" ") { text.removeLast() }
            if text.isEmpty { spans.removeLast() } else {
                spans[spans.count - 1].text = text
                break
            }
        }
        return spans
    }
}

extension MessageMarkup {
    /// Zulip sends the original's size as `data-original-dimensions="1206x2140"`. Knowing it
    /// up front is what lets a message reserve the right height before the image loads,
    /// instead of growing under the reader's thumb mid-scroll.
    static func aspectRatio(from element: HTMLNode.Element) -> Double? {
        guard let raw = element.attribute("data-original-dimensions") else { return nil }
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0
        else { return nil }
        return width / height
    }
}

private extension Character {
    /// Digits, `#`, `©` and `™` carry the emoji property too. Everything below this
    /// codepoint that has it is one of those, unless a variation selector follows.
    static let firstPictograph: UInt32 = 0x238D

    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji
                && (unicodeScalars.count > 1 || first.value >= Self.firstPictograph))
    }
}
