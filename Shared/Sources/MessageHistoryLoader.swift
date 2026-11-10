import Foundation
import GRDB
import Observation
import SwiftUI
import Synchronization
import ZuluStore

/// Owns everything a conversation knows about its messages: what is loaded, whether older
/// messages exist, and whether a fetch is in flight.
///
/// This lives apart from the view because the trigger for loading older history is a
/// conjunction of scroll phase, visible rows, and in-flight state — too much to leave
/// scattered through a view body, and too easy to get wrong in a way that fires a fetch on
/// every keystroke.
@MainActor
@Observable
final class MessageHistoryLoader {
    private(set) var messages: [MessageRecord] = []
    private(set) var grouped: [GroupedMessage] = []
    private(set) var isLoadingOlder = false
    private(set) var hasMoreOlder = true
    /// Snapshotted on first load, so the divider does not vanish the moment the messages
    /// behind it are marked read.
    private(set) var firstUnreadID: Int?
    private(set) var isReady = false
    private(set) var reactions: [Int: [ReactionGroup]] = [:]

    let source: ConversationSource
    private let model: AppModel
    private var scrollPhase: ScrollPhase = .idle
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var openedFromStore = false

    init(source: ConversationSource, model: AppModel) {
        self.source = source
        self.model = model
    }

    /// Called when the conversation closes. `deinit` cannot touch main-actor state, and
    /// leaving the observation running would keep writing into a view that is gone.
    func stop() {
        observation?.cancel()
        observation = nil
        isStopped = true
    }

    /// A conversation coming back on screen opens a fresh loader rather than this one.
    @ObservationIgnored private(set) var isStopped = false

    /// Shows what is stored at once, when that reaches back to the first unread message.
    /// Called before the conversation's first frame, so it opens drawn rather than blank.
    func openFromStore() {
        guard !openedFromStore, canOpenFromStore else { return }
        openedFromStore = true
        observe()
    }

    /// Merges in what the server adds. Opened on a stored history that stops short of the
    /// first unread, the conversation would open past everything the reader has not seen,
    /// so then it waits for the server before showing anything.
    func start() async {
        openFromStore()
        await loadInitialHistory()
        observe()
    }

    private var canOpenFromStore: Bool {
        guard let store = model.storeForReading else { return false }
        return switch source {
        case .topic(let channelID, let name, _):
            (try? store.canOpenFromStore(channelID: channelID, topic: name)) ?? false
        case .dm(let key):
            (try? store.canOpenFromStore(dmKey: key)) ?? false
        }
    }

    private func loadInitialHistory() async {
        switch source {
        case .topic(let channelID, let name, _):
            await model.loadHistory(channelID: channelID, topic: name)
        case .dm(let key):
            await model.loadHistory(dmKey: key)
        }
    }

    /// The first value is read on the spot, so the rows are there for the frame that asked
    /// for them. Every later one is grouped and parsed off the main thread.
    private func observe() {
        guard observation == nil, let writer = model.databaseWriter, let store = model.storeForReading
        else { return }
        let rows = switch source {
        case .topic(let channelID, let name, _): store.observeConversation(channelID: channelID, topic: name)
        case .dm(let key): store.observeConversation(dmKey: key)
        }
        let firstUnread = FirstUnreadSnapshot()
        let selfUserID = model.selfUserID

        observation = rows
            .map { ConversationSnapshot($0, firstUnreadID: firstUnread.resolve(in: $0.messages), selfUserID: selfUserID) }
            .removeDuplicates()
            .start(in: writer, scheduling: .immediate, onError: { _ in }) { [weak self] snapshot in
                MainActor.assumeIsolated { self?.apply(snapshot) }
            }
    }

    private func apply(_ snapshot: ConversationSnapshot) {
        if !isReady {
            firstUnreadID = snapshot.firstUnreadID
            isReady = true
            // Read on the spot, the first value was not parsed ahead of the rows.
            let bodies = snapshot.messages.map(\.renderedContent)
            Task.detached(priority: .userInitiated) { ConversationSnapshot.parse(bodies) }
        }
        if messages != snapshot.messages { messages = snapshot.messages }
        if grouped != snapshot.grouped { grouped = snapshot.grouped }
        if reactions != snapshot.reactions { reactions = snapshot.reactions }
        model.outbox.settle(landed: Set(snapshot.messages.map(\.id)))
    }

