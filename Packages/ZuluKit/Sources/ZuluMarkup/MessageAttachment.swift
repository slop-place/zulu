import Foundation
import UniformTypeIdentifiers

/// A file uploaded to the realm and linked from a message, drawn as a file row rather
/// than a link in the text.
public struct MessageAttachment: Sendable, Equatable {
    public static let uploadsPrefix = "/user_uploads/"
    /// Previews the server made of an upload. They are pictures, not the file itself.
    static let thumbnailPrefix = "/user_uploads/thumbnail/"

    /// Realm-relative, e.g. `/user_uploads/2/ab/xyz/report.pdf`.
    public let path: String
    public let name: String

    /// `nil` unless `path` is an upload. `title` is the link's text, which is the file's
    /// name unless the sender renamed it.
    public init?(path: String, title: String?) {
        guard Self.isUpload(path) else { return nil }
        self.path = path
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = title.isEmpty ? Self.fileName(of: path) : title
    }

    public static func isUpload(_ path: String) -> Bool {
        path.hasPrefix(uploadsPrefix) && !path.hasPrefix(thumbnailPrefix)
    }

    /// Lowercased, from the path rather than the name, since a renamed link keeps the
    /// file's real extension in its path.
    public var fileExtension: String {
        URL(filePath: Self.fileName(of: path)).pathExtension.lowercased()
    }

    public var kind: AttachmentKind { AttachmentKind(fileExtension: fileExtension) }

    private static func fileName(of path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        return last.removingPercentEncoding ?? last
    }
}

/// What sort of file an attachment is, which picks its icon.
public enum AttachmentKind: Sendable, Equatable, CaseIterable {
    case image
    case video
    case audio
    case pdf
    case archive
    case spreadsheet
    case presentation
    case code
    case text
    case other

    /// Checked in order, so the narrower type wins over the one it conforms to.
    private static let conformances: [(UTType, AttachmentKind)] = [
        (.pdf, .pdf),
        (.image, .image),
        (.audio, .audio),
        (.movie, .video),
        (.archive, .archive),
        (.spreadsheet, .spreadsheet),
        (.presentation, .presentation),
        (.sourceCode, .code),
        (.text, .text),
    ]

    public init(fileExtension: String) {
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else {
            self = .other
            return
        }
        self = Self.conformances.first { type.conforms(to: $0.0) }?.1 ?? .other
    }
}
