import Foundation

/// ADR-0024 D-2 (P-b): the password of ONE connection chain, held as bytes that are overwritten
/// when the holder is done with them -- never as a `String` kept for the chain's lifetime.
///
/// Lifetime. The App fetches the password once per chain (the keychain or the Password sheet),
/// into a `SessionSecret`, and hands the bytes to `CRSession` through `withUnsafeData(_:)`. The
/// bridge copies them into its own buffer for the life of that `CRSession` -- the chain, which
/// spans every automatic reconnect and the re-`-start` after a certificate confirmation -- and
/// overwrites that copy in `-dealloc`; this object is wiped as soon as the hand-over is done
/// (`wipe()`), and again in `deinit` in case a path forgot.
///
/// What this does NOT promise (ADR-0024 RK-1): the `String` an `NSSecureTextField` returns, the
/// keychain framework's own buffers and any `CFData` in between cannot be overwritten by this App.
/// The byte buffer is the part this App controls, and only that part is wiped.
final class SessionSecret: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]
    private(set) var isWiped = false

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Copies `data` into a new secret. The caller still owns (and should drop) `data`.
    convenience init(copying data: Data) {
        self.init(bytes: [UInt8](data))
    }

    deinit {
        wipe()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes.count
    }

    var isEmpty: Bool { count == 0 }

    /// Runs `body` with a `Data` that views this secret's bytes without copying them. The `Data`
    /// must not escape `body` (it does not own its storage).
    func withUnsafeData<R>(_ body: (Data) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else {
                return try body(Data())
            }
            return try body(Data(bytesNoCopy: base, count: raw.count, deallocator: .none))
        }
    }

    /// Overwrites every byte with zero (through `memset_s`, which the compiler may not elide) and
    /// empties the buffer. Idempotent.
    func wipe() {
        lock.lock(); defer { lock.unlock() }
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress, raw.count > 0 {
                _ = memset_s(base, raw.count, 0, raw.count)
            }
        }
        bytes.removeAll()
        isWiped = true
    }
}
