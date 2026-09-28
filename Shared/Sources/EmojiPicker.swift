import SwiftUI
import ZuluEmoji

/// The whole emoji set, drawn from the same catalogue and the same ranking the `:`
/// autocomplete uses — which is why the realm's own emoji come first here with nothing
/// typed, without a line of code that says so.
///
/// There are no category tabs: Zulip publishes no category data over its API, and the
/// only grouping on the server lives in a file its own build scripts call internal.
/// Search does the work instead, over every name and alias.
struct EmojiPicker: View {
    /// Receives the shortcode, never the character. The server resolves `:name:` through
    /// the realm's own emoji first, which is the whole point of a custom emoji.
    let insert: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Emoji] = []

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    private var catalogue: EmojiCatalogue { EmojiCatalogueLoader.shared.catalogue }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(results) { emoji in
                        Button {
                            insert(emoji.insertion)
                            dismiss()
                        } label: {
                            EmojiGlyph(emoji: emoji)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(emoji.name)
                    }
                }
                .padding(.horizontal, 16)

                if results.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No emoji yet" : "No emoji named that",
                        systemImage: "face.dashed",
                        description: Text(
                            query.isEmpty && !catalogue.hasUnicodeTable
                                ? "The server's emoji are still loading."
                                : "Try another name."
                        )
                    )
                    .padding(.top, 40)
                }
            }
            .navigationTitle("Emoji")
            .inlineNavigationTitle()
            .searchable(text: $query, prompt: "Search emoji")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { EmojiCatalogueLoader.shared.start(store: model.storeForReading) }
        // Ranking the whole catalogue is cheap, but not cheap enough to redo on every
        // view update, so it happens when the query or the catalogue actually changes.
        .task(id: query) { results = catalogue.search(query) }
        .task(id: catalogue.candidates.count) { results = catalogue.search(query) }
    }
}

/// One emoji, however it is drawn: a character for unicode emoji, an image for the
/// realm's own and for `:zulip:`.
struct EmojiGlyph: View {
    let emoji: Emoji
    var size: CGFloat = 30

    @Environment(AppModel.self) private var model
    @State private var frames: EmojiFrames?

    var body: some View {
        Group {
            if let glyph = emoji.glyph {
                Text(glyph).font(.system(size: size))
            } else if let frames {
                AnimatedEmojiView(frames: frames)
            } else {
                // Until the image lands, the name is still the truth about the emoji —
                // the same fallback the server's own markdown makes.
                Text(":\(emoji.name):")
                    .font(.system(size: size * 0.32))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .task { await load() }
            }
        }
        .frame(width: size, height: size)
    }

    private func load() async {
        guard let path = emoji.imageURL ?? emoji.stillURL else { return }
        guard let data = await model.imageData(at: path) else { return }
        frames = EmojiFrames.decode(data, height: size)
    }
}
