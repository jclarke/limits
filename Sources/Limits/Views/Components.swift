import SwiftUI

/// Ring gauge for one quota window.
///
/// Deliberately not a segmented bar: that reads as a generic progress track
/// and is what every other quota tool draws. A ring echoes the app's own gauge
/// mark, shows the exact figure in the middle where the eye already is, and
/// lets a row be two lines instead of three.
///
/// Font Awesome's meter glyphs (`battery-*`, `gauge-*`, `signal`) were the
/// obvious shortcut, but each is a fixed five-step icon — they cannot tell 93%
/// from 100%, so they would be decoration sitting where data belongs.
struct RingMeter: View {
    let remainingPercent: Double
    var tint: Color
    var diameter: CGFloat = 34
    var lineWidth: CGFloat = 3.5
    /// Scoped windows render quieter so account-wide numbers stay dominant.
    var isMuted = false

    private var fraction: Double { max(0, min(100, remainingPercent)) / 100 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)

            Circle()
                // A sliver of arc always remains while any quota does: the
                // difference between "almost out" and "out" must stay visible.
                .trim(from: 0, to: remainingPercent > 0 ? max(0.012, fraction) : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Start at twelve o'clock and drain clockwise, the way a dial
                // people already read does.
                .rotationEffect(.degrees(-90))

            // The unit lives inside the ring so the figure is self-describing
            // and the row needs no trailing label floating off to the side.
            HStack(spacing: 0) {
                Text("\(Int(remainingPercent.rounded()))")
                    .font(.system(size: diameter * 0.30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: diameter * 0.20, weight: .semibold, design: .rounded))
                    .baselineOffset(diameter * 0.015)
                    .opacity(0.55)
            }
            .foregroundStyle(
                isMuted ? Color.secondary
                    : (Formatting.isLow(remainingPercent) ? tint : .primary)
            )
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .padding(.horizontal, lineWidth)
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.4), value: fraction)
        .help("\(Formatting.percent(remainingPercent)) remaining")
        .accessibilityElement()
        .accessibilityLabel("\(Formatting.percent(remainingPercent)) remaining")
    }
}

/// One quota window: ring, label, and reset time.
struct QuotaWindowRow: View {
    let window: QuotaWindow
    var provider: Provider?
    var isCompact = false

    private var tint: Color {
        Formatting.tint(forRemaining: window.remainingPercent, provider: provider)
    }

    var body: some View {
        HStack(spacing: isCompact ? 9 : 11) {
            RingMeter(
                remainingPercent: window.remainingPercent,
                tint: tint,
                diameter: isCompact ? 28 : 34,
                lineWidth: isCompact ? 3 : 3.5,
                isMuted: window.isScoped
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(window.label)
                    .font(isCompact ? .caption : .subheadline)
                    .fontWeight(window.isScoped ? .regular : .medium)
                    .foregroundStyle(window.isScoped ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let reset = Formatting.resetDescription(window.resetsAt) {
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("No reset time reported")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
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
