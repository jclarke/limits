import SwiftUI

/// Ring gauge for one quota window.
///
/// Drawn as a trimmed circle starting at twelve o'clock and draining
/// clockwise, with the figure in the middle where the eye already is.
struct RingMeter: View {
    let remainingPercent: Double
    var tint: Color
    var diameter: CGFloat = 26
    var lineWidth: CGFloat = 3
    /// Scoped windows render quieter so account-wide numbers stay dominant.
    var isMuted = false

    private var fraction: Double { max(0, min(100, remainingPercent)) / 100 }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.meterTrack, lineWidth: lineWidth)

            Circle()
                // A sliver always remains while any quota does: the difference
                // between "almost out" and "out" must stay visible.
                .trim(from: 0, to: remainingPercent > 0 ? max(0.012, fraction) : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text("\(Int(remainingPercent.rounded()))")
                .font(.system(size: diameter * 0.365, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .kerning(-0.2)
                .foregroundStyle(labelColor)
                .minimumScaleFactor(0.75)
                .lineLimit(1)
                .padding(.horizontal, lineWidth)
        }
        .frame(width: diameter, height: diameter)
        .opacity(isMuted ? 0.72 : 1)
        .animation(.easeOut(duration: 0.4), value: fraction)
        .help("\(Formatting.percent(remainingPercent)) remaining")
        .accessibilityElement()
        .accessibilityLabel("\(Formatting.percent(remainingPercent)) remaining")
    }

    private var labelColor: Color {
        if isMuted { return .secondary }
        return Formatting.isLow(remainingPercent) ? Theme.low : .primary
    }
}

/// One quota window: ring, label, reset time.
struct QuotaWindowRow: View {
    let window: QuotaWindow
    var provider: Provider?
    var diameter: CGFloat = 26

    private var tint: Color {
        Formatting.tint(forRemaining: window.remainingPercent, provider: provider)
    }

    var body: some View {
        HStack(spacing: 9) {
            RingMeter(
                remainingPercent: window.remainingPercent,
                tint: tint,
                diameter: diameter,
                lineWidth: diameter >= 26 ? 3 : 2.5,
                isMuted: window.isScoped
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(window.label)
                    .font(.system(size: 11.5, weight: window.isScoped ? .regular : .medium))
                    .kerning(-0.08)
                    .foregroundStyle(window.isScoped ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Formatting.resetDescription(window.resetsAt) ?? "No reset time reported")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Provider brand mark on its tinted plate, as the design shows it in card
/// headers. The popover uses the bare mark instead.
struct ProviderMarkPlate: View {
    let provider: Provider
    var plateSize: CGFloat = 22
    var markSize: CGFloat = 13
    var cornerRadius: CGFloat = 7

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.markPlate(provider))
            .frame(width: plateSize, height: plateSize)
            .overlay(ProviderMark(provider: provider, size: markSize))
    }
}

/// Small capitalized chip for plan names and account kinds.
struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill(Color.dynamicOpacity(
                    light: (0x000000, 0.06), dark: (0xFFFFFF, 0.10)
                ))
            )
    }
}

/// Health dot with a soft halo, so it stays visible on glass.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(color.opacity(0.18), lineWidth: size * 0.5))
            .accessibilityHidden(true)
    }
}

/// The translucent card every surface is built from.
struct GlassCard<Content: View>: View {
    var radius: CGFloat = Theme.cardRadius
    var muted = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(muted ? Theme.cardFillMuted : Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
            )
    }
}

/// The one place an account's problem is explained and repaired. Every surface
/// renders this, so a broken login is fixable wherever it is noticed.
struct IssueRow: View {
    let snapshot: AccountSnapshot
    let onFix: (AccountIssue.Remedy) -> Void

    var body: some View {
        if let issue = snapshot.issue {
            // A provider the user simply hasn't set up is an invitation, not a
            // fault, and must not wear an alarm color.
            let isAlarming = snapshot.needsAttention
            let accent = isAlarming ? Theme.warning : Color.secondary

            HStack(alignment: .top, spacing: 9) {
                ZStack {
                    Circle().fill(accent)
                    Text("!")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
                .frame(width: 13, height: 13)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title).font(.system(size: 11, weight: .semibold))
                    Text(issue.message(provider: snapshot.provider))
                        .font(.system(size: 10.5))
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
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(accent.opacity(isAlarming ? 0.12 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(accent.opacity(isAlarming ? 0.24 : 0.12), lineWidth: 0.5)
            )
        }
    }
}
