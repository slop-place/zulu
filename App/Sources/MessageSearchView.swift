import SwiftUI
import ZulipAPI

/// Message search as a sheet. Opens scoped to where it was opened from, and opens the
/// conversation a tapped hit belongs to.
struct MessageSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search: MessageSearch
    @FocusState private var fieldFocused: Bool
    private let open: (AppModel.Destination) -> Void

    init(model: AppModel, from destination: AppModel.Destination?, open: @escaping (AppModel.Destination) -> Void) {
        _search = State(initialValue: MessageSearch(
            model: model, options: MessageSearch.options(for: destination, model: model)
        ))
        self.open = open
    }

    var body: some View {
        @Bindable var search = search
        NavigationStack {
            List {
                if search.hits.isEmpty {
                    SearchStatus(search: search).listRowBackground(Color.clear)
                } else {
                    ForEach(search.hits) { hit in
                        Button { choose(hit) } label: { SearchHitRow(hit: hit) }
                            .buttonStyle(.plain)
                    }
                    if search.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .task(id: search.hits.count) { await search.loadMore() }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $search.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search messages"
            )
            .searchFocused($fieldFocused)
            .searchScopes($search.scope) {
                ForEach(search.options) { option in
                    Text(option.title).tag(option.scope)
                }
            }
            .onSubmit(of: .search) { search.searchNow() }
            .task { fieldFocused = true }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .keepsSheetFullWidth()
        .onDisappear { search.stop() }
    }

    private func choose(_ hit: SearchHit) {
        dismiss()
        open(hit.destination)
    }
}

/// Opens message search scoped to `destination`, or to everything when it is nil.
struct MessageSearchButton: View {
    let destination: AppModel.Destination?
    var open: ((AppModel.Destination) -> Void)?
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        Button("Search", systemImage: "magnifyingglass") { showing = true }
            .sheet(isPresented: $showing) {
                MessageSearchView(model: model, from: destination) { destination in
                    if let open { open(destination) } else { model.destination = destination }
                }
            }
    }
}
