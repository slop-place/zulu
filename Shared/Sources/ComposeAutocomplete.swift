import GRDB
import SwiftUI
import ZuluCompose
import ZuluEmoji
import ZuluStore

/// The realm's emoji, built once and shared by everything that needs them.
///
/// Both the picker and the `:` box work off the same catalogue, and building it means
/// parsing the server's 1900-entry table, so it is built when the database says it
/// changed and not once per view.
@MainActor
@Observable
final class EmojiCatalogueLoader {
    static let shared = EmojiCatalogueLoader()

    private(set) var catalogue = EmojiCatalogue.empty
    private var observer: AnyDatabaseCancellable?
    /// Which store is being watched. Signing out and back in makes a new one, and an
    /// observation of the old one would sit there reporting nothing forever.
    private weak var observed: ZuluStore?

    func start(store: ZuluStore?) {
        guard let store, observed !== store else { return }
        observed = store
        catalogue = .empty
        observer = store.observeEmojiSources().removeDuplicates().start(in: store.writer, onError: { _ in }) {
            [weak self] sources in
            let table = sources.unicode.flatMap { try? JSONDecoder().decode(ServerEmojiData.self, from: $0) }
            self?.catalogue = EmojiCatalogue(
                unicode: table, realmEmoji: sources.realm.map(\.item)
            )
        }
    }
}

/// Everything the `@` box ranks people by, read in one pass off the main actor.
private struct MentionData: Sendable {
    var subscribers: Set<Int> = []
    var latestInTopic: [Int: Int] = [:]
    var latestInChannel: [Int: Int] = [:]
    var latestInDirectMessages: [Int: Int] = [:]
    var groups: [UserGroupRecord] = []
    var channels: [ChannelRecord] = []
}

extension AppModel {
    /// The ranking inputs the sources need, read off the main actor because this is
    /// several queries and they run when a conversation opens.
    ///
    /// Recency is derived from message ids, which increase with time, so no extra
    /// bookkeeping is needed to know who spoke here last.
    fileprivate func mentionData(channelID: Int?, topic: String?) async -> MentionData {
        guard let store = storeForReading, let selfID = account?.userID else { return MentionData() }
        return await Task.detached {
            var data = MentionData()
            data.groups = (try? store.userGroups()) ?? []
            data.channels = (try? store.channels()) ?? []
            data.latestInDirectMessages = (try? store.latestDirectMessageIDsByPerson(selfUserID: selfID)) ?? [:]
            if let channelID {
                data.subscribers = (try? store.subscriberIDs(inChannel: channelID)) ?? []
                data.latestInChannel = (try? store.latestMessageIDsBySender(channelID: channelID)) ?? [:]
                if let topic {
                    data.latestInTopic =
                        (try? store.latestMessageIDsBySender(channelID: channelID, topic: topic)) ?? [:]
                }
            }
            return data
        }.value
    }
}

/// Owns the suggestion box: what is open, what is in it, and what picking one does.
///
/// The sources are rebuilt only when their inputs change — a keystroke costs a match and
/// a bucket sort, not a re-sort of the realm.
@MainActor
@Observable
final class ComposeAutocompleteController {
    private(set) var suggestions: [AutocompleteSuggestion] = []

    private let model: AppModel
    private let context: ComposeContext
    private var engine: AutocompleteEngine?
    private var active: ActiveQuery?

    /// Six rows is about as much as fits above the keyboard on a phone without burying
    /// what is being typed.
    private static let visibleLimit = 6

    init(model: AppModel, source: ConversationSource) {
        self.model = model
        switch source {
        case .topic(let channelID, let name, _):
            context = ComposeContext(channelID: channelID, topic: name)
        case .dm:
            context = ComposeContext()
        }
    }

    var isOpen: Bool { !suggestions.isEmpty }

    func prepare() async {
        let data = await model.mentionData(channelID: context.channelID, topic: context.topic)

        let people = model.users.values.map { user in
            PersonCandidate(
                id: user.id,
                fullName: user.fullName,
                email: user.email,
                isBot: user.isBot,
                avatarURL: user.avatarURL,
                isSubscribedToChannel: data.subscribers.contains(user.id),
                latestInTopic: data.latestInTopic[user.id],
                latestInChannel: data.latestInChannel[user.id],
                latestInDirectMessages: data.latestInDirectMessages[user.id]
            )
        }
        let groups = data.groups.map {
            GroupCandidate(
                id: $0.id, name: $0.name, description: $0.groupDescription,
                isMentionable: $0.isMentionable
            )
        }
        let channels = data.channels.map {
            ChannelCandidate(
                id: $0.id, name: $0.name, description: $0.description,
                isPinned: $0.pinned, isMuted: $0.isMuted
            )
        }

        engine = AutocompleteEngine(sources: [
            EmojiAutocompleteSource(catalogue: EmojiCatalogueLoader.shared.catalogue),
            ChannelAutocompleteSource(channels: channels),
            MentionAutocompleteSource(people: people, groups: groups),
        ])
    }

