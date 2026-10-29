import ZuluSync
import SwiftUI

struct EmptyStateView: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(TextTone.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        }
        .navigationTitle("Zulu")
        .inlineNavigationTitle()
    }
}

struct SyncDot: View {
    let status: SyncStatus

    private var tint: Color {
        switch status {
        case .live: .green
        case .connecting: .orange
        case .failed: .red
        case .idle: .gray
        }
    }

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .help(label)
    }

    private var label: String {
        switch status {
        case .live: "Connected"
        case .connecting: "Connecting"
        case .failed(let message): message
        case .idle: "Not connected"
        }
    }
}

struct Badge: View {
    let count: Int
    var mention = false

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(mention ? Color.red : Color.secondary, in: Capsule())
        }
    }
}

/// How many messages wait in an unread conversation, in the accent colour its unread mark
/// uses. A mention takes the red `Badge` instead.
struct UnreadCount: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule())
    }
}

/// Says why a channel sits above the others: it is pinned to the top.
struct PinMark: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(TextTone.tertiary)
            .rotationEffect(.degrees(45))
            .accessibilityLabel("Pinned")
    }
}

/// The small mark beside an unread sidebar row. Its slot is always there, so rows line up
/// whether or not they have one.
struct UnreadDot: View {
    let visible: Bool

    private static let size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(SidebarTone.unread)
            .frame(width: Self.size, height: Self.size)
            .opacity(visible ? 1 : 0)
    }
}

/// How sidebar rows are drawn. Unread is solid black or white rather than `.primary`,
/// which the Mac sidebar tints gray and left unread rows no brighter than read ones.
enum SidebarTone {
    static let unread = Platform.dynamic(light: .black, dark: .white)
    static let readTitle = Platform.dynamic(
        light: Platform.label.withAlphaComponent(0.6), dark: .white.withAlphaComponent(0.6)
    )
    static let readIcon = Platform.dynamic(
        light: Platform.label.withAlphaComponent(0.45), dark: .white.withAlphaComponent(0.5)
    )
}

/// The system's grey text is tuned for a grey window. On a black one it reads as dark
/// grey, so in dark mode every supporting line is a step brighter; light mode keeps the
/// system's own roles.
enum TextTone {
    static let secondary = Platform.dynamic(light: Platform.secondaryLabel, dark: .white.withAlphaComponent(0.74))
    static let tertiary = Platform.dynamic(light: Platform.tertiaryLabel, dark: .white.withAlphaComponent(0.52))
}

struct ChannelIcon: View {
    let isForum: Bool
    var restricted = false
    var size: CGFloat = 15
    var cutout: Color = Platform.grey(light: 0.95, dark: 0.11)

    var body: some View {
        Image(systemName: isForum ? "bubble.left.and.text.bubble.right" : "number")
            .font(.system(size: size))
            .overlay(alignment: .topTrailing) {
                if restricted {
                    Image(systemName: "lock.fill")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .padding(size * 0.14)
                        .background(cutout, in: Circle())
                        .offset(x: size * 0.34, y: -size * 0.2)
                }
            }
    }
}

