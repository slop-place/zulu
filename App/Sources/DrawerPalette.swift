import SwiftUI

/// The drawer's surfaces need to read as separate surfaces.
///
/// The system's grouped-background greys sit within a couple of percent of each other in
/// dark mode, so the rail, the channel list and the message page all looked like one flat
/// black field. The rail is lifted above the list and separated by a hard edge, which
/// carries the division at a glance without relying on the greys alone.
enum DrawerPalette {
    static var rail: Color {
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.07, alpha: 1)
            : UIColor(white: 0.90, alpha: 1)
        })
    }

    static var list: Color {
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0, alpha: 1)
            : UIColor(white: 0.97, alpha: 1)
        })
    }

    /// The edge between rail and list.
    static var edge: Color {
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.24, alpha: 1)
            : UIColor(white: 0.78, alpha: 1)
        })
    }
}
