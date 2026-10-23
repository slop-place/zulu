import SwiftUI
import ZuluStore

/// Reads like a conversation list: who spoke last, what they said, and when.
struct MacRecentRow: View, Equatable {
    let entry: RecentEntry

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
