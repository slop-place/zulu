import SwiftUI
import ZuluScroll

extension ConversationLayout {
    init(_ geometry: ScrollGeometry) {
        // Measured to the end of the content inset, which is where the list stops when
        // scrolled all the way down: the composer sits over the bottom of the content.
        let end = geometry.contentSize.height + geometry.contentInsets.bottom
        self.init(
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.containerSize.height,
            distanceFromBottom: end - geometry.visibleRect.maxY
        )
    }
}

/// Carries out what `ConversationFollow` decides on a conversation's scroll view.
@MainActor
@Observable
final class ConversationScrollManager {
    /// The scroll view writes this back whenever it scrolls, and a write that re-rendered
    /// the list made it scroll and write again: the app hung shortly after a conversation
    /// opened. Only the manager's own scrolls re-render.
    var position: ScrollPosition {
        get {
            access(keyPath: \.position)
            return scrolledPosition
        }
        set { scrolledPosition = newValue }
    }
    @ObservationIgnored private var scrolledPosition = ScrollPosition(idType: Int.self)

    /// Only changes when the button should appear or go.
    private(set) var showsJumpToNewest = false

    /// Whether a growing list keeps its bottom edge in view. Off while the reader holds
    /// or reads the history, so a new message does not move what they are looking at.
    private(set) var followsNewest: Bool

    /// Unobserved on purpose. It takes in the scroll geometry on every frame, and a view
    /// reading it would re-render the whole list each time, which changes the geometry,
    /// which re-renders the list: the app locked up the moment a conversation opened.
    @ObservationIgnored private var follow: ConversationFollow

    init(opensAt firstUnread: Int?) {
        let follow = ConversationFollow(opensAt: firstUnread)
        self.follow = follow
        followsNewest = follow.isPinned
    }

    func scrollPhaseChanged(to phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting:
            follow.userBeganScrolling()
            setFollowsNewest(false)
        case .idle, .animating:
            // The scroll view is left holding whichever message it stopped on, and holds
            // it in place as new ones arrive. Near the bottom edge it goes back to
            // following them, but it is never scrolled there: a mouse wheel ends a
            // scroll at every notch, and snapping the list back to the bottom after
            // each of the first few undid them, so fast wheel scrolling kept landing
            // back on the newest message.
            follow.userFinishedScrolling()
            publish()
        case .decelerating:
            break
        @unknown default:
            break
        }
    }

    func layoutChanged(to layout: ConversationLayout) {
        apply(follow.layoutChanged(to: layout))
    }

    func didSend() {
        apply(follow.pin())
    }

    func jumpToNewest() {
        withAnimation(.snappy) { apply(follow.pin()) }
    }

    private func publish() {
        if showsJumpToNewest != follow.showsJumpToNewest { showsJumpToNewest = follow.showsJumpToNewest }
        setFollowsNewest(follow.isPinned)
    }

    private func setFollowsNewest(_ follows: Bool) {
        if followsNewest != follows { followsNewest = follows }
    }

    private func apply(_ scroll: ConversationFollow.Scroll?) {
        publish()
        switch scroll {
        case .toBottom:
            // A fresh position rather than `scrollTo(edge:)`: one left holding a message
            // id keeps that message where it was through every later layout change,
            // which is exactly what a list following the newest message must not do.
            withMutation(keyPath: \.position) {
                scrolledPosition = ScrollPosition(idType: Int.self, edge: .bottom)
            }
        case .toMessage(let id):
            withMutation(keyPath: \.position) {
                scrolledPosition.scrollTo(id: id, anchor: .top)
            }
        case nil:
            break
        }
    }
}
