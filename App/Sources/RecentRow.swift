import SwiftUI

/// One conversation in the drawer's Recent list: who spoke last, what they said, and
/// when. Sized like a direct message row, since most of what moves is people talking.
struct RecentRow: View, Equatable {
    let entry: RecentEntry
    let isOpen: Bool

    private var isUnread: Bool { entry.unreadCount > 0 }

    var body: some View {
        HStack(spacing: 9) {
            SenderAvatar(name: entry.avatarName, userID: entry.avatarUserID, size: 34)
                // An initial read out before the name says nothing.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(entry.title)
                        .font(.subheadline.weight(isUnread ? .semibold : .regular))
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
                            .font(.caption2)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isOpen ? Color(.tertiarySystemFill) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(.rect)
        .accessibilityValue(isUnread ? "Unread" : "")
    }
}
