import Foundation
import ZulipAPI
import ZuluEmoji
import ZuluStore

public enum SyncStatus: Sendable, Equatable {
    case idle
    case connecting
    case live
    case failed(String)
}

/// Owns the event queue. Registers, long-polls, and writes what arrives into the store.
/// Nothing else talks to the events API.
public actor SyncEngine {
    private let client: ZulipClient
    private let store: ZuluStore
    private let selfUserID: Int

    private var queueID: String?
    private var lastEventID: Int = -1
    private var task: Task<Void, Never>?

    /// Consecutive transport failures, used only to space out retries.
    private var backoffStep = 0

    public private(set) var status: SyncStatus = .idle
    private var statusHandler: (@Sendable (SyncStatus) -> Void)?

    public init(client: ZulipClient, store: ZuluStore, selfUserID: Int) {
        self.client = client
        self.store = store
        self.selfUserID = selfUserID
    }

    public func onStatusChange(_ handler: @escaping @Sendable (SyncStatus) -> Void) {
        statusHandler = handler
        handler(status)
    }

    private var arrivalHandler: (@Sendable (ZulipMessage, _ localID: String?) -> Void)?

    /// Called for each message the event queue delivers, once it is in the store.
    ///
    /// Only the live queue passes through here. The register snapshot and history
    /// backfills are the past, and a notification is about now.
    /// The queue a send should name so its echo comes back tagged. `nil` while
    /// registering, when a send simply goes untagged.
    public var currentQueueID: String? { queueID }

    public func onMessageArrival(_ handler: @escaping @Sendable (ZulipMessage, _ localID: String?) -> Void) {
        arrivalHandler = handler
    }

    private var typingHandler: (@Sendable (TypingEvent) -> Void)?

    /// Typing is never stored: it is only true for the next few seconds.
    public func onTyping(_ handler: @escaping @Sendable (TypingEvent) -> Void) {
        typingHandler = handler
    }

    private func setStatus(_ new: SyncStatus) {
        guard status != new else { return }
        status = new
        statusHandler?(new)
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
        setStatus(.idle)
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                if queueID == nil { try await registerQueue() }
                guard let queueID else { continue }

                let batch = try await client.events(queueID: queueID, lastEventID: lastEventID)
                let failure = await apply(batch.events)
                lastEventID = max(lastEventID, batch.lastEventID)
                try store.saveSyncState(queueID: queueID, lastEventID: lastEventID)

                backoffStep = 0
                // One event the store refuses must not stop the queue: the batch is
                // acknowledged either way, and the refusal is shown until the next batch
                // goes through cleanly.
                setStatus(failure.map { .failed($0.localizedDescription) } ?? .live)
            } catch let error as ZulipError where error.code == "BAD_EVENT_QUEUE_ID" {
                // The queue expired. There is no partial resync: re-register and refetch.
                queueID = nil
                lastEventID = -1
                setStatus(.connecting)
            } catch is CancellationError {
                return
            } catch {
                setStatus(.failed(error.localizedDescription))
                await backoff()
            }
        }
    }

    private func backoff() async {
        backoffStep = min(backoffStep + 1, 6)
        let seconds = min(pow(2.0, Double(backoffStep)), 60)
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func registerQueue() async throws {
        setStatus(.connecting)
        let registration = try await client.register()
        queueID = registration.queue_id
        lastEventID = registration.last_event_id

        if let subscriptions = registration.subscriptions {
            try store.replaceChannels(subscriptions)
            try store.replaceSubscribers(subscriptions)
        }
        if let emoji = registration.realm_emoji {
            try store.replaceRealmEmoji(emoji)
        }
        if let groups = registration.realm_user_groups {
            try store.replaceUserGroups(groups, selfUserID: selfUserID)
        }
        if let userTopics = registration.user_topics {
            try store.replaceMutedTopics(userTopics)
        }
        if let unread = registration.unread_msgs {
            try store.replaceUnread(unread, selfUserID: selfUserID)
        }
        if let users = registration.realm_users {
            try store.saveUsers(users)
        }
        try store.saveSyncState(queueID: queueID, lastEventID: lastEventID)
        setStatus(.live)

        let emojiDataURL = registration.server_emoji_data_url
        Task { [weak self] in await self?.loadServerEmojiData(from: emojiDataURL) }

        await refreshTopics()
        await loadRecentDirectMessages()
    }

    /// Topics are not in the register snapshot and there is no bulk endpoint, so each
    /// subscribed channel is asked individually. Cheap enough at realistic channel counts.
    public func refreshTopics() async {
        guard let channels = try? store.channels() else { return }
        for channel in channels {
            guard !Task.isCancelled else { return }
            if let topics = try? await client.topics(inChannel: channel.id) {
                try? store.saveTopics(topics, inChannel: channel.id)
                try? store.refreshDetectedMode(forChannel: channel.id)
                // A promotion points at a topic name, and names move. Once the real
                // list is in hand, promotions with nothing behind them are dropped.
                try? store.pruneVanishedPromotions(inChannel: channel.id)
            }
        }
    }

    /// Applies every event, and reports the first error rather than stopping at it.
    private func apply(_ events: [ZulipEvent]) async -> Error? {
        var failure: Error?
        for event in events {
            do {
                try await apply(event)
            } catch {
                failure = failure ?? error
            }
        }
        return failure
    }

    private func apply(_ event: ZulipEvent) async throws {
        switch event {
        case .message(let message, let localID):
            try store.save(messages: [message], selfUserID: selfUserID)
            try store.noteArrival(of: message, selfUserID: selfUserID)
            arrivalHandler?(message, localID)

        case .deleteMessage(let ids):
            try store.deleteMessages(ids: ids)

        case .flags(let operation, let flag, _, let all) where flag == "read" && all && operation == "add":
            try store.markEverythingRead()

        case .flags(let operation, let flag, let messageIDs, _) where flag == "read":
            try store.setRead(ids: messageIDs, read: operation == "add")
            if operation == "add" { try store.clearUnread(ids: messageIDs) }

        case .updateMessage(let id, let renderedContent, let editedAt):
            if let renderedContent {
                try store.updateRenderedContent(id: id, html: renderedContent, editedAt: editedAt)
            }

        case .reaction(let added, let messageID, let reaction):
            try store.setReaction(reaction, onMessage: messageID, added: added)

        case .submessage(let submessage):
            try store.apply(submessage)

        case .subscriptionsChanged:
            if let subscriptions = try? await client.subscriptions() {
                try store.replaceChannels(subscriptions)
                try store.replaceSubscribers(subscriptions)
            }

        case .realmEmojiChanged(let emoji):
            try store.replaceRealmEmoji(emoji)

        case .userGroupsChanged:
            if let groups = try? await client.userGroups() {
                try store.replaceUserGroups(groups, selfUserID: selfUserID)
            }

        case .userTopic(let userTopic):
            try store.apply(userTopic)

        case .typing(let typing):
            typingHandler?(typing)

        case .flags, .heartbeat, .other:
            break
        }
    }
}

