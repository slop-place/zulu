import GRDB
import SwiftUI
import ZuluStore

/// Where hidden channels go, and the only way back.
///
/// Hiding is a filing decision, not a mute: these channels are still subscribed, still
/// notify, and still count their mentions. They simply do not take up a row.
struct HiddenChannelsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var channels: [ChannelSummary] = []

    var body: some View {
        NavigationStack {
            Group {
                if channels.isEmpty {
                    ContentUnavailableView(
                        "Nothing hidden",
                        systemImage: "eye",
                        description: Text("Long-press a channel to hide it from the sidebar.")
                    )
                } else {
                    List(channels) { channel in
                        HStack(spacing: 10) {
                            ChannelIcon(
                                isForum: channel.rendersAsForum, restricted: channel.isRestricted
                            )
                            .foregroundStyle(TextTone.secondary)
                            .frame(width: 26, alignment: .leading)
                            Text(channel.name)
                            Spacer()
                            if channel.mentionCount > 0 {
                                Badge(count: channel.mentionCount, mention: true)
                            }
                            Button("Unhide") { model.setHidden(false, forChannel: channel.id) }
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Hidden Channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await observe() }
        }
    }

    private func observe() async {
        guard let writer = model.databaseWriter,
              let observation = model.hiddenChannelObservation
        else { return }
        do {
            for try await rows in observation.removeDuplicates().values(in: writer) { channels = rows }
        } catch {
            // Ends with the sheet; nothing to recover.
        }
    }
}
