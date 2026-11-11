import Foundation
import Testing
@testable import ZuluGIFs

private func gif(_ id: String, aspect: Double = 1) -> GIF {
    GIF(
        id: id, title: id,
        previewURL: URL(string: "https://x/\(id)-p.gif")!, sendURL: URL(string: "https://x/\(id).gif")!,
        aspectRatio: aspect
    )
}

/// Answers from a table keyed by query and cursor, and remembers what it was asked.
private actor FakeSource: GIFSource {
    struct Failure: Error {}

    private let pages: [String: GIFPage]
    private let delays: [String: Duration]
    private(set) var asked: [String] = []

    init(_ pages: [String: GIFPage], delays: [String: Duration] = [:]) {
        self.pages = pages
        self.delays = delays
    }

    static func key(_ query: String, _ cursor: String?) -> String { "\(query)|\(cursor ?? "")" }

    func page(matching query: String, after cursor: String?) async throws -> GIFPage {
        let key = Self.key(query, cursor)
        asked.append(key)
        if let delay = delays[key] { try await Task.sleep(for: delay) }
        guard let page = pages[key] else { throw Failure() }
        return page
    }
}

@MainActor
struct GIFBrowserTests {

    @Test func anEmptyQueryShowsWhatIsFeatured() async {
        let source = FakeSource([FakeSource.key("", nil): GIFPage(gifs: [gif("a")], next: nil)])
        let browser = GIFBrowser(source: source)
        await browser.show("")
        #expect(browser.gifs.map(\.id) == ["a"])
        #expect(browser.phase == .loaded)
    }

    @Test func showingTheSameResultsAgainFetchesNothing() async {
        let source = FakeSource([FakeSource.key("", nil): GIFPage(gifs: [gif("a")], next: nil)])
        let browser = GIFBrowser(source: source)
        await browser.show("")
        await browser.show("")
        #expect(await source.asked.count == 1)
    }

    @Test func aFailureIsAskedAgain() async {
        let source = FakeSource([:])
        let browser = GIFBrowser(source: source)
        await browser.show("")
        await browser.show("")
        #expect(await source.asked.count == 2)
    }

    @Test func surroundingSpaceIsNotSearchedFor() async {
        let source = FakeSource([FakeSource.key("cat", nil): GIFPage(gifs: [gif("c")], next: nil)])
        let browser = GIFBrowser(source: source)
        await browser.show("  cat ")
        #expect(browser.gifs.map(\.id) == ["c"])
    }

    @Test func noResultsIsEmptyNotFailed() async {
        let source = FakeSource([FakeSource.key("zz", nil): GIFPage(gifs: [], next: nil)])
        let browser = GIFBrowser(source: source)
        await browser.show("zz")
        #expect(browser.phase == .empty)
    }

    @Test func aFailedFetchClearsTheGrid() async {
        let source = FakeSource([FakeSource.key("", nil): GIFPage(gifs: [gif("a")], next: nil)])
        let browser = GIFBrowser(source: source)
        await browser.show("")
        await browser.show("missing")
        #expect(browser.gifs.isEmpty)
        #expect(browser.phase == .failed)
    }

    @Test func nearingTheEndFetchesTheNextPageWithoutRepeats() async {
        let source = FakeSource([
            FakeSource.key("", nil): GIFPage(gifs: [gif("a"), gif("b")], next: "2"),
            FakeSource.key("", "2"): GIFPage(gifs: [gif("b"), gif("c")], next: nil),
        ])
        let browser = GIFBrowser(source: source)
        await browser.show("")
        await browser.loadMore(after: gif("b"))
        #expect(browser.gifs.map(\.id) == ["a", "b", "c"])

        await browser.loadMore(after: gif("c"))
        #expect(await source.asked.count == 2)
    }

    @Test func aGIFFarFromTheEndFetchesNothing() async {
        let first = (0..<20).map { gif("\($0)") }
        let source = FakeSource([FakeSource.key("", nil): GIFPage(gifs: first, next: "2")])
        let browser = GIFBrowser(source: source)
        await browser.show("")
        await browser.loadMore(after: first[0])
        #expect(await source.asked.count == 1)
    }

    @Test func aFailedNextPageIsTriedAgain() async {
        let source = FakeSource([FakeSource.key("", nil): GIFPage(gifs: [gif("a")], next: "2")])
        let browser = GIFBrowser(source: source)
        await browser.show("")
        await browser.loadMore(after: gif("a"))
        await browser.loadMore(after: gif("a"))
        #expect(await source.asked.count == 3)
        #expect(browser.phase == .loaded)
    }

    @Test func aSlowEarlierRequestNeverReplacesANewerSearch() async {
        let source = FakeSource(
            [
                FakeSource.key("", nil): GIFPage(gifs: [gif("featured")], next: nil),
                FakeSource.key("dog", nil): GIFPage(gifs: [gif("dog")], next: nil),
            ],
            delays: [FakeSource.key("", nil): .seconds(2)]
        )
        let browser = GIFBrowser(source: source)
        let retry = Task { await browser.show("") }
        await Task.yield()
        await browser.show("dog")
        await retry.value
        #expect(browser.gifs.map(\.id) == ["dog"])
    }

    @Test func resultsCountOnlyForTheQueryTheyAnswer() async {
        let source = FakeSource([FakeSource.key("cat", nil): GIFPage(gifs: [gif("c")], next: nil)])
        let browser = GIFBrowser(source: source)
        await browser.show("cat")
        #expect(browser.hasResults(for: " cat"))
        #expect(!browser.hasResults(for: "dog"))
    }

    @Test func eachGIFGoesUnderTheShortestColumn() {
        let gifs = [gif("tall", aspect: 0.5), gif("wide1", aspect: 2), gif("wide2", aspect: 2), gif("wide3", aspect: 2)]
        let columns = GIFBrowser.columns(of: gifs, count: 2)
        #expect(columns.map { $0.map(\.id) } == [["tall"], ["wide1", "wide2", "wide3"]])
    }
}
