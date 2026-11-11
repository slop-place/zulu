import SwiftUI
import ZuluGIFs

/// The two halves of the composer's picker.
enum ComposerPickerTab: CaseIterable, Hashable {
    case emoji
    case gifs

    var title: String {
        switch self {
        case .emoji: "Emoji"
        case .gifs: "GIFs"
        }
    }
}

extension GIFConfiguration {
    /// Names the provider, which both GIPHY and KLIPY ask apps to do.
    var searchPrompt: String {
        switch provider {
        case .klipy: "Search KLIPY"
        case .giphy: "Search GIPHY"
        }
    }
}

/// GIFs in columns that keep each one's shape, fetching more as the end comes into view.
struct GIFGrid: View {
    let browser: GIFBrowser
    let query: String
    var columns = 2
    var spacing: CGFloat = 6
    var horizontalPadding: CGFloat = 16
    let pick: (GIF) -> Void

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: spacing) {
                ForEach(Array(GIFBrowser.columns(of: browser.gifs, count: columns).enumerated()), id: \.offset) { _, column in
                    LazyVStack(spacing: spacing) {
                        ForEach(column) { gif in
                            Button { pick(gif) } label: { GIFThumbnail(gif: gif) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(gif.title.isEmpty ? "GIF" : gif.title)
                                .task { await browser.loadMore(after: gif) }
                        }
                    }
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, spacing)
        }
        // A new search starts at the top rather than wherever the last one was scrolled to.
        .id(browser.query)
        .overlay { status }
        .task(id: query) { await browser.show(query) }
    }

    @ViewBuilder
    private var status: some View {
        switch browser.phase {
        case .loading where browser.gifs.isEmpty:
            ProgressView()
        case .empty:
            ContentUnavailableView.search(text: browser.query)
        case .failed:
            ContentUnavailableView {
                Label("Couldn't Load GIFs", systemImage: "wifi.exclamationmark")
            } actions: {
                Button("Try Again") { Task { await browser.show(query) } }
            }
        case .loading, .loaded:
            EmptyView()
        }
    }
}

/// One GIF, playing, at the shape it was made.
struct GIFThumbnail: View {
    let gif: GIF

    @Environment(AppModel.self) private var model
    @State private var still: Image?
    @State private var animation: FrameAnimation?

    private static let cornerRadius: CGFloat = 8
    /// Previews are at most a couple of hundred pixels wide, so this is their full size.
    private static let maxPixels = 480
    /// Each GIF on screen holds every frame at once, so many of them share the memory a
    /// single picture in a message would get.
    private static let frameByteBudget = 3 * 1024 * 1024

    private var path: String { gif.previewURL.absoluteString }

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(.quaternary)
            .aspectRatio(gif.aspectRatio, contentMode: .fit)
            .overlay {
                if let still = still ?? DecodedImages.image(at: path) {
                    still.resizable().scaledToFill()
                }
            }
            .overlay {
                if let animation {
                    FrameAnimationView(animation: animation)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .task(id: gif.id) { await load() }
            // Frames scrolled far out of view are let go; the cache brings them back.
            .onDisappear { animation = nil }
    }

    private func load() async {
        let path = path
        if let cached = DecodedImages.animation(at: path) {
            animation = cached
            return
        }
        guard let data = await model.imageData(at: path) else { return }
        if still == nil, DecodedImages.image(at: path) == nil,
           let frame = await Platform.decodedImage(from: data, maxPixelSize: Self.maxPixels) {
            DecodedImages.store(frame, at: path)
            still = frame.swiftUIImage
        }
        guard !Task.isCancelled,
              let decoded = await FrameAnimation.decode(
                  data, maxPixelSize: Self.maxPixels, byteBudget: Self.frameByteBudget
              )
        else { return }
        DecodedImages.store(decoded, at: path)
        animation = decoded
    }
}
