import SwiftUI

/// The two-step Antigravity sign-in: open Google in the browser, then hand the
/// CLI the code the callback page shows.
///
/// The code is short-lived and single-use, and Antigravity's own CLI exchanges
/// it — Limits only carries it across. That is why this is worth a bespoke
/// screen rather than the generic "paste a long-lived token" field it replaces.
struct AntigravitySignInView: View {
    @EnvironmentObject private var usage: UsageStore
    @StateObject private var session = AntigravityLoginSession()
    @State private var code = ""

    let profile: AccountProfile
    /// Called on success, and on cancel with `false`, so the caller can remove
    /// a profile that never completed sign-in.
    let onFinish: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { session.start() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProviderMarkPlate(provider: .antigravity, plateSize: 30, markSize: 17, cornerRadius: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sign in to Antigravity").font(.headline)
                Text(profile.resolvedDisplayName(provider: .antigravity))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle, .launching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting Antigravity's sign-in…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .awaitingCode:
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "Sign in with Google in your browser. Antigravity will then show a code — paste it below.",
                    systemImage: "safari"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                TextField("Authorization code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)

                Button("Open the sign-in page again") { session.openAuthorizationURL() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

        case .completing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Completing sign-in…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .finished:
            Label("Signed in.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                session.cancel()
                onFinish(false)
            }
            Spacer()
            if case .awaitingCode = session.phase {
                Button("Complete Sign-In", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if case .failed = session.phase {
                Button("Close") { onFinish(false) }
            }
        }
    }

    private func submit() {
        session.submit(code: code)
        Task {
            // The CLI is killed mid-prompt once the token lands, so success is
            // confirmed by a usable credential appearing rather than by an
            // exit code. Poll briefly for it.
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if await AntigravityTokenReader().load() != nil {
                    session.markFinished()
                    await usage.refresh(profile)
                    onFinish(true)
                    return
                }
                if case .failed = session.phase { return }
            }
        }
    }
}
