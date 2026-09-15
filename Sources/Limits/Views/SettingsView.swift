import SwiftUI

/// The ⌘, pane. Small on purpose — the app's real surface is the menu bar.
struct SettingsView: View {
    @EnvironmentObject private var launchAtLogin: LaunchAtLogin
    @EnvironmentObject private var usage: UsageStore

    var body: some View {
        Form {
            Section {
                Toggle("Launch Limits at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.set($0) }
                ))
                if launchAtLogin.requiresApproval {
                    Label(
                        "Login items for Limits are turned off in System Settings › General › Login Items.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else if let error = launchAtLogin.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Limits registers the app at its current location, so move it to your Applications folder before turning this on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Checked every") {
                    Text("\(Int(UsageStore.refreshInterval / 60)) minute")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Credentials") {
                    Text("Read-only")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Usage")
            } footer: {
                Text("Limits reads each provider's own saved login and never refreshes, changes or stores your credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin.refresh() }
    }
}
