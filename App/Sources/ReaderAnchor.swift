import MessagingUI
import SwiftUI
import UIKit

extension View {
    /// Keeps what the reader is looking at still when this view takes its real height
    /// above the screen.
    ///
    /// The list measures a row once and moves everything below the row when it grows.
    /// That is right while the growth is on screen, and wrong once it has scrolled off the
    /// top: there the whole screen moves down by the growth, under the reader's thumb.
    func keepsReaderInPlace() -> some View {
        modifier(ReaderAnchor())
    }
}

private struct ReaderAnchor: ViewModifier {
    @State private var anchor = Anchor()

    func body(content: Content) -> some View {
        content
            .background(alignment: .top) {
                AnchorProbe(anchor: anchor).frame(width: 0, height: 0)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { old, new in
                anchor.heightChanged(by: new - old)
            }
    }
}

/// Where the view sits in its list, found through the UIKit view hosting it.
@MainActor
private final class Anchor {
    weak var view: UIView?

    func heightChanged(by delta: CGFloat) {
        guard delta != 0, let view, view.window != nil,
              let scrollView = view.enclosingScrollView
        else { return }
        let top = view.convert(CGPoint.zero, to: scrollView).y
        guard top < scrollView.contentOffset.y + Self.topBarHeight(of: scrollView) else { return }
        scrollView.contentOffset.y += delta
    }

    /// The list runs under the navigation bar, so the part of it the bar covers is not
    /// something the reader is looking at.
    private static func topBarHeight(of scrollView: UIScrollView) -> CGFloat {
        let layout = (scrollView as? UICollectionView)?.collectionViewLayout as? TiledCollectionViewLayout
        return layout?.additionalContentInset.top ?? 0
    }
}

private struct AnchorProbe: UIViewRepresentable {
    let anchor: Anchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        anchor.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchor.view = view
    }
}

private extension UIView {
    var enclosingScrollView: UIScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView { return scrollView }
            candidate = view.superview
        }
        return nil
    }
}
