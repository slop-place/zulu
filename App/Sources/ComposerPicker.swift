import SwiftUI
import ZuluGIFs

/// The composer's emoji button: emoji, and GIFs beside them when the realm allows them.
/// Each half keeps its own search, so switching back finds what was typed there.
struct ComposerPicker: View {
    let insertEmoji: (String) -> Void
    let insertGIF: (GIF) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tab = ComposerPickerTab.emoji
    @State private var emojiQuery = ""
    @State private var gifQuery = ""
    @State private var browser: GIFBrowser?

    private var showsGIFs: Bool { tab == .gifs && model.gifs != nil }

    var body: some View {
        NavigationStack {
            Group {
                if showsGIFs, let browser {
                    GIFGrid(browser: browser, query: gifQuery) { gif in
                        insertGIF(gif)
                        dismiss()
                    }
                } else {
                    EmojiGrid(query: emojiQuery) { shortcode in
                        insertEmoji(shortcode)
                        dismiss()
                    }
                }
            }
            .navigationTitle(ComposerPickerTab.emoji.title)
            .inlineNavigationTitle()
            .searchable(
                text: showsGIFs ? $gifQuery : $emojiQuery,
                prompt: showsGIFs ? model.gifs?.searchPrompt ?? "" : "Search emoji"
            )
            .toolbar {
                if model.gifs == nil {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            // The bar's centre slot sizes the control to its labels, so the full-width
            // control gets a bar of its own.
            .toolbar(model.gifs == nil ? .automatic : .hidden, for: .navigationBar)
            .safeAreaBar(edge: .top) {
                if model.gifs != nil { tabBar }
            }
        }
        .pickerSheetPresentation()
        .task(id: model.gifs) {
            browser = model.gifs.map { GIFBrowser(source: $0.source()) }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $tab) {
                ForEach(ComposerPickerTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)

            Button("Done") { dismiss() }
                .fontWeight(.semibold)
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}
