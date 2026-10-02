import MessagingUI
import SwiftUI
import ZuluScroll

/// Carries out what `ConversationFollow` decides on a conversation's `TiledView`.
///
/// The list cannot scroll to a message, only to its ends. A conversation opening at its
/// first unread therefore starts out holding back everything older, so the unread message
/// is the first row and the list opens on it. Once the list has been laid out the older
/// messages go in above it, and the list keeps the unread row where it is.
@MainActor
@Observable
final class ConversationListManager {
    /// Only written when it has to change: every write lays the list out again.
    var scrollPosition: TiledScrollPosition
    private(set) var showsJumpToNewest = false
    private(set) var isAtNewest = false
    /// True while messages older than the first unread are held back.
    private(set) var isHoldingHistory: Bool

    /// Unobserved on purpose. It takes in the scroll geometry on every frame, and a view
    /// reading it would re-render the whole list each time, which changes the geometry,
    /// which re-renders the list.
    @ObservationIgnored private var follow: ConversationFollow
    @ObservationIgnored private var layout: ConversationLayout?
    @ObservationIgnored private let firstUnreadID: Int?
    @ObservationIgnored private weak var scrollView: UIScrollView?
    @ObservationIgnored private var insetObservation: NSKeyValueObservation?

    init(opensAt firstUnread: Int?) {
        follow = ConversationFollow(opensAt: firstUnread)
        firstUnreadID = firstUnread
        isHoldingHistory = firstUnread != nil
        let opensOnNewest = firstUnread == nil
        scrollPosition = TiledScrollPosition(
            autoScrollsToBottomOnAppend: opensOnNewest,
            scrollsToBottomOnReplace: opensOnNewest
        )
    }

    func shown(_ messages: [GroupedMessage]) -> ArraySlice<GroupedMessage> {
        guard isHoldingHistory, let firstUnreadID,
              let start = messages.firstIndex(where: { $0.id == firstUnreadID })
        else { return messages[...] }
        return messages[start...]
    }

    /// The list's rows find the scroll view, so nothing is decided before a row exists.
    func attach(_ scrollView: UIScrollView) {
        guard scrollView !== self.scrollView else { return }
        self.scrollView = scrollView
        // The list's content edges are its insets. They move when rows land, grow or go,
        // none of which scrolls.
        insetObservation = scrollView.observe(\.contentInset, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            MainActor.assumeIsolated { self?.contentChanged() }
        }
        // Found mid-layout; deciding there would change the rows UIKit is laying out.
        Task { self.contentChanged() }
    }

    func geometryChanged(_ geometry: TiledScrollGeometry) {
        guard let scrollView else { return }
        let layout = ConversationLayout(geometry)
        self.layout = layout
        if scrollView.isTracking || scrollView.isDecelerating {
            // The list reports no scroll phases, and no event marks the end of a flick.
            // Settling the mode on every frame the reader moves it leaves it right
            // wherever the list comes to rest.
            follow.userBeganScrolling()
            _ = follow.layoutChanged(to: layout)
            follow.userFinishedScrolling()
        } else {
            apply(follow.layoutChanged(to: layout))
        }
        publish()
    }

    /// Sending, or the jump button: back to following, from anywhere in the history.
    func followNewest() {
        apply(follow.pin())
        publish()
    }

    /// The list follows appends by itself, but not a row near the end growing: an image
    /// or a reaction landing would push the newest message under the composer.
    private func contentChanged() {
        guard let scrollView, !scrollView.isTracking, !scrollView.isDecelerating else { return }
        let layout = ConversationLayout(scrollView.tiledGeometry)
        self.layout = layout
        apply(follow.layoutChanged(to: layout))
        if follow.isPinned, layout.isMeasured, !layout.isSettledAtBottom {
            scrollPosition.scrollTo(edge: .bottom, animated: true)
        }
        publish()
    }

    private func apply(_ scroll: ConversationFollow.Scroll?) {
        switch scroll {
        case .toBottom:
            scrollPosition.scrollTo(edge: .bottom, animated: true)
        case .toMessage:
            // Already there: the held-back list opened on the unread message.
            break
        case nil:
            break
        }
    }

    private func publish() {
        if showsJumpToNewest != follow.showsJumpToNewest { showsJumpToNewest = follow.showsJumpToNewest }
        let isNearBottom = layout.map { $0.isMeasured && $0.isNearBottom } ?? false
        if isAtNewest != isNearBottom { isAtNewest = isNearBottom }
        if scrollPosition.autoScrollsToBottomOnAppend != follow.isPinned {
            scrollPosition.autoScrollsToBottomOnAppend = follow.isPinned
        }
        if isHoldingHistory, !isOpening { isHoldingHistory = false }
    }

    private var isOpening: Bool {
        if case .opening = follow.mode { return true }
        return false
    }
}

private extension ConversationLayout {
    init(_ geometry: TiledScrollGeometry) {
        self.init(
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.visibleSize.height,
            distanceFromBottom: geometry.pointsFromBottom
        )
    }
}

private extension UIScrollView {
    var tiledGeometry: TiledScrollGeometry {
        TiledScrollGeometry(
            contentOffset: contentOffset,
            contentSize: contentSize,
            visibleSize: bounds.size,
            contentInset: adjustedContentInset
        )
    }
}
