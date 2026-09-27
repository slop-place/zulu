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
    @State private var image: Image?
    @State private var failed = false

    init(path: String, fullSize: String? = nil, alt: String? = nil, aspectRatio: Double? = nil) {
        self.path = path
        self.fullSize = fullSize
        self.alt = alt
        self.aspectRatio = aspectRatio
        _image = State(initialValue: DecodedImages.image(at: path))
    }

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if failed {
                Label(alt ?? "Image", systemImage: "photo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            guard image == nil else { return }
            if let data = await model.imageData(at: path), let decoded = Platform.image(from: data) {
                DecodedImages.store(decoded, at: path)
                image = decoded
            } else {
                failed = true
            }
        }
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

/// Small in-memory cache so scrolling back does not refetch.
actor ImageCache {
    private var entries: [String: Data] = [:]
    private var order: [String] = []
    private let limit = 80

    func value(for key: String) -> Data? { entries[key] }

    func insert(_ data: Data, for key: String) {
        if entries[key] == nil { order.append(key) }
        entries[key] = data
        while order.count > limit {
            entries.removeValue(forKey: order.removeFirst())
        }
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
