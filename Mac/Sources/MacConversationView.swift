import SwiftUI
import UniformTypeIdentifiers
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
            .background(.bar)
        }
        .macAutocompleteBox()
        .overlay {
            if dropTargeted {
                MacDropHint()
            }
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
        }
        .environment(\.macQuickReactions, quickReactions)
        .task(id: source) {
            self.loader?.stop()
            let loader = MessageHistoryLoader(source: source, model: model)
            self.loader = loader
            readTracker = ReadTracker { ids in await model.markRead(ids) }
            // Nothing is marked read here: a conversation opens at its first unread, and
            // the rows the reader scrolls past mark themselves.
            await loader.start()
        }
        .task {
            // The hover bar's emoji are the realm's habits, looked up once per
            // conversation rather than once per message hovered.
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

/// The top of history, so scrolling back ends at a statement rather than a blank.
private struct MacConversationStart: View {
    let title: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "sparkles").foregroundStyle(.tertiary)
            Text("This is the beginning of \(title).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
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

    @State private var scroll = ScrollPosition(idType: Int.self)
    @State private var atBottom = true
    @State private var following = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if loader.isLoadingOlder {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 36)
                } else if !loader.hasMoreOlder, !loader.messages.isEmpty {
                    MacConversationStart(title: title)
                }
                ForEach(loader.grouped) { entry in
                    VStack(alignment: .leading, spacing: 0) {
                        if entry.startsDay {
                            DayDivider(date: entry.message.date).padding(.top, 12)
                        }
                        if entry.message.id == loader.firstUnreadID {
                            UnreadDivider().padding(.top, 10)
                        }
                        MessageRow(
                            message: entry.message,
                            startsGroup: entry.startsGroup,
                            reactions: loader.reactions[entry.message.id] ?? []
                        )
                        .padding(.top, entry.startsGroup ? 12 : 1)
                        .padding(.bottom, 1)
                        .macMessageActions(entry.message, in: source)
                    }
                    .onAppear { readTracker?.sawMessage(id: entry.message.id) }
                    .id(entry.message.id)
                }

                ForEach(model.pendingEntries(in: source, after: loader.messages)) { pending in
                    PendingMessageRow(message: pending.entry, startsGroup: pending.startsGroup)
                        .padding(.top, pending.startsGroup ? 12 : 1)
                        .padding(.bottom, 1)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Holds the bottom row, as the phone does, so a taller composer or an image
        // loading above leaves the newest messages where they were.
        .scrollPosition($scroll, anchor: .bottom)
        .defaultScrollAnchor(.bottom)
        .onAppear {
            if let firstUnread = loader.firstUnreadID { scroll.scrollTo(id: firstUnread, anchor: .top) }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { following = false }
            loader.noteScrollPhase(phase)
        }
        .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.1) { visible in
            loader.noteVisible(visible)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            ConversationScroll.isNearBottom(geometry)
        } action: { _, isNearBottom in
            atBottom = isNearBottom
            if isNearBottom { following = false }
            if isNearBottom {
                Task { await model.markConversationRead(source) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if !atBottom, !following {
                    Button {
                        withAnimation(.snappy) { scroll.scrollTo(edge: .bottom) }
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
            .animation(.snappy(duration: 0.2), value: atBottom || following)
        }
        .onChange(of: loader.messages.last?.id) { _, newest in
            guard atBottom || following, newest != nil else { return }
            followNewest()
        }
        .onChange(of: loader.newestReactions) {
            guard atBottom || following else { return }
            followNewest()
        }
        // Sending always shows what was sent, even from partway up the history.
        .onChange(of: model.outbox.count(in: source)) { old, new in
            guard new > old else { return }
            followNewest()
        }
    }

    /// Without animation, so the jump lands in the same frame as the message.
    private func followNewest() {
        following = true
        scroll.scrollTo(edge: .bottom)
    }
}
