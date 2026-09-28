import SwiftUI
import ZuluStore

struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.red.opacity(0.6)).frame(height: 1)
            Text("Unread").font(.caption2.weight(.semibold)).foregroundStyle(.red)
            Rectangle().fill(.red.opacity(0.6)).frame(height: 1)
        }
    }
}

struct DayDivider: View {
    let date: Date

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        let format: Date.FormatStyle = calendar.isDate(date, equalTo: .now, toGranularity: .year)
            ? .dateTime.weekday(.wide).month(.wide).day()
            : .dateTime.weekday(.wide).month(.wide).day().year()
        return date.formatted(format)
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.separator).frame(height: 1)
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(.separator).frame(height: 1)
        }
    }
}

struct MessageRow: View {
    let message: MessageRecord
    var startsGroup = true
    var reactions: [ReactionGroup] = []

    static let avatarSize: CGFloat = 36
    static let gutterSpacing: CGFloat = 10
    static let headerSpacing: CGFloat = 3

    var body: some View {
        HStack(alignment: .top, spacing: Self.gutterSpacing) {
            if startsGroup {
                SenderAvatar(
                    name: message.senderName,
                    userID: message.senderID,
                    url: message.senderAvatar,
                    size: Self.avatarSize
                )
            } else {
                // Continuations keep the text aligned under the header above them.
                Color.clear.frame(width: Self.avatarSize, height: 1)
            }

            VStack(alignment: .leading, spacing: Self.headerSpacing) {
                if startsGroup {
                    MessageHeader(name: message.senderName, date: message.date, edited: message.editedAt != nil)
                }
                MessageContent(message: message).messageActions(message, reactions: reactions)
            }
        }
    }
}

/// Shared with the pending row, so a sent message's header does not shift when the
/// server's copy replaces it.
struct MessageHeader: View {
    let name: String
    let date: Date
    let edited: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(date, format: .dateTime.hour().minute())
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize()
            if edited {
                Text("edited").font(.caption2).foregroundStyle(.tertiary).fixedSize()
            }
        }
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 36

    private var tint: Color {
        // Swift reseeds hashValue per process, so a name would change colour on every
        // launch. This one is stable.
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return palette[seed % palette.count]
    }

    var body: some View {
        Circle()
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}
