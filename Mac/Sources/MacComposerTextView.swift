import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The keys a composer cares about beyond typing. Each is offered to SwiftUI first and
/// falls through to the text view's own behaviour when nobody wants it.
enum ComposerKey {
    case send, up, down, tab, escape
}

/// A real `NSTextView` under the composer, because SwiftUI's `TextField` on the Mac
/// cannot be told that Return sends, cannot hand arrow keys to an autocomplete box, and
/// cannot see an image on the pasteboard.
///
/// Grows with its text up to a few lines, then scrolls.
struct MacComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// The insertion point as a UTF-16 offset, which is what AppKit speaks and what the
    /// autocomplete needs to find the trigger the cursor is sitting after.
    @Binding var cursor: Int
    /// Set by the parent after it changes `text` itself — completing a suggestion,
    /// inserting an emoji — to say where the cursor should land. Cleared once applied.
    @Binding var pendingCursor: Int?
    var placeholder: String
    /// Bumped by the parent whenever the field should take focus.
    var focusToken: Int
    var onKey: (ComposerKey) -> Bool
    /// Called for what the person typed, never for text the parent set.
    var onEdit: (String) -> Void = { _ in }
    var onFiles: ([URL]) -> Void
    var onImage: (Data, UTType) -> Void

    static let maxLines = 8

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isContinuousSpellCheckingEnabled = true
        // Markdown: a straight quote or a double hyphen is usually meant literally.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // A chat line is not a sentence, and a markdown composer cannot have the system
        // rewriting what was typed. Spelling is still underlined; nothing is changed.
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .none
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        textView.placeholder = placeholder
        textView.onKey = { [weak coordinator] key in coordinator?.parent.onKey(key) ?? false }
        textView.onFiles = { [weak coordinator] urls in coordinator?.parent.onFiles(urls) }
        textView.onImage = { [weak coordinator] data, type in coordinator?.parent.onImage(data, type) }

        coordinator.isSyncing = true
        defer { coordinator.isSyncing = false }

        // Only a change made *outside* the view — a completion, an emoji, a cleared
        // draft — is pushed into it. Comparing against the view's own string instead
        // would clobber a keystroke: AppKit reports the selection moving before it
        // reports the text changing, and an update that runs between the two sees a
        // view that is one character ahead of the state.
        if text != coordinator.knownText {
            coordinator.knownText = text
            let location = min(textView.selectedRange().location, (text as NSString).length)
            textView.string = text
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.needsDisplay = true
        }
        if let pending = pendingCursor {
            let location = min(max(pending, 0), (text as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            // Cleared outside the update, since a state write during one is undefined.
            DispatchQueue.main.async { pendingCursor = nil }
        }
        if coordinator.focusToken != focusToken {
            coordinator.focusToken = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// One line tall for an empty draft, growing to `maxLines`, then a scroll view.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let textView = nsView.documentView as? ComposerTextView
        else { return nil }

        let inset = textView.textContainerInset
        textView.textContainer?.containerSize = NSSize(
            width: width - inset.width * 2, height: CGFloat.greatestFiniteMagnitude
        )
        let content: CGFloat
        if let layout = textView.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
            content = layout.usageBoundsForTextContainer.height
        } else if let layout = textView.layoutManager, let container = textView.textContainer {
            layout.ensureLayout(for: container)
            content = layout.usedRect(for: container).height
        } else {
            content = Self.lineHeight
        }
        let minimum = Self.lineHeight + inset.height * 2
        let maximum = Self.lineHeight * CGFloat(Self.maxLines) + inset.height * 2
        return CGSize(width: width, height: min(max(ceil(content) + inset.height * 2, minimum), maximum))
    }

    static let font = NSFont.preferredFont(forTextStyle: .body)
    static let lineHeight = ceil(font.ascender - font.descender + font.leading)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacComposerTextView
        var focusToken = -1
        /// The last text the view and the state agreed on.
        var knownText = ""
        /// True while `updateNSView` is writing into the view, so the echoes it causes
        /// are not written back into SwiftUI state mid-update.
        var isSyncing = false

        init(parent: MacComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isSyncing, let textView = notification.object as? NSTextView else { return }
            knownText = textView.string
            parent.text = textView.string
            parent.onEdit(textView.string)
            let location = textView.selectedRange().location
            if parent.cursor != location { parent.cursor = location }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isSyncing, let textView = notification.object as? NSTextView else { return }
            let location = textView.selectedRange().location
            if parent.cursor != location { parent.cursor = location }
        }
    }
}

/// The view itself: key handling, a placeholder, and pasteboard and drag handling for
/// files and images.
final class ComposerTextView: NSTextView {
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    var onKey: ((ComposerKey) -> Bool)?
    var onFiles: (([URL]) -> Void)?
    var onImage: ((Data, UTType) -> Void)?

    private enum KeyCode {
        static let `return`: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    /// Return sends; Shift-Return and Option-Return start a new line. That is what every
    /// Mac chat client does, and it is the one behaviour a person notices immediately if
    /// it is wrong.
    override func keyDown(with event: NSEvent) {
        // Arrow keys always arrive flagged as function and keypad keys, which are not
        // modifiers anyone pressed.
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad])
        switch event.keyCode {
        case KeyCode.return, KeyCode.keypadEnter:
            if flags.contains(.shift) || flags.contains(.option) {
                insertNewline(nil)
                return
            }
            if onKey?(.send) == true { return }
        case KeyCode.up:
            if flags.isEmpty, onKey?(.up) == true { return }
        case KeyCode.down:
            if flags.isEmpty, onKey?(.down) == true { return }
        case KeyCode.tab:
            if flags.isEmpty, onKey?(.tab) == true { return }
        case KeyCode.escape:
            if onKey?(.escape) == true { return }
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? MacComposerTextView.font,
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
            y: textContainerInset.height
        )
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    // MARK: pasteboard

    /// A file or a picture on the pasteboard is an attachment, not text. A screenshot
    /// pasted straight from the clipboard is the case that matters most.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = Self.fileURLs(on: pasteboard) {
            onFiles?(urls)
            return
        }
        if pasteboard.string(forType: .string) == nil, let (data, type) = Self.image(on: pasteboard) {
            onImage?(data, type)
            return
        }
        super.paste(sender)
    }

    /// A plain-text view turns Paste off when the pasteboard holds no text, so an image
    /// alone never reached `paste(_:)`.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(on: sender.draggingPasteboard) != nil ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(on: sender.draggingPasteboard) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = Self.fileURLs(on: sender.draggingPasteboard) {
            onFiles?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        guard let urls, !urls.isEmpty else { return nil }
        return urls
    }

    /// PNG when the source offers it, otherwise TIFF re-encoded as PNG, since that is
    /// what the server would rather store and what a browser can show.
    private static func image(on pasteboard: NSPasteboard) -> (Data, UTType)? {
        if let png = pasteboard.data(forType: .png) { return (png, .png) }
        if let tiff = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return (png, .png)
        }
        return nil
    }
}
