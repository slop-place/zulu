import SwiftUI
import ZuluStore

/// Reads like a conversation list: who spoke last, what they said, and when.
///
/// Unread is marked three ways, as Mail does, so it can be told apart at a glance in a
/// list where everything moved lately: a dot before the row, a count after it, and the
/// time in the accent colour. Read rows keep readable text and quiet the avatar.
struct MacRecentRow: View, Equatable {
    let entry: RecentEntry

    private var isUnread: Bool { entry.unreadCount > 0 }

    private static let dotSize: CGFloat = 7

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .opacity(isUnread ? 1 : 0)
            SenderAvatar(name: entry.avatarName, userID: entry.avatarUserID, size: 30)
                .opacity(isUnread ? 1 : 0.55)
                .padding(.trailing, 4)
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
                            .font(.caption.weight(isUnread ? .semibold : .regular))
                            .foregroundStyle(isUnread ? Color.accentColor : TextTone.secondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                HStack(spacing: 4) {
                    Text(entry.preview ?? " ")
                        .font(.caption)
                        .foregroundStyle(isUnread ? Color.primary : TextTone.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.mentionCount > 0 {
                        Badge(count: entry.mentionCount, mention: true)
                    } else if isUnread {
                        UnreadCount(count: entry.unreadCount)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
