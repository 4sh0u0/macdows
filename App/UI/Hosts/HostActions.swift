import Foundation
import MacdowsCore

/// UI slice ① (ADR-0024 D-3 / D-6, UI-1 spec §5.1 ④ / §5.3): the host operations that touch the
/// keychain, kept out of the views so they can be driven offline with the store doubles. Every
/// `nonisolated` method here may block (the file-based keychain can show an authorisation
/// prompt, ADR-0024 probe K) and is called on `KeychainQueue`, never on the main thread.
struct HostActions: Sendable {
    let credentials: any CredentialStore
    let pins: any PinStore

    /// Which keychain step of a Remove failed (the record is then left in place).
    enum RemoveFailure: Error, Equatable {
        case pin(status: Int32)
        case credential(status: Int32)
    }

    /// Remove…, keychain half (UI-1 spec §5.1 ④, ADR-0024 D-3): the pin item first, then the
    /// credential; the first failure stops the sequence. The caller removes the record only on
    /// success, so a failed Remove never leaves a record-less pin or password behind.
    nonisolated func removeKeychainItems(for host: HostID) -> Result<Void, RemoveFailure> {
        do {
            try pins.delete(for: host)
        } catch let error as PinStoreError {
            if case .writeFailed(let status) = error { return .failure(.pin(status: status)) }
            if case .unreadable(let status) = error { return .failure(.pin(status: status)) }
            return .failure(.pin(status: -1))
        } catch {
            return .failure(.pin(status: -1))
        }
        do {
            try credentials.delete(for: host)
        } catch let error as KeychainItems.WriteError {
            return .failure(.credential(status: error.status))
        } catch {
            return .failure(.credential(status: -1))
        }
        return .success(())
    }

    /// What the Host Editor asks the keychain to do on Save.
    struct EditorChanges: Sendable {
        var host: HostID
        var displayName: String
        /// The password typed in this sheet, if any (nil = keep whatever is saved).
        var newPassword: SessionSecret?
        var remember: Bool
        /// `.some(x)` = set the preset to x (nil clears it); `.none` = unchanged.
        var expected: CertificateFingerprint??
    }

    struct EditorFailures: Error, Equatable {
        var credentialStatus: Int32?
        var presetStatus: Int32?
        var isEmpty: Bool { credentialStatus == nil && presetStatus == nil }
    }

    /// Save, keychain half. Remember off deletes a saved password (UI-1 spec §5.1 ②); a new
    /// password with Remember on replaces it. The preset is written through `setExpected`, which
    /// never touches the pin (§5.3). The typed password is wiped before this returns.
    nonisolated func applyEditorChanges(_ changes: EditorChanges) -> EditorFailures {
        var failures = EditorFailures()
        defer { changes.newPassword?.wipe() }
        do {
            if changes.remember {
                if let password = changes.newPassword, !password.isEmpty {
                    try credentials.save(password, for: changes.host, displayName: changes.displayName)
                }
            } else {
                try credentials.delete(for: changes.host)
            }
        } catch let error as KeychainItems.WriteError {
            failures.credentialStatus = error.status
        } catch {
            failures.credentialStatus = -1
        }
        if case .some(let expected) = changes.expected {
            do {
                try pins.setExpected(expected, for: changes.host, displayName: changes.displayName)
            } catch let error as PinStoreError {
                switch error {
                case .unreadable(let status), .writeFailed(let status): failures.presetStatus = status
                }
            } catch {
                failures.presetStatus = -1
            }
        }
        return failures
    }

    /// Reset All Pins, keychain half (ADR-0024 D-6, E-a: presets are kept). The caller then calls
    /// `HostRecordStore.noteAllPinsReset()`.
    nonisolated func resetAllPins(displayNames: [HostID: String]) throws -> [HostID] {
        try pins.resetAllPins(displayName: { displayNames[$0] ?? "" })
    }

    /// Gate r1 m-11: the record's Remember bit after an editor Save -- what the detail then shows
    /// as "Saved in Keychain" or "Asked for on each connection". True only when this Save knows a
    /// password is in the keychain: Remember is on, the credential step did not fail, and either a
    /// password was typed (and saved) or one was already remembered. Remember on with nothing typed
    /// on a host that had no saved password stays "asked each time".
    static func remembersPassword(remember: Bool, typedPassword: Bool, wasRemembering: Bool, credentialFailed: Bool) -> Bool {
        guard remember, !credentialFailed else { return false }
        return typedPassword || wasRemembering
    }

    /// The preset currently stored for a host, for the editor (nil on any failure: the field is
    /// then shown empty and Save leaves the preset alone unless the user types one).
    nonisolated func storedPreset(for host: HostID) -> PinReadResult {
        pins.read(for: host)
    }
}

/// The main-actor halves.
@MainActor
enum HostOperations {
    /// Remove…: keychain items off the main thread, then the record.
    static func remove(_ host: HostID, actions: HostActions, store: HostRecordStore) async -> HostActions.RemoveFailure? {
        let result = await KeychainQueue.run { actions.removeKeychainItems(for: host) }
        switch result {
        case .success:
            store.remove(host)
            return nil
        case .failure(let failure):
            return failure
        }
    }

    /// Reset All Pins: keychain off the main thread, then every record unpinned with a log row.
    static func resetAllPins(actions: HostActions, store: HostRecordStore) async throws -> [HostID] {
        let names = Dictionary(uniqueKeysWithValues: store.records.map { ($0.id, $0.title) })
        let cleared = try await KeychainQueue.runThrowing { try actions.resetAllPins(displayNames: names) }
        store.noteAllPinsReset()
        return cleared
    }
}
