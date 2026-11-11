import SwiftUI
import UniformTypeIdentifiers
import ZuluCompose

/// The compose bar owns its own draft, for the same reason the phone's does: the
/// conversation above it re-evaluates whenever the store changes, and the store changes
/// constantly.
struct MacComposerBar: View {
    let source: ConversationSource
    let placeholder: String

    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui

    @State private var draft = ""
    @State private var cursor = 0
    @State private var pendingCursor: Int?
    @State private var focusToken = 0
    @State private var replyingTo: ReplyDraft?
    @State private var uploads = ComposerUploads()
    @State private var sendError: String?
    @State private var importingFiles = false
    @State private var showingEmoji = false
    @State private var autocomplete: ComposeAutocompleteController?
    @State private var typingSender: TypingSender?
    @State private var editMode: ComposerEditMode?

    static let horizontalPadding: CGFloat = 12

    private var isEditing: Bool { editMode?.isEditing == true }

    /// What Send would post, with every finished upload linked after the typed text.
    private var outgoing: String { uploads.pending.message(with: draft) }

    /// A message waits for its uploads, so none of them is left out of it.
    private var canSend: Bool {
        !outgoing.isEmpty && !uploads.pending.isUploading && editMode?.isSaving != true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if isEditing {
                editBanner
            } else if let replyingTo {
                replyBanner(replyingTo)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    importingFiles = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.body)
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help("Attach Files")
                .padding(.bottom, 2)

                field

                Button {
                    isEditing ? saveEdit() : send()
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .help(isEditing ? "Save  ⏎" : "Send  ⏎")
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 8)
        // Drawn by the conversation, above everything in it. Drawn here, the history
        // covered the part of the box that stuck out above the bar.
        .anchorPreference(key: MacAutocompleteKey.self, value: .bounds) { bounds in
            autocomplete.map { MacAutocompleteRequest(controller: $0, bounds: bounds, pick: accept) }
        }
        .task(id: source) {
            typingSender?.stop()
            // What was being edited belongs to the conversation being left.
            if isEditing { draft = "" }
            editMode = ComposerEditMode(model: model)
            restoreDraft()
            typingSender = TypingSender { [model, source] op in await model.sendTyping(op, in: source) }
            EmojiCatalogueLoader.shared.start(store: model.storeForReading)
            let controller = ComposeAutocompleteController(model: model, source: source)
            await controller.prepare()
            autocomplete = controller
            focusToken += 1
        }
        // The emoji table arrives well after the conversation opens, so the sources are
        // rebuilt when it lands rather than waiting for it up front.
        .task(id: EmojiCatalogueLoader.shared.catalogue.candidates.count) {
            await autocomplete?.prepare()
        }
        .onChange(of: draft) { autocomplete?.update(draft: draft, cursorOffsetUTF16: cursor) }
        .onChange(of: outgoing) { saveDraft() }
        .onChange(of: replyingTo) { saveDraft() }
        .onDisappear { typingSender?.stop() }
        .onChange(of: cursor) { autocomplete?.update(draft: draft, cursorOffsetUTF16: cursor) }
        .onChange(of: ComposerInbox.shared.deliveries) { takeDelivery() }
        .onChange(of: ui.composerFocusRequests) { focusToken += 1 }
        .fileImporter(
            isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { uploads.upload(files: urls, model: model) }
        }
    }

