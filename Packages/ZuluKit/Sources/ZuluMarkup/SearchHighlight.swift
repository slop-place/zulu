import Foundation

/// A search hit as one line of plain text, with the words the server matched marked.
public struct SearchHighlight: Sendable, Equatable {
    public struct Run: Sendable, Equatable {
        public let text: String
        public let isMatch: Bool

        public init(_ text: String, isMatch: Bool = false) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    public let runs: [Run]

    public var plainText: String { runs.map(\.text).joined() }

    private static let matchClass = "highlight"
    /// Elements whose text would only be noise in a one-line preview.
    private static let skipped: Set<String> = ["img", "script", "style"]

    public init(runs: [Run]) {
        self.runs = runs
    }

    /// Reads Zulip's `match_content` or `match_subject`. Block breaks collapse to spaces
    /// so the hit reads as one line.
    public init(html: String) {
        var builder = Builder()
        builder.collect(HTMLParser.parse(html), isMatch: false)
        runs = builder.finish()
    }

    private struct Builder {
        var runs: [Run] = []

        mutating func collect(_ nodes: [HTMLNode], isMatch: Bool) {
            for node in nodes {
                switch node {
                case .text(let text):
                    append(text, isMatch: isMatch)
                case .element(let element):
                    guard !SearchHighlight.skipped.contains(element.name) else { continue }
                    let matches = isMatch || element.classes.contains(SearchHighlight.matchClass)
                    collect(element.children, isMatch: matches)
                    if element.isBlock { append(" ", isMatch: false) }
                }
            }
        }

        mutating func append(_ text: String, isMatch: Bool) {
            var collapsed = text.replacing(/\s+/, with: " ")
            if runs.last?.text.hasSuffix(" ") ?? true, collapsed.hasPrefix(" ") {
                collapsed.removeFirst()
            }
            guard !collapsed.isEmpty else { return }
            if let last = runs.last, last.isMatch == isMatch {
                runs[runs.count - 1] = Run(last.text + collapsed, isMatch: isMatch)
            } else {
                runs.append(Run(collapsed, isMatch: isMatch))
            }
        }

        func finish() -> [Run] {
            var trimmed = runs
            if let last = trimmed.last {
                trimmed[trimmed.count - 1] = Run(
                    String(last.text.reversed().drop { $0 == " " }.reversed()), isMatch: last.isMatch
                )
            }
            return trimmed.filter { !$0.text.isEmpty }
        }
    }
}

private extension HTMLNode.Element {
    static let blockNames: Set<String> = [
        "p", "div", "br", "li", "ul", "ol", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6",
        "table", "tr", "td", "th",
    ]

    var isBlock: Bool { Self.blockNames.contains(name) }
}
