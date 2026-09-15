import Foundation
import LocalAuthentication
import OSLog
import Security

/// Read-only Keychain access for credential discovery. Derived from the
/// TokenRemain project (Apache-2.0); see NOTICE.
enum KeychainRead {
    /// Whether this read may summon the system authorization dialog.
    /// Deliberately has no default value: a missing argument anywhere on the
    /// background refresh path should be a compile error, not a surprise popup.
    enum Interaction {
        /// Automatic refresh. Fails immediately when unauthorized so the
        /// caller can degrade silently.
        case disallowed
        /// Only for an explicit user action, such as tapping "Allow access".
        case allowed
    }

    struct Outcome: Sendable {
        let payload: String?
        let status: OSStatus

        /// The item exists but this process may not read it — a different
        /// situation from "no such credential" (`errSecItemNotFound`), and the
        /// two lead to different remedies in the UI.
        var needsAuthorization: Bool {
            status == errSecAuthFailed
                || status == errSecInteractionNotAllowed
                || status == errSecUserCanceled
        }
    }

    /// `SecKeychainSetUserInteractionAllowed` is a *process-wide* switch, so
    /// one thread restoring it would open the dialog gate for another thread's
    /// concurrent read. The whole set→read→restore must be serialized.
    static let interactionGate = NSLock()

    /// How long a silent read waits for the gate. Refreshes run concurrently
    /// and a read takes milliseconds, so they should wait for each other. But
    /// if the gate is held by an interactive read waiting on a human, waiting
    /// is pointless — time out and let the caller degrade.
    static let silentWaitLimit: TimeInterval = 0.5

    static func genericPassword(
        service: String,
        account: String? = nil,
        interaction: Interaction
    ) -> Outcome {
        read(query: query(service: service, account: account), interaction: interaction)
    }

    static func read(
        query: [String: Any],
        interaction: Interaction,
        gate: NSLock = interactionGate,
        waitLimit: TimeInterval = silentWaitLimit
    ) -> Outcome {
        switch interaction {
        case .allowed:
            gate.lock()
            defer { gate.unlock() }
            return outcome(systemCopy(query))

        case .disallowed:
            guard gate.lock(before: Date().addingTimeInterval(waitLimit)) else {
                return Outcome(payload: nil, status: errSecInteractionNotAllowed)
            }
            defer { gate.unlock() }

            var query = query
            // Data-protection items with a SecAccessControl honor this.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context

            // Legacy file-based keychain ACL prompts honor only the switch
            // below. Neither `kSecUseAuthenticationContext` nor
            // `kSecUseAuthenticationUIFail` stops them, and an unauthorized
            // read would otherwise *block until the user clicks* rather than
            // returning an error — so the fallback path would never run.
            // The deprecation warning here is kept on purpose: it is the
            // reminder that this needs a new answer if macOS drops the API.
            guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                return Outcome(payload: nil, status: errSecInteractionNotAllowed)
            }
            // Restoring to `true` unconditionally is correct: a GUI process
            // allows interaction by default, and the gate rules out nesting.
            defer {
                let restore = SecKeychainSetUserInteractionAllowed(true)
                if restore != errSecSuccess {
                    // Worse than it looks: every later interactive read in this
                    // process would silently fail. Log the code only, never the
                    // item's contents.
                    Logger(subsystem: "com.josephclarke.limits", category: "Keychain")
                        .error("failed to restore keychain interaction: OSStatus \(restore, privacy: .public)")
                }
            }
            return outcome(systemCopy(query))
        }
    }

    private static func query(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private static func systemCopy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    private static func outcome(_ result: (status: OSStatus, data: Data?)) -> Outcome {
        guard result.status == errSecSuccess,
              let data = result.data,
              let text = String(data: data, encoding: .utf8) else {
            return Outcome(payload: nil, status: result.status)
        }
        return Outcome(payload: text, status: result.status)
    }
}

/// A legacy `login.keychain` item carries a *partition list* alongside its
/// trusted-application list, and the partition check runs first. A CLI that
/// stores its secret through `/usr/bin/security` — which is how Claude Code
/// writes `Claude Code-credentials` — leaves the item stamped `apple-tool:`
/// and nothing else, so no GUI app is ever inside the partition. Granting
/// "Always Allow" only appends to the trusted-application list, which the
/// partition check never reaches.
///
/// So read through that same Apple tool: identical item, identical read-only
/// intent, the one path the partition admits. The gate below inspects ACL
/// metadata only — it never decrypts — so deciding whether to delegate cannot
/// itself raise a dialog.
extension KeychainRead {
    static let appleToolPath = "/usr/bin/security"
    static let appleToolPartition = "apple-tool:"

