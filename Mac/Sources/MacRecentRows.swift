import SwiftUI
import ZuluStore

/// One row of the Recent list, resolved against the model: where it opens, what it is
/// called, and who last spoke. A chat channel's rows are merged by the shell, which is
/// why the counts are writable.
struct MacRecentEntry: Identifiable, Equatable {
    let id: String
    let destination: AppModel.Destination
    let title: String
    let preview: String?
    let date: Date?
    let isRestricted: Bool
    let avatarName: String
    let avatarUserID: Int?
    var unreadCount: Int
    var mentionCount: Int

    @MainActor
    init(row: RecentConversation, model: AppModel) {
        id = row.id
        date = row.date
        isRestricted = row.isRestricted ?? false
        unreadCount = row.unreadCount
        mentionCount = row.mentionCount
        let lastMessage = model.preview(for: row)

        if let dmKey = row.dmKey {
            destination = .dm(dmKey)
            title = model.title(forDM: dmKey)
            preview = lastMessage
            avatarName = title
            avatarUserID = model.soleParticipant(inDM: dmKey)
        } else {
            let channelID = row.channelID ?? 0
            let channelName = row.channelName ?? ""
            let topic = row.topic ?? ""
            if row.isForum == true {
                // The topic is the name; the channel is where it lives, said underneath
                // so the name has the whole line.
                destination = .topic(channelID: channelID, name: topic, channelName: channelName)
                title = topic.isEmpty ? "general chat" : topic
                preview = ["#\(channelName)", lastMessage].compactMap { $0 }.joined(separator: " · ")
            } else {
                destination = .channel(channelID)
                title = "#\(channelName)"
                preview = lastMessage
            }
            avatarName = row.lastSender ?? channelName
            avatarUserID = row.lastSenderID
        }
    }
}

/// Reads like a conversation list: who spoke last, what they said, and when.
struct MacRecentRow: View, Equatable {
    let entry: MacRecentEntry

    private var isUnread: Bool { entry.unreadCount > 0 }

    var body: some View {
        HStack(spacing: 9) {
            SenderAvatar(name: entry.avatarName, userID: entry.avatarUserID, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(entry.title)
                        .font(.body.weight(isUnread ? .semibold : .regular))
                        .foregroundStyle(isUnread ? Color.primary : SidebarTone.readTitle)
                        .lineLimit(1)
                    if entry.isRestricted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(TextTone.tertiary)
                    }
                    Spacer(minLength: 4)
                    if let date = entry.date {
                        Text(RecentTime.label(for: date))
                            .font(.caption)
                            .foregroundStyle(TextTone.secondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                HStack(spacing: 4) {
                    Text(entry.preview ?? " ")
                        .font(.caption)
                        .foregroundStyle(TextTone.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.mentionCount > 0 {
                        Badge(count: entry.mentionCount, mention: true)
                    } else {
                        UnreadDot(visible: isUnread)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// How a conversation list dates things: the time today, the day this week, the date
/// otherwise. The year only when it is not this one.
enum RecentTime {
    static func label(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }
}
