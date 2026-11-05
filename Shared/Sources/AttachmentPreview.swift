import ImageIO
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Uploads shown in Quick Look, fetched through the signed-in client and written to disk
/// under their own name. The browser would need the realm's sign-in to open them at all.
@MainActor
@Observable
final class AttachmentPreviewer {
    private static let uploadsPrefix = "/user_uploads/"
    private static let fallbackName = "attachment"

    /// The file Quick Look is showing. Quick Look clears it on close, which removes it.
    var file: URL? {
        didSet {
            if let oldValue, oldValue != file { Self.discard(oldValue) }
        }
    }

    private var loading: Task<Void, Never>?

    var isLoading: Bool { loading != nil }

    /// The realm-relative path of an upload a link points at, or `nil` for any other link.
    static func uploadPath(of url: URL) -> String? {
        guard let realm = RealmContext.realmURL, url.host() == realm.host() else { return nil }
        let path = url.path()
        return path.hasPrefix(uploadsPrefix) ? path : nil
    }

    /// The first of `paths` that loads. With `imagesOnly`, the first that is a picture: a
    /// full-size link can point at a page rather than the picture itself.
    func preview(
        _ paths: [String], imagesOnly: Bool = false, model: AppModel, onFailure: @escaping () -> Void = {}
    ) {
        load(paths, imagesOnly: imagesOnly, model: model) { [weak self] written in
            if let written { self?.file = written } else { onFailure() }
        }
    }

    #if os(macOS)
    /// Saves an upload to Downloads and shows it in Finder.
    func save(_ path: String, model: AppModel) {
        load([path], imagesOnly: false, model: model) { written in
            if let written { Self.moveToDownloads(written) }
        }
    }
    #else
    /// A downloaded upload waiting for the user to pick a folder for it in Files.
    var saving: URL? {
        didSet {
            if let oldValue, oldValue != saving { Self.discard(oldValue) }
        }
    }

    func save(_ path: String, model: AppModel) {
        load([path], imagesOnly: false, model: model) { [weak self] written in
            if let written { self?.saving = written }
        }
    }
    #endif

    private func load(
        _ paths: [String], imagesOnly: Bool, model: AppModel, then finish: @escaping (URL?) -> Void
    ) {
        loading?.cancel()
        loading = Task {
            let written = await Self.download(paths, imagesOnly: imagesOnly, model: model)
            guard !Task.isCancelled else {
                if let written { Self.discard(written) }
                return
            }
            loading = nil
            finish(written)
        }
    }

    private static func download(_ paths: [String], imagesOnly: Bool, model: AppModel) async -> URL? {
        for path in paths {
            guard let data = await model.imageData(at: path) else { continue }
            let imageType = imageType(of: data)
            if imagesOnly, imageType == nil { continue }
            if let file = write(data, named: fileName(for: path, imageType: imageType)) { return file }
        }
        return nil
    }

    private static func imageType(of data: Data) -> UTType? {
        CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap(CGImageSourceGetType)
            .flatMap { UTType($0 as String) }
    }

    /// Quick Look picks a viewer by extension, so a picture served without one gets the
    /// extension of what it decodes as.
    private static func fileName(for path: String, imageType: UTType?) -> String {
        let name = URL(string: path)?.lastPathComponent ?? ""
        let base = name.isEmpty || name == "/" ? fallbackName : name
        guard URL(filePath: base).pathExtension.isEmpty, let ext = imageType?.preferredFilenameExtension else {
            return base
        }
        return "\(base).\(ext)"
    }

    private static func write(_ data: Data, named name: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
        } catch {
            return nil
        }
        return file
    }

    private static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    #if os(macOS)
    private static func moveToDownloads(_ file: URL) {
        defer { discard(file) }
        // The sandbox hands back a link inside the app's container; Finder should show the real folder.
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .resolvingSymlinksInPath()
        else { return }
        let destination = unusedURL(for: file.lastPathComponent, in: downloads)
        guard (try? FileManager.default.moveItem(at: file, to: destination)) != nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    /// `name` in `folder`, or `name 2`, `name 3`… when that is taken, as Finder numbers copies.
    private static func unusedURL(for name: String, in folder: URL) -> URL {
        let isFree = { (url: URL) in !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        let original = folder.appending(path: name)
        if isFree(original) { return original }
        let stem = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        return (2...).lazy
            .map { number in
                let numberedName = "\(stem) \(number)"
                return folder.appending(path: ext.isEmpty ? numberedName : "\(numberedName).\(ext)")
            }
            .first(where: isFree) ?? original
    }
    #endif
}

extension View {
    /// Upload links and tapped images open in Quick Look. A link that fails to download
    /// falls back to the browser.
    func attachmentPreviews() -> some View {
        modifier(AttachmentPreviews())
    }
}

private struct AttachmentPreviews: ViewModifier {
    private static let indicatorPadding: CGFloat = 20
    private static let indicatorCornerRadius: CGFloat = 14

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var previewer = AttachmentPreviewer()

    func body(content: Content) -> some View {
        @Bindable var previewer = previewer
        content
            .environment(previewer)
            .environment(\.openURL, OpenURLAction { url in
                guard let path = AttachmentPreviewer.uploadPath(of: url) else { return .systemAction }
                previewer.preview([path], model: model) { openURL(url) }
                return .handled
            })
            .overlay {
                if previewer.isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .padding(Self.indicatorPadding)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.indicatorCornerRadius))
                }
            }
            .quickLookPreview($previewer.file)
            #if os(iOS)
            .fileMover(
                isPresented: Binding(
                    get: { previewer.saving != nil },
                    set: { if !$0 { previewer.saving = nil } }
                ),
                file: previewer.saving
            ) { _ in
                previewer.saving = nil
            }
            #endif
    }
}
