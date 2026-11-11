import SwiftUI

/// Behind the message a conversation was opened at, so the eye lands on it. Fades out
/// when the loader lets go of it.
///
/// A view of its own so only it reads the loader's highlight, rather than every row's
/// whole body.
struct TargetHighlight: View {
    let loader: MessageHistoryLoader
    let messageID: Int

    private static let tint = 0.18
    private static let cornerRadius: CGFloat = 8
    private static let bleed: CGFloat = -6
    private static let fade = Animation.easeOut(duration: 0.6)

    var body: some View {
        let isLit = loader.highlightedID == messageID
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(Color.accentColor.opacity(isLit ? Self.tint : 0))
            .padding(.horizontal, Self.bleed)
            .animation(Self.fade, value: isLit)
            .allowsHitTesting(false)
    }
}
