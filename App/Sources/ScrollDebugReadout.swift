import MessagingUI
import SwiftUI

/// The conversation's scroll geometry, on screen and readable by the UI tests. Only
/// when launched with `-scrollDebug YES`; a normal launch never builds it.
@MainActor
@Observable
final class ScrollDebugReadout {
    static let shared = ScrollDebugReadout()
    static let isEnabled = UserDefaults.standard.bool(forKey: "scrollDebug")

    var text = ""

    func record(_ g: TiledScrollGeometry, bars: EdgeInsets) {
        let f = { (v: CGFloat) in String(format: "%.1f", v) }
        text = """
        bars top \(f(bars.top)) bottom \(f(bars.bottom))
        offset \(f(g.contentOffset.y)) insets top \(f(g.contentInset.top)) bottom \(f(g.contentInset.bottom))
        container \(f(g.visibleSize.height)) content \(f(g.contentSize.height))
        fromBottom \(f(g.pointsFromBottom))
        """
    }
}

struct ScrollDebugLabel: View {
    @State private var readout = ScrollDebugReadout.shared

    var body: some View {
        Text(readout.text)
            .font(.system(size: 11, design: .monospaced))
            .padding(6)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.yellow)
            .accessibilityIdentifier("scrollDebug")
            .accessibilityValue(readout.text)
    }
}
