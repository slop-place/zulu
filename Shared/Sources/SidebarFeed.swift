import GRDB
import Observation
import ZuluStore

/// What the sidebar section on screen lists, kept current from the store.
///
/// A section's first rows are read on the spot, so switching sections draws the new list
/// in the same frame. Observed piece by piece and delivered later, the old section's rows
/// stayed up for a frame and the new ones filled in a part at a time.
@MainActor
@Observable
final class SidebarFeed {
    enum Content: Equatable {
        case channels(SidebarScope)
        case recent
        case nothing
    }

    private(set) var rows = SidebarRows.empty
    /// Resolved when the store delivers, not on every redraw: each row's preview is a
    /// parse of rendered HTML, and the sidebar redraws far more often than Recent changes.
    private(set) var recent: [RecentEntry] = []

    @ObservationIgnored private var content: Content?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?

    func show(_ content: Content, model: AppModel) {
        guard content != self.content || observation == nil else { return }
        observation?.cancel()
        observation = nil
        self.content = content
        guard let writer = model.databaseWriter, let store = model.storeForReading else { return }

        switch content {
        case .channels(let scope):
            observation = store.observeSidebar(in: scope)
                .removeDuplicates()
                .start(in: writer, scheduling: .immediate, onError: { _ in }) { [weak self] rows in
                    MainActor.assumeIsolated { self?.rows = rows }
                }
        case .recent:
            observation = store.observeRecentConversations()
                .removeDuplicates()
                .start(in: writer, scheduling: .immediate, onError: { _ in }) { [weak self, weak model] rows in
                    MainActor.assumeIsolated {
                        guard let model else { return }
                        self?.recent = RecentEntry.resolve(rows, model: model)
                    }
                }
        case .nothing:
            break
        }
    }
}
