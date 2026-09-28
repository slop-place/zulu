import CoreGraphics

/// The layout facts that decide whether a conversation has to be put back on its newest
/// message.
public struct ConversationLayout: Equatable, Sendable {
    /// Close enough to the newest message to count as reading it, and to go back to
    /// following new ones when the reader lets go there.
    public static let nearBottomDistance: CGFloat = 120

    /// Scroll offsets land on fractional points; this much either side of the bottom is
    /// the bottom.
    public static let settledTolerance: CGFloat = 1

    public var contentHeight: CGFloat
    public var containerHeight: CGFloat
    /// Positive while the newest content is below the visible area, negative while the
    /// list is scrolled past its end.
    public var distanceFromBottom: CGFloat

    public init(contentHeight: CGFloat, containerHeight: CGFloat, distanceFromBottom: CGFloat) {
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        self.distanceFromBottom = distanceFromBottom
    }

    public var isNearBottom: Bool { distanceFromBottom < Self.nearBottomDistance }
    public var isSettledAtBottom: Bool { abs(distanceFromBottom) <= Self.settledTolerance }
    /// Before the scroll view is laid out it reports an empty container, and every such
    /// report looks like sitting exactly at the bottom.
    public var isMeasured: Bool { containerHeight > 0 }
}

/// Whether a conversation follows its newest message, and when it has to be scrolled.
///
/// Pinned, the list is held by its bottom edge, so it stays on the newest message through
/// anything that changes the layout: the keyboard, the composer growing, a suggestion
/// box, an image or a reaction landing. Reading, it is held by a message, and nothing
/// moves it except the reader.
///
/// Only discrete events scroll the list: opening at an unread message, the reader
/// letting go near the bottom, sending, and the jump button. Geometry passing through
/// "not at the bottom" while the keyboard animates is not a decision to stop following.
public struct ConversationFollow: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// Waiting for the list to be laid out before moving to this unread message.
        /// Asked for any earlier, the scroll is dropped or lands on the wrong row.
        case opening(atUnread: Int)
        /// Moved to the unread message; the next layout says whether that left the list
        /// at the bottom anyway.
        case landing
        case pinned
        case reading
    }

    public enum Scroll: Equatable, Sendable {
        case toBottom
        case toMessage(Int)
    }

    public private(set) var mode: Mode
    private var isUserScrolling = false
    private var layout: ConversationLayout?

    /// A conversation opening at its first unread starts out reading; one with nothing
    /// unread starts on the newest message.
    public init(opensAt firstUnread: Int?) {
        mode = firstUnread.map { .opening(atUnread: $0) } ?? .pinned
    }

    public var isPinned: Bool { mode == .pinned }

    /// Only for a reader who has actually left the bottom.
    public var showsJumpToNewest: Bool { mode != .pinned && layout?.isNearBottom == false }

    public mutating func userBeganScrolling() {
        isUserScrolling = true
    }

    /// Wherever the list came to rest decides the mode.
    public mutating func userFinishedScrolling() -> Scroll? {
        guard isUserScrolling else { return nil }
        isUserScrolling = false
        guard let layout else { return nil }
        if layout.isNearBottom { return pin() }
        mode = .reading
        return nil
    }

    public mutating func layoutChanged(to new: ConversationLayout) -> Scroll? {
        guard new.isMeasured else { return nil }
        layout = new
        guard !isUserScrolling else { return nil }

        switch mode {
        case .opening(let unread):
            mode = .landing
            return .toMessage(unread)
        case .landing:
            // So little below the unread message that the list is already at the bottom:
            // there is nothing left to read down to, so follow from here.
            if new.isSettledAtBottom { return pin() }
            mode = .reading
            return nil
        case .pinned, .reading:
            // Never a scroll in answer to a layout. The scroll view's bottom anchor holds
            // a pinned list on the bottom through every size change by itself, and a
            // scroll here changes the layout it answers: the lazy list re-estimates its
            // rows, reports again, and the app locked up scrolling forever.
            return nil
        }
    }

    /// Sending, or the jump button: back to following, from anywhere in the history.
    public mutating func pin() -> Scroll {
        mode = .pinned
        return .toBottom
    }
}
