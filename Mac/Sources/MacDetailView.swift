import GRDB
import SwiftUI
import ZuluStore

/// What the detail column shows for the selected destination.
///
/// A chat channel is not a conversation yet — which topic it means depends on what is in
/// it — so it stays a channel until something resolves it. A forum channel as a
/// destination is its topic page; its sidebar row opens general chat instead, so the page
/// is reached deliberately. Everything else is one conversation.
struct MacDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            .background(Platform.canvas.ignoresSafeArea())
            .toolbarBackground(Platform.canvas, for: .windowToolbar)
    }

    @ViewBuilder
    private var content: some View {
        switch model.destination {
        case .topic(let channelID, let name, let channelName):
            let source = ConversationSource.topic(channelID: channelID, name: name, channelName: channelName)
            MacConversationView(source: source).id(source)
        case .dm(let key):
            MacConversationView(source: .dm(key: key)).id(key)
        case .channel(let id):
            if let channel = model.channel(id) {
                if channel.rendersAsForum {
                    MacTopicListView(channel: channel).id(id)
                } else {
                    MacChatChannelView(channel: channel).id(id)
                }
            } else {
                MacEmptyDetail(
                    symbol: "questionmark.circle",
                    title: "That channel is no longer available.",
                    detail: nil
                )
            }
        case nil:
            MacEmptyDetail(
                symbol: "bubble.left.and.text.bubble.right",
                title: model.allChannels.isEmpty ? "Syncing your channels…" : "Pick a conversation",
                detail: model.allChannels.isEmpty ? nil : "Press ⌘K to jump anywhere."
            )
        }
    }
}

struct MacEmptyDetail: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text(title).font(.title3).foregroundStyle(TextTone.secondary)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(TextTone.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Zulu")
    }
}

/// A channel that reads as chat rather than a forum: whatever single topic carries its
/// traffic, opened directly.
struct MacChatChannelView: View {
    let channel: ChannelSummary

    @Environment(AppModel.self) private var model
    @State private var topics: [TopicSummary] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if let newest = topics.max(by: { $0.maxMessageID < $1.maxMessageID }) {
                MacConversationView(
                    source: .topic(channelID: channel.id, name: newest.name, channelName: channel.name)
                )
                .id(newest.name)
            } else if loaded {
                MacEmptyDetail(
                    symbol: "number",
                    title: "Nothing in #\(channel.name) yet.",
                    detail: "Send the first message from a topic in the sidebar."
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: channel.id) { await observe() }
    }

    private func observe() async {
        guard let writer = model.databaseWriter,
              let observation = model.topics(inChannel: channel.id)
        else { return }
        do {
            for try await rows in observation.removeDuplicates().values(in: writer) {
                topics = rows
                loaded = true
            }
        } catch {}
    }
}

/// A forum channel's page: every topic in it, newest first, with who spoke last and
/// when. The sidebar shows the first few of these; this is where the rest live.
struct MacTopicListView: View {
    let channel: ChannelSummary

    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @State private var topics: [TopicSummary] = []
    @State private var loaded = false
    @State private var filter = ""

    var body: some View {
        Group {
            if topics.isEmpty && loaded {
                MacEmptyDetail(
                    symbol: "bubble.left.and.text.bubble.right",
                    title: "No topics in #\(channel.name) yet.",
                    detail: "Start one with ⇧⌘N."
                )
            } else if topics.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .navigationTitle("#\(channel.name)")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    ui.newTopicChannel = ChannelSummaryBox(channel: channel)
                } label: {
                    Label("New Topic", systemImage: "square.and.pencil")
                }
                .help("New Topic  ⇧⌘N")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await model.markChannelRead(channel.id) }
                } label: {
                    Label("Mark as Read", systemImage: "checkmark.circle")
                }
                .disabled(channel.unreadCount == 0)
                .help("Mark every topic as read")
            }
        }
        .task(id: channel.id) { await observe() }
    }

    private var list: some View {
        List(filtered) { topic in
            Button {
                model.destination = .topic(channelID: channel.id, name: topic.name, channelName: channel.name)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(topic.unreadCount > 0 ? Color.accentColor : .clear)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.name.isEmpty ? "general chat" : topic.name)
                            .font(.body.weight(topic.unreadCount > 0 ? .semibold : .regular))
                            .lineLimit(1)
                        if let sender = topic.lastSender {
                            Text(sender).font(.caption).foregroundStyle(TextTone.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        if let date = topic.date {
                            Text(date, format: Self.dateFormat(for: date))
                                .font(.caption).foregroundStyle(TextTone.secondary).monospacedDigit()
                        }
                        if topic.unreadCount > 0 {
                            Text("\(topic.unreadCount)")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(TextTone.secondary)
                        }
                    }
                }
                .padding(.vertical, 3)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Mark as Read") {
                    Task {
                        await model.markConversationRead(.topic(
                            channelID: channel.id, name: topic.name, channelName: channel.name
                        ))
                    }
                }
                .disabled(topic.unreadCount == 0)
                Button("Promote to Sidebar") {
                    model.promote(
                        topic: topic.name, inChannel: channel.id,
                        toGroup: model.group(containingChannel: channel.id)
                    )
                }
                NotificationLevelMenu.topic(topic.name, inChannel: channel.id, model: model)
            }
        }
        .listStyle(.inset)
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter topics")
    }

    private var filtered: [TopicSummary] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return topics }
        return topics.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private var subtitle: String {
        let unread = topics.reduce(0) { $0 + $1.unreadCount }
        let count = "\(topics.count) topic\(topics.count == 1 ? "" : "s")"
        return unread > 0 ? "\(count) · \(unread) unread" : count
    }

    /// Today shows a time; anything older shows a date. The list is scanned for "when
    /// did this go quiet", which is a different question on different days.
    private static func dateFormat(for date: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute()
            : .dateTime.month(.abbreviated).day()
    }

    private func observe() async {
        guard let writer = model.databaseWriter,
              let observation = model.topics(inChannel: channel.id)
        else { return }
        do {
            for try await rows in observation.removeDuplicates().values(in: writer) {
                topics = rows
                loaded = true
            }
        } catch {}
    }
}
