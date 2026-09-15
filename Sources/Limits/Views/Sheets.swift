import SwiftUI

/// Adds an account: pick a provider, name it, then either run the provider's
/// OAuth login or save a token, depending on what that provider supports.
struct AddAccountSheet: View {
    @EnvironmentObject private var accounts: AccountsStore
    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss

    @State private var provider: Provider = .claude
    @State private var name = ""
    @State private var token = ""
    @State private var isWorking = false
    @State private var error: String?

    private var usesCLILogin: Bool { provider.credentialKind == .isolatedCLI }
    private var cliAvailable: Bool { AccountLoginService.executable(for: provider) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Account").font(.title2).fontWeight(.semibold)

            Picker("Provider", selection: $provider) {
                ForEach(Provider.allCases) { candidate in
                    Label(candidate.displayName, systemImage: candidate.symbolName).tag(candidate)
                }
            }
            .pickerStyle(.menu)

            TextField("Name", text: $name, prompt: Text(accounts.defaultName(for: provider)))
                .textFieldStyle(.roundedBorder)

            if usesCLILogin {
                cliExplanation
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.credentialHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("Token", text: $token)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(usesCLILogin ? "Sign In" : "Save") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || (usesCLILogin ? !cliAvailable : token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }

            if isWorking {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(usesCLILogin ? "Complete the sign-in in your browser…" : "Saving…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private var cliExplanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            if cliAvailable {
                Label(
                    "Limits will open \(provider.displayName)'s own sign-in in your browser and keep the result in a separate profile, so your existing \(provider.displayName) login is untouched.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(
                    "The `\(provider.cliExecutableName ?? "")` command isn't installed where Limits can find it. Install it, then reopen this window.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func submit() {
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                let profile = try accounts.createManagedAccount(provider: provider, displayName: name)
                if usesCLILogin {
                    await usage.signIn(profile)
                    // A failed login leaves a profile with no session. Remove
                    // it rather than stranding a permanently broken row. Any
                    // issue counts: most login failures surface as `.other`,
                    // which is not classified as an auth problem.
                    if usage.state(for: profile.id).issue != nil {
                        let message = usage.lastLoginError ?? "Sign-in did not complete."
                        accounts.remove(profile.id)
                        error = message
                        return
                    }
                } else {
                    await usage.saveCredential(token, for: profile)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Replaces the stored credential for a keychain-backed account.
struct CredentialEntrySheet: View {
    @EnvironmentObject private var usage: UsageStore
    @Environment(\.dismiss) private var dismiss

    let profile: AccountProfile
    @State private var token = ""
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Update \(profile.provider.displayName) Token").font(.title2).fontWeight(.semibold)
            Text(profile.provider.credentialHelpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Token", text: $token)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") {
                    isWorking = true
                    Task {
                        await usage.saveCredential(token, for: profile)
                        isWorking = false
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

/// Explains how to repair an account Limits deliberately does not control —
/// a system account's session belongs to the user's own install.
struct GuidanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: AccountProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Fix \(profile.provider.displayName)", systemImage: profile.provider.symbolName)
                .font(.title2).fontWeight(.semibold)
            Text(steps)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    /// Limits never signs the user's primary account in or out, so the fix is
    /// always something they do in the provider's own tool.
    private var steps: String {
        switch profile.provider {
        case .claude:
            return "Run `claude` in a terminal and sign in, or run `claude auth login`. Limits will pick the new session up on its next refresh.\n\nIf Claude is already signed in, macOS may simply need permission to let Limits read the stored credential — choose \"Always Allow\" if a Keychain prompt appears."
        case .codex:
            return "Run `codex login` in a terminal, or open the Codex app and sign in. Limits reads the session Codex stores and will refresh automatically."
        case .cursor:
            return "Open Cursor and make sure you're signed in. Cursor renews its own token while it runs, and Limits reads it read-only — it never refreshes it for you."
        case .grok:
            return "Run `grok` once in a terminal to refresh its login. Limits reads ~/.grok/auth.json read-only and never renews the token itself."
        case .antigravity:
            return "Open Antigravity and sign in. Limits reads quota straight from the running app, so leaving it open is usually all that's needed."
        }
    }
}
