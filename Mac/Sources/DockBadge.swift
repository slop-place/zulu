import AppKit
import Observation

/// What the dock icon says, the way Discord's does it: a count of what is addressed to
/// you, a dot when there is only something to read, nothing when there is nothing.
struct DockBadge: Equatable {
    /// Mentions and direct messages.
    var addressed: Int
    var hasUnread: Bool

    static let dot = "•"

    var label: String? {
        if addressed > 0 { return String(addressed) }
        return hasUnread ? Self.dot : nil
    }
}

extension DockBadge {
    @MainActor
    init(model: AppModel) {
        self.init(
            addressed: model.dms.reduce(0) { $0 + $1.unreadCount }
                + model.groups.reduce(0) { $0 + $1.mentionCount }
                + model.unfiledMentionCount,
            hasUnread: model.dms.contains { $0.unreadCount > 0 }
                || model.groups.contains { $0.unreadCount > 0 }
                || model.unfiledHasUnread
        )
    }
}

/// Keeps the dock badge in step with the model. A view can't do this: SwiftUI holds back
/// updates to a window that is hidden, behind others, or closed.
@MainActor
final class DockBadgeUpdater {
    private weak var model: AppModel?

    func attach(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        update()
    }

    private func update() {
        guard let model else { return }
        let label = withObservationTracking {
            DockBadge(model: model).label
        } onChange: { [weak self] in
            Task { @MainActor in self?.update() }
        }
        if NSApp.dockTile.badgeLabel != label {
            NSApp.dockTile.badgeLabel = label
        }
    }
}
