import Testing
import ZuluMarkup

struct SearchHighlightTests {
    @Test func marksTheMatchedWords() {
        let highlight = SearchHighlight(html: #"<p>the <span class="highlight">deploy</span> broke</p>"#)
        #expect(highlight.runs == [
            .init("the "), .init("deploy", isMatch: true), .init(" broke"),
        ])
    }

    @Test func readsAsOneLine() {
        let highlight = SearchHighlight(html: "<p>first\n line</p>\n<ul><li>one</li><li>two</li></ul>")
        #expect(highlight.plainText == "first line one two")
    }

    @Test func decodesEntities() {
        let highlight = SearchHighlight(html: #"<p>a &amp; <span class="highlight">b&lt;c</span></p>"#)
        #expect(highlight.runs == [.init("a & "), .init("b<c", isMatch: true)])
    }

    @Test func dropsImages() {
        let highlight = SearchHighlight(html: #"<p>see <img src="/x.png" alt="x"></p>"#)
        #expect(highlight.plainText == "see")
    }

    @Test func readsAPlainTopic() {
        #expect(SearchHighlight(html: "release notes").runs == [.init("release notes")])
    }
}
