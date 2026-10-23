import SwiftUI
import UniformTypeIdentifiers
import ZuluScroll
import ZuluStore

/// One conversation on the Mac: the same message history the phone shows, with a
/// composer that sends on Return and a hover bar on every message.
struct MacConversationView: View {
    let source: ConversationSource

    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui

    @State private var loader: MessageHistoryLoader?
    @State private var readTracker: ReadTracker?
    @State private var quickReactions: [QuickReaction] = []
    @State private var dropTargeted = false
    /// Observed rather than read, so the bell changes the moment the topic is muted —
    /// from here, the menu bar, or another device.
    @State private var mutedTopics: [MutedTopicRecord] = []

    var body: some View {
        Group {
            if let loader, loader.isReady {
                MacConversationHistory(source: source, loader: loader, readTracker: readTracker, title: title)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                TypingIndicatorView(source: source)
                MacComposerBar(source: source, placeholder: placeholder)
            }
            // Behind the typing line too, or history scrolled under it shows through.
            .background(Platform.canvas)
        }
        .macAutocompleteBox()
        .overlay {
            if dropTargeted {
                MacDropHint()
            }
        }
        .confirmationDialog(
            "Delete this message?",
            isPresented: Binding(
                get: { ui.confirmingDeleteOf != nil },
                set: { if !$0 { ui.confirmingDeleteOf = nil } }
            ),
            presenting: ui.confirmingDeleteOf
        ) { message in
            Button("Delete", role: .destructive) {
                Task { _ = await MessageActionsController(message: message, model: model).delete() }
            }
        } message: { _ in
            Text("It is deleted for everyone, and cannot be undone.")
        }
        // Anything dragged in from the Finder is an attachment, wherever it lands.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await model.uploadAndDeliver(files: files, to: ConversationKey.of(source)) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        // Without a background the title sits directly on top of the newest message.
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            if let forum = forumChannel {
                ToolbarItem(placement: .automatic) {
                    Button {
                        model.destination = .channel(forum.id)
                    } label: {
                        Label("All Topics", systemImage: "list.bullet")
                    }
                    .help("All topics in #\(forum.name)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        ui.newTopicChannel = ChannelSummaryBox(channel: forum)
                    } label: {
                        Label("New Topic", systemImage: "square.and.pencil")
                    }
                    .help("New topic in #\(forum.name)  ⇧⌘N")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await model.markConversationRead(source) }
                } label: {
                    Label("Mark as Read", systemImage: "checkmark.circle")
                }
                .disabled(unreadCount == 0)
                .help("Mark as Read  ⇧⎋")
            }
            if case .topic(let channelID, let name, _) = source {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Section("This Topic") {
                            NotificationLevelMenu.topic(name, inChannel: channelID, model: model).flattened()
                        }
                        if let channel = model.channel(channelID) {
                            Section {
                                Menu("#\(channel.name)") {
                                    NotificationLevelMenu.channel(channelID, model: model).flattened()
                                }
                            }
                        }
                    } label: {
                        Label("Notifications", systemImage: isMuted ? "bell.slash" : "bell")
                    }
                    .help(isMuted ? "Muted  ⇧⌘M to unmute" : "Notifications for this topic  ⇧⌘M to mute")
                }
            }
        }
        .environment(\.macQuickReactions, quickReactions)
        .task(id: source) {
            guard case .topic(let channelID, _, _) = source,
                  let writer = model.databaseWriter,
                  let observation = model.mutedTopicObservation(inChannel: channelID)
            else { return }
            do {
                for try await rows in observation.removeDuplicates().values(in: writer) { mutedTopics = rows }
            } catch {}
        }
        .task(id: source) {
            self.loader?.stop()
            let loader = MessageHistoryLoader(source: source, model: model)
            self.loader = loader
            readTracker = ReadTracker { ids in await model.markRead(ids) }
            // Nothing is marked read here: a conversation opens at its first unread, and
            // the rows the reader scrolls past mark themselves.
            await loader.start()
        }
        .task(id: model.reactionHistoryVersion) {
            // The quick row's emoji are the viewer's habits, looked up once per
            // conversation and again after each reaction, not once per message.
            quickReactions = MacQuickReactionsLoader.load(model: model)
        }
        .onChange(of: ui.markReadRequests) {
            Task { await model.markConversationRead(source) }
        }
        .onDisappear {
            loader?.stop()
            Task { await readTracker?.flushNow() }
        }
    }

    private var title: String {
        switch source {
        case .topic(_, let name, _): name.isEmpty ? "general chat" : name
        case .dm(let key): model.title(forDM: key)
        }
    }

    private var subtitle: String {
        switch source {
        case .topic(_, _, let channelName):
            return model.headerSubtitle(forChannel: channelName)
        case .dm(let key):
            let others = key.split(separator: ",").compactMap { Int($0) }.filter { $0 != model.selfUserID }
            return others.count > 1 ? "Group direct message" : "Direct message"
        }
    }

    private var placeholder: String {
        switch source {
        case .topic(_, let name, _): "Message \(name.isEmpty ? "general chat" : name)"
        case .dm(let key): "Message \(model.title(forDM: key))"
        }
    }

    private var isMuted: Bool {
        guard case .topic(_, let name, _) = source else { return false }
        return mutedTopics.contains { $0.topic == name }
    }

    private var forumChannel: ChannelSummary? {
        guard case .topic(let channelID, _, _) = source,
              let channel = model.channel(channelID), channel.rendersAsForum
        else { return nil }
        return channel
    }

    /// Read off the sidebar's own summaries, so the toolbar button greys out the moment
    /// the conversation is caught up.
    private var unreadCount: Int {
        switch source {
        case .dm(let key): model.dms.first { $0.dmKey == key }?.unreadCount ?? 0
        case .topic(let channelID, let name, _):
            model.recentTopics[channelID]?.first { $0.name == name }?.unreadCount
                ?? (model.channel(channelID)?.unreadCount ?? 0)
        }
    }
}

