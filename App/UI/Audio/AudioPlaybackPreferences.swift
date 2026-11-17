import Combine
import Foundation

/// adr/0026 (proposed) lane L1 (owner rulings D3 = A and D4 = A of 2026-11-17): the App's one audio
/// preference -- "Play remote audio on this Mac", one `UserDefaults` key, ON by default, global
/// (not per host) -- and what it means for the next connection. Playback only; there is no
/// microphone preference because no connection ever enables the microphone (`CRAudioPlaybackMode`).
///
/// Lives here and not in `App/UI/Settings/` for the reason `StartPanelPreferences` does (owner
/// ruling §10-7): the Settings files keep no settings and touch no persistence API
/// (`SettingsWindowTests` pins that); the General page renders this object and calls its setter.
///
/// `AppDelegate` reads `sessionMode` at every session start and again before every automatic
/// reconnect, so a change applies at the next connection -- a reconnect included -- and a
/// connected session keeps the mode it connected with (no switch mid-session; the page's note says
/// so).
@MainActor
final class AudioPlaybackPreferences: ObservableObject {
    /// The one key. A defaults domain without it -- every install from before this preference
    /// existed -- reads as the default.
    nonisolated static let playOnThisMacKey = "audioPlayback.playOnThisMac"
    /// D3 = A: on.
    nonisolated static let playOnThisMacDefault = true

    /// The App's instance, on the standard defaults.
    static let shared = AudioPlaybackPreferences()

    @Published private(set) var playOnThisMac: Bool

    private let defaults: UserDefaults

    /// Tests pass their own suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playOnThisMac = Self.storedValue(in: defaults)
    }

    /// The Settings checkbox.
    func setPlayOnThisMac(_ on: Bool) {
        playOnThisMac = on
        defaults.set(on, forKey: Self.playOnThisMacKey)
    }

    /// What the next `CRSession` is given (see `sessionMode(playOnThisMac:)`).
    var sessionMode: CRAudioPlaybackMode { Self.sessionMode(playOnThisMac: playOnThisMac) }

    /// On -> `.on`, off -> `.off`. The App never hands a session `.unmanaged`: that value is the
    /// bridge's default for the harnesses, which never set it.
    nonisolated static func sessionMode(playOnThisMac: Bool) -> CRAudioPlaybackMode {
        playOnThisMac ? .on : .off
    }

    /// The key absent -> the default; present -> `UserDefaults`' own Boolean reading of it.
    nonisolated static func storedValue(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: playOnThisMacKey) == nil ? playOnThisMacDefault : defaults.bool(forKey: playOnThisMacKey)
    }
}
