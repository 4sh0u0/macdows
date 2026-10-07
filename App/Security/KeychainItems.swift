import Foundation
import Security

/// ADR-0024 D-1 (C-a + S-b): the generic-password item operations both stores use, in one place.
///
/// - Class `kSecClassGenericPassword`; `kSecAttrService` names the store (`<bundle-id>.rdp`,
///   `<bundle-id>.cert-pin`, or a test service ending in `.test`); `kSecAttrAccount` is the host's
///   UUID; `kSecAttrLabel` is "Macdows — <display name>" so the item is recognisable in Keychain
///   Access.
/// - `kSecAttrSynchronizable` is explicitly false on every query: nothing goes to iCloud Keychain.
/// - S-b, the file-based login keychain: `kSecUseDataProtectionKeychain` is NOT set. ADR-0024
///   probe K (ad-hoc half, 2026-10-06) measured the data-protection keychain refusing an ad-hoc
///   build with errSecMissingEntitlement (-34018), so S-a waits for the maintainer-signed half of
///   the probe and Phase 4 signing.
/// - Every call can block: on S-b a read from a binary the item's ACL does not trust shows a
///   system authorisation prompt and blocks the calling thread until it is answered (probe K: a
///   no-UI `LAContext` does not turn that into errSecInteractionNotAllowed). Callers therefore
///   never call these on the main thread, and the App's call sites go through `KeychainQueue`.
/// - The query dictionaries and the status-to-result mapping are separate, pure, internal
///   functions (`readQuery` / `baseQuery` / `classify`) so their shape is pinned offline (gate r1
///   I-1): a read that FAILED must never become "not found", and no query may turn on iCloud sync,
///   the data-protection keychain or an access-control object.
enum KeychainItems {
    /// A read's three outcomes (ADR-0024 D-3′: a failed read is NOT a missing item).
    enum ReadResult: Equatable {
        case found(Data)
        /// errSecItemNotFound, and only that.
        case notFound
        /// Any other status (ACL refusal, errSecInteractionNotAllowed, errSecUserCanceled, ...).
        case failed(OSStatus)
    }

    struct WriteError: Error, Equatable {
        let status: OSStatus
    }

    static func baseQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// The one-item data read: the base query plus "return the data, at most one item".
    static func readQuery(service: String, account: String) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    /// ADR-0024 D-3′: `errSecItemNotFound` -- and only that -- is "not found"; success without a
    /// `Data` payload is `errSecDecode`; every other status is a failure the caller must not read
    /// as "no item".
    static func classify(status: OSStatus, data: CFTypeRef?) -> ReadResult {
        switch status {
        case errSecSuccess:
            guard let data = data as? Data else { return .failed(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    static func read(service: String, account: String) -> ReadResult {
        var out: CFTypeRef?
        let status = SecItemCopyMatching(readQuery(service: service, account: account) as CFDictionary, &out)
        return classify(status: status, data: out)
    }

    /// Adds the item, or updates its data and label when it already exists.
    static func upsert(service: String, account: String, label: String, data: Data) throws {
        var add = baseQuery(service: service, account: account)
        add[kSecAttrLabel as String] = label
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw WriteError(status: status) }
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        let updated = SecItemUpdate(baseQuery(service: service, account: account) as CFDictionary, update as CFDictionary)
        guard updated == errSecSuccess else { throw WriteError(status: updated) }
    }

    /// Deletes the item. A missing item is success (the state asked for already holds).
    static func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WriteError(status: status) }
    }

    /// Every account that has an item under `service` (attributes only, no data, so no item's
    /// secret is read). A failed enumeration throws.
    static func accounts(service: String) throws -> [String] {
        var query = baseQuery(service: service, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw WriteError(status: status) }
        let rows = (out as? [[String: Any]]) ?? []
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// The `kSecAttrLabel` of a host's items.
    static func label(displayName: String) -> String {
        "Macdows — \(displayName)"
    }

    /// `<bundle-id>.<suffix>`; the bundle id falls back to the App's when there is none (tools).
    static func service(suffix: String) -> String {
        "\(Bundle.main.bundleIdentifier ?? "dev.haru.macdows").\(suffix)"
    }
}

/// Gate r1 m-5: the ONE serial queue every keychain call of the App runs on.
///
/// A keychain call can block for as long as a system authorisation prompt stays unanswered
/// (ADR-0024 probe K). Run inside `Task.detached` such a call holds a thread of Swift's
/// cooperative pool for that whole time, and a preflight, an Edit Host… read and a Show… read
/// waiting on prompts at once could take the pool down to nothing. Here the awaiting task is
/// suspended (it holds no thread), the blocked call holds this queue's own thread, and the calls
/// run one at a time -- so at most one prompt is ever on screen, in the order the user caused them.
enum KeychainQueue {
    static let queue = DispatchQueue(label: "dev.haru.macdows.keychain", qos: .userInitiated)

    /// Runs `body` on `queue` and resumes the caller with its result.
    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// `run(_:)` for a throwing body.
    static func runThrowing<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
