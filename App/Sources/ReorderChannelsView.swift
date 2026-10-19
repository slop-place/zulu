import SwiftUI
import ZuluStore

/// Drag the sidebar into the order you want.
///
/// A dedicated screen rather than a drag gesture in the drawer itself: the drawer already
/// spends its horizontal drag on opening and closing, and its rows own a long press for
/// their context menu. A list in edit mode gets the system's own reorder affordance
/// instead of competing with either.
struct ReorderChannelsView: View {
    let entries: [SidebarEntry]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var ordered: [SidebarEntry] = []

    var body: some View {
        NavigationStack {
            Group {
                if ordered.isEmpty {
                    ContentUnavailableView(
                        "Nothing to reorder",
                        systemImage: "arrow.up.arrow.down",
                        description: Text("This part of the sidebar has nothing in it.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(ordered) { entry in
                                HStack(spacing: 10) {
                                    ChannelIcon(
                                        isForum: entry.rendersAsForum,
                                        restricted: entry.isRestricted
                                    )
                                    .foregroundStyle(TextTone.secondary)
                                    .frame(width: 24, alignment: .leading)
                                    Text(entry.name).lineLimit(1)
                                    if case .promoted(let promoted) = entry {
                                        Text(promoted.channelName)
                                            .font(.caption)
                                            .foregroundStyle(TextTone.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .onMove { source, destination in
                                ordered.move(fromOffsets: source, toOffset: destination)
                            }
                        } footer: {
                            Text("A forum's topics stay under it. This order is yours alone.")
                        }
                    }
                    // Always in edit mode: the screen exists for one purpose, so making
                    // someone press Edit first is a step for nothing.
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("Reorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        model.reorderSidebar(ordered.map(\.slot))
                        dismiss()
                    }
                    .disabled(ordered.isEmpty)
                }
            }
            .task { if ordered.isEmpty { ordered = entries } }
        }
    }
}
