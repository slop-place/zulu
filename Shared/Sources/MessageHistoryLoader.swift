import Foundation
import GRDB
import Observation
import SwiftUI
import Synchronization
import ZulipAPI
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
    /// Where the conversation opens: the message it was asked to open at, or else the
    /// first unread. Settled on first load.
    private(set) var openingID: Int?
    /// The message asked for, lit up for a moment once it is on screen.
    private(set) var highlightedID: Int?
    /// True while the conversation shows a stretch of older history fetched around
    /// `targetID`, which stops short of the newest message.
    private(set) var hasMoreNewer = false
    private(set) var isLoadingNewer = false

    let source: ConversationSource
    /// The message to open at instead of the first unread.
    let targetID: Int?
    /// Opens on the newest message even with something unread above it.
    private let opensAtNewest: Bool
    private let model: AppModel
    private var scrollPhase: ScrollPhase = .idle
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var openedFromStore = false
    @ObservationIgnored private let firstUnread = FirstUnreadSnapshot()
    /// What was fetched around the target while it does not reach the stored history.
    /// Kept out of the store until it does, so the stored history never has a gap.
    @ObservationIgnored private var detached: [ZulipMessage] = []

    /// Matches the page `AppModel.loadHistory` fetches the newest messages in.
    private static let detachedPageSize = 100
    private static let highlightDuration = Duration.seconds(2)

    init(source: ConversationSource, model: AppModel, targetID: Int? = nil, opensAtNewest: Bool = false) {
        self.source = source
        self.model = model
        self.targetID = targetID
        self.opensAtNewest = opensAtNewest
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
        if observation == nil, let targetID, !model.isStored(targetID) {
            await openDetached(around: targetID)
        }
        if !hasMoreNewer { observe() }
    }

    private var canOpenFromStore: Bool {
        if let targetID { return model.isStored(targetID) }
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
        guard observation == nil, !isStopped, let writer = model.databaseWriter, let store = model.storeForReading
        else { return }
        let rows = switch source {
        case .topic(let channelID, let name, _): store.observeConversation(channelID: channelID, topic: name)
        case .dm(let key): store.observeConversation(dmKey: key)
        }
        let firstUnread = firstUnread
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
            // A deleted target opens at whatever came after it.
            let target = targetID.flatMap { id in snapshot.messages.first { $0.id >= id }?.id }
            openingID = target ?? (opensAtNewest ? nil : snapshot.firstUnreadID)
            if let target { highlight(target) }
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
        if let oldest = messages.first?.id, ids.contains(oldest) {
            Task { await loadOlder() }
        }
        if hasMoreNewer, let newest = messages.last?.id, ids.contains(newest) {
            Task { await loadNewer() }
        }
    }

    func loadOlder() async {
        guard hasMoreOlder, !isLoadingOlder, let oldest = messages.first?.id else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        if hasMoreNewer {
            await loadOlderDetached(before: oldest)
            return
        }
        let result = switch source {
        case .topic(let channelID, let name, _):
            await model.loadOlder(channelID: channelID, topic: name, before: oldest)
        case .dm(let key):
            await model.loadOlder(dmKey: key, before: oldest)
        }
        if result == .reachedStart { hasMoreOlder = false }
    }

    // MARK: opening at an older message

    /// The target is older than anything stored. If what comes back around it reaches
    /// the stored history it is saved and shown from the store like any other opening;
    /// otherwise it is shown from here, apart from the store.
    private func openDetached(around targetID: Int) async {
        guard let page = await model.fetchMessages(
            in: source, anchor: .id(targetID),
            before: Self.detachedPageSize, after: Self.detachedPageSize, includeAnchor: true
        ), !isStopped else { return }
        if page.found_oldest || (page.history_limited ?? false) { hasMoreOlder = false }
        detached = page.messages
        if !joinIfReached(page) {
            hasMoreNewer = true
            showDetached()
        }
    }

    func loadNewer() async {
        guard hasMoreNewer, !isLoadingNewer, let newest = detached.last?.id else { return }
        isLoadingNewer = true
        defer { isLoadingNewer = false }

        guard let page = await model.fetchMessages(
            in: source, anchor: .id(newest), before: 0, after: Self.detachedPageSize, includeAnchor: false
        ), hasMoreNewer else { return }
        detached += page.messages
        if !joinIfReached(page) { showDetached() }
    }

    private func loadOlderDetached(before oldest: Int) async {
        guard let page = await model.fetchMessages(
            in: source, anchor: .id(oldest), before: Self.detachedPageSize, after: 0, includeAnchor: false
        ) else { return }
        if page.found_oldest || (page.history_limited ?? false) { hasMoreOlder = false }
        // Reached the stored history while this was in flight: what it fetched sits
        // right before the stored messages now, so it is stored with them.
        guard hasMoreNewer else {
            model.save(page.messages)
            return
        }
        detached = page.messages + detached
        showDetached()
    }

    /// A page that reaches the newest message, or overlaps what is stored, closes the
    /// gap: everything fetched is saved, and the store takes over.
    private func joinIfReached(_ page: MessagesPage) -> Bool {
        guard page.found_newest || model.storesAny(of: page.messages.map(\.id)) else { return false }
        model.save(detached)
        detached = []
        hasMoreNewer = false
        observe()
        return true
    }

    private func showDetached() {
        guard let selfUserID = model.selfUserID else { return }
        let messages = detached.map { MessageRecord(from: $0, selfUserID: selfUserID) }
        let reactions = detached.flatMap { message in
            message.reactions.map { ReactionRecord(messageID: message.id, reaction: $0) }
        }
        apply(ConversationSnapshot(
            messages: messages, reactions: reactions,
            firstUnreadID: firstUnread.resolve(in: messages), selfUserID: selfUserID
        ))
    }

    private func highlight(_ id: Int) {
        highlightedID = id
        Task { [weak self] in
            try? await Task.sleep(for: Self.highlightDuration)
            self?.highlightedID = nil
        }
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
        self.init(messages: rows.messages, reactions: rows.reactions, firstUnreadID: firstUnreadID, selfUserID: selfUserID)
    }

    init(messages: [MessageRecord], reactions: [ReactionRecord], firstUnreadID: Int?, selfUserID: Int?) {
        self.messages = messages
        self.firstUnreadID = firstUnreadID
        grouped = Self.group(messages, firstUnreadID: firstUnreadID)
        self.reactions = Dictionary(grouping: reactions, by: \.messageID)
            .mapValues { ReactionGroup.group($0, selfUserID: selfUserID) }
        // The first value is read on the main thread, where parsing every body would
        // hold up the frame it is read for.
        if !Thread.isMainThread { Self.parse(messages.map(\.renderedContent)) }
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
