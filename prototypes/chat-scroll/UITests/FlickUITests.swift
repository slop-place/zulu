// PROTOTYPE — throwaway. Scrolls up, then flicks back to the end, and saves the event
// log: shows which scroll phases the bounce at the end reports and whether a
// programmatic scroll interrupts it.
import XCTest

final class FlickUITests: XCTestCase {
    func testFlickToEnd() {
        let variant = ProcessInfo.processInfo.environment["AUTOPILOT_VARIANT"] ?? "signal"
        let app = XCUIApplication()
        app.launchArguments = ["-variant", variant, "-logFlick", "YES"]
        app.launch()
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.swipeDown(velocity: .slow)
        sleep(2)
        list.swipeUp(velocity: .fast)
        sleep(3)
    }
}
