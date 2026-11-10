import SwiftUI

/// A spinner that waits to be needed. Most conversations are drawn within a few frames,
/// and a spinner shown for those few frames flashed on every switch.
struct DelayedProgressView: View {
    @State private var isSlow = false

    private static let delay = Duration.milliseconds(350)

    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isSlow ? 1 : 0)
            .task {
                try? await Task.sleep(for: Self.delay)
                isSlow = true
            }
    }
}
