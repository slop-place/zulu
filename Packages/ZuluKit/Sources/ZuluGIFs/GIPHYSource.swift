import Foundation

/// GIPHY's API, asked for the same two sizes Zulip's web app uses.
public struct GIPHYSource: GIFSource {
    let apiKey: String
    let rating: GIFRating
    let locale: Locale
    let session: URLSession

    static let baseURL = URL(string: "https://api.giphy.com/v1/gifs")!
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
        let endpoint = query.isEmpty ? "trending" : "search"
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "limit", value: String(Self.pageSize)),
            URLQueryItem(name: "offset", value: cursor ?? "0"),
            URLQueryItem(name: "rating", value: rating.rawValue),
            // Only what the picker reads, which keeps the response small.
            URLQueryItem(name: "fields", value: "id,title,images.downsized_medium,images.fixed_height"),
        ]
        if !query.isEmpty {
            items.append(URLQueryItem(name: "q", value: query))
            items.append(URLQueryItem(name: "lang", value: locale.language.languageCode?.identifier ?? "en"))
        }
        return Self.baseURL.appending(path: endpoint).appending(queryItems: items)
    }

    struct Response: Decodable {
        struct Item: Decodable {
            struct Rendition: Decodable {
                let url: URL
                /// GIPHY sends sizes as strings.
                let width: String?
                let height: String?
            }

            struct Images: Decodable {
                let fixed_height: Rendition?
                let downsized_medium: Rendition?
            }

            let id: String
            let title: String?
            let images: Images
        }

        struct Pagination: Decodable {
            let total_count: Int
            let count: Int
            let offset: Int
        }

        let data: [Item]
        let pagination: Pagination

        var page: GIFPage {
            let gifs = data.compactMap { item -> GIF? in
                guard let preview = item.images.fixed_height, let send = item.images.downsized_medium else {
                    return nil
                }
                return GIF(
                    id: item.id,
                    title: item.title ?? "",
                    previewURL: preview.url,
                    sendURL: send.url,
                    aspectRatio: aspectRatio(preview)
                )
            }
            let end = pagination.offset + pagination.count
            let hasMore = pagination.count > 0 && end < pagination.total_count
            return GIFPage(gifs: gifs, next: hasMore ? String(end) : nil)
        }

        private func aspectRatio(_ rendition: Item.Rendition) -> Double {
            guard let width = rendition.width.flatMap(Double.init),
                  let height = rendition.height.flatMap(Double.init),
                  width > 0, height > 0
            else { return 1 }
            return width / height
        }
    }
}
