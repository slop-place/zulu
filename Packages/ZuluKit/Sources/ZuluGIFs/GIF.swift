import Foundation

/// One result from a GIF provider: a small copy for the picker and a bigger one to send.
public struct GIF: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let previewURL: URL
    public let sendURL: URL
    /// Width over height of the preview.
    public let aspectRatio: Double

    public init(id: String, title: String, previewURL: URL, sendURL: URL, aspectRatio: Double) {
        self.id = id
        self.title = title
        self.previewURL = previewURL
        self.sendURL = sendURL
        self.aspectRatio = aspectRatio
    }

    /// What Zulip's web app inserts. The empty link text leaves only the server's inline
    /// preview in the rendered message.
    public var markdown: String { "[](\(sendURL.absoluteString))" }
}

public struct GIFPage: Sendable, Equatable {
    public let gifs: [GIF]
    /// Hands back to the provider for the page after this one. `nil` on the last page.
    public let next: String?

    public init(gifs: [GIF], next: String?) {
        self.gifs = gifs
        self.next = next
    }
}

/// A GIF provider's search. An empty query asks for what the provider features.
public protocol GIFSource: Sendable {
    func page(matching query: String, after cursor: String?) async throws -> GIFPage
}

/// The content ratings Zulip lets a realm allow, by the names it gives them.
public enum GIFRating: String, Sendable, CaseIterable {
    case g
    case pg
    case pg13 = "pg-13"
    case r
}

public enum GIFError: Error, Equatable {
    case status(Int)
}

enum GIFFetch {
    static func decode<T: Decodable>(_ type: T.Type, from url: URL, session: URLSession) async throws -> T {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GIFError.status(http.statusCode)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
