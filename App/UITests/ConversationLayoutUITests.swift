import XCTest

/// The conversation list on a real keyboard. Runs against whatever conversation the app
/// has open, so it needs a signed-in device and skips anywhere else.
///
/// The list is upright: the newest message sits at the end of the content, just above
/// the composer. The app is launched with `-scrollDebug YES`, which puts the scroll
/// geometry on screen as an accessibility value the test can read back.
final class ConversationLayoutUITests: XCTestCase {
    /// Scroll offsets land on fractional points.
    static let tolerance: CGFloat = 1.5
    /// Far enough from the end that the list is clearly reading history.
    static let scrolledIntoHistory: CGFloat = 100
    static let maxFlicksToNewest = 6
    static let historySwipes = 4
    static let settleSeconds: UInt32 = 2

    override func setUp() {
        continueAfterFailure = false
    }

    /// Opening the keyboard, growing the composer and shrinking it again all leave the
    /// newest message sitting right on the composer.
    func testKeyboardAndComposerGrowthKeepTheNewestMessageOnTheComposer() throws {
        let app = try launchOnAConversation()
        let field = app.textViews.firstMatch
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard did not appear")
        sleep(Self.settleSeconds)
        try assertNewestMessageOnComposer(app, "keyboard up")

        let typed = "one\ntwo\nthree"
        field.typeText(typed)
        sleep(Self.settleSeconds)
        try assertNewestMessageOnComposer(app, "composer grown")

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count))
        sleep(Self.settleSeconds)
        try assertNewestMessageOnComposer(app, "composer shrunk")
    }

    /// Swiping a message to reply raises the keyboard and the reply banner together.
    func testSwipeToReplyKeepsTheNewestMessageOnTheComposer() throws {
        let app = try launchOnAConversation()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "swipe did not open a reply")
        sleep(Self.settleSeconds)
        try assertNewestMessageOnComposer(app, "swipe to reply")
    }

    /// A flick back from history comes to rest exactly on the newest message.
    func testFlickBackFromHistoryRestsOnTheNewestMessage() throws {
        let app = try launchOnAConversation()
        dragTowardHistory(app)
        dragTowardHistory(app)
        let scrolledUp = try readout(app, "scrolled into history")
        XCTAssertGreaterThan(scrolledUp.fromBottom, Self.scrolledIntoHistory, "list did not scroll into history")

        for _ in 0..<Self.maxFlicksToNewest {
            app.swipeUp(velocity: .fast)
            sleep(Self.settleSeconds)
            if try readout(app, "flick to newest").fromBottom <= Self.tolerance { break }
        }
        try assertNewestMessageOnComposer(app, "flick to newest")
    }

    /// Older pages landing above the view must not move what the reader is looking at.
    func testOlderPagesLandingDoNotMoveTheView() throws {
        let app = try launchOnAConversation()
        for swipe in 1...Self.historySwipes {
            dragTowardHistory(app)
            let before = try readout(app, "history swipe \(swipe)")
            sleep(Self.settleSeconds)
            let after = try readout(app, "history swipe \(swipe) settled")
            XCTAssertEqual(after.fromBottom, before.fromBottom, accuracy: Self.tolerance, "view moved while history loaded after swipe \(swipe)")
        }
    }

    private func launchOnAConversation() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-scrollDebug", "YES"]
        app.launch()
        let field = app.textViews.firstMatch
        try XCTSkipUnless(field.waitForExistence(timeout: 10), "no conversation open: sign in and open one first")
        sleep(Self.settleSeconds)
        // The drawer opens on launch and pushes the conversation off to the right.
        if field.frame.minX > app.frame.width / 2 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            sleep(Self.settleSeconds)
        }
        return app
    }

    /// A slow drag that ends held still, so the list stops where the finger lifts.
    private func dragTowardHistory(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
    }

    private func readout(_ app: XCUIApplication, _ step: String) throws -> ScrollReadout {
        let text = app.staticTexts["scrollDebug"].firstMatch.value as? String
        return try XCTUnwrap(ScrollReadout(text), "no readout: \(step)")
    }

    private func assertNewestMessageOnComposer(_ app: XCUIApplication, _ step: String) throws {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = step
        shot.lifetime = .keepAlways
        add(shot)
        let geometry = try readout(app, step)
        XCTAssertEqual(geometry.insetBottom, geometry.barBottom, accuracy: Self.tolerance, "list inset is not the bar's height: \(step)")
        XCTAssertEqual(geometry.fromBottom, 0, accuracy: Self.tolerance, "list is not resting on the newest message: \(step)")
    }

    /// The numbers the app prints, picked out of its readout text.
    private struct ScrollReadout {
        let barBottom: CGFloat
        let insetBottom: CGFloat
        let fromBottom: CGFloat

        init?(_ text: String?) {
            guard let text,
                  let insets = text.range(of: "insets "),
                  let barBottom = Self.number(after: "bottom", in: text),
                  let insetBottom = Self.number(after: "bottom", in: text[insets.upperBound...]),
                  let fromBottom = Self.number(after: "fromBottom", in: text)
            else { return nil }
            self.barBottom = barBottom
            self.insetBottom = insetBottom
            self.fromBottom = fromBottom
        }

        private static func number<Text: StringProtocol>(after label: String, in text: Text) -> CGFloat? {
            guard let range = text.range(of: label + " ") else { return nil }
            let token = text[range.upperBound...].prefix { !$0.isWhitespace }
            return Double(token).map { CGFloat($0) }
        }
    }
}
