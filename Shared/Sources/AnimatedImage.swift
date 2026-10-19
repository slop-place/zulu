import ImageIO
import SwiftUI
import Synchronization

/// One frame of a moving picture, with the pixels already decoded. `CGImage` is not
/// declared Sendable, but a decoded one is immutable, which is what Sendable asks for.
struct DecodedFrame: @unchecked Sendable {
    let image: CGImage
    let delay: Double
}

/// A picture with more than one frame, played the way a browser plays it: at the file's
/// own delays, one frame decoded at a time, so a long GIF never sits in memory whole.
///
/// Decoding runs off the main thread. `CGAnimateImageDataWithBlock` decoded every frame
/// on it, and a conversation with a few GIFs in view spent a tenth of its frame budget
/// in the GIF decoder before drawing anything.
enum AnimatedPicture {
    static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// Frames, for as long as the reader keeps reading them, no larger than
    /// `maxPixelSize` on their longer side: a frame is drawn at the size it will be shown.
    static func frames(of data: Data, maxPixelSize: Int) -> AsyncStream<CGImage> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    continuation.finish()
                    return
                }
                let count = CGImageSourceGetCount(source)
                guard count > 1 else {
                    continuation.finish()
                    return
                }
                let delays = (0..<count).map { FrameDecoding.delay(source: source, index: $0) }
                var index = 0
                while !Task.isCancelled {
                    let started = ContinuousClock.now
                    if let frame = FrameDecoding.image(source: source, index: index, maxPixelSize: maxPixelSize) {
                        continuation.yield(frame)
                    }
                    let elapsed = ContinuousClock.now - started
                    let remaining = Duration.seconds(delays[index]) - elapsed
                    if remaining > .zero {
                        try? await Task.sleep(for: remaining)
                    }
                    index = (index + 1) % count
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Shared by the emoji and the picture decoders.
enum FrameDecoding {
    /// A frame no larger than `maxPixelSize`, with its pixels decoded now rather than at
    /// first draw. ImageIO otherwise hands back a promise, and the decode lands on the
    /// main thread the moment the frame is drawn.
    static func image(source: CGImageSource, index: Int, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// What browsers show a frame for when the file gives no delay, or one too small to
    /// be meant literally.
    private static let fallbackDelay = 0.1
    private static let minimumDelay = 0.011

    /// Where each format keeps its frame delays. Each has a clamped and an unclamped
    /// value, and the unclamped one is the file's own.
    private static var delayKeys: [(dictionary: CFString, unclamped: CFString, clamped: CFString)] {
        [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
    }

    static func delay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any]
        else { return fallbackDelay }

        for keys in delayKeys {
            guard let format = properties[keys.dictionary] as? [CFString: Any] else { continue }
            let delay = (format[keys.unclamped] as? Double) ?? (format[keys.clamped] as? Double)
            guard let delay else { continue }
            return delay < minimumDelay ? fallbackDelay : delay
        }
        return fallbackDelay
    }
}

/// Realm custom emoji are frequently animated GIFs or WebPs, decoded here into the frames
/// a caller can play.
///
/// Frames rather than a platform image view: an emoji inline in a paragraph has to be a
/// `Text`, which can only hold one still image, so the only way to animate one is to
/// rebuild the paragraph with a different frame each tick. Reactions then use the same
/// mechanism rather than a second one.
struct EmojiFrames: Equatable {
    let frames: [Image]
    /// When each frame stops showing, measured from the start of the loop. Frames in one
    /// file can each have their own delay, so they cannot be spread evenly over the loop.
    let frameEnds: [Double]

    var isAnimated: Bool { frames.count > 1 }
    var duration: Double { frameEnds.last ?? 0 }

    init(frames: [Image], delays: [Double]) {
        self.frames = frames
        var elapsed: Double = 0
        frameEnds = delays.map { delay in
            elapsed += delay
            return elapsed
        }
    }

    func frame(at time: TimeInterval) -> Image {
        guard isAnimated, duration > 0 else { return frames[0] }
        let position = time.truncatingRemainder(dividingBy: duration)
        let index = frameEnds.firstIndex { $0 > position } ?? frames.count - 1
        return frames[index]
    }

    /// Decoded off the main thread, into bitmaps no larger than the emoji is shown
    /// (twice its height, for a Retina screen). The source was left at full size before
    /// and decoded lazily, which meant every tick of an animated emoji ran the GIF
    /// decoder on the main thread for a frame nobody would see at that size.
    static func decode(_ data: Data, height: CGFloat) async -> EmojiFrames? {
        guard height > 0 else { return nil }
        let maxPixelSize = Int((height * 2).rounded(.up))
        let decoded = await Task.detached(priority: .userInitiated) { () -> [DecodedFrame] in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
            return (0..<CGImageSourceGetCount(source)).compactMap { index in
                FrameDecoding.image(source: source, index: index, maxPixelSize: maxPixelSize)
                    .map { DecodedFrame(image: $0, delay: FrameDecoding.delay(source: source, index: index)) }
            }
        }.value
        guard !decoded.isEmpty else { return nil }
        return EmojiFrames(
            frames: decoded.map { Image(decorative: $0.image, scale: CGFloat($0.image.height) / height) },
            delays: decoded.map(\.delay)
        )
    }
}

/// One emoji, playing if it has more than one frame.
struct AnimatedEmojiView: View {
    let frames: EmojiFrames

    /// Fast enough that nothing looks like a slideshow, slow enough that a wall of
    /// reactions is not redrawn at display rate.
    static let tick: TimeInterval = 1.0 / 15

    var body: some View {
        if frames.isAnimated {
            TimelineView(.periodic(from: .now, by: Self.tick)) { context in
                frames.frame(at: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            frames.frames[0]
        }
    }
}
