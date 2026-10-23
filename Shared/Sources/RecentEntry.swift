import Foundation
import ZuluStore

/// One row of the Recent list, resolved against the model: where it opens, what it is
/// called, and who last spoke. A chat channel's rows are merged by `resolve`, which is
/// why the counts are writable.
struct RecentEntry: Identifiable, Equatable {
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

    /// A chat channel is one conversation however many topics the server files it
    /// under, so its topics fold into one row that opens the channel itself.
    @MainActor
    static func resolve(_ rows: [RecentConversation], model: AppModel) -> [RecentEntry] {
        var entries: [RecentEntry] = []
        var chatChannelRows: [Int: Int] = [:]
        for row in rows {
            if row.isDirect || row.isForum == true {
                entries.append(RecentEntry(row: row, model: model))
            } else if let channelID = row.channelID {
                if let index = chatChannelRows[channelID] {
                    entries[index].unreadCount += row.unreadCount
                    entries[index].mentionCount += row.mentionCount
                } else {
                    chatChannelRows[channelID] = entries.count
                    entries.append(RecentEntry(row: row, model: model))
                }
            }
        }
        return entries
    }

}

extension AppModel {
    func markRead(_ entry: RecentEntry) async {
        switch entry.destination {
        case .dm(let key):
            await markConversationRead(.dm(key: key))
        case .topic(let channelID, let name, let channelName):
            await markConversationRead(.topic(channelID: channelID, name: name, channelName: channelName))
        case .channel(let id):
            await markChannelRead(id)
        }
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
