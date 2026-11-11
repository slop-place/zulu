import Foundation
import Observation

/// What the GIF picker shows: one query's results, a page at a time.
@MainActor
@Observable
public final class GIFBrowser {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case empty
        case failed
    }

    private enum Paging: Equatable {
        case more(cursor: String)
        case fetching
        case exhausted
    }

    public private(set) var gifs: [GIF] = []
    public private(set) var phase: Phase = .loading
    /// What `gifs` answers. Changes only once the new results are in.
    public private(set) var query = ""

    @ObservationIgnored private var paging = Paging.exhausted
    private let source: any GIFSource

    /// How long typing has to pause before a search goes out.
    public static let searchDelay: Duration = .milliseconds(300)
    /// How close to the end a shown GIF has to be to fetch the next page.
    static let prefetchDistance = 8

    public init(source: any GIFSource) {
        self.source = source
    }

    /// Replaces what is shown with what matches `query`, or with what the provider
    /// features when it is empty. Meant for `.task(id:)`, so a newer query cancels this one.
    public func show(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Coming back to the picker asks again for what it already shows.
        if query == self.query, phase == .loaded || phase == .empty { return }
        if !query.isEmpty {
            try? await Task.sleep(for: Self.searchDelay)
            guard !Task.isCancelled else { return }
        }
        phase = .loading
        do {
            let page = try await source.page(matching: query, after: nil)
            guard !Task.isCancelled else { return }
            self.query = query
            gifs = Self.unique(page.gifs)
            paging = page.next.map { .more(cursor: $0) } ?? .exhausted
            phase = gifs.isEmpty ? .empty : .loaded
        } catch {
            guard !Task.isCancelled else { return }
            self.query = query
            gifs = []
            paging = .exhausted
            phase = .failed
        }
    }

    /// Fetches the next page once `gif` is among the last few shown.
    public func loadMore(after gif: GIF) async {
        guard case .more(let cursor) = paging,
              gifs.suffix(Self.prefetchDistance).contains(gif)
        else { return }
        let query = self.query
        paging = .fetching
        do {
            let page = try await source.page(matching: query, after: cursor)
            guard query == self.query else { return }
            gifs = Self.unique(gifs + page.gifs)
            paging = page.next.map { .more(cursor: $0) } ?? .exhausted
        } catch {
            // Left to try again the next time a GIF near the end appears.
            guard query == self.query else { return }
            paging = .more(cursor: cursor)
        }
    }

    /// Splits `gifs` into `count` columns, each GIF going under the shortest column so far.
    public static func columns(of gifs: [GIF], count: Int) -> [[GIF]] {
        guard count > 0 else { return [] }
        var columns = Array(repeating: [GIF](), count: count)
        var heights = Array(repeating: 0.0, count: count)
        for gif in gifs {
            let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[shortest].append(gif)
            heights[shortest] += 1 / gif.aspectRatio
        }
        return columns
    }

    /// Providers repeat a GIF across pages, and a repeat would break the grid's identity.
    private static func unique(_ gifs: [GIF]) -> [GIF] {
        var seen: Set<String> = []
        return gifs.filter { seen.insert($0.id).inserted }
    }
}
