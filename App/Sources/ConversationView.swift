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

    @State private var loader: MessageHistoryLoader?
    @State private var readTracker: ReadTracker?

    var body: some View {
        Group {
            if let loader, loader.isReady {
                // Apart from this view: the toolbar and title read sidebar data that
                // changes on every sync, and in the same view each change rebuilt the list.
                ConversationList(source: source, title: title, loader: loader, readTracker: readTracker)
                    .id(ObjectIdentifier(loader))
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
        .overlay(alignment: .top) {
            if ScrollDebugReadout.isEnabled { ScrollDebugLabel().padding(.top, 4) }
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
