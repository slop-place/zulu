import Foundation
import Testing
@testable import ZuluGIFs

struct KLIPYSourceTests {

    private let source = KLIPYSource(apiKey: "k", rating: .pg, locale: Locale(identifier: "en_GB"))

    private func items(_ url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func anEmptyQueryAsksForFeatured() {
        let url = source.url(matching: "", after: nil)
        #expect(url.path() == "/v2/featured")
        #expect(items(url)["q"] == nil)
        #expect(items(url)["pos"] == nil)
    }

    @Test func aSearchCarriesTheQueryCursorRatingAndLocale() {
        let query = items(source.url(matching: "cat", after: "Mg=="))
        #expect(query["q"] == "cat")
        #expect(query["pos"] == "Mg==")
        #expect(query["contentfilter"] == "medium")
        #expect(query["locale"] == "en_GB")
        #expect(query["key"] == "k")
    }

    @Test func ratingsMapToKLIPYsContentFilters() {
        #expect(GIFRating.allCases.map(KLIPYSource.contentFilter) == ["high", "medium", "low", "off"])
    }

    @Test func aResultBecomesAGIFWithThePreviewsShape() throws {
        let json = """
        {"results": [{"id": "1", "title": "Wave", "media_formats": {
            "tinygif": {"url": "https://x/tiny.gif", "dims": [200, 100]},
            "mediumgif": {"url": "https://x/medium.gif", "dims": [640, 320]}
        }}], "next": "Mg=="}
        """
        let page = try JSONDecoder().decode(KLIPYSource.Response.self, from: Data(json.utf8)).page
        #expect(page.next == "Mg==")
        #expect(page.gifs == [GIF(
            id: "1", title: "Wave",
            previewURL: URL(string: "https://x/tiny.gif")!, sendURL: URL(string: "https://x/medium.gif")!,
            aspectRatio: 2
        )])
    }

    @Test func theLastPageHasNoCursor() throws {
        let json = #"{"results": [], "next": ""}"#
        let page = try JSONDecoder().decode(KLIPYSource.Response.self, from: Data(json.utf8)).page
        #expect(page.next == nil)
    }

    @Test func aResultMissingASizeIsSkipped() throws {
        let json = """
        {"results": [{"id": "1", "media_formats": {"tinygif": {"url": "https://x/t.gif"}}}], "next": "Mg=="}
        """
        let page = try JSONDecoder().decode(KLIPYSource.Response.self, from: Data(json.utf8)).page
        #expect(page.gifs.isEmpty)
    }
}

struct GIPHYSourceTests {

    private let source = GIPHYSource(apiKey: "k", rating: .pg13, locale: Locale(identifier: "de_DE"))

    private func items(_ url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func anEmptyQueryAsksForTrending() {
        let url = source.url(matching: "", after: nil)
        #expect(url.path() == "/v1/gifs/trending")
        #expect(items(url)["offset"] == "0")
        #expect(items(url)["lang"] == nil)
    }

    @Test func aSearchCarriesTheQueryOffsetRatingAndLanguage() {
        let query = items(source.url(matching: "dog", after: "30"))
        #expect(query["q"] == "dog")
        #expect(query["offset"] == "30")
        #expect(query["rating"] == "pg-13")
        #expect(query["lang"] == "de")
    }

    @Test func theNextCursorIsTheOffsetAfterThisPage() throws {
        let json = """
        {"data": [{"id": "a", "title": "Hi", "images": {
            "fixed_height": {"url": "https://g/f.gif", "width": "300", "height": "200"},
            "downsized_medium": {"url": "https://g/d.gif"}
        }}], "pagination": {"total_count": 100, "count": 30, "offset": 30}}
        """
        let page = try JSONDecoder().decode(GIPHYSource.Response.self, from: Data(json.utf8)).page(maxOffset: GIPHYSource.searchMaxOffset)
        #expect(page.next == "60")
        #expect(page.gifs.first?.aspectRatio == 1.5)
        #expect(page.gifs.first?.sendURL == URL(string: "https://g/d.gif"))
    }

    @Test func theLastPageHasNoCursor() throws {
        let json = #"{"data": [], "pagination": {"total_count": 40, "count": 10, "offset": 30}}"#
        let page = try JSONDecoder().decode(GIPHYSource.Response.self, from: Data(json.utf8)).page(maxOffset: GIPHYSource.searchMaxOffset)
        #expect(page.next == nil)
    }

    /// Trending reports thousands of results but refuses any offset past 499.
    @Test func pagingStopsAtTheDeepestOffsetTheEndpointTakes() throws {
        let json = #"{"data": [], "pagination": {"total_count": 9000, "count": 30, "offset": 480}}"#
        let response = try JSONDecoder().decode(GIPHYSource.Response.self, from: Data(json.utf8))
        #expect(response.page(maxOffset: GIPHYSource.trendingMaxOffset).next == nil)
        #expect(response.page(maxOffset: GIPHYSource.searchMaxOffset).next == "510")
    }
}

struct GIFMarkdownTests {
    @Test func aGIFIsSentAsAnEmptyLinkSoOnlyThePreviewShows() {
        let gif = GIF(
            id: "1", title: "", previewURL: URL(string: "https://x/p.gif")!,
            sendURL: URL(string: "https://x/s.gif")!, aspectRatio: 1
        )
        #expect(gif.markdown == "[](https://x/s.gif)")
    }
}
