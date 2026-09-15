#!/usr/bin/env swift
import AppKit
import Foundation

// Draws the Limits app icon: a gauge arc on a rounded-square gradient tile,
// following Apple's macOS icon grid (the art sits in the inner ~82%, with the
// squircle corner radius Apple uses for app tiles).
func drawIcon(side: CGFloat, in context: CGContext) {
    let inset = side * 0.09              // Apple's macOS tiles float in their canvas
    let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = rect.width * 0.2237     // macOS squircle ratio

    context.saveGState()
    let tile = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(tile)
    context.clip()

    // Deep indigo → violet, lit from the top like every other macOS tile.
    let colors = [
        CGColor(red: 0.32, green: 0.30, blue: 0.78, alpha: 1),
        CGColor(red: 0.16, green: 0.14, blue: 0.42, alpha: 1)
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY), options: [])

    // Soft top highlight for the glassy tile look.
    let highlight = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0)
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(highlight, start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    context.restoreGState()

    // The gauge. No needle: at 16pt a needle collapses into the arc and
    // reads as noise, while a thick two-tone sweep stays legible at every
    // size and carries the same "how much is left" meaning.
    let center = CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.09)
    let arcRadius = rect.width * 0.315
    let lineWidth = rect.width * 0.135
    let start = CGFloat.pi * 0.85        // sweep from lower-left...
    let end = CGFloat.pi * 0.15          // ...to lower-right, gauge-style
    let remaining: CGFloat = 0.68        // partly full: neither a plain ring nor an error

    context.setLineCap(.round)
    context.setLineWidth(lineWidth)

    // Spent portion: a recessed track.
    context.setStrokeColor(CGColor(red: 0.04, green: 0.03, blue: 0.16, alpha: 0.40))
    context.addArc(center: center, radius: arcRadius, startAngle: start, endAngle: end,
                   clockwise: true)
    context.strokePath()

    // Remaining portion, drawn over the track so the two share a rounded cap.
    context.setStrokeColor(CGColor(red: 0.42, green: 0.96, blue: 0.70, alpha: 1))
    context.addArc(center: center, radius: arcRadius, startAngle: start,
                   endAngle: start - (start - end) * remaining, clockwise: true)
    context.strokePath()

    // A single dot marks the gauge's origin and keeps the composition from
    // reading as a bare crescent.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    let hub = lineWidth * 0.30
    context.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub,
                                   width: hub * 2, height: hub * 2))
}

func render(side: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    drawIcon(side: CGFloat(side), in: ctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outputDirectory).appendingPathComponent("Limits.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes `iconutil` expects for a complete .icns.
for (side, name) in [(16,"icon_16x16"), (32,"icon_16x16@2x"), (32,"icon_32x32"),
                     (64,"icon_32x32@2x"), (128,"icon_128x128"), (256,"icon_128x128@2x"),
                     (256,"icon_256x256"), (512,"icon_256x256@2x"), (512,"icon_512x512"),
                     (1024,"icon_512x512@2x")] {
    try render(side: side).write(to: iconset.appendingPathComponent("\(name).png"))
}
print("wrote \(iconset.path)")
