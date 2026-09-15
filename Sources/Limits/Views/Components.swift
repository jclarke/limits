import SwiftUI

/// Segmented meter matching the reference app's look: discrete blocks rather
/// than a continuous bar, so a glance reads as "about eight of twelve left".
struct SegmentedMeter: View {
    let remainingPercent: Double
    var tint: Color
    var segments: Int = 14
    var height: CGFloat = 6

    private var filled: Int {
        // Never show zero segments while any quota remains: a hairline of
        // color is the difference between "almost out" and "out".
        let exact = remainingPercent / 100 * Double(segments)
        if remainingPercent > 0 { return max(1, Int(exact.rounded())) }
        return 0
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index < filled ? tint : Color.primary.opacity(0.12))
                    .frame(height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(Formatting.percent(remainingPercent)) remaining")
    }
}

/// One quota window: label, remaining percent, meter, reset time.
struct QuotaWindowRow: View {
    let window: QuotaWindow
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 3 : 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(isCompact ? .caption : .subheadline)
                    .foregroundStyle(window.isScoped ? .secondary : .primary)
                Spacer(minLength: 8)
                Text("\(Formatting.percent(window.remainingPercent)) remaining")
                    .font(isCompact ? .caption : .subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(Formatting.tint(forRemaining: window.remainingPercent))
            }
            SegmentedMeter(
                remainingPercent: window.remainingPercent,
                tint: Formatting.tint(forRemaining: window.remainingPercent),
                height: isCompact ? 5 : 6
            )
            if let reset = Formatting.resetDescription(window.resetsAt) {
                Text(reset)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Provider mark used in headers, rows and the menu bar.
struct ProviderMark: View {
    let provider: Provider
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: provider.symbolName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(provider.tint)
            .accessibilityHidden(true)
    }
}

/// The one place an account's problem is explained and repaired. Every
/// surface renders this, so a broken login is fixable wherever it is noticed.
struct IssueRow: View {
    let snapshot: AccountSnapshot
    var isCompact = false
    let onFix: (AccountIssue.Remedy) -> Void

    private var issue: AccountIssue? { snapshot.issue }

    var body: some View {
        if let issue {
            let remedy = issue.remedy(for: snapshot.profile)
            // A provider the user simply hasn't set up is presented as an
            // invitation, not a fault.
            let isAlarming = snapshot.needsAttention
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isAlarming ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(isAlarming ? .orange : .secondary)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(issue.message(provider: snapshot.provider))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                }
                HStack {
                    Spacer()
                    Button(remedy.actionLabel) { onFix(remedy) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(isCompact ? 8 : 10)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isAlarming ? Color.orange.opacity(0.10) : Color.primary.opacity(0.05))
            )
        }
    }
}
