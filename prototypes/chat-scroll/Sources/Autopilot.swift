// PROTOTYPE — throwaway. Scripted run for comparing variants by numbers: launch with
// `-autopilot YES -variant <current|fixed|flipped>` and read the AUTOPILOT lines on stdout.
import SwiftUI

enum Autopilot {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "autopilot") }
    static var launchVariant: Variant? {
        switch UserDefaults.standard.string(forKey: "variant") {
        case "current": .current
        case "fixed": .fixed
        case "flipped": .flipped
        case "signal": .signal
        case "glass": .flippedGlass
        case "reader": .flippedGlassReader
        default: nil
        }
    }

    static let sampleInterval: Duration = .milliseconds(50)
    static let settleTime: Duration = .seconds(2)

    static func run(
        focus: (Bool) -> Void,
        type: (String) -> Void,
        reply: () -> Void,
        send: () -> Void,
        store: ChatStore,
        readout: ScrollReadout
    ) async {
        try? await Task.sleep(for: .seconds(1.5))
        await step("open", readout: readout) {}
        await step("keyboard up", readout: readout) { focus(true) }
        await step("send short", readout: readout) { type("hello"); send() }
        await step("send 4 lines", readout: readout) { type("one\ntwo\nthree\nfour"); send() }
        await step("reply + send", readout: readout) { reply(); type("replying"); send() }
        await step("send 3 quickly", readout: readout) { ["a", "b", "c"].forEach(store.send) }
        await step("incoming", readout: readout) { store.receiveOne() }
        await step("keyboard down", readout: readout) { focus(false) }
        await step("send, no keyboard", readout: readout) { type("no keyboard"); send() }
        report("done")
        readout.autopilotDone = true
    }

    /// Samples the distance from the newest message while the step settles: the worst
    /// value seen, and where it came to rest.
    private static func step(_ name: String, readout: ScrollReadout, _ action: () -> Void) async {
        let correctionsBefore = readout.corrections
        action()
        var lowest = readout.distanceFromNewest
        var highest = readout.distanceFromNewest
        let clock = ContinuousClock()
        let end = clock.now + settleTime
        while clock.now < end {
            try? await Task.sleep(for: sampleInterval)
            lowest = min(lowest, readout.distanceFromNewest)
            highest = max(highest, readout.distanceFromNewest)
        }
        let rest = readout.distanceFromNewest
        let verdict = abs(rest) <= ScrollReadout.pastEndTolerance ? "ON NEWEST" : (rest < 0 ? "PAST END" : "SHORT")
        report(String(format: "%-18@ rest %7.1f  min %7.1f  max %7.1f  inset %5.0f  scrolls %3d  %@",
                     name as NSString, rest, lowest, highest, readout.insetBottom, readout.corrections - correctionsBefore, verdict as NSString))
    }
}

extension Autopilot {
    static let keyboardWait: Duration = .seconds(15)

    static var logURL: URL { URL.documentsDirectory.appending(path: "autopilot.log") }

    /// The UI test taps the composer; a programmatic focus never brought the keyboard up.
    fileprivate static func waitForKeyboard(_ readout: ScrollReadout) async {
        let shown = Task {
            for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardDidShowNotification) { return }
        }
        let timeout = Task { try? await Task.sleep(for: keyboardWait); shown.cancel() }
        await shown.value
        timeout.cancel()
        try? await Task.sleep(for: settleTime)
        report(String(format: "keyboard shown %@  inset %.0f  container %.0f",
                      (!shown.isCancelled ? "yes" : "NO") as NSString, readout.insetBottom, readout.containerHeight))
    }

    fileprivate static func report(_ line: String) {
        print("AUTOPILOT \(line)")
        let existing = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }
}