extension SyncEngine {
    /// Fetches the server's unicode emoji table, if it is not already cached.
    ///
    /// Nothing waits on this. The table is not needed to render a message — only to
    /// search emoji — and it cannot change without a server restart, so it is fetched
    /// after the queue is up and the picker simply shows the realm's own emoji until it
    /// lands. The URL may point off the realm entirely when static files are on a CDN,
    /// which is why the request carries no credentials.
    func loadServerEmojiData(from path: String?) async {
        guard let path, let url = URL(string: path, relativeTo: client.realmURL)?.absoluteURL else {
            return
        }
        let cached = try? store.cachedServerEmojiData()
        // A new URL means a new content hash, so the cached body is already stale and
        // its ETag would only tell the server about a file that no longer exists.
        let etag = cached?.url == url.absoluteString ? cached?.etag : nil

        guard let fetched = try? await ServerEmojiDataFetch.fetch(
            from: url, etag: etag, userAgent: ZulipClient.userAgent
        ) else { return }

        guard let data = fetched.data else { return }
        guard let json = try? JSONEncoder().encode(data) else { return }
        try? store.saveServerEmojiData(url: url.absoluteString, etag: fetched.etag, json: json)
    }

    /// DM conversations are derived from the messages themselves — there is no endpoint
    /// that lists them. Without this initial fetch the DM list stays empty forever,
    /// because a conversation has to be listed before it can be opened and loaded.
    public func loadRecentDirectMessages(limit: Int = 300) async {
        guard let page = try? await client.messages(
            narrow: [.directMessages], anchor: .newest, before: limit
        ) else { return }
        try? store.save(messages: page.messages, selfUserID: selfUserID)
    }
}
