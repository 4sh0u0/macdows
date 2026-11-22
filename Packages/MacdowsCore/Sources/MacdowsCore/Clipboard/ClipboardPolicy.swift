// Clipboard T1 (plain text, both directions, plus an explicit off): the pure policy layer.
//
// Owner rulings of 2026-11-17: T1 plus an off switch (D1 = A); on by default, both
// directions, one master switch (D2 = A); a global setting (D4 = A). The detailed semantics
// this file implements are the controller's proposed table S1-S9
// (`design-clipboard-audio/t1-semantics-proposed.md`), which adr/0026 (PROPOSED) records.
// Nothing here reads a clock, a pasteboard, a setting or any other global state, and nothing
// here logs: every input is a parameter, every output a value.

/// Windows clipboard format numbers the T1 logic names. Only CF_UNICODETEXT appears: T1
/// moves nothing else. FreeRDP's clipboard feature-mask values deliberately do NOT appear in
/// this package (S1): mapping `ClipboardPolicy` onto them is the bridge's job, in C, with
/// FreeRDP's own macros, so a renumbering upstream can never be silently mirrored wrong here.
public enum ClipboardFormat {
    /// `CF_UNICODETEXT` (winuser.h): NUL-terminated UTF-16LE text. T1's only wire format.
    public static let unicodeText: UInt32 = 13
}

/// S6: the byte limits, one per direction. Exceeding a limit refuses the transfer; nothing is
/// ever truncated (a truncated text pasted elsewhere looks complete, which is worse than a
/// paste that visibly did not happen).
///
/// Both limits count UTF-16LE bytes INCLUDING the terminating NUL code unit -- the same bytes
/// that cross the wire -- so "exactly at the limit" means an encoded payload whose length,
/// NUL included, equals the limit.
public struct ClipboardLimits: Equatable, Sendable {
    /// The one place the S6 number lives (4 MiB = 4 x 1024 x 1024 bytes). adr/0026's review may
    /// move it. The C store (`crdpq_clip_store_create`) deliberately has no copy of it: the
    /// bridge is meant to create the store from this value, so the number exists only here.
    public static let defaultMaxBytes: Int = 4 * 1024 * 1024

    /// Windows -> Mac: the most bytes a Format Data Response may carry and still be written.
    public let remoteToLocalMaxBytes: Int
    /// Mac -> Windows: the most bytes an encoded answer may have and still be sent.
    public let localToRemoteMaxBytes: Int

    public init(remoteToLocalMaxBytes: Int = ClipboardLimits.defaultMaxBytes,
                localToRemoteMaxBytes: Int = ClipboardLimits.defaultMaxBytes) {
        self.remoteToLocalMaxBytes = remoteToLocalMaxBytes
        self.localToRemoteMaxBytes = localToRemoteMaxBytes
    }

    /// Both directions at `defaultMaxBytes`.
    public static let standard = ClipboardLimits()

    /// Whether `byteCount` bytes received from Windows are within the limit.
    public func admitsRemoteToLocal(byteCount: Int) -> Bool {
        byteCount <= remoteToLocalMaxBytes
    }

    /// Whether `byteCount` encoded bytes bound for Windows are within the limit.
    public func admitsLocalToRemote(byteCount: Int) -> Bool {
        byteCount <= localToRemoteMaxBytes
    }
}

/// S1: the five clipboard modes. Raw values are fixed (the bridge's own mode enum must use the
/// same numbers); `unmanaged` is 0 so a zero-initialized setting means "behave as before
/// clipboard support existed".
public enum ClipboardMode: Int, CaseIterable, Sendable {
    /// Today's wiring, untouched: no clipboard setting is written and no callback is installed,
    /// so whatever FreeRDP does by default still happens. For tools such as window-smoke.
    case unmanaged = 0
    /// Explicitly off: the channel is not loaded at all.
    case off = 1
    /// Plain text both ways.
    case bidirectional = 2
    /// Windows -> Mac only. Reserved in the model and the bridge; not exposed in the UI (D2).
    case remoteToLocalOnly = 3
    /// Mac -> Windows only. Reserved in the model and the bridge; not exposed in the UI (D2).
    case localToRemoteOnly = 4

    /// The App exposes one master switch (D2 = A): on is `bidirectional`, off is `off`.
    public static func forUserSetting(enabled: Bool) -> ClipboardMode {
        enabled ? .bidirectional : .off
    }
}

/// S1's first question: what the bridge does with the channel-loading setting at connect time.
public enum ClipboardChannelSetting: Equatable, Sendable {
    /// Write nothing; leave FreeRDP's default in force (`unmanaged`).
    case leaveDefault
    /// Load the channel (`RedirectClipboard = TRUE` plus the direction mask).
    case load
    /// Do not load the channel (`RedirectClipboard = FALSE`).
    case doNotLoad
}

/// S1's four answers for one mode, plus the S6 limits every decision in this directory takes.
/// Read once per connection, like every other per-connection setting.
public struct ClipboardPolicy: Equatable, Sendable {
    public let mode: ClipboardMode
    public let limits: ClipboardLimits

    public init(mode: ClipboardMode, limits: ClipboardLimits = .standard) {
        self.mode = mode
        self.limits = limits
    }

    /// Whether, and how, the bridge touches the channel-loading setting.
    public var channelSetting: ClipboardChannelSetting {
        switch mode {
        case .unmanaged: .leaveDefault
        case .off: .doNotLoad
        case .bidirectional, .remoteToLocalOnly, .localToRemoteOnly: .load
        }
    }

    /// Whether Mac text may go to Windows (announce, and answer a data request).
    public var allowsLocalToRemote: Bool {
        switch mode {
        case .bidirectional, .localToRemoteOnly: true
        case .unmanaged, .off, .remoteToLocalOnly: false
        }
    }

    /// Whether Windows text may come to the Mac (request, and write what arrives).
    public var allowsRemoteToLocal: Bool {
        switch mode {
        case .bidirectional, .remoteToLocalOnly: true
        case .unmanaged, .off, .localToRemoteOnly: false
        }
    }

    /// Whether the bridge installs its cliprdr callbacks. Exactly the modes that load the
    /// channel: `unmanaged` keeps today's "loaded by default, nobody listening" state on
    /// purpose, and `off` has no channel to listen to.
    public var installsCallbacks: Bool {
        switch mode {
        case .bidirectional, .remoteToLocalOnly, .localToRemoteOnly: true
        case .unmanaged, .off: false
        }
    }
}
