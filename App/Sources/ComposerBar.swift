import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import ZuluCompose

/// The compose bar owns its own draft.
///
/// It used to live inside `ConversationView`, which re-evaluates whenever the store
/// changes — and the store changes constantly, since reading messages writes to it. Every
/// one of those rebuilds cost the text field its focus, so only the first character of
/// anything typed survived. Holding the draft down here keeps the field out of that path.
struct ComposerBar: View {
    let source: ConversationView.Source
    let placeholder: String
    let suggestionBox: AutocompleteSlot

    @Environment(AppModel.self) private var model

    @State private var draft = ""
    @State private var replyingTo: ReplyDraft?
    @State private var uploading = false
    @State private var sendError: String?
    @State private var showEmoji = false
    @State private var attachment: AttachmentSource?
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var autocomplete: ComposeAutocompleteController?
    @State private var focusToken = 0
    @State private var typingSender: TypingSender?
    @State private var editMode: ComposerEditMode?
    @State private var hasKeyboard = false

    /// Every icon control in the bar is the same circle, so the row reads as one piece.
    static let controlSize: CGFloat = 26
    /// What a glass button pads around its label. The emoji button sits that far in from
    /// the field's corner, so it centres on the same line as the buttons either side.
    private static let glassControlInset: CGFloat = 7
    static let horizontalPadding: CGFloat = 12
    /// Half the field's one-line height.
    private static let fieldCornerRadius: CGFloat = 20

    private var isEditing: Bool { editMode?.isEditing == true }

