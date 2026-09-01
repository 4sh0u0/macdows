import Foundation
@testable import ReplayDiffKit

/// Hand-built `rail-probe`-shaped JSONL used by every suite in this target.
///
/// Synthetic on purpose, and synthetic *here* on purpose: M1 wave-1 ruling U7 freezes
/// `samples/phase05-rail-events-2026-08-19` byte-for-byte, because that directory is what
/// the upgrade gate diffs against. Fixtures live under `Tests/`, never under `samples/`.
///
/// Every field name and type matches `RailEvent`'s payload structs, so these lines decode
/// through MacdowsCore's real parser rather than through a lenient stand-in. No value here
/// resembles a host address, host name, user name or credential — a window title of
/// "Fixture Window" is the most identifying string in the file, by design.
enum CaptureFixture {
    /// Index into ``baseline`` for the lines individual tests mutate. 0-based array index,
    /// so `line N` in a diff report is `index N-1` here.
    enum Line: Int {
        case preConnect = 0
        case postConnect = 1
        case channelConnected = 2
        case windowCreate = 3
        case gfxMapSurfaceToWindow = 4
        case monitoredDesktop = 5
        case postDisconnect = 6
    }

    /// A seven-line capture covering the shapes the differ has to reason about: envelope-
    /// only events, a string-payload event, a wide `WindowCreate` (the identity + geometry
    /// case), an RDPGFX event on a *different* thread (the cross-channel interleave the
    /// order tolerance exists for), and an event that references a window without owning
    /// it (`MonitoredDesktop.activeWindowId`, same identifier namespace as `windowId`).
    static let baseline: [String] = [
        #"{"t_ms":0,"tid":"0x1f6be3540","ev":"PreConnect"}"#,
        #"{"t_ms":218,"tid":"0x1f6be3540","ev":"PostConnect"}"#,
        #"{"t_ms":220,"tid":"0x1f6be3540","ev":"ChannelConnected","name":"rdpdr"}"#,
        #"{"t_ms":900,"tid":"0x1f6be3540","ev":"WindowCreate","windowId":65832,"fieldFlags":13567,"windowOffsetX":100,"windowOffsetY":120,"windowWidth":800,"windowHeight":600,"numVisibilityRects":1,"style":382664704,"styleEx":256,"show":5,"title":"Fixture Window"}"#,
        #"{"t_ms":905,"tid":"0x2f6be3540","ev":"GfxMapSurfaceToWindow","surfaceId":1,"windowId":65832,"mappedWidth":800,"mappedHeight":600}"#,
        #"{"t_ms":950,"tid":"0x1f6be3540","ev":"MonitoredDesktop","fieldFlags":2,"activeWindowId":65832,"numWindowIds":1}"#,
        #"{"t_ms":2000,"tid":"0x1f6be3540","ev":"PostDisconnect"}"#,
    ]

    /// A `GfxMapSurfaceToScaledWindow` line — the F-1 event. Uses the *same* `surfaceId`
    /// as the plain map above so that inserting it cannot perturb the `surface` namespace's
    /// first-appearance ordinals, which would turn this into a field-difference test by
    /// accident. (That coupling is a documented property of identifier canonicalization,
    /// see ``SemanticDiffer``'s "known limitation" note.)
    static func scaledMapLine(tMs: Int, targetWidth: Int, targetHeight: Int) -> String {
        """
        {"t_ms":\(tMs),"tid":"0x2f6be3540","ev":"GfxMapSurfaceToScaledWindow",\
        "surfaceId":1,"windowId":65832,"mappedWidth":800,"mappedHeight":600,\
        "targetWidth":\(targetWidth),"targetHeight":\(targetHeight)}
        """
    }

    static let windowDeleteLine = #"{"t_ms":1900,"tid":"0x1f6be3540","ev":"WindowDelete","windowId":65832}"#

    /// Six lines, **all on the main RAIL lane** (one tid) — the shape round-1 review used to
    /// show that a global-only order tolerance swallows a same-thread causal inversion.
    /// `WindowIcon` and `MonitoredDesktop` both reference the window `WindowCreate` opens,
    /// so moving `WindowCreate` after them is causally impossible, not interleaving noise.
    enum MainLaneLine: Int {
        case preConnect = 0
        case postConnect = 1
        case windowCreate = 2
        case windowIcon = 3
        case monitoredDesktop = 4
        case postDisconnect = 5
    }

