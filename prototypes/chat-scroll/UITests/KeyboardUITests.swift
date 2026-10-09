// PROTOTYPE — throwaway. Taps the composer with the real software keyboard, then opens a
// reply banner while it is up: the sequence that froze the app on device.
import XCTest

final class KeyboardUITests: XCTestCase {
    func testReplyWithKeyboard() {
        let variant = ProcessInfo.processInfo.environment["AUTOPILOT_VARIANT"] ?? "glass"
        let app = XCUIApplication()
        app.launchArguments = ["-variant", variant]
        app.launch()
        let field = app.textFields["Message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        sleep(2)
        print("KEYBOARD frame", app.keyboards.firstMatch.exists ? "\(app.keyboards.firstMatch.frame)" : "none")
        save("keyboard-up")
        app.buttons["Reply"].firstMatch.tap()
        sleep(3)
        save("reply-open")
        print("ALIVE after reply", app.textFields["Message"].firstMatch.exists)
    }

    private func save(_ name: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        print("SHOT", url.path)
    }
}
