import CoreGraphics
import Testing
import ZuluScroll

private func layout(distance: CGFloat, content: CGFloat = 2400, container: CGFloat = 650) -> ConversationLayout {
    ConversationLayout(contentHeight: content, containerHeight: container, distanceFromBottom: distance)
}

/// Measured in the simulator: the keyboard shrinks the list by this much.
private let keyboardHeight: CGFloat = 294

struct PinnedTests {

    @Test func aConversationWithNothingUnreadOpensFollowingTheNewestMessage() {
        var follow = ConversationFollow(opensAt: nil)
        #expect(follow.layoutChanged(to: layout(distance: 0)) == nil)
        #expect(follow.isPinned)
    }

    /// A scroll in answer to a layout changes the layout it answers. With a lazy list
    /// re-estimating its rows each time, that loop never ended and the app locked up.
    @Test func noLayoutEverScrollsAFollowingList() {
        var follow = ConversationFollow(opensAt: nil)
        _ = follow.layoutChanged(to: layout(distance: 0))
        for step in 0..<50 {
            let churn = layout(distance: CGFloat(step * 7 % 300), content: 2400 + CGFloat(step * 13))
            #expect(follow.layoutChanged(to: churn) == nil)
        }
        #expect(follow.layoutChanged(to: layout(distance: keyboardHeight, container: 356)) == nil)
        #expect(follow.layoutChanged(to: layout(distance: -401)) == nil)
    }

    /// The other bug this type exists for: a frame of "not at the bottom" mid-animation
    /// used to switch following off, and the next message landed below the fold.
    @Test func passingThroughNotAtTheBottomDoesNotStopFollowing() {
        var follow = ConversationFollow(opensAt: nil)
        _ = follow.layoutChanged(to: layout(distance: 0))
        _ = follow.layoutChanged(to: layout(distance: keyboardHeight * 2))
        #expect(follow.isPinned)
        #expect(!follow.showsJumpToNewest)
    }

    @Test func anUnlaidOutListIsIgnored() {
        var follow = ConversationFollow(opensAt: 30)
        #expect(follow.layoutChanged(to: layout(distance: 0, container: 0)) == nil)
        #expect(follow.mode == .opening(atUnread: 30))
    }

    @Test func nothingScrollsTheListWhileTheReaderIsDraggingIt() {
        var follow = ConversationFollow(opensAt: nil)
        _ = follow.layoutChanged(to: layout(distance: 0))
        follow.userBeganScrolling()
        #expect(follow.layoutChanged(to: layout(distance: 500)) == nil)
    }
}

struct ReadingTests {

    @Test func aReaderWhoLetsGoFarFromTheBottomIsReading() {
        var follow = ConversationFollow(opensAt: nil)
        _ = follow.layoutChanged(to: layout(distance: 0))
        follow.userBeganScrolling()
        _ = follow.layoutChanged(to: layout(distance: 900))
        #expect(follow.userFinishedScrolling() == nil)
        #expect(follow.mode == .reading)
        #expect(follow.showsJumpToNewest)
    }

    @Test func newMessagesDoNotPullAReaderDown() {
        var follow = reading()
        #expect(follow.layoutChanged(to: layout(distance: 1000, content: 2500)) == nil)
        #expect(follow.layoutChanged(to: layout(distance: 1000 + keyboardHeight, container: 356)) == nil)
    }

    @Test func aReaderWhoLetsGoNearTheBottomFollowsAgain() {
        var follow = reading()
        follow.userBeganScrolling()
        _ = follow.layoutChanged(to: layout(distance: 60))
        #expect(follow.userFinishedScrolling() == .toBottom)
        #expect(follow.isPinned)
        #expect(!follow.showsJumpToNewest)
    }

    @Test func sendingFollowsFromAnywhere() {
        var follow = reading()
        #expect(follow.pin() == .toBottom)
        #expect(follow.isPinned)
    }

    /// A programmatic scroll finishing is not the reader letting go.
    @Test func finishingWithoutHavingStartedChangesNothing() {
        var follow = reading()
        #expect(follow.userFinishedScrolling() == nil)
        #expect(follow.mode == .reading)
    }

    private func reading() -> ConversationFollow {
        var follow = ConversationFollow(opensAt: nil)
        _ = follow.layoutChanged(to: layout(distance: 0))
        follow.userBeganScrolling()
        _ = follow.layoutChanged(to: layout(distance: 900))
        _ = follow.userFinishedScrolling()
        return follow
    }
}

struct OpeningAtUnreadTests {

    @Test func theUnreadMessageIsScrolledToOnceTheListIsLaidOut() {
        var follow = ConversationFollow(opensAt: 30)
        #expect(follow.layoutChanged(to: layout(distance: 0)) == .toMessage(30))
        #expect(follow.mode == .landing)
    }

    @Test func landingWithHistoryBelowIsReading() {
        var follow = ConversationFollow(opensAt: 30)
        _ = follow.layoutChanged(to: layout(distance: 0))
        #expect(follow.layoutChanged(to: layout(distance: 640)) == nil)
        #expect(follow.mode == .reading)
    }

    /// So few unread messages that the list could not scroll to the first one without
    /// also being at the bottom.
    @Test func landingAtTheBottomFollows() {
        var follow = ConversationFollow(opensAt: 58)
        _ = follow.layoutChanged(to: layout(distance: 0))
        #expect(follow.layoutChanged(to: layout(distance: 0)) == .toBottom)
        #expect(follow.isPinned)
    }
}
