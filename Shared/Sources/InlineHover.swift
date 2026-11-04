import SwiftUI

/// Marks the runs of a `Text` that are links, so the Mac can find them under the pointer.
struct LinkAttribute: TextAttribute {}

/// Marks an emoji's run of a `Text` with its `:name:`, so pointing at it can say what it is.
struct EmojiNameAttribute: TextAttribute {
    let name: String
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
    var links: [CGRect] = []
    var emoji: [EmojiFrame] = []
}

struct EmojiFrame: Equatable {
    let rect: CGRect
    let name: String
}

/// Draws the text unchanged, noting where each link and emoji landed along the way.
private struct InlineFrameRecorder: TextRenderer {
    let frames: InlineFrames

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var links: [CGRect] = []
        var emoji: [EmojiFrame] = []
        for line in layout {
            for run in line {
                let rect = run.typographicBounds.rect
                if run[LinkAttribute.self] != nil { links.append(rect) }
                if let name = run[EmojiNameAttribute.self]?.name {
                    emoji.append(EmojiFrame(rect: rect, name: name))
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

private struct InlineHover: ViewModifier {
    @State private var frames = InlineFrames()
    @State private var emojiName = EmojiNameState()
    #if os(macOS)
    @State private var overLink = false
    #endif

    func body(content: Content) -> some View {
        content
            .textRenderer(InlineFrameRecorder(frames: frames))
            .overlay(alignment: .topLeading) { bubble }
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    overLink = frames.links.contains { $0.contains(point) }
                    emojiName.hover(over: emoji(at: point))
                case .ended:
                    overLink = false
                    emojiName.hover(over: nil)
                }
            }
            .pointerStyle(overLink ? .link : nil)
            #else
            // Alongside rather than instead of the text's own taps, so links still open.
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                emojiName.tap(on: emoji(at: tap.location))
            })
            #endif
    }

    @ViewBuilder private var bubble: some View {
        if let shown = emojiName.shown {
            EmojiNameBubble(name: shown.name)
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

/// The `:name:` of an emoji in a message, in the same bubble a reaction's hover uses.
private struct EmojiNameBubble: View {
    let name: String

    var body: some View {
        Text(":\(name):")
            .font(.callout.weight(.semibold))
            .lineLimit(1)
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