private struct MacDropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                Label("Drop to attach", systemImage: "paperclip")
                    .font(.title3.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(12)
            .allowsHitTesting(false)
    }
}

// MARK: - Quick reactions

/// The realm's habits, computed the same way the phone's action sheet computes them.
enum MacQuickReactionsLoader {
    @MainActor
    static func load(model: AppModel, count: Int = 3) -> [QuickReaction] {
        // The controller does the resolution; the message it is built for is irrelevant
        // to which emoji are popular here.
        let probe = MessageRecord(
            id: 0, channelID: nil, topic: nil, dmKey: nil, senderID: 0, senderName: "",
            senderAvatar: nil, renderedContent: "", timestamp: 0, isRead: true,
            isMentioned: false, editedAt: nil, isWidget: false
        )
        let controller = MessageActionsController(message: probe, model: model)
        controller.loadQuickReactions()
        return Array(controller.quickReactions.prefix(count))
    }
}

private struct MacQuickReactionsKey: EnvironmentKey {
    static let defaultValue: [QuickReaction] = []
}

extension EnvironmentValues {
    var macQuickReactions: [QuickReaction] {
        get { self[MacQuickReactionsKey.self] }
        set { self[MacQuickReactionsKey.self] = newValue }
    }
}

// MARK: - Uploads from outside the composer

extension AppModel {
    /// Uploads files dropped anywhere on a conversation and hands the resulting markdown
    /// to that conversation's composer, which appends it like any other delivery.
    func uploadAndDeliver(files: [URL], to conversation: String) async {
        for url in files {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            if case .success(let markdown) = await upload(
                data, filename: url.lastPathComponent, contentType: type.preferredMIME
            ) {
                ComposerInbox.shared.deliver(markdown + "\n", to: conversation)
            }
        }
    }
}

/// The message list, apart from the toolbar and title around it. Those read sidebar data
/// that changes on every sync; in the same view, each of those changes rebuilt the whole
/// list, and a sync after waking rebuilt it once per channel.
private struct MacConversationHistory: View {
    let source: ConversationSource
    let loader: MessageHistoryLoader
    let readTracker: ReadTracker?
    let title: String

    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @Environment(AttachmentPreviewer.self) private var previewer
    @Environment(\.openURL) private var openURL
    @Environment(\.macQuickReactions) private var quickReactions
    @State private var scroll = MacConversationScroll()

    var body: some View {
        MacConversationTable(
            rows: rows,
            context: MacConversationCellContext(
                model: model, ui: ui, previewer: previewer, openURL: openURL,
                quickReactions: quickReactions, source: source
            ),
            scroll: scroll,
            loader: loader,
            readTracker: readTracker
        )
        .onChange(of: scroll.isNearBottom, initial: true) { _, isNearBottom in
            if isNearBottom {
                model.liveEdgeReached(in: source)
                Task { await model.markConversationRead(source) }
            } else {
                model.liveEdgeLeft(in: source)
            }
        }
        .onDisappear { model.liveEdgeLeft(in: source) }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if scroll.showsJumpToNewest {
                    Button {
                        scroll.jumpToNewest()
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.quaternary))
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .padding(.bottom, 12)
                    .transition(.scale.combined(with: .opacity))
                    .help("Jump to newest")
                }
            }
            .animation(.snappy(duration: 0.2), value: scroll.showsJumpToNewest)
        }
        .onChange(of: model.outbox.count(in: source)) { old, new in
            guard new > old else { return }
            scroll.didSend()
        }
    }

    private var rows: [MacConversationRow] {
        var rows: [MacConversationRow] = [.top(top)]
        rows.reserveCapacity(loader.grouped.count + 2)
        for entry in loader.grouped {
            rows.append(.message(
                entry,
                reactions: loader.reactions[entry.id] ?? [],
                isFirstUnread: entry.message.id == loader.firstUnreadID
            ))
        }
        for pending in model.pendingEntries(in: source, after: loader.messages) {
            rows.append(.pending(pending))
        }
        return rows
    }

    private var top: MacConversationTop {
        if loader.isLoadingOlder { return .loading }
        if !loader.hasMoreOlder, !loader.messages.isEmpty { return .start(title: title) }
        return .margin
    }
}
