import Foundation

// `--diagnose` reads every provider once and prints what Limits sees, then
// exits. It is the quickest way to tell a credential problem apart from a
// rendering one without clicking through the UI.
if CommandLine.arguments.contains("--diagnose") {
    Diagnostics.run()
} else {
    LimitsApp.main()
}
