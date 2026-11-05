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
    let minHeight: CGFloat

    private var isUnread: Bool { entry.unreadCount > 0 }

    var body: some View {
        HStack(spacing: ConversationUnreadDot.spacing) {
            ConversationUnreadDot(visible: isUnread)
            HStack(spacing: 9) {
                SenderAvatar(name: entry.avatarName, userID: entry.avatarUserID, size: 34)
                    .opacity(isUnread ? 1 : 0.8)
                    // An initial read out before the name says nothing.
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(entry.title)
                            .font(.callout.weight(isUnread ? .semibold : .medium))
                            .foregroundStyle(isUnread ? SidebarTone.unread : SidebarTone.readTitle)
                            .lineLimit(1)
                        if entry.channel == nil, entry.isRestricted {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(TextTone.tertiary)
                        }
                        Spacer(minLength: 4)
                        if let date = entry.date {
                            Text(RecentTime.label(for: date))
                                .font(.caption.weight(isUnread ? .semibold : .regular))
                                .foregroundStyle(isUnread ? Color.accentColor : TextTone.tertiary)
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                    RecentChannelLine(channel: entry.channel, isRestricted: entry.isRestricted)
                        .font(.footnote)
                    HStack(spacing: 4) {
                        Text(entry.preview ?? " ")
                            .font(.footnote)
                            .foregroundStyle(isUnread ? TextTone.secondary : TextTone.tertiary)
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
        .frame(minHeight: minHeight)
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

/// The accent dot before an unread conversation in the drawer's lists. Its slot is always
/// there, so read and unread rows line up.
struct ConversationUnreadDot: View {
    let visible: Bool

    static let size: CGFloat = 8
    static let spacing: CGFloat = 6

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: Self.size, height: Self.size)
            .opacity(visible ? 1 : 0)
    }
}
