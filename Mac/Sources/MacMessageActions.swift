import SwiftUI
import ZuluEmoji
import ZuluStore

extension View {
    /// The Mac's answer to the phone's long press: a context menu on right-click, and
    /// the same things under the small buttons in a message's header.
    func macMessageActions(_ message: MessageRecord, in source: ConversationSource) -> some View {
        modifier(MacMessageActions(message: message, source: source))
    }
}

/// The row's own part: the right-click menu, and the picker that menu can ask for. A
/// bar that appeared under the pointer on every message was a lot of chrome for
/// reacting, and tracking the pointer over every row showed in the scroll profile.
private struct MacMessageActions: ViewModifier {
    let message: MessageRecord
    let source: ConversationSource

    @State private var showingPicker = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                MacMessageMenuItems(message: message) { showingPicker = true }
            }
            // Anchored to the row, for the menu's "Add Reaction…".
            .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                MacReactionPopover(message: message, mode: .picker)
            }
    }
}

/// What every message offers, in one list: the right-click menu and the header's "…"
/// show exactly these.
struct MacMessageMenuItems: View {
    let message: MessageRecord
    /// Opens the full emoji picker; where it is anchored is the caller's business.
    let addReaction: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @Environment(\.macQuickReactions) private var quickReactions

    private var controller: MessageActionsController {
        MessageActionsController(message: message, model: model)
    }

    var body: some View {
        Button("Reply") { MacMessageReply.reply(to: message, ui: ui) }
        Menu("React") {
            ForEach(quickReactions) { quick in
                Button(":\(quick.name):") { Task { await controller.react(to: quick) } }
            }
            if !quickReactions.isEmpty { Divider() }
            Button("Add Reaction…") { addReaction() }
        }
        Divider()
        Button("Copy Text") { controller.copyText() }
        Button("Copy Link") { controller.copyLink() }
        if model.isOwn(message) {
            Divider()
            Button("Edit Message") {
                Task { _ = await controller.edit() }
                ui.requestComposerFocus()
            }
            // One dialog for the conversation, not one per message: see the conversation view.
            Button("Delete Message…", role: .destructive) { ui.confirmingDeleteOf = message }
        }
    }
}

enum MacMessageReply {
    @MainActor
    static func reply(to message: MessageRecord, ui: MacUIState) {
        ComposerInbox.shared.deliver(reply: ReplyDraft(message: message), to: ConversationKey.of(message))
        ui.requestComposerFocus()
    }
}

/// The small buttons after the time in a message's header: reply, react, and the rest.
/// They are the only message controls always on screen.
struct MacHeaderActions: View {
    let message: MessageRecord

    @Environment(MacUIState.self) private var ui
    @State private var reacting: MacReactionPopover.Mode?

    var body: some View {
        HStack(spacing: 2) {
            headerButton(help: "Reply", systemImage: "arrowshape.turn.up.left") {
                MacMessageReply.reply(to: message, ui: ui)
            }
            headerButton(help: "React", systemImage: "face.smiling") {
                reacting = .quick
            }
            .popover(item: $reacting, arrowEdge: .bottom) { mode in
                MacReactionPopover(message: message, mode: mode)
            }
            Menu {
                MacMessageMenuItems(message: message) { reacting = .picker }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(TextTone.tertiary)
                    .frame(width: 18, height: 16)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.leading, 2)
    }

    private func headerButton(help: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(TextTone.tertiary)
                .frame(width: 18, height: 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Reacting, in two sizes: the realm's usual few in a row, and behind "more" the whole
/// picker, which lists the realm's own emoji too.
struct MacReactionPopover: View {
    enum Mode: String, Identifiable {
        case quick
        case picker
        var id: String { rawValue }
    }

    let message: MessageRecord
    @State var mode: Mode

    @Environment(AppModel.self) private var model
    @Environment(\.macQuickReactions) private var quickReactions
    @Environment(\.dismiss) private var dismiss

    private var controller: MessageActionsController {
        MessageActionsController(message: message, model: model)
    }

    var body: some View {
        switch mode {
        case .quick:
            HStack(spacing: 2) {
                ForEach(quickReactions) { quick in
                    Button {
                        Task { await controller.react(to: quick) }
                        dismiss()
                    } label: {
                        EmojiDisplayView(display: display(of: quick), size: 18)
                            .frame(width: 28, height: 26)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(":\(quick.name):")
                }
                if !quickReactions.isEmpty { Divider().frame(height: 16) }
                Button {
                    mode = .picker
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(TextTone.secondary)
                        .frame(width: 28, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("More emoji…")
            }
            .padding(4)
        case .picker:
            MacEmojiPicker { shortcode in
                Task { await controller.react(toShortcode: shortcode) }
                dismiss()
            }
        }
    }

    private func display(of quick: QuickReaction) -> EmojiDisplay {
        EmojiCatalogueLoader.shared.catalogue
            .display(reactionType: quick.type, code: quick.code, name: quick.name)
    }
}
