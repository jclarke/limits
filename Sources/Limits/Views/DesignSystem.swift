import SwiftUI

/// Shared metrics and surfaces. Centralized so the popover and the window read
/// as one app, and so every value is a deliberate choice rather than a literal
/// scattered through a view.
enum Metrics {
    /// macOS control spacing runs tighter than iOS; these match the rhythm of
    /// system windows like System Settings.
    static let cardRadius: CGFloat = 10
    static let cardPadding: CGFloat = 14
    static let rowSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 14
    static let popoverWidth: CGFloat = 332
}

/// A grouped container matching the inset-group look macOS uses for settings
/// and status surfaces: a filled card with a hairline, no heavy shadow.
struct Card<Content: View>: View {
    var padding: CGFloat = Metrics.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }
}

/// A small capitalized chip for plan names and account kinds.
struct Chip: View {
    let text: String
    var prominent = false

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(prominent ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    prominent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.07)
                )
            )
            .fixedSize()
    }
}

/// Health dot used in account rows and the sidebar footer.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            // A soft halo keeps the dot visible against both card fills and
            // the sidebar's vibrancy without needing a heavier color.
            .overlay(Circle().stroke(color.opacity(0.25), lineWidth: size * 0.5))
            .accessibilityHidden(true)
    }
}

/// Column layout that balances items by weight instead of filling row by row.
///
/// A `LazyVGrid` aligns each row to the tallest card in it, so one provider
/// with six quota windows leaves a tall gap beside every short neighbour.
/// Distributing into independent columns and always appending to the lightest
/// one keeps the columns roughly level and removes the holes.
struct BalancedColumns<Item: Identifiable, Content: View>: View {
    let items: [Item]
    /// Relative height of an item — row count is a good enough proxy.
    let weight: (Item) -> Int
    var minimumColumnWidth: CGFloat = 340
    var spacing: CGFloat = 14
    @ViewBuilder let content: (Item) -> Content

    /// Measured separately from layout: a `GeometryReader` wrapping the
    /// content would report no intrinsic height and collapse the scroll view.
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            let columns = distribute(into: columnCount)
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                VStack(spacing: spacing) {
                    ForEach(column) { item in content(item) }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear.onAppear { availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in availableWidth = width }
            }
        )
    }

    private var columnCount: Int {
        guard availableWidth > 0, !items.isEmpty else { return 1 }
        let fits = Int((availableWidth + spacing) / (minimumColumnWidth + spacing))
        return max(1, min(items.count, fits))
    }

    private func distribute(into count: Int) -> [[Item]] {
        var columns = Array(repeating: [Item](), count: count)
        var weights = Array(repeating: 0, count: count)
        for item in items {
            // Always extend the shortest column so the tallest card does not
            // dictate a whole row's height.
            let target = weights.enumerated().min { $0.element < $1.element }?.offset ?? 0
            columns[target].append(item)
            weights[target] += weight(item)
        }
        return columns
    }
}
