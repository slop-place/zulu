// PROTOTYPE — throwaway. Drives the real Zulu app on the device with the scroll readout
// on: opens the keyboard, grows the composer, swipes to reply, and screenshots each step
// with the geometry printed.
import XCTest

final class AppKeyboardUITests: XCTestCase {
    static let zulu = "com.bwees.zulu"

    func testKeyboardGap() {
        let app = launch()
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        sleep(3)
        report("keyboard-up", app)

        field.typeText("one\ntwo\nthree")
        sleep(2)
        report("composer-grown", app)
    }

    func testSwipeToReply() {
        let app = launch()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
        sleep(3)
        report("after-swipe-reply", app)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.zulu)
        app.launchArguments = ["-scrollDebug", "YES"]
        app.launch()
        sleep(4)
        report("opened", app)
        closeDrawer(app)
        return app
    }

    /// The app opens with the drawer out, which pushes the conversation off to the right.
    private func closeDrawer(_ app: XCUIApplication) {
        guard app.textViews.firstMatch.frame.minX > 300 else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        sleep(2)
    }

    private func report(_ name: String, _ app: XCUIApplication) {
        let value = app.staticTexts["scrollDebug"].firstMatch
        print("READOUT \(name):", value.exists ? (value.value as? String ?? value.label) : "none")
        let composer = app.textViews.firstMatch
        print("COMPOSER \(name):", composer.exists ? "\(composer.frame)" : "none")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
