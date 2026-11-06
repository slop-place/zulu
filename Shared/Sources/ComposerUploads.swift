import SwiftUI
import UniformTypeIdentifiers
import ZuluCompose
import ZuluMarkup

/// The files attached to the composer's draft, and the uploads carrying them to the realm.
@MainActor
@Observable
final class ComposerUploads {
    typealias Loader = @Sendable () async -> Data?

    private static let imageMIMEPrefix = "image/"
    private static let unreadable = "The file could not be read."

    /// Where an upload's bytes come from, kept so a failed upload can be tried again.
    private struct Source {
        let filename: String
        let contentType: String
        let load: Loader
    }

    private(set) var pending = PendingUploads()
    /// The bytes of each picture, for its card's thumbnail.
    private(set) var previews: [UUID: Data] = [:]
    @ObservationIgnored private var sources: [UUID: Source] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    func upload(_ data: Data, filename: String, contentType: String, model: AppModel) {
        upload(filename: filename, contentType: contentType, model: model) { data }
    }

    /// The card shows at once; `load` runs inside the upload, so a slow read, like a photo
    /// coming down from iCloud, shows as an upload that has not started yet.
    func upload(filename: String, contentType: String, model: AppModel, load: @escaping Loader) {
        let id = pending.add(filename: filename, isImage: contentType.hasPrefix(Self.imageMIMEPrefix))
        sources[id] = Source(filename: filename, contentType: contentType, load: load)
        start(id, model: model)
    }

    func upload(files urls: [URL], model: AppModel) {
        for url in urls where url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            upload(data, filename: url.lastPathComponent, contentType: type.preferredMIME, model: model)
        }
    }

    func retry(_ id: UUID, model: AppModel) {
        pending.restart(id)
        start(id, model: model)
    }

    func remove(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        forgetCachedPicture(of: id)
        pending.remove(id)
        forgetRemoved()
    }

    func removeAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        pending.removeAll()
        forgetRemoved()
    }

    /// The draft as it would be sent, with the finished uploads taken out of the composer.
    /// Uploads still going stay, and join whatever is typed next.
    func setAside(with draft: String) -> String {
        let message = pending.message(with: draft)
        pending.removeUploaded()
        forgetRemoved()
        return message
    }

    /// Puts back a draft from `setAside(with:)` or from disk, and returns its text.
    func restore(from message: String) -> String {
        let restored = PendingUploads.restoring(from: message)
        pending.prepend(restored.uploads)
        return restored.text
    }

    private func start(_ id: UUID, model: AppModel) {
        guard let source = sources[id], tasks[id] == nil else { return }
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.pending.progress(id, fraction: fraction) }
        }
        tasks[id] = Task { [weak self] in
            let data = await source.load()
            guard let self, !Task.isCancelled else { return }
            guard let data else {
                tasks[id] = nil
                pending.fail(id, message: Self.unreadable)
                return
            }
            if source.contentType.hasPrefix(Self.imageMIMEPrefix) { previews[id] = data }

            let outcome = await model.upload(
                data, filename: source.filename, contentType: source.contentType, progress: report
            )
            guard !Task.isCancelled else { return }
            tasks[id] = nil
            switch outcome {
            case .success(let file):
                if let preview = previews[id] { AppModel.rememberImageData(preview, at: file.path) }
                pending.finish(id, path: file.path, filename: file.filename)
            case .failure(let message):
                pending.fail(id, message: message)
            }
        }
    }

    /// A picture taken out before sending is never drawn, so its bytes need not stay cached.
    private func forgetCachedPicture(of id: UUID) {
        guard previews[id] != nil,
              case .uploaded(let path)? = pending.items.first(where: { $0.id == id })?.state
        else { return }
        AppModel.forgetImageData(at: path)
    }

    private func forgetRemoved() {
        let kept = Set(pending.items.map(\.id))
        sources = sources.filter { kept.contains($0.key) }
        previews = previews.filter { kept.contains($0.key) }
    }
}

/// The composer's attachments, one card each, inside the field above the text.
struct ComposerUploadStrip: View {
    let uploads: ComposerUploads
    /// How far the cards sit from the field's edges.
    let inset: CGFloat

    @Environment(AppModel.self) private var model

    private static let spacing: CGFloat = 8

    var body: some View {
        if !uploads.pending.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: Self.spacing) {
                        ForEach(uploads.pending.items) { upload in
                            ComposerUploadCard(
                                upload: upload,
                                preview: uploads.previews[upload.id],
                                retry: { uploads.retry(upload.id, model: model) },
                                remove: { uploads.remove(upload.id) }
                            )
                        }
                    }
                }
                // A file just attached would otherwise land out of sight past the others.
                .onChange(of: uploads.pending.items.last?.id) { _, newest in
                    guard let newest else { return }
                    withAnimation(.snappy) { proxy.scrollTo(newest, anchor: .trailing) }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, inset, for: .scrollContent)
            .padding(.top, inset)
            .transition(.opacity)
        }
    }
}

