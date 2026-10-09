// PROTOTYPE — throwaway. Fake conversation that reproduces the layout churn the real app
// sees: pending rows that confirm with a different height, images that load late,
// incoming messages, and older history prepended at the top.
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    /// Server id. Pending rows have none.
    let id: Int
    /// Stays the same from pending to confirmed, so a list keyed on it sees one row.
    let rowID: Int
    let author: String
    let text: String
    let hasImage: Bool
    let sent: Date?

    var isPending: Bool { sent == nil }
}

@MainActor
@Observable
final class ChatStore {
    private(set) var messages: [ChatMessage] = []
    private(set) var pending: [ChatMessage] = []
    private(set) var sentCount = 0
    private(set) var isLoadingOlder = false
    private(set) var hasMoreOlder = true
    var incomingEnabled = false {
        didSet { incomingEnabled ? startIncoming() : incoming?.cancel() }
    }
    var confirmDelay: Duration = .milliseconds(700)

    /// Pending and confirmed in one list, keyed on `rowID`.
    var rows: [ChatMessage] { messages + pending }

    @ObservationIgnored private var nextServerID = 10_000
    @ObservationIgnored private var nextLocalID = -1
    @ObservationIgnored private var oldestServerID = 10_000
    @ObservationIgnored private var incoming: Task<Void, Never>?
    @ObservationIgnored var loadedImages: Set<Int> = []

    static let pageSize = 30
    static let maxPages = 5

    init() {
        messages = Self.page(endingBefore: nextServerID)
        oldestServerID = messages.first?.id ?? nextServerID
    }

    func send(_ text: String) {
        let localID = nextLocalID
        nextLocalID -= 1
        pending.append(ChatMessage(id: localID, rowID: localID, author: "me", text: text, hasImage: false, sent: nil))
        sentCount += 1
        Task {
            try? await Task.sleep(for: confirmDelay)
            pending.removeAll { $0.rowID == localID }
            messages.append(ChatMessage(id: takeServerID(), rowID: localID, author: "me", text: text, hasImage: false, sent: .now))
        }
    }

    func loadOlder() {
        guard !isLoadingOlder, hasMoreOlder else { return }
        isLoadingOlder = true
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            let older = Self.page(endingBefore: oldestServerID)
            oldestServerID = older.first?.id ?? oldestServerID
            messages.insert(contentsOf: older, at: 0)
            hasMoreOlder = messages.count < Self.pageSize * Self.maxPages
            isLoadingOlder = false
        }
    }

    func receiveOne() {
        let id = takeServerID()
        messages.append(ChatMessage(
            id: id, rowID: id, author: Self.authors[id % Self.authors.count],
            text: Self.lines[id % Self.lines.count], hasImage: id % 4 == 0, sent: .now
        ))
    }

    private func takeServerID() -> Int {
        defer { nextServerID += 1 }
        return nextServerID
    }

    private func startIncoming() {
        incoming?.cancel()
        incoming = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                receiveOne()
            }
        }
    }

    private static func page(endingBefore end: Int) -> [ChatMessage] {
        (end - pageSize ..< end).map { id in
            ChatMessage(
                id: id, rowID: id, author: authors[abs(id) % authors.count],
                text: lines[abs(id) % lines.count], hasImage: id % 9 == 0,
                sent: Date(timeIntervalSinceNow: TimeInterval(id - end) * 60)
            )
        }
    }

    private static let authors = ["alex", "sam", "jordan", "me", "riley"]
    private static let lines = [
        "ok",
        "Did the deploy go out?",
        "Yeah, finished about ten minutes ago. Watching the dashboards now.",
        "The migration took longer than expected because the index rebuild locked the table for a while, so some requests queued up behind it. Nothing failed though.",
        "👍",
        "Can you look at the flaky test in the sync package when you get a chance? It fails maybe one run in twenty.",
        "sure",
        "Here's the trace from last night.\nLine two of the message.\nAnd a third line to make it tall.",
        "lol",
        "I think the keyboard inset is being counted twice somewhere, the list jumps past the end after sending.",
    ]
}
