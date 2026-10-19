import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A real `UITextView` under the composer. SwiftUI's vertical `TextField` kept its
/// multi-line height after the draft was cleared, and cannot take a pasted image.
///
/// Grows with its text up to `maxLines`, then scrolls.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Bumped by the parent whenever the field should take focus.
    var focusToken: Int
    /// Called for what the person typed, never for text the parent set.
    var onEdit: (String) -> Void = { _ in }
    var onImage: (Data, UTType) -> Void

    static let maxLines = 5
    static let insets = UIEdgeInsets(top: 10, left: 9, bottom: 10, right: 0)

    func makeUIView(context: Context) -> PastingTextView {
        let view = PastingTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = Self.insets
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: PastingTextView, context: Context) {
        context.coordinator.parent = self
        view.onImage = onImage
        view.placeholder = placeholder
        if view.text != text {
            view.text = text
            view.textChanged()
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PastingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(fitting.height, uiView.maximumHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var focusToken: Int

        init(parent: ComposerTextView) {
            self.parent = parent
            focusToken = parent.focusToken
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.onEdit(textView.text)
            (textView as? PastingTextView)?.textChanged()
        }
    }
}

/// Paste takes an image as an attachment, and a placeholder shows while it is empty.
final class PastingTextView: UITextView {
    var onImage: ((Data, UTType) -> Void)?

    var placeholder = "" {
        didSet { placeholderLabel.text = placeholder }
    }

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .placeholderText
        return label
    }()

    var maximumHeight: CGFloat {
        let line = font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        return ceil(line * CGFloat(ComposerTextView.maxLines)) + textContainerInset.top + textContainerInset.bottom
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let x = textContainerInset.left + textContainer.lineFragmentPadding
        placeholderLabel.frame = CGRect(
            x: x, y: textContainerInset.top,
            width: bounds.width - x - textContainerInset.right,
            height: placeholderLabel.font.lineHeight
        )
    }

    /// Scrolling stays off until the text outgrows the field, so that until then the
    /// field grows instead of scrolling inside itself.
    func textChanged() {
        placeholderLabel.isHidden = !text.isEmpty
        let fitting = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        isScrollEnabled = fitting.height > maximumHeight
        invalidateIntrinsicContentSize()
    }

    // MARK: paste

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        if !pasteboard.hasStrings, let (data, type) = Self.image(on: pasteboard) {
            onImage?(data, type)
            return
        }
        super.paste(sender)
    }

    /// The clipboard's own PNG or JPEG bytes when it has them, so a screenshot is not
    /// re-encoded on the way up.
    private static func image(on pasteboard: UIPasteboard) -> (Data, UTType)? {
        for type in [UTType.png, .jpeg] {
            if let data = pasteboard.data(forPasteboardType: type.identifier) { return (data, type) }
        }
        return pasteboard.image?.pngData().map { ($0, .png) }
    }
}
