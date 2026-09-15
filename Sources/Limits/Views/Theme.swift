import AppKit
import SwiftUI

extension NSColor {
    /// 0xRRGGBB, the form the design tokens are written in.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }

    /// Picks between two hex tokens by the current appearance.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

/// Design tokens shared by every surface.
///
/// The redesign is a translucent, single-column utility window: glass cards on
/// a vibrant background rather than opaque panels in a split view. These values
/// are the ones the design specifies, kept in one place so the window, the
/// popover and the cards cannot drift apart.
enum Theme {
    // MARK: Layout

    static let windowWidth: CGFloat = 512
    static let popoverWidth: CGFloat = 332
    static let contentPadding: CGFloat = 10
    static let cardGap: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let popoverCardRadius: CGFloat = 10

    // MARK: Surfaces

    /// Card fill. Light mode is a near-white wash that still lets the window's
    /// vibrancy through; dark mode is a faint lift off the background.
    static var cardFill: Color {
        .dynamicOpacity(light: (0xFFFFFF, 0.72), dark: (0xFFFFFF, 0.055))
    }

    /// A card for a provider the user is not tracking.
    static var cardFillMuted: Color {
        .dynamicOpacity(light: (0xFFFFFF, 0.45), dark: (0xFFFFFF, 0.035))
    }

    static var cardStroke: Color {
        .dynamicOpacity(light: (0x000000, 0.07), dark: (0xFFFFFF, 0.085))
    }

    /// Hairline between rows inside a card.
    static var divider: Color {
        .dynamicOpacity(light: (0x000000, 0.07), dark: (0xFFFFFF, 0.085))
    }

    /// Unfilled portion of a ring.
    static var meterTrack: Color {
        .dynamicOpacity(light: (0x000000, 0.10), dark: (0xFFFFFF, 0.13))
    }

    // MARK: Status

    /// Quota that needs attention. Distinct from the system red so it reads as
    /// a measured warning rather than a destructive action.
    static var low: Color { .dynamic(light: 0xC8352A, dark: 0xFF6961) }
    static var warning: Color { .dynamic(light: 0xE08100, dark: 0xFF9F0A) }
    static var healthy: Color { .dynamic(light: 0x28A745, dark: 0x30D158) }

    /// Tinted plate behind a provider mark.
    static func markPlate(_ provider: Provider) -> Color {
        provider.tint.opacity(0.16)
    }
}

extension Color {
    /// Two hex+alpha tokens resolved by appearance. Opacity differs between
    /// themes here, which `Color.opacity` alone cannot express dynamically.
    static func dynamicOpacity(
        light: (UInt32, CGFloat),
        dark: (UInt32, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(hex: dark.0, alpha: dark.1)
                : NSColor(hex: light.0, alpha: light.1)
        })
    }
}
