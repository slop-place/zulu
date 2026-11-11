import SwiftUI
import ZuluGIFs

/// The composer's emoji popover, with GIFs beside the emoji when the realm allows them.
struct MacComposerPicker: View {
    let insertEmoji: (String) -> Void
    let insertGIF: (GIF) -> Void

    @Environment(AppModel.self) private var model
    @State private var tab = ComposerPickerTab.emoji
    @State private var browser: GIFBrowser?

    var body: some View {
        VStack(spacing: 0) {
            if model.gifs != nil {
                Picker("Show", selection: $tab) {
                    ForEach(ComposerPickerTab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .padding([.horizontal, .top], 12)
            }

            if tab == .gifs, let gifs = model.gifs, let browser {
                MacGIFPicker(browser: browser, configuration: gifs, insert: insertGIF)
            } else {
                MacEmojiPicker(insert: insertEmoji)
            }
        }
        .task(id: model.gifs) {
            browser = model.gifs.map { GIFBrowser(source: $0.source()) }
        }
    }
}

/// A search field over the GIF grid. Return sends the first result.
struct MacGIFPicker: View {
    let browser: GIFBrowser
    let configuration: GIFConfiguration
    let insert: (GIF) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 8) {
            TextField(configuration.searchPrompt, text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .onSubmit {
                    // Until the new search lands, the grid still shows the last one's GIFs.
                    guard browser.hasResults(for: query), let first = browser.gifs.first else { return }
                    pick(first)
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }

            GIFGrid(
                browser: browser, query: query, attribution: configuration.attribution,
                spacing: 4, horizontalPadding: 0, pick: pick
            )
        }
        .padding(12)
        .frame(width: 340, height: 360)
        .task { searching = true }
    }

    private func pick(_ gif: GIF) {
        insert(gif)
        dismiss()
    }
}
