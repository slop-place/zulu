import SwiftUI

/// One conversation in the drawer's Recent list: who spoke last, what they said, and
/// when. Sized like a direct message row, since most of what moves is people talking.
///
/// Unread has to be told apart at a glance in a list where everything moved lately, so it
/// is marked three ways, as Messages and Mail do: a dot before the row, a count after it,
/// and the time in the accent colour. Read rows keep readable text and quiet the avatar.
struct RecentRow: View, Equatable {
    let entry: RecentEntry
    let isOpen: Bool

    private var isUnread: Bool { entry.unreadCount > 0 }

    private static let dotSize: CGFloat = 8

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .opacity(isUnread ? 1 : 0)
            HStack(spacing: 9) {
                SenderAvatar(name: entry.avatarName, userID: entry.avatarUserID, size: 34)
                    .opacity(isUnread ? 1 : 0.55)
                    // An initial read out before the name says nothing.
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(entry.title)
                            .font(.subheadline.weight(isUnread ? .semibold : .regular))
                            .foregroundStyle(isUnread ? SidebarTone.unread : SidebarTone.readTitle)
                            .lineLimit(1)
                        if entry.isRestricted {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(TextTone.tertiary)
                        }
                        Spacer(minLength: 4)
                        if let date = entry.date {
                            Text(RecentTime.label(for: date))
                                .font(.caption2.weight(isUnread ? .semibold : .regular))
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
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(
            isOpen ? Color(.tertiarySystemFill) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(.rect)
        .accessibilityValue(isUnread ? "\(entry.unreadCount) unread" : "")
    }
}
