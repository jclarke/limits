import SwiftUI

/// Segmented meter: discrete blocks rather than a continuous bar, so a glance
/// reads as "about eight of twelve left" instead of an abstract ratio.
struct SegmentedMeter: View {
    let remainingPercent: Double
    var tint: Color
    var segments: Int = 16
    var height: CGFloat = 5

    private var filled: Int {
        // Never round down to zero while any quota remains: a hairline of
        // color is the difference between "almost out" and "out".
        let exact = remainingPercent / 100 * Double(segments)
        return remainingPercent > 0 ? max(1, Int(exact.rounded())) : 0
    }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let width = (geometry.size.width - spacing * CGFloat(segments - 1)) / CGFloat(segments)
            HStack(spacing: spacing) {
                ForEach(0..<segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(index < filled ? tint : Color.primary.opacity(0.10))
                        .frame(width: max(1, width))
                }
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: filled)
        .accessibilityElement()
        .accessibilityLabel("\(Formatting.percent(remainingPercent)) remaining")
    }
}

/// One quota window: label, remaining percent, meter, reset time.
struct QuotaWindowRow: View {
    let window: QuotaWindow
    var provider: Provider?
    var isCompact = false

    private var tint: Color {
        Formatting.tint(forRemaining: window.remainingPercent, provider: provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 4 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label)
                    .font(isCompact ? .caption : .subheadline)
                    .foregroundStyle(window.isScoped ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(Formatting.percent(window.remainingPercent))
                    .font(isCompact ? .caption : .subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    // Percentages stay neutral unless low: coloring every
                    // number its provider's hue turns the text into decoration
                    // and makes a genuinely low one easy to miss.
                    .foregroundStyle(Formatting.isLow(window.remainingPercent) ? tint : .primary)
                Text("left")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            SegmentedMeter(remainingPercent: window.remainingPercent, tint: tint,
                           height: isCompact ? 4 : 5)
            if let reset = Formatting.resetDescription(window.resetsAt) {
                Text(reset)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// The one place an account's problem is explained and repaired. Every surface
/// renders this, so a broken login is fixable wherever it is noticed.
struct IssueRow: View {
    let snapshot: AccountSnapshot
    var isCompact = false
    let onFix: (AccountIssue.Remedy) -> Void

    var body: some View {
        if let issue = snapshot.issue {
            // A provider the user simply hasn't set up is an invitation, not
            // a fault, and must not wear an alarm color.
            let isAlarming = snapshot.needsAttention
            let accent: Color = isAlarming ? .orange : .secondary

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isAlarming ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(accent)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(issue.message(provider: snapshot.provider))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(issue.remedy(for: snapshot.profile).actionLabel) {
                    onFix(issue.remedy(for: snapshot.profile))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
            .padding(isCompact ? 9 : 11)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isAlarming ? Color.orange.opacity(0.09) : Color.primary.opacity(0.045))
            )
        }
    }
}

/// Provider heading shared by the popover and the Limits screen.
struct ProviderHeader: View {
    let provider: Provider
    let accountCount: Int
    var planName: String?
    var markSize: CGFloat = 15

    var body: some View {
        HStack(spacing: 7) {
            ProviderMark(provider: provider, size: markSize)
            Text(provider.displayName)
                .font(.headline)
            if let planName { Chip(text: planName) }
            Spacer(minLength: 6)
            if accountCount > 1 {
                Text("\(accountCount) accounts")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
