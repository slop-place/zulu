import SwiftUI

/// Zulip's uploads need the account's credentials, and they must only ever be sent to
/// the realm itself — never to Gravatar, a preview host, or anything off-origin.
/// `AsyncImage` cannot do that, so images load through the signed-in client instead.
struct RemoteImage: View {
    let path: String
    var fullSize: String?
    var alt: String?
    /// Width over height, when Zulip told us. Reserving the right height before the
    /// bytes arrive is what stops the list reflowing under a scroll.
    var aspectRatio: Double?

    @Environment(AppModel.self) private var model
    @Environment(AttachmentPreviewer.self) private var previewer
    @State private var loaded: (path: String, image: Image)?
    /// The frame showing now, while a picture with more than one is playing.
    @State private var frame: (path: String, image: Image)?
    @State private var failedPath: String?

    init(path: String, fullSize: String? = nil, alt: String? = nil, aspectRatio: Double? = nil) {
        self.path = path
        self.fullSize = fullSize
        self.alt = alt
        self.aspectRatio = aspectRatio
    }

    /// A reused row keeps its state, so a picture only counts if it was loaded for this path.
    private var image: Image? {
        if let loaded, loaded.path == path { return loaded.image }
        return DecodedImages.image(at: path) ?? fullSize.flatMap(DecodedImages.image(at:))
    }

    private var currentFrame: Image? {
        guard let frame, frame.path == path else { return nil }
        return frame.image
    }

    private var failed: Bool { failedPath == path }

    var body: some View {
        Group {
            if let image {
                (currentFrame ?? image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if failed {
                Label(alt ?? "Image", systemImage: "photo")
                    .font(.footnote)
                    .foregroundStyle(TextTone.secondary)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .aspectRatio(aspectRatio ?? 4.0 / 3.0, contentMode: .fit)
                    .overlay { ProgressView() }
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        #if os(iOS)
        .keepsReaderInPlace()
        #endif
        #if os(macOS)
        // A click opens the image at the size it was uploaded. The pointer says so on
        // the way in.
        .onHover { inside in
            guard image != nil else { return }
            inside ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
        #endif
        .onTapGesture {
            guard image != nil else { return }
            previewer.preview(previewPaths, imagesOnly: true, model: model)
        }
        .task(id: path) {
            let path = path
            if image == nil {
                guard let data = await data(for: path), let decoded = Platform.image(from: data) else {
                    // Scrolled away mid-fetch is not a failure; the next appearance fetches again.
                    if !Task.isCancelled { failedPath = path }
                    return
                }
                DecodedImages.store(decoded, at: path)
                loaded = (path, decoded)
            }
            await play(path)
        }
    }

    /// The picture is shown at most this wide, so a frame need not be decoded larger
    /// than twice that: enough for a Retina screen, and far less work than full size.
    private static let maxFramePixels = 640

    /// Runs for as long as the picture is on screen, and only if it moves.
    private func play(_ path: String) async {
        guard let data = await data(for: path), AnimatedPicture.isAnimated(data) else { return }
        for await next in AnimatedPicture.frames(of: data, maxPixelSize: Self.maxFramePixels) {
            frame = (path, Image(decorative: next, scale: 1))
        }
    }

    /// The original stands in for the thumbnail when this device already has it, as it
    /// does for a picture it just sent, so the server's copy does not fetch it again.
    private func data(for path: String) async -> Data? {
        if let fullSize, let original = AppModel.cachedImageData(at: fullSize) { return original }
        return await model.imageData(at: path)
    }
}

extension RemoteImage {
    /// The original where the message linked to one, then the preview already on screen.
    private var previewPaths: [String] {
        [fullSize, path].compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// The full-size upload, resolved against the realm since the server hands out a
    /// realm-relative path. `nil` when the message carried no link, in which case there is
    /// nothing bigger to see.
    @MainActor
    var fullSizeURL: URL? {
        guard let fullSize, !fullSize.isEmpty else { return nil }
        return URL(string: fullSize, relativeTo: RealmContext.realmURL)?.absoluteURL
    }
}

/// Small in-memory cache so scrolling back does not refetch. Bounded by bytes, since one
/// photo can weigh as much as hundreds of avatars.
final class ImageCache: Sendable {
    private static let totalBytesLimit = 64 * 1024 * 1024
    /// A file bigger than this is fetched again rather than pushing most of the cache out.
    private static let entryBytesLimit = 16 * 1024 * 1024

    // NSCache is thread-safe but not marked Sendable.
    nonisolated(unsafe) private let entries: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = totalBytesLimit
        return cache
    }()

    func value(for key: String) -> Data? {
        entries.object(forKey: key as NSString) as Data?
    }

    func insert(_ data: Data, for key: String) {
        guard data.count <= Self.entryBytesLimit else { return }
        entries.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }

    func remove(for key: String) {
        entries.removeObject(forKey: key as NSString)
    }
}

/// Decoded pictures, held so a row scrolled back into view draws at its final size in
/// its first frame, instead of starting as a placeholder and growing under the reader.
@MainActor
enum DecodedImages {
    private final class Box<Value> {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private static let images: NSCache<NSString, Box<Image>> = {
        let cache = NSCache<NSString, Box<Image>>()
        cache.countLimit = 300
        return cache
    }()

    private static let emoji: NSCache<NSString, Box<EmojiFrames>> = {
        let cache = NSCache<NSString, Box<EmojiFrames>>()
        cache.countLimit = 300
        return cache
    }()

    static func image(at path: String) -> Image? {
        images.object(forKey: path as NSString)?.value
    }

    static func store(_ image: Image, at path: String) {
        images.setObject(Box(image), forKey: path as NSString)
    }

    /// Keyed by height as well, since a text size change needs the emoji redrawn.
    static func emoji(at url: String, height: CGFloat) -> EmojiFrames? {
        emoji.object(forKey: "\(height)|\(url)" as NSString)?.value
    }

    static func store(_ frames: EmojiFrames, at url: String, height: CGFloat) {
        emoji.setObject(Box(frames), forKey: "\(height)|\(url)" as NSString)
    }
}
