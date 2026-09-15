import Foundation
import SwiftUI

enum Formatting {
    /// "Resets in 4 hr 48 min" / "Resets Sep 30 at 10:08 AM". Near-term resets
    /// read better as a countdown; distant ones as a date.
    static func resetDescription(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "Resetting now" }
        if interval < 24 * 3600 {
            return "Resets in \(duration(interval))"
        }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = interval < 6 * 24 * 3600 ? "EEEE 'at' h:mm a" : "MMM d 'at' h:mm a"
        return "Resets \(formatter.string(from: date))"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            let remainder = hours % 24
            return remainder == 0 ? "\(days) d" : "\(days) d \(remainder) hr"
        }
        if hours > 0 { return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min" }
        return "\(max(1, minutes)) min"
    }

    /// Whole numbers read better in a menu bar; a fraction only matters when
    /// the value is nearly gone.
    static func percent(_ value: Double) -> String {
        let clamped = max(0, min(100, value))
        if clamped > 0, clamped < 1 { return String(format: "%.1f%%", clamped) }
        return "\(Int(clamped.rounded()))%"
    }

    static func relative(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "Updated just now" }
        return "Updated \(duration(interval)) ago"
    }

    /// Green while there is headroom, amber as it tightens, red when nearly
    /// exhausted. The same scale is used by every meter in the app.
    static func tint(forRemaining remaining: Double) -> Color {
        switch remaining {
        case ..<10: .red
        case ..<25: .orange
        default: .green
        }
    }
}
