// PROTOTYPE — throwaway. Drags the list partway into history and holds, so the rows
// passing under the composer and the navigation bar can be seen in a screenshot.
import XCTest

final class PeekUITests: XCTestCase {
    func testPeekUnderBars() {
        let variant = ProcessInfo.processInfo.environment["AUTOPILOT_VARIANT"] ?? "glass"
        let app = XCUIApplication()
        app.launchArguments = ["-variant", variant]
        app.launch()
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        sleep(2)
        let shot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("peek.png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shot)
        print("SHOT", shot.path)
    }
}
