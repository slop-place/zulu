import SwiftUI

/// Finds the scroll view a conversation's rows sit in, sets it up, and hands it over.
///
/// SwiftUI exposes no handle on it, so it is found by walking up the view hierarchy.
/// Setting it up is idempotent, so every row can carry a probe.
struct ConversationScrollProbe: UIViewRepresentable {
    let found: (UIScrollView) -> Void

    func makeUIView(context: Context) -> Probe { Probe(found: found) }
    func updateUIView(_ probe: Probe, context: Context) { probe.found = found }

    final class Probe: UIView {
        var found: (UIScrollView) -> Void

        init(found: @escaping (UIScrollView) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var candidate: UIView? = superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView {
                    // A status-bar tap would leap to the oldest message, which is never
                    // what was meant.
                    scrollView.scrollsToTop = false
                    scrollView.bottomEdgeEffect.style = .soft
                    found(scrollView)
                    return
                }
                candidate = view.superview
            }
        }
    }
}
