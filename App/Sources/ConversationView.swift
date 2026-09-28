import SwiftUI
import ZuluEmoji
import ZuluScroll
import ZuluStore

/// One conversation: a channel topic, or a DM. Reads messages out of the store and
/// backfills history, since the event queue only carries what arrives after it opened.
struct ConversationView: View {
    /// Spelled out here as well because the whole iOS shell navigates by
    /// `ConversationView.Source`, and the type itself is shared with the Mac app.
    typealias Source = ConversationSource

    let source: Source
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var loader: MessageHistoryLoader?
    @State private var readTracker: ReadTracker?

    var body: some View {
        Group {
            if let loader, loader.isReady {
                ConversationHistory(source: source, loader: loader, readTracker: readTracker)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 0) {
                TypingIndicatorView(source: source)
                ComposerBar(source: source, placeholder: placeholder)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .topic(_, _, let channelName) = source {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title).font(.headline).lineLimit(1)
                        // The alias is what the sidebar shows; the real name lives here
                        // so a reference to it elsewhere is still recognisable.
                        Text(model.headerSubtitle(forChannel: channelName))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let forum = forumChannel {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("All topics", systemImage: "list.bullet") {
                        model.destination = .channel(forum.id)
                    }
                }
            }
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
        .onDisappear {
            loader?.stop()
            Task { await readTracker?.flushNow() }
        }
        // Leaving the app never fires `onDisappear`, and a suspended app sends nothing.
        .onChange(of: scenePhase) {
            if scenePhase == .background { flushBeforeSuspending() }
        }
    }

    private func flushBeforeSuspending() {
        let application = UIApplication.shared
        let flushing = Task { await readTracker?.flushNow() }
        let assertion = application.beginBackgroundTask { flushing.cancel() }
        Task {
            await flushing.value
            application.endBackgroundTask(assertion)
        }
    }

    private var forumChannel: ChannelSummary? {
        guard case .topic(let channelID, _, _) = source,
              let channel = model.channel(channelID), channel.rendersAsForum
        else { return nil }
        return channel
    }

    private var title: String {
        switch source {
        case .topic(_, let name, _): name.isEmpty ? "general chat" : name
        case .dm(let key): model.title(forDM: key)
        }
    }

    private var placeholder: String {
        switch source {
        case .topic(_, let name, _): "Message \(name.isEmpty ? "general chat" : name)"
        case .dm(let key): "Message \(model.title(forDM: key))"
        }
    }
}


/// The message list, apart from the toolbar and title around it. Those read sidebar data
/// that changes on every sync; in the same view, each of those changes rebuilt the whole
/// list.
private struct ConversationHistory: View {
    let source: ConversationView.Source
    let loader: MessageHistoryLoader
    let readTracker: ReadTracker?

    @Environment(AppModel.self) private var model
    @State private var scroll: ConversationScrollManager

    init(source: ConversationView.Source, loader: MessageHistoryLoader, readTracker: ReadTracker?) {
        self.source = source
        self.loader = loader
        self.readTracker = readTracker
        _scroll = State(initialValue: ConversationScrollManager(opensAt: loader.firstUnreadID))
    }

    var body: some View {
        @Bindable var scroll = scroll
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Outside the ForEach and deliberately unidentified: a row that appears and
                // disappears inside the stack changes its subview count, which is one of the
                // documented causes of lazy-stack jank.
                if loader.isLoadingOlder {
                    ProgressView().frame(maxWidth: .infinity).frame(height: 44)
                }

                ForEach(loader.grouped) { entry in
                    // One child per message, always. Yielding nothing for some rows would
                    // change the stack's shape as the data moves.
                    VStack(alignment: .leading, spacing: 0) {
                        if entry.startsDay {
                            DayDivider(date: entry.message.date).padding(.top, 14)
                        }
                        if entry.message.id == loader.firstUnreadID {
                            UnreadDivider().padding(.top, 10)
                        }
                        MessageRow(
                            message: entry.message,
                            startsGroup: entry.startsGroup,
                            reactions: loader.reactions[entry.message.id] ?? []
                        )
                            .padding(.top, entry.startsGroup ? 14 : 2)
                            .swipeToReply {
                                ComposerInbox.shared.deliver(
                                    reply: ReplyDraft(message: entry.message),
                                    to: ConversationKey.of(source)
                                )
                            }
                    }
                    .onAppear { readTracker?.sawMessage(id: entry.message.id) }
                    .id(entry.message.id)
                }

                ForEach(model.pendingEntries(in: source, after: loader.messages)) { pending in
                    PendingMessageRow(message: pending.entry, startsGroup: pending.startsGroup)
                        .padding(.top, pending.startsGroup ? 14 : 2)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DisablesScrollToTop().frame(width: 0, height: 0))
        }
        // Anchoring by item identity is what keeps the view still while older messages are
        // prepended. Everything about following the newest message lives in the manager.
        .scrollPosition($scroll.position, anchor: .bottom)
        .defaultScrollAnchor(.bottom)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onScrollPhaseChange { _, phase in
            scroll.scrollPhaseChanged(to: phase)
            loader.noteScrollPhase(phase)
        }
        .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.1) { visible in
            loader.noteVisible(visible)
        }
        .onScrollGeometryChange(for: ConversationLayout.self) { geometry in
            ConversationLayout(geometry)
        } action: { _, layout in
            scroll.layoutChanged(to: layout)
        }
        // Scrolling back down after reading history, and catching up on messages that
        // arrived while the conversation was open, both land here.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            ConversationLayout(geometry).isNearBottom
        } action: { _, isNearBottom in
            if isNearBottom { Task { await model.markConversationRead(source) } }
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if scroll.showsJumpToNewest {
                    Button {
                        scroll.jumpToNewest()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            // Scoped to the button. On the whole list it also animated whatever else
            // changed in the same update, like a message landing.
            .animation(.snappy(duration: 0.2), value: scroll.showsJumpToNewest)
        }
        // Sending always shows what was sent, even from partway up the history.
        .onChange(of: model.outbox.count(in: source)) { old, new in
            guard new > old else { return }
            scroll.didSend()
        }
    }
}
