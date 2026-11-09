import Foundation

/// Where a search looks. Zulip searches whatever the narrow allows, so each scope is
/// the narrow of the place it names plus the search terms.
public enum SearchScope: Sendable, Hashable {
    case topic(channelID: Int, name: String)
    case channel(Int)
    case conversation(dmUserIDs: [Int])
    case directMessages
    case everywhere

    public func narrow(for query: String) -> [NarrowFilter] {
        place + [.search(query)]
    }

    private var place: [NarrowFilter] {
        switch self {
        case .topic(let channelID, let name): [.channel(channelID), .topic(name)]
        case .channel(let id): [.channel(id)]
        case .conversation(let ids): [.dm(ids)]
        case .directMessages: [.directMessages]
        case .everywhere: []
        }
    }
}

extension NarrowFilter {
    public static func search(_ query: String) -> NarrowFilter { .init("search", .text(query)) }
}

extension ZulipClient {
    public static let searchPageSize = 50

    /// One page of hits, newest first. Pass the oldest hit already shown as `olderThan`
    /// to get the page before it.
    public func search(
        _ query: String, in scope: SearchScope, olderThan oldestShown: Int? = nil
    ) async throws -> MessagesPage {
        try await messages(
            narrow: scope.narrow(for: query),
            anchor: oldestShown.map(Anchor.id) ?? .newest,
            before: Self.searchPageSize,
            after: 0,
            includeAnchor: oldestShown == nil
        )
    }
}
