import ImageIO
import SwiftUI
import Synchronization

/// One frame of a moving picture, with the pixels already decoded. `CGImage` is not
/// declared Sendable, but a decoded one is immutable, which is what Sendable asks for.
struct DecodedFrame: @unchecked Sendable {
    let image: CGImage
    let delay: Double
}

enum AnimatedPicture {
    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(source) != nil
    }
}

extension Platform {
    /// A picture's first frame, decoded off the main thread at no more than `maxPixelSize`.
    /// Made from the bytes directly, a platform image is decoded at full size on the main
    /// thread the first time it is drawn.
    static func decodedImage(from data: Data, maxPixelSize: Int) async -> DecodedFrame? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = FrameDecoding.image(source: source, index: 0, maxPixelSize: maxPixelSize)
            else { return nil }
            return DecodedFrame(image: image, delay: 0)
        }.value
    }
}

extension DecodedFrame {
    var swiftUIImage: Image { Image(decorative: image, scale: 1) }
    var cost: Int { image.bytesPerRow * image.height }
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
/// An emoji inline in a paragraph has to be a `Text`, which holds one still image, so the
/// paragraph's renderer draws the frame for the moment over it. Anywhere else the emoji
/// is its own view, and Core Animation plays `animation` instead.
struct EmojiFrames: Equatable {
    let frames: [Image]
    /// When each frame stops showing, measured from the start of the loop. Frames in one
    /// file can each have their own delay, so they cannot be spread evenly over the loop.
    let frameEnds: [Double]
    let animation: FrameAnimation?

    var isAnimated: Bool { frames.count > 1 }
    var duration: Double { frameEnds.last ?? 0 }

    init(frames: [Image], delays: [Double], animation: FrameAnimation? = nil) {
        self.frames = frames
        self.animation = animation
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
        let delays = decoded.map(\.delay)
        return EmojiFrames(
            frames: decoded.map { Image(decorative: $0.image, scale: CGFloat($0.image.height) / height) },
            delays: delays,
            animation: FrameAnimation(frames: decoded.map(\.image), delays: delays)
        )
    }
}

/// One emoji, playing if it has more than one frame.
struct AnimatedEmojiView: View {
    let frames: EmojiFrames

    var body: some View {
        frames.frames[0].overlay {
            if let animation = frames.animation, animation.isAnimated {
                FrameAnimationView(animation: animation)
            }
        }
    }
}