    static let mainLaneOnly: [String] = [
        #"{"t_ms":0,"tid":"0x1f6be3540","ev":"PreConnect"}"#,
        #"{"t_ms":10,"tid":"0x1f6be3540","ev":"PostConnect"}"#,
        #"{"t_ms":20,"tid":"0x1f6be3540","ev":"WindowCreate","windowId":65832,"fieldFlags":13567,"windowOffsetX":100,"windowOffsetY":120,"windowWidth":800,"windowHeight":600,"numVisibilityRects":1,"style":382664704,"styleEx":256,"show":5,"title":"Fixture Window"}"#,
        #"{"t_ms":30,"tid":"0x1f6be3540","ev":"WindowIcon","windowId":65832}"#,
        #"{"t_ms":40,"tid":"0x1f6be3540","ev":"MonitoredDesktop","fieldFlags":2,"activeWindowId":65832,"numWindowIds":1}"#,
        #"{"t_ms":50,"tid":"0x1f6be3540","ev":"PostDisconnect"}"#,
    ]

    // MARK: - Building streams

    static func stream(_ lines: [String], label: String) -> ReplayStream {
        ReplayStream.parse(contents: lines.joined(separator: "\n") + "\n", label: label)
    }

    static func baselineStream(label: String = "fixture-baseline") -> ReplayStream {
        stream(baseline, label: label)
    }

    // MARK: - Mutations

    /// Replaces every `t_ms` value and every `tid` value. Structure-preserving: no field is
    /// added, removed or reordered, and no non-timing value changes.
    static func perturbTimestampsAndThreadIds(_ lines: [String]) -> [String] {
        lines.enumerated().map { index, line in
            var mutated = replaceNumber(in: line, key: "t_ms", with: (index + 1) * 137 + 11)
            mutated = replaceString(in: mutated, key: "tid", with: "0x7ffabc\(String(format: "%03d", index))")
            return mutated
        }
    }

    /// Swaps two adjacent lines.
    static func swapping(_ lines: [String], _ first: Line, _ second: Line) -> [String] {
        var mutated = lines
        mutated.swapAt(first.rawValue, second.rawValue)
        return mutated
    }

    /// Moves one line to a new index, shifting everything in between.
    static func moving(_ lines: [String], _ from: Line, toIndex: Int) -> [String] {
        moving(lines, index: from.rawValue, toIndex: toIndex)
    }

    /// Index-based counterpart, for fixtures that do not use the ``Line`` enum.
    static func moving(_ lines: [String], index: Int, toIndex: Int) -> [String] {
        var mutated = lines
        let line = mutated.remove(at: index)
        mutated.insert(line, at: toIndex)
        return mutated
    }

    static func inserting(_ lines: [String], _ newLines: [String], atIndex index: Int) -> [String] {
        var mutated = lines
        mutated.insert(contentsOf: newLines, at: index)
        return mutated
    }

    /// Changes a single integer field on a single line.
    static func changingNumber(_ lines: [String], on line: Line, key: String, to value: Int) -> [String] {
        var mutated = lines
        mutated[line.rawValue] = replaceNumber(in: mutated[line.rawValue], key: key, with: value)
        return mutated
    }

    /// Appends a new integer key to a single line, which is what a probe upgrade looks
    /// like under adr/0008 §5's append-only field rule. Used for the presence-vs-value
    /// distinction; *adding* rather than removing, because every field the baseline
    /// already carries is a required field of `RailEvent`'s payload structs, so deleting
    /// one would produce a parse failure rather than an absent field.
    static func addingNumber(_ lines: [String], on line: Line, key: String, value: Int) -> [String] {
        var mutated = lines
        let original = mutated[line.rawValue]
        precondition(original.hasSuffix("}"), "fixture line must end with '}'")
        mutated[line.rawValue] = String(original.dropLast()) + ",\"\(key)\":\(value)}"
        return mutated
    }

    // MARK: - Primitive line editing
    //
    // Regex over the fixture text rather than a JSON round-trip: a round-trip through
    // JSONSerialization would reorder keys and reformat numbers, which would make every
    // mutation look like a whole-line rewrite when a test fails and someone prints it.

    private static func replaceNumber(in line: String, key: String, with value: Int) -> String {
        line.replacingOccurrences(
            of: "\"\(key)\":-?[0-9]+",
            with: "\"\(key)\":\(value)",
            options: .regularExpression
        )
    }

    private static func replaceString(in line: String, key: String, with value: String) -> String {
        line.replacingOccurrences(
            of: "\"\(key)\":\"[^\"]*\"",
            with: "\"\(key)\":\"\(value)\"",
            options: .regularExpression
        )
    }
}
