import ImageIO
import SwiftUI

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

    /// The emoji is sized by telling SwiftUI how many pixels of source make one point,
    /// which costs nothing — redrawing each frame into a smaller bitmap would.
    static func decode(_ data: Data, height: CGFloat) -> EmojiFrames? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), height > 0 else {
            return nil
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var images: [Image] = []
        var delays: [Double] = []
        images.reserveCapacity(count)
        delays.reserveCapacity(count)

        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            images.append(
                Image(decorative: cgImage, scale: CGFloat(cgImage.height) / height)
            )
            delays.append(delay(source: source, index: index))
        }

        guard !images.isEmpty else { return nil }
        return EmojiFrames(frames: images, delays: delays)
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

    private static func delay(source: CGImageSource, index: Int) -> Double {
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
