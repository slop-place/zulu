import SwiftUI
import ZuluEmoji
import ZuluStore

/// Where a message's buttons live: always in its header, or in a bar over the message
/// under the pointer.
enum MacMessageActionStyle: String, CaseIterable, Identifiable {
    case header
    case hover

    static let storageKey = "messages.actionStyle"
    static let standard = MacMessageActionStyle.header

    var id: String { rawValue }

    var title: String {
        switch self {
        case .header: "Next to the name"
        case .hover: "On hover"
        }
    }
}

extension View {
    /// The Mac's answer to the phone's long press: a context menu on right-click, and
    /// the same things under the small buttons in a message's header or hover bar.
    func macMessageActions(_ message: MessageRecord, in source: ConversationSource) -> some View {
        modifier(MacMessageActions(message: message, source: source))
    }
}

private struct MacMessageActions: ViewModifier {
    let message: MessageRecord
    let source: ConversationSource

    @AppStorage(MacMessageActionStyle.storageKey) private var style = MacMessageActionStyle.standard

    func body(content: Content) -> some View {
        switch style {
        case .header: content.modifier(MacMessageRowMenu(message: message))
        case .hover: content.modifier(MacMessageHoverBar(message: message))
        }
    }
}

/// The row's own part: the right-click menu, and the picker that menu can ask for. A
/// bar that appeared under the pointer on every message was a lot of chrome for
/// reacting, and tracking the pointer over every row showed in the scroll profile.
private struct MacMessageRowMenu: ViewModifier {
    let message: MessageRecord

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

/// A bar that appears on hover and a context menu on right-click, both offering the
/// same things.
private struct MacMessageHoverBar: ViewModifier {
    let message: MessageRecord

    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @Environment(\.macQuickReactions) private var quickReactions

    @State private var hovering = false
    @State private var showingPicker = false

    /// The bar stays while its popover is up, or the popover would lose its anchor and
    /// close the moment the pointer moved.
    private var barVisible: Bool { hovering || showingPicker }

    private var controller: MessageActionsController {
        MessageActionsController(message: message, model: model)
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(barVisible ? Color.primary.opacity(0.045) : .clear)
            }
            .padding(.horizontal, -8)
            .overlay(alignment: .topTrailing) {
                if barVisible {
                    bar.offset(x: -4, y: -12)
                }
            }
            .onHover { hovering = $0 }
            .contextMenu {
                MacMessageMenuItems(message: message) { showingPicker = true }
            }
    }

    private var bar: some View {
        HStack(spacing: 2) {
            ForEach(quickReactions) { quick in
                barButton(help: ":\(quick.name):") {
                    Task { await controller.react(to: quick) }
                } label: {
                    EmojiDisplayView(display: display(of: quick), size: 15)
                }
            }
            if !quickReactions.isEmpty { Divider().frame(height: 14) }

            barButton(help: "Add Reaction") {
                showingPicker = true
            } label: {
                Image(systemName: "face.smiling")
            }
            .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                MacEmojiPicker { shortcode in
                    Task { await controller.react(toShortcode: shortcode) }
                }
            }

            barButton(help: "Reply") {
                MacMessageReply.reply(to: message, ui: ui)
            } label: {
                Image(systemName: "arrowshape.turn.up.left")
            }

            if model.isOwn(message) {
                barButton(help: "Edit") {
                    MacMessageEdit.edit(message, model: model, ui: ui)
                } label: {
                    Image(systemName: "pencil")
                }
            }

            Menu {
                MacMessageCopyAndOwnItems(message: message)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 22)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .transition(.opacity)
    }

    private func barButton<Label: View>(
        help: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(TextTone.secondary)
                .frame(width: 24, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func display(of quick: QuickReaction) -> EmojiDisplay {
        EmojiCatalogueLoader.shared.catalogue
            .display(reactionType: quick.type, code: quick.code, name: quick.name)
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
        MacMessageCopyAndOwnItems(message: message)
    }
}

/// The hover bar's "…" shows only these: the bar already has reply and react.
struct MacMessageCopyAndOwnItems: View {
    let message: MessageRecord

    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui

    private var controller: MessageActionsController {
        MessageActionsController(message: message, model: model)
    }

    var body: some View {
        Button("Copy Text") { controller.copyText() }
        Button("Copy Link") { controller.copyLink() }
        if model.isOwn(message) {
            Divider()
            Button("Edit Message") { MacMessageEdit.edit(message, model: model, ui: ui) }
            // One dialog for the conversation, not one per message: see the conversation view.
            Button("Delete Message…", role: .destructive) { ui.confirmingDeleteOf = message }
        }
    }
}

enum MacMessageEdit {
    @MainActor
    static func edit(_ message: MessageRecord, model: AppModel, ui: MacUIState) {
        let controller = MessageActionsController(message: message, model: model)
        Task { _ = await controller.edit() }
        ui.requestComposerFocus()
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
    @AppStorage(MacMessageActionStyle.storageKey) private var style = MacMessageActionStyle.standard
    @State private var reacting: MacReactionPopover.Mode?

    var body: some View {
        if style == .header {
            buttons
        }
    }

    private var buttons: some View {
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
