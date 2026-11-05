import Foundation
import Testing
@testable import ZuluCompose

/// Kept in memory, so a test can open a second store over the same blob and see what a
/// relaunch would.
private final class MemoryStorage: DraftStorage, @unchecked Sendable {
    var data: Data?
    private(set) var writes = 0

    init(data: Data? = nil) { self.data = data }

    func load() -> Data? { data }

    func save(_ data: Data?) {
        self.data = data
        writes += 1
    }
}

@MainActor
struct DraftStoreTests {
    private static let lunch = "c:7/lunch"
    private static let other = "d:3,5"
    private static let reply = SavedReply(messageID: 42, author: "Ana", authorID: 9, preview: "see you at noon", renderedContent: "<p>see you at noon</p>")

    @Test func aConversationWithNothingTypedHasNoDraft() {
        #expect(DraftStore(storage: MemoryStorage()).draft(for: Self.lunch) == nil)
    }

    @Test func aDraftComesBackForItsConversation() {
        let store = DraftStore(storage: MemoryStorage())
        store.save(SavedDraft(text: "half a thought"), for: Self.lunch)
        #expect(store.draft(for: Self.lunch) == SavedDraft(text: "half a thought"))
    }

    @Test func draftsDoNotLeakBetweenConversations() {
        let store = DraftStore(storage: MemoryStorage())
        store.save(SavedDraft(text: "one"), for: Self.lunch)
        store.save(SavedDraft(text: "two"), for: Self.other)
        #expect(store.draft(for: Self.lunch)?.text == "one")
        #expect(store.draft(for: Self.other)?.text == "two")
    }

    @Test func aDraftSurvivesARelaunch() {
        let storage = MemoryStorage()
        DraftStore(storage: storage).save(SavedDraft(text: "kept", reply: Self.reply), for: Self.lunch)
        let relaunched = DraftStore(storage: storage)
        #expect(relaunched.draft(for: Self.lunch) == SavedDraft(text: "kept", reply: Self.reply))
    }

    @Test func aReplyAloneIsWorthKeeping() {
        let store = DraftStore(storage: MemoryStorage())
        store.save(SavedDraft(text: "", reply: Self.reply), for: Self.lunch)
        #expect(store.draft(for: Self.lunch)?.reply == Self.reply)
    }

    @Test func whitespaceIsKeptAsTyped() {
        let store = DraftStore(storage: MemoryStorage())
        store.save(SavedDraft(text: "line one\n  "), for: Self.lunch)
        #expect(store.draft(for: Self.lunch)?.text == "line one\n  ")
    }

    @Test func emptyingADraftForgetsIt() {
        let storage = MemoryStorage()
        let store = DraftStore(storage: storage)
        store.save(SavedDraft(text: "gone soon"), for: Self.lunch)
        store.save(SavedDraft(text: ""), for: Self.lunch)
        #expect(store.draft(for: Self.lunch) == nil)
        #expect(DraftStore(storage: storage).draft(for: Self.lunch) == nil)
    }

    @Test func clearingForgetsOnlyThatConversation() {
        let store = DraftStore(storage: MemoryStorage())
        store.save(SavedDraft(text: "one"), for: Self.lunch)
        store.save(SavedDraft(text: "two"), for: Self.other)
        store.clear(Self.lunch)
        #expect(store.draft(for: Self.lunch) == nil)
        #expect(store.draft(for: Self.other)?.text == "two")
    }

    @Test func clearingTheLastDraftEmptiesStorage() {
        let storage = MemoryStorage()
        let store = DraftStore(storage: storage)
        store.save(SavedDraft(text: "one"), for: Self.lunch)
        store.clear(Self.lunch)
        #expect(storage.data == nil)
    }

    /// Restoring a draft into the composer saves it straight back; that must not cost
    /// a write per conversation opened.
    @Test func savingWhatIsAlreadyThereDoesNotWrite() {
        let storage = MemoryStorage()
        let store = DraftStore(storage: storage)
        store.save(SavedDraft(text: "same"), for: Self.lunch)
        store.save(SavedDraft(text: "same"), for: Self.lunch)
        store.clear(Self.other)
        #expect(storage.writes == 1)
    }

    @Test func unreadableStorageStartsEmptyAndRecovers() {
        let storage = MemoryStorage(data: Data("not json".utf8))
        let store = DraftStore(storage: storage)
        #expect(store.draft(for: Self.lunch) == nil)
        store.save(SavedDraft(text: "fresh"), for: Self.lunch)
        #expect(DraftStore(storage: storage).draft(for: Self.lunch)?.text == "fresh")
    }

    @Test func signingOutForgetsEveryDraft() {
        let storage = MemoryStorage()
        let store = DraftStore(storage: storage)
        store.save(SavedDraft(text: "one"), for: Self.lunch)
        store.save(SavedDraft(text: "two"), for: Self.other)
        store.removeAll()
        #expect(store.draft(for: Self.lunch) == nil)
        #expect(storage.data == nil)
        #expect(DraftStore(storage: storage).draft(for: Self.other) == nil)
    }

    @Test func accountsKeyedApartDoNotSeeEachOthersDrafts() {
        let work = "test.drafts.\(UUID().uuidString)"
        let home = "test.drafts.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: work)
            UserDefaults.standard.removeObject(forKey: home)
        }
        DraftStore(storage: UserDefaultsDraftStorage(key: work)).save(SavedDraft(text: "work"), for: Self.lunch)
        #expect(DraftStore(storage: UserDefaultsDraftStorage(key: work)).draft(for: Self.lunch)?.text == "work")
        #expect(DraftStore(storage: UserDefaultsDraftStorage(key: home)).draft(for: Self.lunch) == nil)
    }
}
