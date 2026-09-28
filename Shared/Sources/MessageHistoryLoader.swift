import Foundation
import GRDB
import Observation
import SwiftUI
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
    private(set) var isLoadingOlder = false
    private(set) var hasMoreOlder = true
    /// Snapshotted on first load, so the divider does not vanish the moment the messages
    /// behind it are marked read.
    private(set) var firstUnreadID: Int?
    private(set) var isReady = false
    private(set) var reactions: [Int: [ReactionGroup]] = [:]

    private let source: ConversationSource
    private let model: AppModel
    private var scrollPhase: ScrollPhase = .idle
    private var observationTask: Task<Void, Never>?
    private var reactionTask: Task<Void, Never>?

    init(source: ConversationSource, model: AppModel) {
        self.source = source
        self.model = model
    }

    /// Called when the conversation closes. `deinit` cannot touch main-actor state, and
    /// leaving the observation running would keep writing into a view that is gone.
    func stop() {
        observationTask?.cancel()
        observationTask = nil
        reactionTask?.cancel()
        reactionTask = nil
    }

    func start() async {
        await loadInitialHistory()
        observeReactions()
        observe()
    }

    private func loadInitialHistory() async {
        switch source {
        case .topic(let channelID, let name, _):
            await model.loadHistory(channelID: channelID, topic: name)
        case .dm(let key):
            await model.loadHistory(dmKey: key)
        }
    }

    private func observe() {
        guard let writer = model.databaseWriter, let store = model.storeForReading else { return }
        let observation: ValueObservation<ValueReducers.Fetch<[MessageRecord]>> = switch source {
        case .topic(let channelID, let name, _):
            store.observeMessages(channelID: channelID, topic: name)
        case .dm(let key):
            store.observeMessages(dmKey: key)
        }

        observationTask = Task { [weak self] in
            do {
                for try await rows in observation.removeDuplicates().values(in: writer) {
                    guard let self else { return }
                    if !isReady {
                        firstUnreadID = rows.first { !$0.isRead }?.id
                        isReady = true
                    }
                    messages = rows
                    model.outbox.settle(landed: Set(rows.map(\.id)))
                }
            } catch {
                // Observation ends when the conversation closes; nothing to recover.
            }
        }
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

    /// Consecutive messages from one person collapse under a single header, the way every
    /// chat client does it. A long enough pause starts a new group even for the same sender,
    /// so a conversation picked up hours later does not read as one block.
    var grouped: [GroupedMessage] {
        var previous: MessageRecord?
        return messages.map { message in
            defer { previous = message }
            guard let previous else {
                return GroupedMessage(message: message, startsGroup: true, startsDay: true)
            }
            let startsDay = !Calendar.current.isDate(previous.date, inSameDayAs: message.date)
            let sameSender = previous.senderID == message.senderID
            let closeInTime = message.timestamp - previous.timestamp < Self.groupingWindow
            let continues = sameSender && closeInTime && !startsDay && message.id != firstUnreadID
            return GroupedMessage(message: message, startsGroup: !continues, startsDay: startsDay)
        }
    }

    /// Five minutes, matching what Discord and Slack settle on.
    static let groupingWindow = 5 * 60
}

struct GroupedMessage: Identifiable {
    let message: MessageRecord
    let startsGroup: Bool
    let startsDay: Bool

    var id: Int { message.id }
}

extension MessageHistoryLoader {
    /// Reactions arrive as one observation for the whole conversation. Watching them per
    /// message meant every row started empty and grew once its own query returned — and a
    /// lazy row that gains height after it has been measured is not reliably re-laid-out,
    /// so the chips never appeared at all.
    func observeReactions() {
        guard let writer = model.databaseWriter, let store = model.storeForReading else { return }
        reactionTask = Task { [weak self] in
            do {
                for try await records in store.observeAllReactions().removeDuplicates().values(in: writer) {
                    guard let self else { return }
                    let byMessage = Dictionary(grouping: records, by: \.messageID)
                    reactions = byMessage.mapValues {
                        ReactionGroup.group($0, selfUserID: model.selfUserID)
                    }
                }
            } catch {
                // Ends with the conversation; nothing to recover.
            }
        }
    }
}
