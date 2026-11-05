import SwiftUI
import ZuluEmoji

/// Marks the runs of a `Text` that are links, so the Mac can find them under the pointer.
struct LinkAttribute: TextAttribute {
    let url: URL
}

/// Marks an emoji's run of a `Text` with its `:name:`, so pointing at it can say what it is.
struct EmojiNameAttribute: TextAttribute {
    let name: String
    let display: EmojiDisplay
}

extension View {
    /// Selectable text shows an I-beam everywhere, links included. This puts the
    /// pointing hand back over the links, and names an emoji when the pointer rests on
    /// it on the Mac or it is tapped on the phone.
    func inlineHover() -> some View {
        modifier(InlineHover())
    }
}

/// Where the renderer last drew each link and emoji. Written while drawing, so it is
/// not observed: a change here must not ask for another draw.
private final class InlineFrames: @unchecked Sendable {
    var links: [LinkFrame] = [] {
        didSet { if links != oldValue { onLinksChange?(links) } }
    }
    var emoji: [EmojiFrame] = []
    var onLinksChange: (([LinkFrame]) -> Void)?
}

struct LinkFrame: Equatable {
    let rect: CGRect
    let url: URL
}

struct EmojiFrame: Equatable {
    let rect: CGRect
    let emoji: EmojiNameAttribute
}

/// Draws the text unchanged, noting where each link and emoji landed along the way.
private struct InlineFrameRecorder: TextRenderer {
    let frames: InlineFrames

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var links: [LinkFrame] = []
        var emoji: [EmojiFrame] = []
        for line in layout {
            for run in line {
                let rect = run.typographicBounds.rect
                if let link = run[LinkAttribute.self] { links.append(LinkFrame(rect: rect, url: link.url)) }
                if let attribute = run[EmojiNameAttribute.self] {
                    emoji.append(EmojiFrame(rect: rect, emoji: attribute))
                }
                context.draw(run)
            }
        }
        frames.links = links
        frames.emoji = emoji
    }
}

/// Which emoji's name is showing, and the wait before it shows or hides.
@MainActor
@Observable
final class EmojiNameState {
    /// Long enough that sweeping the pointer across a line of text does not flash bubbles.
    static let hoverDelay: Duration = .milliseconds(250)
    /// A tapped name has no pointer leaving to hide it.
    static let tapLifetime: Duration = .seconds(2.5)
    static let gap: CGFloat = 6

    private(set) var shown: EmojiFrame?
    var bubbleHeight: CGFloat = 30

    @ObservationIgnored private var target: EmojiFrame?
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// The pointer moved. Only a change of emoji under it restarts the wait.
    func hover(over emoji: EmojiFrame?) {
        guard emoji != target else { return }
        target = emoji
        pending?.cancel()
        guard let emoji else {
            show(nil)
            return
        }
        pending = Task {
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled else { return }
            show(emoji)
        }
    }

    /// A tap on an emoji names it; a tap anywhere else in the text puts the name away.
    func tap(on emoji: EmojiFrame?) {
        pending?.cancel()
        show(emoji == shown ? nil : emoji)
        guard emoji != nil else { return }
        pending = Task {
            try? await Task.sleep(for: Self.tapLifetime)
            guard !Task.isCancelled else { return }
            show(nil)
        }
    }

    private func show(_ emoji: EmojiFrame?) {
        withAnimation(.easeOut(duration: 0.12)) { shown = emoji }
    }
}

#if os(macOS)
/// Selectable text shows its I-beam over everything it is the top view of, links
/// included, so each link gets a view of its own above the text to own the pointer.
private struct LinkTargets: View {
    let links: [LinkFrame]
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: link.rect.width, height: link.rect.height)
                    .offset(x: link.rect.minX, y: link.rect.minY)
                    .pointerStyle(.link)
                    .onTapGesture { openURL(link.url) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif

private struct InlineHover: ViewModifier {
    @State private var frames = InlineFrames()
    @State private var emojiName = EmojiNameState()
    #if os(macOS)
    @State private var links: [LinkFrame] = []
    #endif

    func body(content: Content) -> some View {
        content
            .textRenderer(InlineFrameRecorder(frames: frames))
            #if os(macOS)
            .overlay { LinkTargets(links: links) }
            .onAppear {
                links = frames.links
                // Drawing must not change state directly, so the new frames land on the next turn.
                frames.onLinksChange = { changed in
                    Task { @MainActor in links = changed }
                }
            }
            #endif
            .overlay(alignment: .topLeading) { bubble }
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    emojiName.hover(over: emoji(at: point))
                case .ended:
                    emojiName.hover(over: nil)
                }
            }
            #else
            // Alongside rather than instead of the text's own taps, so links still open.
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                emojiName.tap(on: emoji(at: tap.location))
            })
            #endif
    }

    @ViewBuilder private var bubble: some View {
        if let shown = emojiName.shown {
            EmojiNameBubble(emoji: shown.emoji)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    emojiName.bubbleHeight = $0
                }
                .offset(
                    x: shown.rect.minX,
                    y: shown.rect.minY - emojiName.bubbleHeight - EmojiNameState.gap
                )
                .transition(.opacity)
        }
    }

    private func emoji(at point: CGPoint) -> EmojiFrame? {
        frames.emoji.first { $0.rect.contains(point) }
    }
}

/// An emoji in a message drawn larger with its `:name:`, in the same bubble a
/// reaction's hover uses.
private struct EmojiNameBubble: View {
    let emoji: EmojiNameAttribute

    var body: some View {
        HStack(spacing: 8) {
            EmojiDisplayView(display: emoji.display, size: 22)
            Text(":\(emoji.name):")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .hoverBubbleChrome()
    }
}

extension View {
    /// The look of the little bubbles that float over a message to name what is under
    /// the pointer.
    func hoverBubbleChrome() -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .fixedSize()
            .allowsHitTesting(false)
    }
}