    /// The cursor is taken to be at the end of the draft, which is where it is while
    /// someone is typing. A completion mid-sentence is a rarer thing than the flicker
    /// that comes of guessing the cursor wrong.
    func update(draft: String) {
        guard let engine, let query = engine.activeQuery(in: draft, cursor: draft.endIndex) else {
            suggestions = []
            active = nil
            return
        }
        active = query
        suggestions = engine.suggestions(for: query, in: context, limit: Self.visibleLimit)
    }

    func apply(_ suggestion: AutocompleteSuggestion, to draft: String) -> String {
        guard let engine, let active else { return draft }
        let result = engine.apply(suggestion, to: draft, replacing: active)
        suggestions = []
        self.active = nil
        return result.text
    }

    // MARK: cursor-aware, for a composer that knows where the insertion point is

    /// Which row the keyboard has landed on. Reset to the best match whenever the
    /// suggestions change, so arrowing down always starts from the top.
    private(set) var selectedIndex = 0

    var selectedSuggestion: AutocompleteSuggestion? {
        suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil
    }

    /// The Mac composer reports the real cursor, so a completion can be picked
    /// mid-sentence rather than assumed to be at the end.
    func update(draft: String, cursorOffsetUTF16: Int) {
        let offset = max(0, min(cursorOffsetUTF16, draft.utf16.count))
        let cursor = String.Index(utf16Offset: offset, in: draft)
        guard let engine, let query = engine.activeQuery(in: draft, cursor: cursor) else {
            suggestions = []
            active = nil
            selectedIndex = 0
            return
        }
        let unchanged = query == active
        active = query
        suggestions = engine.suggestions(for: query, in: context, limit: Self.visibleLimit)
        if !unchanged || selectedIndex >= suggestions.count { selectedIndex = 0 }
    }

    func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + suggestions.count) % suggestions.count
    }

    /// Replaces the query with the completion and says where the cursor now belongs,
    /// as a UTF-16 offset because that is what an `NSTextView` speaks.
    func complete(
        _ suggestion: AutocompleteSuggestion, in draft: String
    ) -> (text: String, cursorOffsetUTF16: Int)? {
        guard let engine, let active else { return nil }
        let result = engine.apply(suggestion, to: draft, replacing: active)
        suggestions = []
        self.active = nil
        selectedIndex = 0
        let offset = result.text.utf16.distance(from: result.text.startIndex, to: result.cursor)
        return (result.text, offset)
    }

    func dismiss() {
        suggestions = []
        active = nil
        selectedIndex = 0
    }
}

/// The box itself, sitting directly above the compose bar.
///
/// The best match is the bottom row, nearest the text field and nearest the thumb: the
/// list grows upwards away from the keyboard, so the row most likely to be wanted is the
/// one that costs the least to reach.
struct AutocompleteBox: View {
    let suggestions: [AutocompleteSuggestion]
    let pick: (AutocompleteSuggestion) -> Void

    private static let rowHeight: CGFloat = 40
    private static let iconSize: CGFloat = 24
    private static let maxVisibleRows = 6

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(suggestions.reversed()) { suggestion in
                    Button { pick(suggestion) } label: { row(suggestion) }
                        .buttonStyle(.plain)
                }
            }
        }
        .defaultScrollAnchor(.bottom)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Self.rowHeight * CGFloat(Self.maxVisibleRows))
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func row(_ suggestion: AutocompleteSuggestion) -> some View {
        HStack(spacing: 10) {
            SuggestionIcon(icon: suggestion.icon, size: Self.iconSize)
                .frame(width: Self.iconSize, height: Self.iconSize)
            Text(suggestion.title)
                .font(.callout)
                .lineLimit(1)
            if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .contentShape(.rect)
    }
}

/// Draws whichever of the three shapes a suggestion carries. Custom emoji and avatars
/// are images on the realm, so they load through the signed-in client like any other.
struct SuggestionIcon: View {
    let icon: AutocompleteSuggestion.Icon
    let size: CGFloat

    @Environment(AppModel.self) private var model
    @State private var image: Image?
    @State private var frames: EmojiFrames?

    var body: some View {
        Group {
            switch icon {
            case .glyph(let text):
                Text(text).font(.system(size: 20))
            case .symbol(let name):
                Image(systemName: name).foregroundStyle(.secondary)
            case .image(let path):
                if let frames {
                    AnimatedEmojiView(frames: frames)
                } else {
                    Color.clear.task { await loadFrames(path) }
                }
            case .avatar(let path):
                if let image {
                    image.resizable().scaledToFit().clipShape(.circle)
                } else {
                    Color.clear.task { await load(path) }
                }
            }
        }
    }

    private func load(_ path: String) async {
        guard !path.isEmpty, let data = await model.imageData(at: path) else { return }
        image = Platform.image(from: data)
    }

    private func loadFrames(_ path: String) async {
        guard !path.isEmpty, let data = await model.imageData(at: path) else { return }
        frames = EmojiFrames.decode(data, height: size)
    }
}
