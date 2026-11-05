import Combine
import Observation
import Sparkle

/// Checks the appcast for a newer DMG and installs it.
@MainActor
@Observable
final class MacUpdater {
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var subscription: AnyCancellable?

    init() {
        // A local build is numbered 1, so every release looks newer and it would
        // offer to replace itself.
        #if DEBUG
        let startsUpdater = false
        #else
        let startsUpdater = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: startsUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        subscription = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                MainActor.assumeIsolated { self?.canCheckForUpdates = canCheck }
            }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
