// PROTOTYPE — throwaway. Keyboard up, then the composer grown line by line, reading the
// scroll geometry after each: does the top inset ever exceed the bar's height?
import XCTest

final class TallComposerUITests: XCTestCase {
    func testGrowingComposer() {
        let variant = ProcessInfo.processInfo.environment["AUTOPILOT_VARIANT"] ?? "reader"
        let app = XCUIApplication()
        app.launchArguments = ["-variant", variant, "-fix", ProcessInfo.processInfo.environment["FIX"] ?? "none"]
        app.launch()
        XCTAssertTrue(app.textFields["Message"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        save("rest", app)
        field(app).tap()
        sleep(2)
        if !app.keyboards.firstMatch.exists {
            field(app).tap()
            sleep(2)
        }
        save("kb", app)
        for line in ["one", "two"] {
            field(app).typeText(line + "\n")
            sleep(1)
            save("line-\(line)", app)
        }
        app.buttons["Reply"].firstMatch.tap()
        sleep(2)
        save("reply", app)
    }

    /// A vertical `TextField` turns into a text view once it holds more than one line.
    private func field(_ app: XCUIApplication) -> XCUIElement {
        let view = app.textViews.firstMatch
        return view.exists ? view : app.textFields["Message"].firstMatch
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let readout = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'uikit'")).firstMatch
        let keyboard = app.keyboards.firstMatch
        let shown = keyboard.exists && keyboard.frame.minY < app.frame.maxY
        print("GEOM \(name): keyboard \(shown ? "\(keyboard.frame.minY)" : "NONE") composer \(field(app).frame.minY)", readout.exists ? readout.label : "none")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        print("SHOT", url.path)
    }
}
