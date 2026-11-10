import Foundation
import Observation
import SwiftUI
import ZulipAPI
import ZuluCompose
import ZuluMarkup
import ZuluStore

/// What the app needs to redraw and resend a message it has not seen land yet.
struct Outgoing: Sendable {
    let source: ConversationSource
    /// What was typed, without the quote a reply adds at send time.
    let text: String
    let reply: ReplyDraft?
}

/// A message the person has sent that has not shown up in the conversation yet. It is
/// drawn as sent straight away; only a failure looks different, in red with a retry.
typealias OutgoingMessage = OutboxLedger<Outgoing>.Entry

@MainActor
@Observable
final class Outbox {
    private(set) var ledger = OutboxLedger<Outgoing>()

    /// Long enough for a slow network, short enough that a dead one is reported while the
    /// person is still looking.
    static let sendTimeout = Duration.seconds(30)
    static let timeoutReason = "Not sent. The server did not answer in time."

    func count(in source: ConversationSource) -> Int {
        ledger.entries(in: ConversationKey.of(source)).count
    }

    func message(_ id: UUID) -> OutgoingMessage? { ledger.entry(id) }

    func add(_ message: Outgoing) -> UUID {
        ledger.add(message, in: ConversationKey.of(message.source), at: .now)
    }

    func attempting(_ id: UUID, tagged: Bool) { ledger.attempting(id, tagged: tagged) }
    func sent(_ id: UUID, as messageID: Int) { ledger.sent(id, as: messageID) }
    func failed(_ id: UUID, reason: String) { ledger.failed(id, reason: reason) }
    func timedOut(_ id: UUID) { ledger.timedOut(id, reason: Self.timeoutReason) }
    func remove(_ id: UUID) { ledger.remove(id) }

    func echoed(messageID: Int, localID: String?, in conversation: String) {
        ledger.echoed(messageID: messageID, localID: localID, in: conversation)
    }

    func settle(landed ids: Set<Int>) {
        // Checked first, so an update that settles nothing does not touch observed state.
        guard ledger.entries.contains(where: { $0.sentID.map(ids.contains) ?? false }) else { return }
        ledger.settle(landed: ids)
    }

    func removeAll() {
        ledger = OutboxLedger()
    }
}

extension AppModel {
    /// Returns at once. The message shows as sent until the server echoes it back.
    func enqueue(_ text: String, replyingTo reply: ReplyDraft?, in source: ConversationSource) {
        let id = outbox.add(Outgoing(source: source, text: text, reply: reply))
        Task { await deliver(id) }
    }

    func resend(_ id: UUID) {
        outbox.attempting(id, tagged: false)
        Task { await deliver(id) }
    }

    func discard(_ id: UUID) {
        outbox.remove(id)
    }

    private func deliver(_ id: UUID) async {
        guard let message = outbox.message(id) else { return }
        let timeout = Task { [outbox] in
            try? await Task.sleep(for: Outbox.sendTimeout)
            guard !Task.isCancelled else { return }
            outbox.timedOut(id)
        }
        defer { timeout.cancel() }

        // Named in the send so the echo says which message it is. Without a queue yet the
        // send still goes, and its echo is matched by conversation instead.
        let echo = await currentQueueID().map { LocalEcho(queueID: $0, localID: message.localID) }
        outbox.attempting(id, tagged: echo != nil)

        // The quote is assembled here rather than when the reply was started, so the
        // field held the person's own words the whole time they were typing.
        var text = message.payload.text
        if let reply = message.payload.reply,
           let quote = await quotedPrefix(for: reply, in: message.payload.source) {
            text = quote + text
        }
        switch await sendReturningID(text, in: message.payload.source, echo: echo) {
        case .sent(messageID: let sentID):
            outbox.sent(id, as: sentID)
        case .failed(let reason):
            outbox.failed(id, reason: reason)
        }
    }
}

typealias PendingEntry = OutboxLedger<Outgoing>.Pending

extension AppModel {
    /// The conversation's pending messages, minus any whose real message is already on
    /// screen, grouped by the same rule as the history above them.
    func pendingEntries(in source: ConversationSource, after loaded: [MessageRecord]) -> [PendingEntry] {
        outbox.ledger.pending(
            in: ConversationKey.of(source),
            shown: Set(loaded.map(\.id)),
            after: loaded.last.map { .init(senderID: $0.senderID, date: $0.date) },
            selfUserID: selfUserID,
            groupingWindow: TimeInterval(ConversationSnapshot.groupingWindow)
        )
    }
}

/// A pending message, drawn the way the person's own message will be once it lands.
struct PendingMessageRow: View {
    let message: OutgoingMessage
    let startsGroup: Bool
    @Environment(AppModel.self) private var model

    private var failure: String? {
        if case .failed(let reason) = message.state { return reason }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: MessageRow.gutterSpacing) {
            if startsGroup {
                SenderAvatar(name: senderName, userID: model.selfUserID, size: MessageRow.avatarSize)
            } else {
                Color.clear.frame(width: MessageRow.avatarSize, height: 1)
            }
            VStack(alignment: .leading, spacing: MessageRow.headerSpacing) {
                if startsGroup {
                    MessageHeader(name: senderName, date: message.createdAt, edited: false)
                }
                content
                    .foregroundStyle(failure == nil ? AnyShapeStyle(TextTone.body) : AnyShapeStyle(.red))
                if let failure {
                    HStack(spacing: 10) {
                        Label(failure, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                        Button("Resend") { model.resend(message.id) }
                            .font(.caption.weight(.semibold))
                        Button("Discard", role: .destructive) { model.discard(message.id) }
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var senderName: String {
        model.selfUserID.map(model.name(forUser:)) ?? ""
    }

    private var content: MessageBody {
        let catalogue = EmojiCatalogueLoader.shared.catalogue
        let blocks = PendingMarkup.blocks(
            of: message.payload.text,
            replyingTo: message.payload.reply.map(PendingMarkup.Reply.init),
            emoji: catalogue.resolve(name:)
        )
        // Keyed on the blocks, so a custom emoji the catalogue resolves late is still loaded.
        return MessageBody(blocks: blocks, contentKey: String(describing: blocks))
    }
}

private extension PendingMarkup.Reply {
    init(_ draft: ReplyDraft) {
        let quoted = draft.renderedContent.map(MessageMarkup.blocks(from:))
            ?? [.paragraph([InlineSpan(text: draft.preview)])]
        self.init(author: draft.author, authorID: draft.authorID, messageID: draft.messageID, quoted: quoted)
    }
}
