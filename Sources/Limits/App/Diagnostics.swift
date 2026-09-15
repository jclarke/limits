import Foundation

/// One-shot provider readout for troubleshooting. Prints only quota shapes and
/// error reasons — never a token, and never a full credential path.
enum Diagnostics {
    static func run() -> Never {
        // `dispatchMain()` rather than blocking on a semaphore: the work below
        // is main-actor isolated, so parking the main thread would deadlock
        // before it could run.
        Task { @MainActor in
            // Roster first: which accounts exist and where they are shown.
            let accounts = AccountsStore()
            accounts.refreshDiscoveredAccounts()
            await accounts.refreshDiscoveredCursorAccounts()
            print("Accounts (\(accounts.allProfiles.count)):")
            for profile in accounts.allProfiles {
                let flags = [
                    profile.isEnabled ? "tracked" : "untracked",
                    profile.showsInMenuBar ? "menubar" : "hidden"
                ].joined(separator: ",")
                print("  \(profile.provider.rawValue): \(profile.resolvedDisplayName(provider: profile.provider)) [\(profile.kind.rawValue)] (\(flags))")
            }
            print("")

            let fetcher = QuotaFetcher()
            for provider in Provider.allCases {
                let profile = AccountProfile.system(provider)
                do {
                    let quota = try await fetcher.fetch(profile)
                    let plan = quota.planName.map { " [\($0)]" } ?? ""
                    print("\(provider.displayName)\(plan): OK")
                    for window in quota.windows {
                        let reset = Formatting.resetDescription(window.resetsAt) ?? "no reset reported"
                        print("    \(window.label): \(Formatting.percent(window.remainingPercent)) remaining — \(reset)")
                    }
                } catch {
                    let issue = (error as? AccountIssue) ?? .other(error.localizedDescription)
                    print("\(provider.displayName): \(issue.title) — \(issue.message(provider: provider))")
                }
            }
            exit(0)
        }
        dispatchMain()
    }
}