    func noteScrollPhase(_ phase: ScrollPhase) {
        scrollPhase = phase
    }

    /// Older messages are fetched only when the reader has actually scrolled the oldest row
    /// into view. Watching the scroll offset instead would fire on the keyboard appearing,
    /// on the list growing, and on the fetch's own result landing.
    func noteVisible(_ ids: [Int]) {
        guard scrollPhase.isScrolling else { return }
        guard let oldest = messages.first?.id, ids.contains(oldest) else { return }
        Task { await loadOlder() }
    }

    func loadOlder() async {
        guard hasMoreOlder, !isLoadingOlder, let oldest = messages.first?.id else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let result = switch source {
        case .topic(let channelID, let name, _):
            await model.loadOlder(channelID: channelID, topic: name, before: oldest)
        case .dm(let key):
            await model.loadOlder(dmKey: key, before: oldest)
        }
        if result == .reachedStart { hasMoreOlder = false }
    }
}

struct GroupedMessage: Identifiable, Equatable, Sendable {
    let message: MessageRecord
    let startsGroup: Bool
    let startsDay: Bool

    var id: Int { message.id }
}

/// What a conversation shows, worked out from its rows wherever the store delivers them.
struct ConversationSnapshot: Equatable, Sendable {
    let messages: [MessageRecord]
    let grouped: [GroupedMessage]
    let reactions: [Int: [ReactionGroup]]
    let firstUnreadID: Int?

    init(_ rows: ConversationRows, firstUnreadID: Int?, selfUserID: Int?) {
        messages = rows.messages
        self.firstUnreadID = firstUnreadID
        grouped = Self.group(rows.messages, firstUnreadID: firstUnreadID)
        reactions = Dictionary(grouping: rows.reactions, by: \.messageID)
            .mapValues { ReactionGroup.group($0, selfUserID: selfUserID) }
        // The first value is read on the main thread, where parsing every body would
        // hold up the frame it is read for.
        if !Thread.isMainThread { Self.parse(rows.messages.map(\.renderedContent)) }
    }

    /// The newest bodies are the ones a conversation opens on.
    static func parse(_ bodies: [String]) {
        for body in bodies.suffix(parsedAhead) { _ = ParsedMessages.blocks(from: body) }
    }

    private static let parsedAhead = 300

    /// Consecutive messages from one person collapse under a single header, the way every
    /// chat client does it. A long enough pause starts a new group even for the same sender,
    /// so a conversation picked up hours later does not read as one block.
    static func group(_ messages: [MessageRecord], firstUnreadID: Int?) -> [GroupedMessage] {
        var previous: MessageRecord?
        return messages.map { message in
            defer { previous = message }
            guard let previous else {
                return GroupedMessage(message: message, startsGroup: true, startsDay: true)
            }
            // The first unread message always carries its date beside the unread line.
            // A conversation opens on it from what is stored, often before the message
            // before it has arrived; were its date to depend on that message, it would
            // vanish once that message landed and the whole screen would jump.
            let startsDay = !Calendar.current.isDate(previous.date, inSameDayAs: message.date)
                || message.id == firstUnreadID
            let sameSender = previous.senderID == message.senderID
            let closeInTime = message.timestamp - previous.timestamp < groupingWindow
            let continues = sameSender && closeInTime && !startsDay && message.id != firstUnreadID
            return GroupedMessage(message: message, startsGroup: !continues, startsDay: startsDay)
        }
    }

    /// Five minutes, matching what Discord and Slack settle on.
    static let groupingWindow = 5 * 60
}

/// The first unread message as the conversation first loaded, kept for as long as it is open.
private final class FirstUnreadSnapshot: Sendable {
    private let value = Mutex<Int??>(nil)

    func resolve(in messages: [MessageRecord]) -> Int? {
        value.withLock { stored in
            if let stored { return stored }
            let first = messages.first { !$0.isRead }?.id
            stored = .some(first)
            return first
        }
    }
}
