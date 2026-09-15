import Foundation

/// One-shot provider readout for troubleshooting. Prints only quota shapes and
/// error reasons — never a token, and never a full credential path.
enum Diagnostics {
    static func run() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
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
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }
}
