import Foundation

/// KLIPY's Tenor-compatible API, asked for the same two sizes Zulip's web app uses.
public struct KLIPYSource: GIFSource {
    let apiKey: String
    let rating: GIFRating
    let locale: Locale
    let session: URLSession

    static let baseURL = URL(string: "https://api.klipy.com/v2")!
    static let pageSize = 30

    public init(apiKey: String, rating: GIFRating, locale: Locale = .current, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.rating = rating
        self.locale = locale
        self.session = session
    }

    public func page(matching query: String, after cursor: String?) async throws -> GIFPage {
        let response = try await GIFFetch.decode(
            Response.self, from: url(matching: query, after: cursor), session: session
        )
        return response.page
    }

    func url(matching query: String, after cursor: String?) -> URL {
        let endpoint = query.isEmpty ? "featured" : "search"
        var items = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "limit", value: String(Self.pageSize)),
            URLQueryItem(name: "media_filter", value: "tinygif,mediumgif"),
            URLQueryItem(name: "locale", value: Self.localeCode(locale)),
            URLQueryItem(name: "contentfilter", value: Self.contentFilter(rating)),
        ]
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let cursor { items.append(URLQueryItem(name: "pos", value: cursor)) }
        return Self.baseURL.appending(path: endpoint).appending(queryItems: items)
    }

    /// KLIPY filters by strictness rather than by rating.
    static func contentFilter(_ rating: GIFRating) -> String {
        switch rating {
        case .g: "high"
        case .pg: "medium"
        case .pg13: "low"
        case .r: "off"
        }
    }

    /// `en_US`, the form KLIPY expects.
    static func localeCode(_ locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier ?? "US"
        return "\(language)_\(region)"
    }

    struct Response: Decodable {
        struct Result: Decodable {
            struct Media: Decodable {
                let url: URL
                let dims: [Double]?
            }

            struct Formats: Decodable {
                let tinygif: Media?
                let mediumgif: Media?
            }

            let id: String
            let title: String?
            let media_formats: Formats
        }

        let results: [Result]
        let next: String?

        var page: GIFPage {
            let gifs = results.compactMap { result -> GIF? in
                guard let preview = result.media_formats.tinygif,
                      let send = result.media_formats.mediumgif
                else { return nil }
                return GIF(
                    id: result.id,
                    title: result.title ?? "",
                    previewURL: preview.url,
                    sendURL: send.url,
                    aspectRatio: aspectRatio(preview.dims)
                )
            }
            // The last page hands back an empty cursor rather than none.
            let cursor = next.flatMap { $0.isEmpty ? nil : $0 }
            return GIFPage(gifs: gifs, next: results.isEmpty ? nil : cursor)
        }

        private func aspectRatio(_ dims: [Double]?) -> Double {
            guard let dims, dims.count == 2, dims[0] > 0, dims[1] > 0 else { return 1 }
            return dims[0] / dims[1]
        }
    }
}
