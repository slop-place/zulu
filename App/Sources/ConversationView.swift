import SwiftUI
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
    @Environment(\.isStandaloneConversation) private var isStandalone
    @Environment(\.pageSideInsets) private var pageSideInsets
    @Environment(\.isCoveredByList) private var isCoveredByList

    @State private var loader: MessageHistoryLoader?
    @State private var readTracker: ReadTracker?
    @State private var isSlowToLoad = false

    private static let spinnerDelay = Duration.milliseconds(350)
    @State private var suggestionBox = AutocompleteSlot()

    var body: some View {
        Group {
            if let loader, loader.isReady {
                // Apart from this view: the toolbar and title read sidebar data that
                // changes on every sync, and in the same view each change rebuilt the list.
                ConversationList(
                    source: source, title: title, loader: loader, readTracker: readTracker,
                    sideInsets: pageSideInsets
                )
                    .id(ObjectIdentifier(loader))
            } else {
                // Most conversations are drawn within a few frames. A spinner shown for
                // those few frames flashed on every switch, so it waits to be needed.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(isSlowToLoad ? 1 : 0)
                    .task {
                        try? await Task.sleep(for: Self.spinnerDelay)
                        isSlowToLoad = true
                    }
            }
        }
        .overlay(alignment: .bottom) { AutocompleteOverlay(slot: suggestionBox) }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 0) {
                TypingIndicatorView(source: source)
                ComposerBar(source: source, placeholder: placeholder, suggestionBox: suggestionBox)
            }
        }
        .overlay(alignment: .top) {
            if ScrollDebugReadout.isEnabled { ScrollDebugLabel().padding(.top, 4) }
        }
        .navigationTitle(title)
        // The alias is what the sidebar shows; the real name lives here so a reference to
        // it elsewhere is still recognisable. The system's own subtitle rather than a
        // custom title view: a custom one cannot sit in the bar down a foldable's side,
        // and it surfaced as an empty bubble under the composer every time a topic opened.
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // While the list is still showing, closed, the toolbar is the list's: these
            // belong to the conversation, and "All topics" would replace it.
            if let forum = forumChannel, !isCoveredByList {
                if !isStandalone {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("All topics", systemImage: "list.bullet") {
                            model.destination = .channel(forum.id)
                        }
                    }
                    .sideBarItem()
                }
                ToolbarItem(placement: .topBarTrailing) { NewTopicButton(channel: forum) }
                    .sideBarItem()
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

    private var subtitle: String {
        if case .topic(_, _, let channelName) = source {
            return model.headerSubtitle(forChannel: channelName)
        }
        return ""
    }

    private var placeholder: String {
        switch source {
        case .topic(_, let name, _): "Message \(name.isEmpty ? "general chat" : name)"
        case .dm(let key): "Message \(model.title(forDM: key))"
        }
    }
}

private extension ToolbarContent {
    /// Goes down the side with the back button wherever bars run vertically, as on a
    /// foldable's displays. Left to decide while a conversation was being pushed, the
    /// system laid these out as a bar along the bottom first, an empty bubble under the
    /// composer that pushed it up for half a second.
    @ToolbarContentBuilder
    func sideBarItem() -> some ToolbarContent {
        if #available(iOS 27.1, *) {
            axisBehavior(.verticalPreferred)
        } else {
            self
        }
    }
}
