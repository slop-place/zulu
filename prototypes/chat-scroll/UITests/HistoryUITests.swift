// PROTOTYPE — throwaway. Flicks up through history, past the point where older pages
// load, recording every frame's offset and content height.
import XCTest

final class HistoryUITests: XCTestCase {
    func testFlickThroughHistory() {
        let variant = ProcessInfo.processInfo.environment["AUTOPILOT_VARIANT"] ?? "signal"
        let app = XCUIApplication()
        app.launchArguments = ["-variant", variant, "-logFlick", "YES"]
        app.launch()
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        for _ in 0..<6 {
            list.swipeDown(velocity: .fast)
            sleep(2)
        }
    }
}
