import GRDB
import SwiftUI
import ZulipAPI
import ZuluPolls
import ZuluStore

/// Chooses between a message's widget and its body.
///
/// A widget message keeps the literal `/poll …` text in `content` — the server never
/// rewrites it — so the body is dropped entirely rather than trimmed.
struct MessageContent: View {
    let message: MessageRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        if message.isWidget {
            PollView(messageID: message.id, model: model)
        } else {
            MessageBody(html: message.renderedContent)
        }
    }
}

struct PollView: View {
    @Environment(AppModel.self) private var model
    @State private var controller: PollController
    @State private var addingOption = false
    @FocusState private var optionFieldFocused: Bool

    private static let controlSize: CGFloat = 26
    private static let cardShape = RoundedRectangle(cornerRadius: 18)

    init(messageID: Int, model: AppModel) {
        _controller = State(initialValue: PollController(messageID: messageID, model: model))
    }

    var body: some View {
        card {
            switch controller.widget {
            case .some(.poll(let poll)):
                contents(of: poll)
            case .some(.unsupported):
                unsupported
            case .none:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await controller.observe() }
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: Self.cardShape)
    }

    @ViewBuilder
    private func contents(of poll: Poll) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(.caption)
                .foregroundStyle(TextTone.secondary)
            Text(poll.question.isEmpty ? "Poll" : poll.question)
                .font(.subheadline.weight(.semibold))
        }

        if poll.options.isEmpty {
            Text("No options yet.").font(.caption).foregroundStyle(TextTone.secondary)
        }
        ForEach(poll.options) { option in
            optionRow(option)
        }

        if addingOption {
            optionField
        } else {
            Button {
                addingOption = true
                optionFieldFocused = true
            } label: {
                Label("Add option", systemImage: "plus")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glass)
        }

        if let error = controller.error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private func optionRow(_ option: PollOption) -> some View {
        let mine = model.selfUserID.map(option.voterIDs.contains) ?? false
        return Button {
            Task { await controller.toggleVote(option: option.key) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: mine ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.text).font(.subheadline)
                    if !option.voterIDs.isEmpty {
                        Text(voters(of: option))
                            .font(.caption2)
                            .foregroundStyle(TextTone.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Text("\(option.voterIDs.count)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.glass)
        .tint(mine ? Color.accentColor : nil)
    }

    private var optionField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("New option", text: $controller.draftOption)
                .textFieldStyle(.plain)
                .focused($optionFieldFocused)
                .submitLabel(.done)
                .onSubmit { submitOption() }
                .padding(.leading, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)

            Button {
                submitOption()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: Self.controlSize, height: Self.controlSize)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(controller.draftOption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Todo lists and zform reverse the key encoding and change the type of `key` between
    /// their own events, so nothing here tries to guess at one.
    private var unsupported: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .foregroundStyle(TextTone.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Interactive message").font(.subheadline.weight(.semibold))
                Text("Zulu cannot show this one. Open it on the web or desktop app.")
                    .font(.caption)
                    .foregroundStyle(TextTone.secondary)
            }
        }
    }

    private func submitOption() {
        addingOption = false
        optionFieldFocused = false
        Task { await controller.addOption() }
    }

    private func voters(of option: PollOption) -> String {
        option.voterIDs.map(model.name(forUser:)).sorted().joined(separator: ", ")
    }
}

/// Holds one poll's log and the round trip that appends to it.
///
/// A poll is server state that changes without the message changing, so this watches the
/// submessage table rather than riding along with the message list.
@MainActor
@Observable
final class PollController {
    private(set) var widget: MessageWidget?
    private(set) var error: String?
    var draftOption = ""

    private let messageID: Int
    private let model: AppModel

    private var log: [PollSubmessage] = []
    /// Events sent from here that the queue has not echoed back yet.
    private var pending: [PollSubmessage] = []
    /// The highest submessage id known when `pending` was filled.
    private var pendingBaseline = 0

    init(messageID: Int, model: AppModel) {
        self.messageID = messageID
        self.model = model
    }

    func observe() async {
        guard let writer = model.databaseWriter,
              let observation = model.pollObservation(forMessage: messageID)
        else { return }
        do {
            for try await rows in observation.removeDuplicates().values(in: writer) {
                log = rows.map(\.pollSubmessage)
                // Anything newer than the baseline means the server has spoken since, so
                // the guesses made here have either landed or been overtaken.
                if log.contains(where: { $0.id > pendingBaseline }) { pending = [] }
                rebuild()
            }
        } catch {
            // The observation ends when the row goes away; nothing to recover.
        }
    }

    func toggleVote(option key: String) async {
        guard let poll = widget?.poll, let me = model.selfUserID,
              let event = poll.voteEvent(forOption: key, voter: me)
        else { return }
        await send(event)
    }

    func addOption() async {
        let text = draftOption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let poll = widget?.poll, let me = model.selfUserID else { return }
        draftOption = ""
        await send(.newOption(idx: poll.nextOptionIndex(forSender: me), text: text))
    }

    /// Shown before the server confirms it. The server applies a set-add or a set-remove
    /// rather than a toggle, so the guess and the echo agree even if someone else votes in
    /// between.
    private func send(_ event: PollEvent) async {
        error = nil
        guard let me = model.selfUserID else { return }

        if pending.isEmpty { pendingBaseline = log.map(\.id).max() ?? 0 }
        pending.append(PollSubmessage(
            id: pendingBaseline + pending.count + 1, senderID: me, content: event.json
        ))
        rebuild()

        guard let failure = await model.sendPollEvent(event, onMessage: messageID) else { return }
        error = failure
        pending = []
        rebuild()
    }

    private func rebuild() {
        widget = MessageWidget(submessages: log + pending)
    }
}

extension SubmessageRecord {
    var pollSubmessage: PollSubmessage {
        PollSubmessage(id: id, senderID: senderID, msgType: msgType, content: content)
    }
}

extension AppModel {
    var selfUserID: Int? { account?.userID }

    func pollObservation(forMessage id: Int)
        -> ValueObservation<ValueReducers.Fetch<[SubmessageRecord]>>?
    {
        storeForReading?.observeSubmessages(forMessage: id)
    }

    /// Nothing is written locally. The server echoes the event back through the queue,
    /// which is the same path other people's votes arrive on.
    func sendPollEvent(_ event: PollEvent, onMessage id: Int) async -> String? {
        guard let account else { return "Not signed in." }
        do {
            try await ZulipClient(account: account)
                .sendSubmessage(messageID: id, content: event.json)
            return nil
        } catch {
            return Self.describe(error)
        }
    }
}
