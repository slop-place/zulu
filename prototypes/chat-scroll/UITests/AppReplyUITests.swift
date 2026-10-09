// PROTOTYPE — throwaway. Drives the real Zulu app already signed in on the device:
// long-presses a message and picks Reply, the path that froze, and reports whether the
// app still answers afterwards.
import XCTest

final class AppReplyUITests: XCTestCase {
    static let zulu = "com.bwees.zulu"
    static let answerTimeout: TimeInterval = 20

    func testReplyFromActions() {
        let app = XCUIApplication(bundleIdentifier: Self.zulu)
        app.activate()
        sleep(2)
        attach("opened", app)
        if app.staticTexts["Channels"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            sleep(1)
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).press(forDuration: 0.8)
        let reply = app.buttons["Reply"].firstMatch
        print("REPLY sheet shown", reply.waitForExistence(timeout: 5))
        attach("sheet", app)
        reply.tap()
        let started = Date()
        let keyboard = app.keyboards.firstMatch.waitForExistence(timeout: Self.answerTimeout)
        print("REPLY keyboard", keyboard, "after", Date().timeIntervalSince(started))
        sleep(3)
        attach("after-reply", app)
        let probe = Date()
        print("REPLY banner", app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Replying to'")).firstMatch.exists,
              "query took", Date().timeIntervalSince(probe))
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
