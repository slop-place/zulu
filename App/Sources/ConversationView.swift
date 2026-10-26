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
    /// The bars beside this conversation, measured on the conversation itself.
    @State private var measuredSideInsets: HorizontalInsets?
    @Environment(\.isCoveredByList) private var isCoveredByList
    @Environment(\.hasScreenToItself) private var hasScreenToItself
    /// The edge the bars run down, on a display that puts them at the side.
    @State private var sideBarEdge: HorizontalEdge?
    @State private var isTyping = false

    @State private var loader: MessageHistoryLoader?
    @State private var readTracker: ReadTracker?
    @State private var isSlowToLoad = false

    private static let spinnerDelay = Duration.milliseconds(350)
    private static let minimumMeasuredSize: CGFloat = 200

    /// The conversation's own measurement once there is one; until then, its column's,
    /// which is right from the first frame wherever it reaches.
    private var sideInsets: HorizontalInsets { measuredSideInsets ?? pageSideInsets }
    @State private var suggestionBox = AutocompleteSlot()

    var body: some View {
        Group {
            if let loader, loader.isReady {
                // Apart from this view: the toolbar and title read sidebar data that
                // changes on every sync, and in the same view each change rebuilt the list.
                ConversationList(
                    source: source, title: title, loader: loader, readTracker: readTracker,
                    sideInsets: sideInsets
                )
                    .id(ObjectIdentifier(loader))
                    .environment(\.jumpsFromSideBar, hasScreenToItself && sideBarEdge != nil)
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
            .reachesUnderSideBar()
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
        // Measured here as well as handed down: a conversation pushed from a channel's
        // topic list does not receive what its column measured, and laid out from the
        // screen's edge, under the sidebar. Placeholder sizes from before the split view
        // has sized its columns are not measurements.
        .onGeometryChange(for: HorizontalInsets?.self) { proxy in
            guard proxy.size.width >= Self.minimumMeasuredSize, proxy.size.height >= Self.minimumMeasuredSize
            else { return nil }
            return HorizontalInsets(leading: proxy.safeAreaInsets.leading, trailing: proxy.safeAreaInsets.trailing)
        } action: { measured in
            if let measured, measured != measuredSideInsets { measuredSideInsets = measured }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // While the list is still showing, closed, the toolbar is the list's: these
            // belong to the conversation, and "All topics" would replace it.
            if let forum = forumChannel, !isCoveredByList, !clearsSideBarForTyping {
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
        .background { SideBarEdgeReader(edge: $sideBarEdge) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isTyping = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isTyping = false
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

    /// Closed, the keyboard lifts the composer level with the buttons down the side; only
    /// the way back stays while it is up.
    private var clearsSideBarForTyping: Bool {
        isTyping && hasScreenToItself && sideBarEdge != nil
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

extension ToolbarContent {
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


extension EnvironmentValues {
    /// Closed, with the conversation over its list and the tab bar out of the way.
    @Entry var hasScreenToItself = false
    /// Jumping to the newest message is a button in the bar down the side, under the
    /// way back, rather than one floating over the conversation.
    @Entry var jumpsFromSideBar = false
}

extension View {
    /// Lets what sits at the bottom of a conversation reach across the bottom of the bars'
    /// column to the screen's edge, when they run down the side of a conversation that has
    /// the screen to itself. They sit at the top of it and leave the rest empty.
    func reachesUnderSideBar() -> some View {
        modifier(ReachesUnderSideBar())
    }
}

private struct ReachesUnderSideBar: ViewModifier {
    @Environment(\.hasScreenToItself) private var hasScreenToItself

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *), hasScreenToItself {
            content.modifier(ReachesToSideBarEdge())
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private struct ReachesToSideBarEdge: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var edge

    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: edges)
    }

    private var edges: Edge.Set {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case nil: []
        }
    }
}

/// Hands the edge the bars run down to a view that cannot read it itself before iOS 27.1.
private struct SideBarEdgeReader: View {
    @Binding var edge: HorizontalEdge?

    var body: some View {
        if #available(iOS 27.1, *) {
            SideBarEdgeReader271(edge: $edge)
        }
    }
}

@available(iOS 27.1, *)
private struct SideBarEdgeReader271: View {
    @Binding var edge: HorizontalEdge?
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    var body: some View {
        Color.clear.onChange(of: verticalEdge, initial: true) { edge = verticalEdge }
    }
}