/// A picture as a thumbnail with its remove button on the corner; any other file, or a
/// failed upload, as a chip with its name and progress or failure.
private struct ComposerUploadCard: View {
    let upload: PendingUpload
    /// A picture's own bytes, when this device still has them.
    let preview: Data?
    let retry: () -> Void
    let remove: () -> Void

    @Environment(AppModel.self) private var model
    /// A picture restored from a saved draft, fetched back from the realm.
    @State private var fetched: Data?

    private static let width: CGFloat = 220
    private static let cornerRadius: CGFloat = 10
    private static let iconCornerRadius: CGFloat = 7
    private static let iconSize: CGFloat = 36
    private static let padding: CGFloat = 8
    private static let spacing: CGFloat = 8
    private static let borderWidth: CGFloat = 0.5
    private static let textSpacing: CGFloat = 4
    private static let iconTintOpacity = 0.15
    private static let fillOpacity = 0.5
    private static let removeSymbol = "xmark.circle.fill"
    private static let retrySymbol = "arrow.clockwise.circle.fill"
    private static let failedSymbol = "exclamationmark.triangle.fill"
    private static let tileSize: CGFloat = 64
    private static let badgeInset: CGFloat = 3
    private static let badgeBackdropOpacity = 0.6
    private static let uploadingDimOpacity = 0.35

    private var fileExtension: String {
        URL(filePath: upload.filename).pathExtension.lowercased()
    }

    private var thumbnail: Image? {
        (preview ?? fetched).flatMap(Platform.image(from:))
    }

    var body: some View {
        Group {
            if upload.isImage, !isFailed {
                pictureTile
            } else {
                fileChip
            }
        }
        .accessibilityElement(children: .contain)
        .task(id: upload.state) { await fetchRestoredPicture() }
    }

    private var pictureTile: some View {
        Group {
            if let thumbnail {
                thumbnail
                    .resizable()
                    .scaledToFill()
            } else {
                icon
            }
        }
        .frame(width: Self.tileSize, height: Self.tileSize)
        .overlay {
            if case .uploading(let fraction) = upload.state {
                Color.black.opacity(Self.uploadingDimOpacity)
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .accessibilityLabel("Uploading")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(.quaternary, lineWidth: Self.borderWidth)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: Self.removeSymbol)
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(Self.badgeBackdropOpacity))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .padding(Self.badgeInset)
            .accessibilityLabel("Remove \(upload.filename)")
        }
        .help(upload.filename)
    }

    private var fileChip: some View {
        HStack(spacing: Self.spacing) {
            icon
            VStack(alignment: .leading, spacing: Self.textSpacing) {
                Text(upload.filename)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }
            Spacer(minLength: 0)
            if isFailed {
                control(Self.retrySymbol, label: "Retry \(upload.filename)", action: retry)
            }
            control(Self.removeSymbol, label: "Remove \(upload.filename)", action: remove)
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .background(.quaternary.opacity(Self.fillOpacity), in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(.quaternary, lineWidth: Self.borderWidth)
        }
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(TextTone.secondary)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var icon: some View {
        if !isFailed, let thumbnail {
            thumbnail
                .resizable()
                .scaledToFill()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: Self.iconCornerRadius))
        } else {
            Image(systemName: isFailed ? Self.failedSymbol : AttachmentKind(fileExtension: fileExtension).symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .background(tint.opacity(Self.iconTintOpacity), in: RoundedRectangle(cornerRadius: Self.iconCornerRadius))
        }
    }

    private func fetchRestoredPicture() async {
        guard upload.isImage, preview == nil, fetched == nil, case .uploaded(let path) = upload.state else { return }
        fetched = await model.imageData(at: path)
    }

    private var tint: AnyShapeStyle {
        isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.tint)
    }

    @ViewBuilder
    private var status: some View {
        switch upload.state {
        case .uploading(let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .accessibilityLabel("Uploading")
        case .uploaded:
            Text(fileExtension.uppercased())
                .font(.caption)
                .foregroundStyle(TextTone.secondary)
        case .failed(let message):
            Text("Failed")
                .font(.caption)
                .foregroundStyle(.red)
                .help(message)
                .accessibilityHint(message)
        }
    }

    private var isFailed: Bool {
        if case .failed = upload.state { true } else { false }
    }
}
