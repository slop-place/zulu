// PROTOTYPE — throwaway. Scrolls into history while messages keep arriving: the rows on
// screen should not move. Screenshots before and after two arrivals.
import XCTest

final class ReadingUITests: XCTestCase {
    func testIncomingWhileReading() {
        let variant = ProcessInfo.processInfo.environment["AUTOPILOT_VARIANT"] ?? "glass"
        let app = XCUIApplication()
        app.launchArguments = ["-variant", variant, "-logFlick", "YES", "-incoming", "YES"]
        app.launch()
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        sleep(1)
        save("reading-before")
        sleep(6)
        save("reading-after")
    }

    private func save(_ name: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        print("SHOT", url.path)
    }
}
