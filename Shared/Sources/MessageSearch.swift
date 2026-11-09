import Foundation
import Observation
import SwiftUI
import ZulipAPI
import ZuluMarkup
import ZuluStore

/// One place a search can look, named for the picker.
struct SearchScopeOption: Identifiable, Hashable {
    let scope: SearchScope
    let title: String

    var id: SearchScope { scope }
}

/// One message the server matched, ready to draw and to open.
struct SearchHit: Identifiable, Equatable {
    let id: Int
    let senderID: Int
    let senderName: String
    let avatarURL: String?
    let date: Date
    let destination: AppModel.Destination
    let location: String
    let snippet: SearchHighlight
}

/// Runs a message search as the person types: waits for a pause, drops answers to
/// queries already replaced, and fetches older pages on request.
@MainActor
@Observable
final class MessageSearch {
    enum Phase: Equatable {
        case idle
        case searching
        case loaded
        case failed(String)
    }

    var query = "" {
        didSet { if query != oldValue { restart() } }
    }
    var scope: SearchScope {
        didSet { if scope != oldValue { restart() } }
    }
    let options: [SearchScopeOption]

    private(set) var hits: [SearchHit] = []
    private(set) var phase: Phase = .idle
    private(set) var hasMore = false
    private(set) var loadMoreFailed = false

    private let model: AppModel
    private var searchTask: Task<Void, Never>?
    private var moreTask: Task<Void, Never>?

    private static let typingPause = Duration.milliseconds(300)

    init(model: AppModel, options: [SearchScopeOption]) {
        self.model = model
        self.options = options
        scope = options.first?.scope ?? .everywhere
    }

    private var terms: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func stop() {
        searchTask?.cancel()
        searchTask = nil
        moreTask?.cancel()
        moreTask = nil
    }

    /// Return in the field: search now rather than after the pause.
    func searchNow() {
        restart(after: nil)
    }

    private func restart(after pause: Duration? = typingPause) {
        stop()
        hits = []
        hasMore = false
        loadMoreFailed = false
        guard !terms.isEmpty else {
            phase = .idle
            return
        }
        phase = .searching
        let terms = terms, scope = scope
        searchTask = Task { [weak self] in
            if let pause { try? await Task.sleep(for: pause) }
            guard !Task.isCancelled, let self else { return }
            do {
                let page = try await model.search(terms, in: scope, olderThan: nil)
                guard !Task.isCancelled else { return }
                accept(page, replacing: true)
                phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(AppModel.describe(error))
            }
        }
    }

    /// Belongs to the search that started it: a restart cancels it, so an older page of
    /// a replaced query never lands in, or holds up, the new one.
    func loadMore() {
        guard hasMore, moreTask == nil, phase == .loaded, let oldest = hits.last?.id else { return }
        loadMoreFailed = false
        let terms = terms, scope = scope
        moreTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { moreTask = nil } }
            do {
                let page = try await model.search(terms, in: scope, olderThan: oldest)
                guard !Task.isCancelled else { return }
                accept(page, replacing: false)
            } catch {
                guard !Task.isCancelled else { return }
                loadMoreFailed = true
            }
        }
    }

    private func accept(_ page: MessagesPage, replacing: Bool) {
        let older = page.messages.sorted { $0.id > $1.id }.compactMap(hit(from:))
        hits = replacing ? older : hits + older
        hasMore = !(page.found_oldest || (page.history_limited ?? false))
    }

    private func hit(from message: ZulipMessage) -> SearchHit? {
        guard let (destination, location) = place(of: message) else { return nil }
        return SearchHit(
            id: message.id,
            senderID: message.sender_id,
            senderName: message.sender_full_name,
            avatarURL: message.avatar_url,
            date: message.date,
            destination: destination,
            location: location,
            snippet: SearchHighlight(html: message.match_content ?? message.content)
        )
    }

    private func place(of message: ZulipMessage) -> (AppModel.Destination, String)? {
        if message.isChannelMessage, let channelID = message.stream_id {
            let channelName = model.channel(channelID)?.name ?? message.channelName ?? ""
            let topic = message.subject.isEmpty ? "general chat" : message.subject
            return (
                .topic(channelID: channelID, name: message.subject, channelName: channelName),
                "#\(channelName) › \(topic)"
            )
        }
        guard let key = model.dmKey(with: message.dmParticipants.map(\.id)) else { return nil }
        return (.dm(key), model.title(forDM: key))
    }
}

extension MessageSearch {
    /// The scopes that make sense from where the person is: narrowest first, so the
    /// picker opens on the place they are looking at.
    static func options(for destination: AppModel.Destination?, model: AppModel) -> [SearchScopeOption] {
        let wide = [
            SearchScopeOption(scope: .everywhere, title: "Everywhere"),
            SearchScopeOption(scope: .directMessages, title: "Direct messages"),
        ]
        switch destination {
        case .topic(let channelID, let name, let channelName):
            let channel = model.channel(channelID)
            let topic = SearchScopeOption(scope: .topic(channelID: channelID, name: name), title: "This topic")
            let whole = SearchScopeOption(
                scope: .channel(channelID), title: "#\(channel?.name ?? channelName)"
            )
            // A chat channel is one topic as far as the reader can tell.
            let narrow = channel?.rendersAsForum == false ? [whole] : [topic, whole]
            return narrow + wide
        case .channel(let id):
            return [SearchScopeOption(scope: .channel(id), title: "#\(model.channel(id)?.name ?? "")")] + wide
        case .dm(let key):
            let ids = key.split(separator: ",").compactMap { Int($0) }
            return [SearchScopeOption(scope: .conversation(dmUserIDs: ids), title: "This conversation")] + wide
        case nil:
            return wide
        }
    }
}

/// A hit as a row: who, where, when, and the text with the matched words picked out.
struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SenderAvatar(name: hit.senderName, userID: hit.senderID, url: hit.avatarURL, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(hit.senderName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(RecentTime.label(for: hit.date))
                        .font(.caption)
                        .foregroundStyle(TextTone.secondary)
                        .monospacedDigit()
                }
                Text(hit.location).font(.caption).foregroundStyle(TextTone.secondary).lineLimit(1)
                Text(Self.attributed(hit.snippet))
                    .font(.callout)
                    .foregroundStyle(TextTone.body)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    static func attributed(_ snippet: SearchHighlight) -> AttributedString {
        snippet.runs.reduce(into: AttributedString()) { text, run in
            var piece = AttributedString(run.text)
            if run.isMatch {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.backgroundColor = Color.yellow.opacity(0.35)
            }
            text += piece
        }
    }
}

/// Under the last hit while older ones exist: fetches them on appearing, or offers a
/// retry when that fetch failed.
struct SearchMoreFooter: View {
    let search: MessageSearch

    var body: some View {
        Group {
            if search.loadMoreFailed {
                Button("Couldn’t load more. Try Again") { search.loadMore() }
                    .font(.callout)
                    .buttonStyle(.borderless)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .task(id: search.hits.count) { search.loadMore() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// What the results area shows when there are no rows to show.
struct SearchStatus: View {
    let search: MessageSearch

    var body: some View {
        switch search.phase {
        case .idle:
            message("Search messages by word, phrase or name.")
        case .searching:
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 28)
        case .loaded:
            message("No messages match “\(search.query)”.")
        case .failed(let reason):
            message(reason)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(TextTone.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }
}
