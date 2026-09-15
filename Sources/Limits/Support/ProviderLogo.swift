import AppKit
import SwiftUI

/// Loads and tints the bundled provider brand marks.
///
/// The marks are monochrome single-path SVGs, which macOS rasterizes natively
/// and which tint cleanly to each provider's color. An SF Symbol stands in if
/// one ever fails to load, so a missing asset degrades to a plain icon rather
/// than an empty gap.
enum ProviderLogo {
    /// Rasterizing an SVG is not free and the menu bar redraws on every
    /// refresh, so keep the decoded images.
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func image(for provider: Provider) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[provider.rawValue] { return cached }
        guard let url = Bundle.module.url(
            forResource: provider.rawValue,
            withExtension: "svg",
            subdirectory: "ProviderIcons"
        ) ?? Bundle.module.url(forResource: provider.rawValue, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        // Template rendering is what lets one asset carry every tint.
        image.isTemplate = true
        cache[provider.rawValue] = image
        return image
    }

    /// A tinted, pixel-sized copy for AppKit drawing (the menu bar title).
    static func tinted(_ provider: Provider, pointSize: CGFloat, color: NSColor) -> NSImage? {
        guard let base = image(for: provider) else { return nil }
        // Brand marks have differing amounts of internal padding; scale to a
        // square box so they sit at a consistent optical size next to text.
        let size = NSSize(width: pointSize, height: pointSize)
        let rendered = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        rendered.isTemplate = false
        return rendered
    }
}

/// The provider's brand mark, tinted to its color.
struct ProviderMark: View {
    let provider: Provider
    var size: CGFloat = 13

    var body: some View {
        Group {
            if let image = ProviderLogo.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: provider.symbolName)
                    .font(.system(size: size, weight: .medium))
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(provider.tint)
        .accessibilityHidden(true)
    }
}
