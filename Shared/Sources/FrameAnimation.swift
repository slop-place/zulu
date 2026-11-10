import ImageIO
import QuartzCore
import SwiftUI

/// A moving picture's frames, decoded once and played by Core Animation. The render
/// server steps through them, so a picture that moves costs the app nothing per frame:
/// no decoding, no view update, no layout.
struct FrameAnimation: @unchecked Sendable, Equatable {
    let frames: [CGImage]
    /// How long each frame shows, in seconds.
    let delays: [Double]

    var isAnimated: Bool { frames.count > 1 }
    var duration: Double { delays.reduce(0, +) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.delays == rhs.delays && lhs.frames.elementsEqual(rhs.frames, by: ===)
    }

    /// Bytes the decoded frames hold, for a cache to weigh them by.
    var cost: Int { frames.reduce(0) { $0 + $1.bytesPerRow * $1.height } }

    /// Every frame of a picture with more than one, no larger than `maxPixelSize` on its
    /// longer side. A long animation is decoded smaller rather than holding more than
    /// `byteBudget` in memory.
    static func decode(_ data: Data, maxPixelSize: Int, byteBudget: Int = defaultByteBudget) async -> FrameAnimation? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let count = CGImageSourceGetCount(source)
            guard count > 1 else { return nil }
            let pixelSize = fittedPixelSize(source: source, count: count, maxPixelSize: maxPixelSize, byteBudget: byteBudget)
            var frames: [CGImage] = []
            var delays: [Double] = []
            for index in 0..<count {
                guard let frame = FrameDecoding.image(source: source, index: index, maxPixelSize: pixelSize) else { continue }
                frames.append(frame)
                delays.append(FrameDecoding.delay(source: source, index: index))
            }
            return frames.count > 1 ? FrameAnimation(frames: frames, delays: delays) : nil
        }.value
    }

    static let defaultByteBudget = 24 * 1024 * 1024
    private static let bytesPerPixel = 4
    private static let minimumPixelSize = 64

    private static func fittedPixelSize(source: CGImageSource, count: Int, maxPixelSize: Int, byteBudget: Int) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return maxPixelSize }
        let longer = Double(max(width, height))
        let scale = min(1, Double(maxPixelSize) / longer)
        let bytes = Double(width * height * bytesPerPixel * count) * scale * scale
        guard bytes > Double(byteBudget) else { return maxPixelSize }
        let shrunk = longer * scale * (Double(byteBudget) / bytes).squareRoot()
        return max(minimumPixelSize, Int(shrunk))
    }

    /// Steps through the frames at the file's own delays, forever.
    fileprivate func keyframes() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: Self.contentsKey)
        animation.values = frames
        animation.calculationMode = .discrete
        // A discrete animation takes one more key time than it has values: each frame's
        // start, then the end of the last.
        let total = duration
        var elapsed = 0.0
        var keyTimes: [NSNumber] = [0]
        for delay in delays {
            elapsed += delay
            keyTimes.append(NSNumber(value: total > 0 ? elapsed / total : 1))
        }
        animation.keyTimes = keyTimes
        animation.duration = total
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    fileprivate static let contentsKey = "contents"
    fileprivate static let animationKey = "zulu.frames"
}

/// Plays a `FrameAnimation`, filling the space it is given at the picture's own aspect.
/// Laid over the still first frame, which sizes it.
struct FrameAnimationView: View {
    let animation: FrameAnimation
    var cornerRadius: CGFloat = 0

    var body: some View {
        FrameAnimationLayer(animation: animation, cornerRadius: cornerRadius)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The layer's side of it: what to play, and starting it again whenever it comes back on
/// screen, since a layer that leaves the window can lose its animation.
@MainActor
private final class FramePlayer {
    private(set) var animation: FrameAnimation?

    func play(_ animation: FrameAnimation, cornerRadius: CGFloat, on layer: CALayer, onScreen: Bool) {
        layer.contentsGravity = .resizeAspect
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = cornerRadius > 0
        guard animation != self.animation else { return }
        self.animation = animation
        restart(on: layer, onScreen: onScreen)
    }

    func restart(on layer: CALayer, onScreen: Bool) {
        layer.removeAnimation(forKey: FrameAnimation.animationKey)
        guard let animation else { return }
        layer.contents = animation.frames.first
        guard onScreen, animation.isAnimated else { return }
        layer.add(animation.keyframes(), forKey: FrameAnimation.animationKey)
    }
}

#if os(macOS)
private struct FrameAnimationLayer: NSViewRepresentable {
    let animation: FrameAnimation
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> FrameAnimationHost { FrameAnimationHost() }

    func updateNSView(_ view: FrameAnimationHost, context: Context) {
        view.play(animation, cornerRadius: cornerRadius)
    }
}

private final class FrameAnimationHost: NSView {
    private let player = FramePlayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func play(_ animation: FrameAnimation, cornerRadius: CGFloat) {
        guard let layer else { return }
        player.play(animation, cornerRadius: cornerRadius, on: layer, onScreen: window != nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let layer else { return }
        player.restart(on: layer, onScreen: window != nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#else
private struct FrameAnimationLayer: UIViewRepresentable {
    let animation: FrameAnimation
    let cornerRadius: CGFloat

    func makeUIView(context: Context) -> FrameAnimationHost { FrameAnimationHost() }

    func updateUIView(_ view: FrameAnimationHost, context: Context) {
        view.play(animation, cornerRadius: cornerRadius)
    }
}

private final class FrameAnimationHost: UIView {
    private let player = FramePlayer()
    private var foregroundObserver: (any NSObjectProtocol)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // The system drops a layer's animations while the app is in the background.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    func play(_ animation: FrameAnimation, cornerRadius: CGFloat) {
        player.play(animation, cornerRadius: cornerRadius, on: layer, onScreen: window != nil)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restart()
    }

    private func restart() {
        player.restart(on: layer, onScreen: window != nil)
    }
}
#endif
