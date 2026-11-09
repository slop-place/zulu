import SwiftUI
import ZulipAPI

/// ⌘F searches where you are, ⇧⌘F everywhere. Arrows move through the hits, Return
/// opens the conversation the chosen one is in.
struct MacMessageSearch: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @Environment(\.dismiss) private var dismiss

    @State private var search: MessageSearch
    @State private var selectedID: Int?
    @FocusState private var focused: Bool

    init(model: AppModel, from origin: AppModel.Destination?) {
        _search = State(initialValue: MessageSearch(
            model: model, options: MessageSearch.options(for: origin, model: model)
        ))
    }

    var body: some View {
        @Bindable var search = search
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(TextTone.secondary)
                TextField("Search messages", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                if !search.query.isEmpty {
                    Button {
                        search.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(TextTone.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if search.options.count > 1 {
                Picker("Search in", selection: $search.scope) {
                    ForEach(search.options) { option in
                        Text(option.title).tag(option.scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            Divider()

            if search.hits.isEmpty {
                SearchStatus(search: search)
            } else {
                results
            }
        }
        .frame(width: 620)
        .onChange(of: search.hits.first?.id) { selectedID = search.hits.first?.id }
        .onDisappear { search.stop() }
        .task { focused = true }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(search.hits) { hit in
                        SearchHitRow(hit: hit)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                hit.id == selectedID ? Color.accentColor.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .id(hit.id)
                            .onTapGesture { open(hit) }
                    }
                    if search.hasMore {
                        SearchMoreFooter(search: search)
                    }
                }
                .padding(6)
            }
            .frame(height: 440)
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private var selectedHit: SearchHit? {
        search.hits.first { $0.id == selectedID }
    }

    /// Return opens the highlighted hit, or searches at once when there is none yet.
    private func submit() {
        if let selectedHit { open(selectedHit) } else { search.searchNow() }
    }

    private func move(_ delta: Int) {
        let hits = search.hits
        guard !hits.isEmpty else { return }
        let current = hits.firstIndex { $0.id == selectedID } ?? 0
        selectedID = hits[(current + delta + hits.count) % hits.count].id
    }

    private func open(_ hit: SearchHit) {
        ui.section = MacShellView.section(for: hit.destination, model: model)
        model.destination = hit.destination
        dismiss()
    }
}
