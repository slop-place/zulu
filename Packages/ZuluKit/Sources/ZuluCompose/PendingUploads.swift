import Foundation

/// A file attached in the composer, from the moment it is picked until the message
/// carrying it is sent.
public struct PendingUpload: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// From 0 to 1.
        case uploading(fraction: Double)
        /// Realm-relative, e.g. `/user_uploads/2/ab/xyz/photo.jpg`.
        case uploaded(path: String)
        case failed(message: String)
    }

    public let id: UUID
    public internal(set) var filename: String
    public let isImage: Bool
    public internal(set) var state: State

    public init(id: UUID = UUID(), filename: String, isImage: Bool, state: State) {
        self.id = id
        self.filename = filename
        self.isImage = isImage
        self.state = state
    }

    /// Zulip embeds uploads as ordinary markdown. Images get the image form, which only
    /// works for files already uploaded to the realm.
    var markdown: String? {
        guard case .uploaded(let path) = state else { return nil }
        return "\(isImage ? "!" : "")[\(filename)](\(path))"
    }
}

/// The files attached to one draft. They stay out of the typed text and are written into
/// the message as upload links only when it is sent or saved.
public struct PendingUploads: Equatable, Sendable {
    public private(set) var items: [PendingUpload] = []

    private static let uploadsPrefix = "/user_uploads/"
    private static let imageMarker = "!"

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    public var isUploading: Bool {
        items.contains { if case .uploading = $0.state { true } else { false } }
    }

    public var hasUploaded: Bool { items.contains { $0.markdown != nil } }

    public mutating func add(filename: String, isImage: Bool) -> UUID {
        let upload = PendingUpload(filename: filename, isImage: isImage, state: .uploading(fraction: 0))
        items.append(upload)
        return upload.id
    }

    public mutating func progress(_ id: UUID, fraction: Double) {
        update(id) { upload in
            guard case .uploading = upload.state else { return }
            upload.state = .uploading(fraction: min(max(fraction, 0), 1))
        }
    }

    /// `filename` is what the server named the file, which can differ from what was sent.
    public mutating func finish(_ id: UUID, path: String, filename: String) {
        update(id) { upload in
            upload.filename = filename
            upload.state = .uploaded(path: path)
        }
    }

    public mutating func fail(_ id: UUID, message: String) {
        update(id) { $0.state = .failed(message: message) }
    }

    /// Only a failed upload starts over.
    public mutating func restart(_ id: UUID) {
        update(id) { upload in
            guard case .failed = upload.state else { return }
            upload.state = .uploading(fraction: 0)
        }
    }

    /// `earlier` goes first, since its files were attached before these.
    public mutating func prepend(_ earlier: PendingUploads) {
        items.insert(contentsOf: earlier.items, at: 0)
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func removeUploaded() {
        items.removeAll { $0.markdown != nil }
    }

    public mutating func removeAll() {
        items.removeAll()
    }

    /// The typed text with a link to each finished upload after it. A blank line keeps the
    /// links in a paragraph of their own, which is what draws them as files.
    public func message(with text: String) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let links = items.compactMap(\.markdown).joined(separator: "\n")
        return [body, links].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The reverse of `message(with:)`: every line that is only an upload link becomes a
    /// finished upload again, and the rest is returned as the text.
    public static func restoring(from message: String) -> (text: String, uploads: PendingUploads) {
        var uploads = PendingUploads()
        var kept: [Substring] = []
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            if let upload = upload(in: line) {
                uploads.items.append(upload)
            } else {
                kept.append(line)
            }
        }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, uploads)
    }

    private static func upload(in line: Substring) -> PendingUpload? {
        let link = /^(!?)\[([^\]\n]*)\]\(([^)\s]+)\)$/
        guard let match = line.trimmingCharacters(in: .whitespaces).wholeMatch(of: link),
              match.3.hasPrefix(uploadsPrefix)
        else { return nil }
        return PendingUpload(
            filename: String(match.2),
            isImage: match.1 == imageMarker,
            state: .uploaded(path: String(match.3))
        )
    }

    private mutating func update(_ id: UUID, _ change: (inout PendingUpload) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}
