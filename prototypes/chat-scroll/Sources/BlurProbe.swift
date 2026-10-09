// PROTOTYPE — throwaway. Launch with `-blurProbe YES`: the edge blur over plain background
// with rows of text, so it can be measured by pixel. Plain background must come out
// exactly the background colour; the text should still show, softened.
import SwiftUI

struct BlurProbe: View {
    static let barHeight: CGFloat = 120
    static let rows = 12

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<Self.rows, id: \.self) { _ in
                    Text("The quick brown fox").font(.body)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 16)
            EdgeBlur(edge: .bottom, barHeight: Self.barHeight)
        }
        .ignoresSafeArea()
    }
}