    private static let uploadInset: CGFloat = 6

    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            ComposerUploadStrip(uploads: uploads, inset: Self.uploadInset)
            fieldInput
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var fieldInput: some View {
        HStack(alignment: .bottom, spacing: 4) {
            MacComposerTextView(
                text: $draft,
                cursor: $cursor,
                pendingCursor: $pendingCursor,
                placeholder: placeholder,
                focusToken: focusToken,
                onKey: handle(_:),
                onEdit: { typingSender?.draftChanged(to: $0) },
                onFiles: { uploads.upload(files: $0, model: model) },
                onImage: { data, type in
                    let name = "pasted-\(Self.stamp()).\(type.preferredFilenameExtension ?? "png")"
                    uploads.upload(data, filename: name, contentType: type.preferredMIME, model: model)
                }
            )
            .padding(.leading, 6)

            Button {
                showingEmoji = true
            } label: {
                Image(systemName: "face.smiling")
                    .foregroundStyle(TextTone.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Emoji")
            .padding(.trailing, 4)
            .padding(.bottom, 3)
            .popover(isPresented: $showingEmoji, arrowEdge: .top) {
                MacComposerPicker(insertEmoji: { insert($0) }, insertGIF: { insertOnOwnLine($0.markdown) })
            }
        }
    }

    /// Who is being answered, and enough of what they said to be sure it is the right
    /// message — the same information a sent reply shows, before it is sent.
    private func replyBanner(_ reply: ReplyDraft) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(Color.accentColor).frame(width: 3)
            SenderAvatar(name: reply.author, userID: reply.authorID, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Label("Replying to \(reply.author)", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(reply.preview).font(.caption).foregroundStyle(TextTone.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.snappy(duration: 0.2)) { replyingTo = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TextTone.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Cancel reply  ⎋")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .frame(height: 42)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var editBanner: some View {
        HStack(spacing: 8) {
            Capsule().fill(Color.accentColor).frame(width: 3)
            Label("Editing message", systemImage: "pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Spacer(minLength: 0)
            if editMode?.isSaving == true {
                ProgressView().controlSize(.small)
            }
            Button {
                cancelEdit()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TextTone.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Cancel edit  ⎋")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .frame(height: 42)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: keys

    /// Return and Tab accept a suggestion when the box is open and otherwise fall
    /// through; Escape closes whatever is open, the box first, then an edit, then the
    /// reply. Up in an empty composer edits your last message, as it does in Slack.
    private func handle(_ key: ComposerKey) -> Bool {
        let open = autocomplete?.isOpen == true
        switch key {
        case .send:
            if open, let suggestion = autocomplete?.selectedSuggestion {
                accept(suggestion)
                return true
            }
            isEditing ? saveEdit() : send()
            return true
        case .tab:
            guard open, let suggestion = autocomplete?.selectedSuggestion else { return false }
            accept(suggestion)
            return true
        case .up:
            if open {
                autocomplete?.moveSelection(by: -1)
                return true
            }
            guard draft.isEmpty, !isEditing else { return false }
            Task { await model.beginEditingLatestMessage(in: source) }
            return true
        case .down:
            guard open else { return false }
            autocomplete?.moveSelection(by: 1)
            return true
        case .escape:
            if open {
                autocomplete?.dismiss()
                return true
            }
            if isEditing {
                cancelEdit()
                return true
            }
            if replyingTo != nil {
                withAnimation(.snappy(duration: 0.2)) { replyingTo = nil }
                return true
            }
            return false
        }
    }

    /// The cursor is moved along with the text. The text view does not report a cursor
    /// it was told to move, and the box would reopen on the query at the old one.
    private func accept(_ suggestion: AutocompleteSuggestion) {
        guard let result = autocomplete?.complete(suggestion, in: draft) else { return }
        cursor = result.cursorOffsetUTF16
        draft = result.text
        pendingCursor = result.cursorOffsetUTF16
        focusToken += 1
    }

    /// The picker hands back a shortcode rather than a character, because the server
    /// resolves the name against the realm's own emoji when it renders. It lands at the
    /// cursor, with a space before it so it does not run into the word before it.
    private func insert(_ shortcode: String) {
        insert(shortcode, separatedBy: " ", unlessAfter: \.isWhitespace)
    }

    /// Where Zulip's web app puts a GIF.
    private func insertOnOwnLine(_ markdown: String) {
        insert(markdown, separatedBy: "\n", unlessAfter: \.isNewline)
    }

    private func insert(
        _ text: String, separatedBy separator: String, unlessAfter isSeparator: (Character) -> Bool
    ) {
        let offset = max(0, min(cursor, draft.utf16.count))
        let index = String.Index(utf16Offset: offset, in: draft)
        var insertion = text
        if index > draft.startIndex, let previous = draft[draft.index(before: index)...].first,
           !isSeparator(previous) {
            insertion = separator + insertion
        }
        cursor = offset + insertion.utf16.count
        draft.insert(contentsOf: insertion, at: index)
        pendingCursor = cursor
        focusToken += 1
    }

    private func takeDelivery() {
        let key = ConversationKey.of(source)
        if let edit = ComposerInbox.shared.takeEdit(for: key) {
            beginEdit(edit)
        }
        if let reply = ComposerInbox.shared.takeReply(for: key) {
            withAnimation(.snappy(duration: 0.24)) { replyingTo = reply }
            focusToken += 1
        }
        if let files = ComposerInbox.shared.takeFiles(for: key) {
            uploads.upload(files: files, model: model)
        }
        guard let text = ComposerInbox.shared.take(for: key) else { return }
        append(text)
        focusToken += 1
    }

    private func append(_ text: String) {
        if !draft.isEmpty, !draft.hasSuffix("\n") { draft += "\n" }
        draft += text
        pendingCursor = draft.utf16.count
    }

    /// While editing, the draft on disk stays whatever was being typed before.
    private func saveDraft() {
        guard !isEditing else { return }
        model.saveDraft(outgoing, replyingTo: replyingTo, in: source)
    }

    // MARK: editing

    private func beginEdit(_ edit: EditDraft) {
        editMode?.begin(edit, settingAside: uploads.setAside(with: draft), reply: replyingTo)
        sendError = nil
        autocomplete?.dismiss()
        withAnimation(.snappy(duration: 0.2)) { replyingTo = nil }
        replaceDraft(with: edit.original)
    }

    private func cancelEdit() {
        guard let setAside = editMode?.cancel() else { return }
        restore(setAside)
    }

    private func saveEdit() {
        guard let editMode, canSend else { return }
        Task {
            switch await editMode.save(outgoing) {
            case .success(let setAside):
                sendError = nil
                uploads.removeAll()
                restore(setAside)
            case .failure(let error):
                sendError = error.message
            }
        }
    }

    private func restore(_ setAside: ComposerEditMode.SetAside) {
        withAnimation(.snappy(duration: 0.2)) { replyingTo = setAside.reply }
        replaceDraft(with: uploads.restore(from: setAside.text))
    }

    private func replaceDraft(with text: String) {
        cursor = text.utf16.count
        draft = text
        pendingCursor = cursor
        focusToken += 1
    }

    /// Only into an empty composer, so coming back to the conversation never replaces
    /// something already typed. The cursor goes to the end, where typing left off.
    private func restoreDraft() {
        guard draft.isEmpty, uploads.pending.isEmpty, replyingTo == nil,
              let saved = model.savedDraft(in: source)
        else { return }
        draft = uploads.restore(from: saved.text)
        replyingTo = saved.reply
        pendingCursor = draft.utf16.count
    }

    /// Hands the message to the outbox and clears at once; a failure shows on the
    /// message itself, with a resend.
    private func send() {
        guard canSend else { return }
        model.enqueue(outgoing, replyingTo: replyingTo, in: source)
        typingSender?.stop()
        sendError = nil
        draft = ""
        uploads.removeAll()
        autocomplete?.dismiss()
        withAnimation(.snappy(duration: 0.2)) { replyingTo = nil }
    }

    // MARK: attachments

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}

/// What the conversation needs to draw the composer's suggestion box over itself.
struct MacAutocompleteRequest {
    let controller: ComposeAutocompleteController
    /// The compose bar's, so the box can sit on top of it.
    let bounds: Anchor<CGRect>
    let pick: (AutocompleteSuggestion) -> Void
}

struct MacAutocompleteKey: PreferenceKey {
    static var defaultValue: MacAutocompleteRequest? { nil }

    static func reduce(value: inout MacAutocompleteRequest?, nextValue: () -> MacAutocompleteRequest?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Hosts the suggestion box of a composer somewhere inside this view.
    func macAutocompleteBox() -> some View {
        overlayPreferenceValue(MacAutocompleteKey.self) { request in
            if let request {
                GeometryReader { proxy in
                    let bar = proxy[request.bounds]
                    if request.controller.isOpen {
                        MacAutocompleteBox(
                            suggestions: request.controller.suggestions,
                            selectedIndex: request.controller.selectedIndex,
                            pick: request.pick
                        )
                        .padding(.horizontal, MacComposerBar.horizontalPadding)
                        .frame(width: bar.width, height: bar.minY, alignment: .bottomLeading)
                        .offset(x: bar.minX)
                    }
                }
            }
        }
    }
}

/// The suggestion box, sitting above the field with the best match on top and the
/// keyboard's row highlighted. Click or Return picks; the composer moves the highlight.
struct MacAutocompleteBox: View {
    let suggestions: [AutocompleteSuggestion]
    let selectedIndex: Int
    let pick: (AutocompleteSuggestion) -> Void

    private static let iconSize: CGFloat = 20

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { pick(suggestion) } label: {
                    HStack(spacing: 8) {
                        SuggestionIcon(icon: suggestion.icon, size: Self.iconSize)
                            .frame(width: Self.iconSize, height: Self.iconSize)
                        Text(suggestion.title)
                            .font(.callout)
                            .lineLimit(1)
                        if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(TextTone.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if index == selectedIndex {
                            Text("↩")
                                .font(.caption2)
                                .foregroundStyle(TextTone.tertiary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(
                        index == selectedIndex ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
