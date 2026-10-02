import SwiftUI
import ZulipAPI
import ZuluCompose
import ZuluEmoji
import ZuluMarkup
import ZuluStore

extension View {
    /// Hangs the reactions row under a message and the action sheet off a long press.
    func messageActions(_ message: MessageRecord, reactions: [ReactionGroup]) -> some View {
        modifier(MessageActionsModifier(message: message, reactions: reactions))
    }
}

#if os(iOS)
/// Sheets a message asks for, shown by a view outside the list. A row hosted in a
/// collection view cell cannot present anything itself.
@MainActor
@Observable
final class MessagePresenter {
    var actionsMessage: MessageRecord?
    var reactors: ReactorsRequest?
}

struct ReactorsRequest: Identifiable {
    let display: EmojiDisplay
    let emojiName: String
    let userIDs: [Int]
    let id: String
}

extension View {
    /// Shows the sheets that rows inside this view ask `presenter` for.
    func presentsMessageSheets(_ presenter: MessagePresenter) -> some View {
        @Bindable var presenter = presenter
        return sheet(item: $presenter.actionsMessage) { message in
            MessageActionsSheet(message: message)
        }
        .sheet(item: $presenter.reactors) { request in
            ReactorSheet(display: request.display, emojiName: request.emojiName, userIDs: request.userIDs)
        }
    }
}
#endif

private struct MessageActionsModifier: ViewModifier {
    let message: MessageRecord
    let reactions: [ReactionGroup]

    @State private var showingActions = false
    #if os(iOS)
    @Environment(MessagePresenter.self) private var presenter: MessagePresenter?
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 0) {
            // The gesture is on the message itself, never on the chips below it: a chip
            // owns its own long press, for showing who reacted.
            content
                .contentShape(.rect)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                        Platform.tap()
                        if let presenter {
                            presenter.actionsMessage = message
                        } else {
                            showingActions = true
                        }
                    }
                )
            MessageReactionsRow(messageID: message.id, groups: reactions)
        }
        // A sheet rather than `.contextMenu`, because a context menu can hold only menu
        // items and the quick-reaction row is a strip of tappable emoji laid out across
        // the top. Slack and Discord both reach for a custom sheet for the same reason.
        .sheet(isPresented: $showingActions) {
            MessageActionsSheet(message: message)
        }
        #else
        // A pointer has no long press worth waiting for. The Mac conversation hangs its
        // own hover bar and context menu off the whole row instead.
        VStack(alignment: .leading, spacing: 0) {
            content
            MessageReactionsRow(messageID: message.id, groups: reactions)
        }
        #endif
    }
}

/// The long-press menu: a row of emoji to react with, then the things you can do to the
/// message itself.
struct MessageActionsSheet: View {
    let message: MessageRecord

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var controller: MessageActionsController?
    @State private var showingPicker = false
    @State private var confirmingDelete = false

