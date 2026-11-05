import SwiftUI

/// How much larger or smaller than the system's size the reader wants text. The Mac has no
/// Dynamic Type, so it carries its own setting; the phone stays at the standard scale and
/// follows the system's text size.
enum TextScale {
    static let storageKey = "text.scale"
    static let standard: Double = 1
    /// One press of Bigger or Smaller, and one notch of the slider in Settings.
    static let increment: Double = 0.15
    static let range: ClosedRange<Double> = 0.85...1.6

    static var current: CGFloat {
        #if os(macOS)
        let stored = UserDefaults.standard.double(forKey: storageKey)
        return CGFloat(stored > 0 ? stored : standard)
        #else
        return CGFloat(standard)
        #endif
    }

    /// Nil at the largest size, so the menu item can be disabled there.
    static func bigger(than scale: Double) -> Double? {
        let next = rounded(scale + increment)
        return next <= range.upperBound + tolerance ? min(next, range.upperBound) : nil
    }

    /// Nil at the smallest size, so the menu item can be disabled there.
    static func smaller(than scale: Double) -> Double? {
        let next = rounded(scale - increment)
        return next >= range.lowerBound - tolerance ? max(next, range.lowerBound) : nil
    }

    private static let tolerance: Double = 0.001
    private static let precision: Double = 100

    /// Steps of a hundredth, so a few presses of Bigger and Smaller land back on exactly 1.
    private static func rounded(_ scale: Double) -> Double {
        (scale * precision).rounded() / precision
    }
}

extension EnvironmentValues {
    @Entry var textScale: CGFloat = CGFloat(TextScale.standard)
}

extension Font {
    /// A text style at the reader's scale. On the phone this is the style itself, which
    /// Dynamic Type already sizes.
    static func scaled(_ style: Font.TextStyle, by scale: CGFloat, design: Font.Design = .default) -> Font {
        #if os(macOS)
        guard scale != CGFloat(TextScale.standard) else { return .system(style, design: design) }
        return .system(size: Platform.pointSize(of: style) * scale, design: design)
        #else
        return .system(style, design: design)
        #endif
    }
}
