import Foundation
import Security

/// Holds one opaque credential per account for providers that expose no CLI
/// login to delegate to. The Keychain account is the app-owned `AccountID`,
/// never an email address or a provider-side identifier.
///
/// This is the only place Limits *writes* a secret, and it writes only what
/// the user explicitly pasted.
enum AccountSecretStore {
    static let service = "com.josephclarke.limits.account-credential"

    static func save(_ secret: String, for id: AccountID) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountIssue.noCredentialStored }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            // Readable only on this device while unlocked; never synced.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AccountIssue.other("Could not save the credential (OSStatus \(addStatus)).")
            }
            return
        }
        guard status == errSecSuccess else {
            throw AccountIssue.other("Could not update the credential (OSStatus \(status)).")
        }
    }

    static func load(for id: AccountID) -> String? {
        // This app wrote the item, so it is inside its own partition and the
        // read never prompts.
        KeychainRead.genericPassword(
            service: service,
            account: id.rawValue,
            interaction: .disallowed
        ).payload?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func delete(for id: AccountID) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.rawValue
        ] as CFDictionary)
    }
}
