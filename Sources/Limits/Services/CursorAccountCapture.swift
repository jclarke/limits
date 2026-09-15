import Foundation

/// Saves a copy of the Cursor session its CLI just produced, so Limits can
/// keep showing an account after Cursor has moved on to another one.
///
/// Cursor stores exactly one credential, under fixed `cursor-access-token` /
/// `cursor-refresh-token` Keychain identities with nothing account-specific in
/// them, so signing in a second account replaces the first. Copying the
/// session into Limits' own Keychain item is the only way both can be shown.
///
/// This is the one place Limits keeps a provider credential it was not handed
/// directly, so it is strictly opt-in: it runs only when the user asks to add
/// an account, never during a refresh.
enum CursorAccountCapture {
    struct Identity: Sendable {
        let token: String
        /// Stable per-account id from the session JWT, used to tell captured
        /// accounts apart and to notice when one is simply the account Cursor
        /// is currently signed into.
        let subject: String
        let email: String?
        let expiry: Date?

        var suggestedName: String {
            if let email, !email.isEmpty { return email }
            return "Cursor account"
        }
    }

    /// Reads the account the `cursor-agent` CLI holds — the one a new sign-in
    /// is about to replace. The editor's credential is separate and survives.
    static func currentCLIIdentity() async -> Identity? {
        let accounts = await CursorAuthReader().loadAll()
        guard let auth = accounts.last, let subject = auth.subject else { return nil }
        return Identity(
            token: auth.accessToken,
            subject: subject,
            email: auth.email,
            expiry: auth.expiry
        )
    }

    /// True when a session has enough life left to be worth saving. A token
    /// about to lapse would become a broken row within the hour.
    static func isWorthCapturing(_ identity: Identity, now: Date = .now) -> Bool {
        guard let expiry = identity.expiry else { return true }
        return expiry.timeIntervalSince(now) > 24 * 3600
    }
}