    private static let rowHeight: CGFloat = 48
    private static let height: CGFloat = 300
    /// Room for Edit and Delete, which only your own messages offer.
    private static let ownHeight = height + rowHeight * 2

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let controller {
                quickRow(controller)
                actions(controller)
                if let error = controller.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(model.isOwn(message) ? Self.ownHeight : Self.height)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thinMaterial)
        .task {
            let controller = MessageActionsController(message: message, model: model)
            self.controller = controller
            controller.loadQuickReactions()
        }
        .sheet(isPresented: $showingPicker) {
            EmojiPicker { shortcode in
                Task {
                    await controller?.react(toShortcode: shortcode)
                    dismiss()
                }
            }
        }
    }

    /// Scrolls rather than wraps: on a narrow phone the last emoji should still be
    /// reachable without the row stealing height from the actions below it.
    private func quickRow(_ controller: MessageActionsController) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(controller.quickReactions) { quick in
                    Button {
                        Task {
                            await controller.react(to: quick)
                            dismiss()
                        }
                    } label: {
                        EmojiDisplayView(display: controller.display(of: quick), size: 26)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(quick.name)
                }

                Button {
                    showingPicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("More emoji")
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func actions(_ controller: MessageActionsController) -> some View {
        VStack(spacing: 0) {
            row("Add Reaction", "face.smiling") { showingPicker = true }
            Divider()
            row("Reply", "arrowshape.turn.up.left") {
                controller.reply()
                dismiss()
            }
            Divider()
            row("Copy Text", "doc.on.doc") {
                controller.copyText()
                dismiss()
            }
            Divider()
            row("Copy Link", "link") {
                controller.copyLink()
                dismiss()
            }
            if controller.isOwn {
                Divider()
                row("Edit", "pencil") {
                    Task { if await controller.edit() { dismiss() } }
                }
                Divider()
                row("Delete", "trash", role: .destructive) { confirmingDelete = true }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .confirmationDialog("Delete this message?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { if await controller.delete() { dismiss() } }
            }
        } message: {
            Text("It is deleted for everyone, and cannot be undone.")
        }
    }

    private func row(
        _ title: String, _ symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 22)
                Text(title).font(.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .padding(.horizontal, 16)
            .frame(height: Self.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// One emoji the quick row offers, resolved down to exactly what the API needs.
struct QuickReaction: Identifiable, Equatable, Sendable {
    let name: String
    let code: String
    let type: String

    var id: String { "\(type):\(code)" }
}

/// Everything the action sheet can do, so the sheet itself only decides what it looks like.
@MainActor
@Observable
final class MessageActionsController {
    private(set) var quickReactions: [QuickReaction] = []
    private(set) var error: String?

    private let message: MessageRecord
    private let model: AppModel

    /// Six fits across a phone without the row needing to scroll, which is the point of
    /// a quick row.
    private static let quickCount = 6

    init(message: MessageRecord, model: AppModel) {
        self.message = message
        self.model = model
    }

    // MARK: reacting

    /// The realm's own habits first — what people here have actually reacted with —
    /// topped up from the web client's fallback set when the realm has not reacted six
    /// distinct ways yet.
    ///
    /// Emoji that no longer resolve are dropped: a deactivated custom emoji still has old
    /// reactions pointing at it, and offering it again would only be refused by the server.
    func loadQuickReactions() {
        let catalogue = EmojiCatalogueLoader.shared.catalogue
        let used = ((try? model.storeForReading?.popularReactions(limit: Self.quickCount * 2)) ?? [])
            .map { QuickReaction(name: $0.emojiName, code: $0.emojiCode, type: $0.reactionType) }

        // Codes, not names: the canonical name of a popular emoji differs between server
        // versions, and only the server's own table says which name goes with which code.
        let fallback = EmojiCode.popularCodes.compactMap { code in
            catalogue.candidates
                .first { $0.kind == .unicode && $0.code == code }
                .map { QuickReaction(name: $0.name, code: $0.code, type: $0.kind.rawValue) }
        }

        var seen = Set<String>()
        quickReactions = (used + fallback)
            .filter { seen.insert($0.id).inserted && resolves($0, in: catalogue) }
            .prefix(Self.quickCount)
            .map { $0 }
    }

    private func resolves(_ quick: QuickReaction, in catalogue: EmojiCatalogue) -> Bool {
        if case .text = catalogue.display(reactionType: quick.type, code: quick.code, name: quick.name) {
            return false
        }
        return true
    }

    func display(of quick: QuickReaction) -> EmojiDisplay {
        EmojiCatalogueLoader.shared.catalogue
            .display(reactionType: quick.type, code: quick.code, name: quick.name)
    }

    func react(to quick: QuickReaction) async {
        error = await model.toggleReaction(
            emojiName: quick.name, emojiCode: quick.code, reactionType: quick.type,
            onMessage: message.id
        )
    }

    /// The picker hands back `:name:`, which has to go through the catalogue's own
    /// resolution order before it names a reaction — an active realm emoji shadows the
    /// unicode emoji of the same name, exactly as it does on the server.
    func react(toShortcode shortcode: String) async {
        let name = shortcode.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard let emoji = EmojiCatalogueLoader.shared.catalogue.resolve(name: name) else {
            error = "Zulu does not know an emoji called \(shortcode)."
            return
        }
        await react(to: QuickReaction(name: emoji.name, code: emoji.code, type: emoji.kind.rawValue))
    }

    // MARK: the message itself

    /// Hands the composer the message, not the quote markdown. The markdown is built when
    /// the reply is actually sent, so what is on screen while typing stays readable.
    func reply() {
        ComposerInbox.shared.deliver(
            reply: ReplyDraft(message: message), to: ConversationKey.of(message)
        )
    }

    var isOwn: Bool { model.isOwn(message) }

    /// True once the composer has the message, so the caller knows to get out of its way.
    func edit() async -> Bool {
        error = await model.beginEditing(message)
        return error == nil
    }

    func delete() async -> Bool {
        error = await model.delete(message)
        return error == nil
    }

    func copyText() {
        Platform.copyToClipboard(plainText)
    }

    func copyLink() {
        guard let account else { return }
        Platform.copyToClipboard(
            ComposeMarkup.permalink(
                toMessage: message.id, in: location, realmURL: account.realmURL
            )
        )
    }

    private var account: ZulipAccount? { model.account }

    private var location: ComposeMarkup.MessageLocation {
        if let channelID = message.channelID {
            return .topic(
                channelID: channelID,
                channelName: model.channel(channelID)?.name ?? "",
                topic: message.topic ?? ""
            )
        }
        let ids = (message.dmKey ?? "").split(separator: ",").compactMap { Int($0) }
        let others = ids.filter { $0 != model.selfUserID }
        return .directMessage(userIDs: others.isEmpty ? ids : others)
    }

    /// Falls out of the same blocks the message is drawn from, so what gets copied is
    /// what is on screen — and it costs no round trip.
    private var plainText: String { Self.plainText(of: message.renderedContent) }

    static func plainText(of renderedContent: String) -> String {
        MessageMarkup.blocks(from: renderedContent)
            .map(MessageActionsController.text(of:))
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func text(of block: MessageBlock) -> String {
        switch block {
        case .paragraph(let spans):
            spans.map(\.text).joined()
        case .quote(let inner), .quotedReply(_, _, _, let inner):
            inner.map(text(of:)).joined(separator: "\n")
        case .codeBlock(_, let code):
            code
        case .bulletList(let items):
            items.map { "• " + $0.map(\.text).joined() }.joined(separator: "\n")
        case .numberedList(let items):
            items.enumerated().map { "\($0.offset + 1). " + $0.element.map(\.text).joined() }
                .joined(separator: "\n")
        case .image(let source, _, let alt, _):
            alt ?? source
        }
    }
}

/// Which conversation a draft belongs to, spelled the same way whether it is derived
/// from the open conversation or from one message in it.
enum ConversationKey {
    static func of(_ source: ConversationSource) -> String {
        switch source {
        case .topic(let channelID, let name, _): "c:\(channelID)/\(name)"
        case .dm(let key): "d:\(key)"
        }
    }

    static func of(_ message: MessageRecord) -> String {
        guard let channelID = message.channelID else { return "d:\(message.dmKey ?? "")" }
        return "c:\(channelID)/\(message.topic ?? "")"
    }
}

/// Text on its way into a composer that is somewhere else in the view tree.
///
/// The composer owns its draft on purpose — it used to lose focus every time the store
/// changed — so a reply cannot simply be written into it from here. This hands the text
/// over and lets the composer pick it up.
@MainActor
@Observable
final class ComposerInbox {
    static let shared = ComposerInbox()

    /// Changes on every delivery, so replying twice to the same message is still two
    /// events rather than one unchanged value.
    private(set) var deliveries = 0

    private var pending: [String: String] = [:]
    private var replies: [String: ReplyDraft] = [:]
    private var edits: [String: EditDraft] = [:]

    func deliver(_ text: String, to conversation: String) {
        pending[conversation, default: ""] += text
        deliveries += 1
    }

    func take(for conversation: String) -> String? {
        pending.removeValue(forKey: conversation)
    }

    /// Replacing rather than accumulating: a message answers one other message, and
    /// swiping a second one means you changed your mind about which.
    func deliver(reply: ReplyDraft, to conversation: String) {
        replies[conversation] = reply
        deliveries += 1
    }

    func takeReply(for conversation: String) -> ReplyDraft? {
        replies.removeValue(forKey: conversation)
    }

    func deliver(edit: EditDraft, to conversation: String) {
        edits[conversation] = edit
        deliveries += 1
    }

    func takeEdit(for conversation: String) -> EditDraft? {
        edits.removeValue(forKey: conversation)
    }
}
