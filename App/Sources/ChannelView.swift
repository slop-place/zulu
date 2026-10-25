import GRDB
import SwiftUI
import ZuluStore

/// A channel renders as a topic list or as flat chat, decided by how its traffic is
/// actually spread. A channel whose messages all sit in one topic is a chat room.
struct ChannelView: View {
    let channel: ChannelSummary
    @Environment(AppModel.self) private var model

    @State private var topics: [TopicSummary] = []

    var body: some View {
        Group {
            if channel.rendersAsForum || topics.count > 1 {
                topicList
            } else if let only = topics.first {
                let source = ConversationView.Source.topic(
                    channelID: channel.id, name: only.name, channelName: channel.name
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
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(topic.unreadCount > 0 ? Color.accentColor : .clear)
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(topic.name.isEmpty ? "general chat" : topic.name)
                                .font(.subheadline.weight(topic.unreadCount > 0 ? .semibold : .regular))
                                .lineLimit(1)
                            if let sender = topic.lastSender {
                                Text(sender).font(.caption).foregroundStyle(TextTone.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 4) {
                            if let date = topic.date {
                                Text(date, format: .dateTime.hour().minute())
                                    .font(.caption2).foregroundStyle(TextTone.secondary)
                            }
                            Badge(count: topic.unreadCount)
                        }
                    }
                    .padding(.vertical, 2)
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
