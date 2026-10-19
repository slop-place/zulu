import SwiftUI
import ZuluEmoji

/// The whole emoji set in a popover: a search field and a grid, the realm's own emoji
/// first with nothing typed. Return inserts the best match, so a name can be typed and
/// committed without touching the mouse.
struct MacEmojiPicker: View {
    /// Receives the shortcode, never the character. The server resolves `:name:` through
    /// the realm's own emoji first, which is the whole point of a custom emoji.
    let insert: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Emoji] = []
    @FocusState private var searching: Bool

    private let columns = [GridItem(.adaptive(minimum: 34), spacing: 4)]
    private var catalogue: EmojiCatalogue { EmojiCatalogueLoader.shared.catalogue }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search emoji", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .onSubmit {
                    guard let first = results.first else { return }
                    pick(first)
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }

            ScrollView {
                if results.isEmpty {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(TextTone.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(results) { emoji in
                            Button { pick(emoji) } label: {
                                EmojiGlyph(emoji: emoji, size: 24)
                                    .frame(width: 34, height: 34)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(":\(emoji.name):")
                            .accessibilityLabel(emoji.name)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(12)
        .frame(width: 340, height: 360)
        .task {
            EmojiCatalogueLoader.shared.start(store: model.storeForReading)
            searching = true
        }
        // Ranking the whole catalogue is cheap, but not cheap enough to redo on every
        // view update, so it happens when the query or the catalogue actually changes.
        .task(id: query) { results = catalogue.search(query, limit: 240) }
        .task(id: catalogue.candidates.count) { results = catalogue.search(query, limit: 240) }
    }

    private var emptyMessage: String {
        if query.isEmpty && !catalogue.hasUnicodeTable { return "The server's emoji are still loading." }
        return query.isEmpty ? "No emoji yet." : "No emoji named that."
    }

    private func pick(_ emoji: Emoji) {
        insert(emoji.insertion)
        dismiss()
    }
}
