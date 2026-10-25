import SwiftUI
import ZuluStore

/// Starts a topic in a channel: its name, and the message that opens it. Sent, it opens
/// the new topic.
struct NewTopicSheet: View {
    let channel: ChannelSummary

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var topic = ""
    @State private var message = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case topic, message }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Topic", text: $topic)
                        .focused($focus, equals: .topic)
                        .submitLabel(.next)
                        .onSubmit { focus = .message }
                }
                Section {
                    TextField("Say something to start it off", text: $message, axis: .vertical)
                        .focused($focus, equals: .message)
                        .lineLimit(4...12)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Topic")
            .navigationSubtitle("#\(channel.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Send", systemImage: "arrow.up") { Task { await send() } }
                            .disabled(!ready)
                    }
                }
            }
            .task { focus = .topic }
        }
    }

    private var ready: Bool {
        !topic.trimmingCharacters(in: .whitespaces).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() async {
        let name = topic.trimmingCharacters(in: .whitespaces)
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !text.isEmpty else { return }
        sending = true
        error = nil
        defer { sending = false }
        if let failure = await model.send(text, toChannel: channel.id, topic: name) {
            error = failure
            return
        }
        model.destination = .topic(channelID: channel.id, name: name, channelName: channel.name)
        dismiss()
    }
}

/// Opens `NewTopicSheet` for a channel. Each place that offers a new topic carries one.
struct NewTopicButton: View {
    let channel: ChannelSummary
    @State private var showing = false

    var body: some View {
        Button("New Topic", systemImage: "square.and.pencil") { showing = true }
            .sheet(isPresented: $showing) { NewTopicSheet(channel: channel) }
    }
}
