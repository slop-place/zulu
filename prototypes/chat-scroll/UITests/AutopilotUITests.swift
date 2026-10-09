// PROTOTYPE — throwaway. Brings the real keyboard up by tapping the composer, then lets
// the in-app autopilot run. Results land in the app's Documents/autopilot.log.
import XCTest

final class AutopilotUITests: XCTestCase {
    func testAutopilot() {
        let variant = ProcessInfo.processInfo.environment["AUTOPILOT_VARIANT"] ?? "current"
        let app = XCUIApplication()
        app.launchArguments = ["-autopilot", "YES", "-variant", variant]
        app.launch()
        let field = app.textViews["Message"].firstMatch.exists ? app.textViews["Message"].firstMatch : app.textFields["Message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        sleep(3)
        let shot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("after-tap.png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shot)
        print("SHOT", shot.path)
        print("KEYBOARDS", app.keyboards.count, "FOCUSED", (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false)
        XCTAssertTrue(app.staticTexts["autopilot-done"].waitForExistence(timeout: 60))
    }
}
