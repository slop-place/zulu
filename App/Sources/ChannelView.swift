import GRDB
import SwiftUI
import ZuluStore

/// A channel renders as a topic list or as flat chat, decided by how its traffic is
/// actually spread, or by the reader's choice. A chat room opens on the topic its
/// traffic is in, as on the Mac.
struct ChannelView: View {
    let channel: ChannelSummary
    @Environment(AppModel.self) private var model

    /// Newest first.
    @State private var topics: [TopicSummary] = []

    var body: some View {
        Group {
            if channel.rendersAsForum {
                topicList
            } else if let newest = topics.first {
                let source = ConversationView.Source.topic(
                    channelID: channel.id, name: newest.name, channelName: channel.name
                )
                ConversationView(source: source).id(source)
            } else {
                EmptyStateView(text: "Nothing in #\(channel.name) yet.")
            }
        }
        .task(id: channel.id) { await observeTopics() }
    }

    private var topicList: some View {
        List {
            ForEach(topics) { topic in
                NavigationLink(value: ConversationView.Source.topic(
                    channelID: channel.id, name: topic.name, channelName: channel.name
                )) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(topic.unreadCount > 0 ? Color.accentColor : .clear)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(topic.name.isEmpty ? "general chat" : topic.name)
                                .font(.body.weight(topic.unreadCount > 0 ? .semibold : .regular))
                                .foregroundStyle(topic.unreadCount > 0 ? SidebarTone.unread : Color.primary)
                                .lineLimit(2)
                            if let sender = topic.lastSender {
                                Text(sender).font(.footnote).foregroundStyle(TextTone.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 4) {
                            if let date = topic.date {
                                Text(RecentTime.label(for: date))
                                    .font(.footnote)
                                    .foregroundStyle(topic.unreadCount > 0 ? Color.accentColor : TextTone.secondary)
                                    .monospacedDigit()
                            }
                            if topic.unreadCount > 0 {
                                UnreadCount(count: topic.unreadCount)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .contextMenu {
                    OpenInNewWindowButton(source: .topic(
                        channelID: channel.id, name: topic.name, channelName: channel.name
                    ))
                    Button("Promote to sidebar", systemImage: "arrow.up.left") {
                        model.promote(topic: topic.name, inChannel: channel.id)
                    }
                    NotificationLevelMenu.topic(topic.name, inChannel: channel.id, model: model)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("#\(channel.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { NewTopicButton(channel: channel) }
            ToolbarItem(placement: .topBarTrailing) { MessageSearchButton(destination: .channel(channel.id)) }
        }
        .refreshable { await model.refreshTopics() }
    }

    private func observeTopics() async {
        guard let writer = model.databaseWriter, let observation = model.topics(inChannel: channel.id) else {
            return
        }
        do {
            for try await rows in observation.removeDuplicates().values(in: writer) {
                topics = rows
            }
        } catch {
            // Observation ends when the view goes away; nothing to recover.
        }
    }
}
