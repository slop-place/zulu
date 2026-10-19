import UniformTypeIdentifiers
import SwiftUI

#if canImport(UIKit)
import UIKit

typealias PlatformImage = UIImage
typealias PlatformColor = UIColor

enum Platform {
    static func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// A short knock, for the moment a gesture commits. Silent where the hardware
    /// has nothing to knock with.
    static func tap() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    static func image(from data: Data) -> Image? {
        UIImage(data: data).map(Image.init(uiImage:))
    }

    static func scaled(_ image: UIImage, toHeight height: CGFloat) -> Image? {
        guard image.size.height > 0 else { return Image(uiImage: image) }
        let size = CGSize(
            width: image.size.width * (height / image.size.height), height: height
        )
        let scaled = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return Image(uiImage: scaled)
    }

    /// Light and dark are picked per draw rather than from a captured environment,
    /// which is what keeps a colour correct when the system theme changes underneath
    /// a running app.
    static func grey(light: CGFloat, dark: CGFloat) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: dark, alpha: 1)
            : UIColor(white: light, alpha: 1)
        })
    }

    /// The surface everything sits on. Dark mode means black, not a lighter grey; light
    /// mode keeps the system's own background.
    static let canvas = Color(UIColor { $0.userInterfaceStyle == .dark ? .black : .systemBackground })

    /// The system's text roles, under one name on both platforms.
    static let label = UIColor.label
    static let secondaryLabel = UIColor.secondaryLabel
    static let tertiaryLabel = UIColor.tertiaryLabel

    static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

#else
import AppKit

typealias PlatformImage = NSImage
typealias PlatformColor = NSColor

enum Platform {
    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    static func image(from data: Data) -> Image? {
        NSImage(data: data).map(Image.init(nsImage:))
    }

    static func scaled(_ image: NSImage, toHeight height: CGFloat) -> Image? {
        guard image.size.height > 0 else { return Image(nsImage: image) }
        let size = NSSize(
            width: image.size.width * (height / image.size.height), height: height
        )
        let scaled = NSImage(size: size)
        scaled.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        scaled.unlockFocus()
        return Image(nsImage: scaled)
    }

    static func grey(light: CGFloat, dark: CGFloat) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }

    /// The surface everything sits on. Dark mode means black, not a lighter grey; light
    /// mode keeps the system's own window colour.
    static let canvas = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .windowBackgroundColor
    })

    /// The system's text roles, under one name on both platforms.
    static let label = NSColor.labelColor
    static let secondaryLabel = NSColor.secondaryLabelColor
    static let tertiaryLabel = NSColor.tertiaryLabelColor

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}
#endif

extension View {
    /// The compact navigation title the phone wants, and nothing at all on a Mac, where
    /// the modifier does not exist.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        return navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }
}

extension UTType {
    /// Zulip wants a content type on every upload, and a file whose extension means
    /// nothing to the system still has to go somewhere.
    var preferredMIME: String { preferredMIMEType ?? "application/octet-stream" }
}

extension Platform {
    /// The body text's line, top of the tallest letter to the bottom of the lowest. An
    /// inline picture this size, dropped by the descender, sits on the line without
    /// making it taller than its neighbours.
    static var bodyLine: (height: CGFloat, descender: CGFloat) { line(of: .body) }

    /// The line of a message that is nothing but emoji, which is drawn at this size.
    static var emojiOnlyLine: (height: CGFloat, descender: CGFloat) { line(of: .largeTitle) }

    #if canImport(UIKit)
    private static func line(of style: UIFont.TextStyle) -> (height: CGFloat, descender: CGFloat) {
        let font = UIFont.preferredFont(forTextStyle: style)
        return (ceil(font.ascender - font.descender), font.descender)
    }
    #else
    private static func line(of style: NSFont.TextStyle) -> (height: CGFloat, descender: CGFloat) {
        let font = NSFont.preferredFont(forTextStyle: style)
        return (ceil(font.ascender - font.descender), font.descender)
    }
    #endif
}
