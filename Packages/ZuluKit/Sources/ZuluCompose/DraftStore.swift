import Foundation

/// What the person had typed into one conversation's composer, and who they were
/// answering.
public struct SavedDraft: Codable, Equatable, Sendable {
    public var text: String
    public var reply: SavedReply?

    public init(text: String, reply: SavedReply? = nil) {
        self.text = text
        self.reply = reply
    }

    public var isEmpty: Bool { text.isEmpty && reply == nil }
}

public struct SavedReply: Codable, Equatable, Sendable {
    public let messageID: Int
    public let author: String
    public let authorID: Int?
    public let preview: String
    /// The quoted message's HTML. Drafts saved before this was kept have none.
    public let renderedContent: String?

    public init(messageID: Int, author: String, authorID: Int?, preview: String, renderedContent: String? = nil) {
        self.messageID = messageID
        self.author = author
        self.authorID = authorID
        self.preview = preview
        self.renderedContent = renderedContent
    }
}

/// Where drafts are kept between launches. One blob, since they are read all at once.
public protocol DraftStorage: Sendable {
    func load() -> Data?
    func save(_ data: Data?)
}

public struct UserDefaultsDraftStorage: DraftStorage {
    private let key: String

    /// `key` should name the account, so two accounts never see each other's drafts.
    public init(key: String) {
        self.key = key
    }

    public func load() -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    public func save(_ data: Data?) {
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Unsent drafts, one per conversation, so leaving a conversation mid-sentence and
/// coming back finds the sentence still there.
@MainActor
public final class DraftStore {
    private let storage: DraftStorage
    private var drafts: [String: SavedDraft]

    public init(storage: DraftStorage) {
        self.storage = storage
        // Unreadable drafts are dropped rather than blocking the composer.
        drafts = storage.load().flatMap { try? JSONDecoder().decode([String: SavedDraft].self, from: $0) } ?? [:]
    }

    public func draft(for conversation: String) -> SavedDraft? {
        drafts[conversation]
    }

    public func save(_ draft: SavedDraft, for conversation: String) {
        let stored = draft.isEmpty ? nil : draft
        guard drafts[conversation] != stored else { return }
        drafts[conversation] = stored
        storage.save(drafts.isEmpty ? nil : try? JSONEncoder().encode(drafts))
    }

    public func clear(_ conversation: String) {
        save(SavedDraft(text: ""), for: conversation)
    }

    public func removeAll() {
        drafts = [:]
        storage.save(nil)
    }
}