    var body: some View {
        VStack(spacing: 6) {
            if let sendError {
                Text(sendError).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if uploading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Uploading…").font(.caption).foregroundStyle(TextTone.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isEditing {
                editBanner
            } else if let replyingTo {
                replyBanner(replyingTo)
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Swiping the conversation away is not obvious, and there is no key for
                // it on a phone's keyboard.
                if hasKeyboard {
                    Button {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                        )
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.body.weight(.semibold))
                            .frame(width: Self.controlSize, height: Self.controlSize)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Hide keyboard")
                    .transition(.scale.combined(with: .opacity))
                }

                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { attachment = .photos }
                    Button("Choose Files", systemImage: "folder") { attachment = .files }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Take Photo", systemImage: "camera") { attachment = .camera }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: Self.controlSize, height: Self.controlSize)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                field

                Button {
                    isEditing ? saveEdit() : send()
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: Self.controlSize, height: Self.controlSize)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editMode?.isSaving == true)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 8)
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
            suggestionBox.request = AutocompleteRequest(controller: controller) { suggestion in
                draft = controller.apply(suggestion, to: draft)
            }
        }
        // The emoji table arrives well after the conversation opens, so the sources are
        // rebuilt when it lands rather than waiting for it up front.
        .task(id: EmojiCatalogueLoader.shared.catalogue.candidates.count) {
            await autocomplete?.prepare()
        }
        .onChange(of: draft) {
            autocomplete?.update(draft: draft)
            saveDraft()
        }
        .onChange(of: replyingTo) { saveDraft() }
        .onDisappear { typingSender?.stop() }
        .onChange(of: ComposerInbox.shared.deliveries) { takeDelivery() }
        .sheet(isPresented: $showEmoji) { EmojiPicker { insert($0) } }
        .photosPicker(
            isPresented: binding(for: .photos), selection: $pickedPhotos,
            maxSelectionCount: 5, matching: .any(of: [.images, .videos])
        )
        .onChange(of: pickedPhotos) { takePickedPhotos() }
        .fileImporter(
            isPresented: binding(for: .files), allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { Task { await upload(urls: urls) } }
        }
        .fullScreenCover(isPresented: binding(for: .camera)) {
            CameraPicker { data in
                guard let data else { return }
                Task { await upload(data: data, filename: "photo.jpg", contentType: "image/jpeg") }
            }
            .ignoresSafeArea()
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
                    .labelStyle(.titleAndIcon)
                Text(reply.preview)
                    .font(.caption)
                    .foregroundStyle(TextTone.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.snappy(duration: 0.2)) { replyingTo = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TextTone.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .frame(height: 44)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var editBanner: some View {
        HStack(spacing: 8) {
            Capsule().fill(Color.accentColor).frame(width: 3)
            Label("Editing message", systemImage: "pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .labelStyle(.titleAndIcon)
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
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel edit")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .frame(height: 44)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ComposerTextView(
                text: $draft,
                placeholder: placeholder,
                focusToken: focusToken,
                onEdit: { typingSender?.draftChanged(to: $0) },
                onFocusChange: { focused in
                    withAnimation(.snappy(duration: 0.2)) { hasKeyboard = focused }
                },
                onImage: { data, type in
                    Task { await upload(data: data, filename: Self.pastedName(type), contentType: type.preferredMIME) }
                }
            )

            Button {
                showEmoji = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.body)
                    .foregroundStyle(TextTone.secondary)
                    .frame(width: Self.controlSize, height: Self.controlSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .padding([.trailing, .bottom], Self.glassControlInset)
        }
        // A capsule while one line tall; rounded corners that stay put once it grows.
        .glassEffect(.regular, in: .rect(cornerRadius: Self.fieldCornerRadius))
    }

    /// A quote-and-reply is appended rather than replacing what is there, so replying
    /// after starting to type does not throw the typing away.
    private func takeDelivery() {
        let key = ConversationKey.of(source)
        if let edit = ComposerInbox.shared.takeEdit(for: key) {
            beginEdit(edit)
        }
        if let reply = ComposerInbox.shared.takeReply(for: key) {
            withAnimation(.snappy(duration: 0.24)) { replyingTo = reply }
            focusToken += 1
        }
        guard let text = ComposerInbox.shared.take(for: key) else { return }
        if !draft.isEmpty, !draft.hasSuffix("\n") { draft += "\n" }
        draft += text
        focusToken += 1
    }

    /// The picker hands back a shortcode rather than a character, because the server
    /// resolves the name against the realm's own emoji when it renders. The space keeps
    /// it from running into the word before it.
    private func insert(_ shortcode: String) {
        if let last = draft.last, last != " ", last != "\n" { draft += " " }
        draft += shortcode
    }

    /// While editing, the draft on disk stays whatever was being typed before.
    private func saveDraft() {
        guard !isEditing else { return }
        model.saveDraft(draft, replyingTo: replyingTo, in: source)
    }

    // MARK: editing

    private func beginEdit(_ edit: EditDraft) {
        editMode?.begin(edit, settingAside: draft, reply: replyingTo)
        sendError = nil
        withAnimation(.snappy(duration: 0.2)) { replyingTo = nil }
        draft = edit.original
        focusToken += 1
    }

    private func cancelEdit() {
        guard let setAside = editMode?.cancel() else { return }
        restore(setAside)
    }

    private func saveEdit() {
        guard let editMode else { return }
        Task {
            switch await editMode.save(draft) {
            case .success(let setAside):
                sendError = nil
                restore(setAside)
            case .failure(let error):
                sendError = error.message
            }
        }
    }

    private func restore(_ setAside: ComposerEditMode.SetAside) {
        withAnimation(.snappy(duration: 0.2)) { replyingTo = setAside.reply }
        draft = setAside.text
    }

    /// Only into an empty composer, so coming back to the conversation never replaces
    /// something already typed.
    private func restoreDraft() {
        guard draft.isEmpty, replyingTo == nil, let saved = model.savedDraft(in: source) else { return }
        draft = saved.text
        replyingTo = saved.reply
    }

    /// Hands the message to the outbox and clears at once; a failure shows on the
    /// message itself, with a resend.
    private func send() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        model.enqueue(typed, replyingTo: replyingTo, in: source)
        typingSender?.stop()
        sendError = nil
        draft = ""
        withAnimation(.snappy(duration: 0.2)) { replyingTo = nil }
    }

    // MARK: attachments

    private func binding(for wanted: AttachmentSource) -> Binding<Bool> {
        Binding(
            get: { attachment == wanted },
            set: { if !$0, attachment == wanted { attachment = nil } }
        )
    }

    /// Clearing the selection would cancel a task keyed on it, so the uploads run in a
    /// task of their own.
    private func takePickedPhotos() {
        guard !pickedPhotos.isEmpty else { return }
        let items = pickedPhotos
        pickedPhotos = []
        Task { await upload(photos: items) }
    }

    private func upload(photos items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first ?? .data
            let name = "\(UUID().uuidString.prefix(8)).\(type.preferredFilenameExtension ?? "dat")"
            await upload(data: data, filename: name, contentType: type.preferredMIME)
        }
    }

    private static func pastedName(_ type: UTType) -> String {
        "pasted-\(UUID().uuidString.prefix(8)).\(type.preferredFilenameExtension ?? "png")"
    }

    private func upload(urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            await upload(data: data, filename: url.lastPathComponent, contentType: type.preferredMIME)
        }
    }

    /// Zulip uploads first and embeds the result as ordinary markdown, so an attachment
    /// lands in the draft as a link the person can still edit or caption before sending.
    private func upload(data: Data, filename: String, contentType: String) async {
        uploading = true
        sendError = nil
        defer { uploading = false }

        switch await model.upload(data, filename: filename, contentType: contentType) {
        case .success(let markdown):
            if !draft.isEmpty, !draft.hasSuffix("\n") { draft += "\n" }
            draft += markdown + "\n"
        case .failure(let message):
            sendError = message
        }
    }
}

/// What the conversation needs to draw the composer's suggestion box over itself.
struct AutocompleteRequest {
    let controller: ComposeAutocompleteController
    let pick: (AutocompleteSuggestion) -> Void
}

/// Hands the composer's suggestions up to the conversation.
///
/// The composer sits in the bottom bar, and the bar takes no touches outside its own
/// frame. A box hung above it from inside could be seen but not tapped, apart from the
/// sliver of its bottom row that overlapped the typing line.
@MainActor
@Observable
final class AutocompleteSlot {
    var request: AutocompleteRequest?
}

/// Floats over the conversation, along its bottom edge, which is the top of the bar.
/// In the bar instead, every list that opened or closed resized it and moved the
/// conversation.
///
/// Its own view, so a keystroke redraws the box and not the whole conversation.
struct AutocompleteOverlay: View {
    let slot: AutocompleteSlot

    var body: some View {
        if let request = slot.request, request.controller.isOpen {
            AutocompleteBox(suggestions: request.controller.suggestions, pick: request.pick)
                .padding(.horizontal, ComposerBar.horizontalPadding)
        }
    }
}