    static func genericPasswordViaAppleTool(
        service: String,
        account: String? = nil,
        timeout: TimeInterval = 8
    ) async -> Outcome {
        guard appleToolMayDecrypt(service: service, account: account) else {
            return Outcome(payload: nil, status: errSecInteractionNotAllowed)
        }
        var arguments = ["find-generic-password", "-w", "-s", service]
        if let account { arguments.append(contentsOf: ["-a", account]) }
        do {
            let data = try await ProcessRunner.run(appleToolPath, arguments: arguments, timeout: timeout)
            guard let payload = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
                return Outcome(payload: nil, status: errSecItemNotFound)
            }
            return Outcome(payload: payload, status: errSecSuccess)
        } catch {
            // Timeouts land here too, with the tool already killed. Report it
            // as "needs authorization" so callers keep their fallback.
            return Outcome(payload: nil, status: errSecInteractionNotAllowed)
        }
    }

    /// True only when this item's own ACL lets `/usr/bin/security` decrypt it,
    /// its partition list admits Apple tools, and the keychain is unlocked.
    /// All three are metadata reads, so none can prompt.
    static func appleToolMayDecrypt(service: String, account: String? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // A reference is metadata: unlike `kSecReturnData` it never asks
            // securityd to decrypt, so no authorization is evaluated here.
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var reference: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &reference) == errSecSuccess,
              let reference,
              CFGetTypeID(reference) == SecKeychainItemGetTypeID() else {
            return false
        }
        let item = unsafeBitCast(reference, to: SecKeychainItem.self)
        guard isUnlocked(item), let acls = accessControlList(of: item) else { return false }

        var decryptAllowed = false
        // An item with no partition ACL predates the mechanism and is
        // unrestricted by it.
        var partitionAllowed = true
        for acl in acls {
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            var applications: CFArray?
            var description: CFString?
            var promptSelector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &promptSelector) == errSecSuccess else {
                continue
            }
            if authorizations.contains(kSecACLAuthorizationPartitionID as String) {
                partitionAllowed = partitions(inACLDescription: description as String?)?
                    .contains(appleToolPartition) ?? false
                continue
            }
            guard authorizations.contains(kSecACLAuthorizationDecrypt as String)
                || authorizations.contains(kSecACLAuthorizationAny as String) else {
                continue
            }
            guard let trusted = applications as? [SecTrustedApplication] else {
                // A nil application list means any application may decrypt, in
                // which case the direct read already succeeded.
                decryptAllowed = true
                continue
            }
            if trusted.contains(where: isAppleTool) { decryptAllowed = true }
        }
        return decryptAllowed && partitionAllowed
    }

    /// A locked keychain makes `security` ask for the login password — exactly
    /// the dialog automatic refresh must never raise.
    private static func isUnlocked(_ item: SecKeychainItem) -> Bool {
        var keychain: SecKeychain?
        guard SecKeychainItemCopyKeychain(item, &keychain) == errSecSuccess, let keychain else {
            return false
        }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return false }
        return status & kSecUnlockStateStatus != 0
    }

    private static func accessControlList(of item: SecKeychainItem) -> [SecACL]? {
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else { return nil }
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess else { return nil }
        return list as? [SecACL]
    }

    /// The partition ACL keeps its plist in the ACL description, hex-encoded
    /// on current macOS. Accept the plain form too rather than relying on that.
    static func partitions(inACLDescription description: String?) -> [String]? {
        guard let description, !description.isEmpty else { return nil }
        for data in [hexDecoded(description), Data(description.utf8)].compactMap({ $0 }) {
            guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any] else { continue }
            if let partitions = plist["Partitions"] as? [String] { return partitions }
        }
        return nil
    }

    private static func hexDecoded(_ text: String) -> Data? {
        guard text.count % 2 == 0, !text.isEmpty else { return nil }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            guard let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
                  let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func isAppleTool(_ application: SecTrustedApplication) -> Bool {
        var data: CFData?
        guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess,
              let data = data as Data? else { return false }
        return String(data: data, encoding: .utf8)?.contains(appleToolPath) ?? false
    }
}
