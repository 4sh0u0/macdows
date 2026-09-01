import Foundation
import Testing
@testable import ReplayDiffKit

/// Round-2 finding **N-3**: the previous "this partition cannot silently rot when a probe
/// build adds an event" claim was false. `laneDerivationMatchesThreadIds` reads only the six
/// frozen captures, and U7 freezes them — so an event a future probe adds can never appear
/// in that test's input, and it could never fail for that reason. The guard protected
/// against the one thing that cannot happen.
///
/// What holds the line instead is that ``EventLane/mainLaneEventNames`` is an **allow-list**
/// with no `return .main` fall-through: an unlisted, non-`Gfx*`, non-`Server*` name resolves
/// to ``EventLane/ambiguous`` and is exempt from the within-lane check until someone measures
/// its thread. This suite pins that, in both directions and behaviourally.
@Suite("L5-8 the lane allow-list, and what happens to a name it has not seen")
struct LaneAllowListTests {
    // MARK: - The allow-list is honest in both directions

    /// Every name in the allow-list must be one MacdowsCore actually models. Catches typos
    /// and entries left behind by a rename — a misspelt name would silently never match and
    /// its real events would fall to `ambiguous`, quietly losing coverage.
    @Test("every allow-listed name is an event MacdowsCore models", arguments: EventLane.mainLaneEventNames.sorted())
    func allowListedNamesAreModelled(name: String) throws {
        let line = try #require(Self.minimalLine(for: name), "no minimal fixture line for \(name)")
        let stream = ReplayStream.parse(contents: line + "\n", label: name)
        #expect(stream.parseFailures.isEmpty, "\(name): \(stream.parseFailures)")
        let record = try #require(stream.records.first)
        #expect(record.eventName == name)
        #expect(record.isModelled, "\(name) is not modelled by MacdowsCore — stale allow-list entry")
        #expect(EventLane.lane(forEventName: name, isModelled: record.isModelled) == .main)
    }

    /// ...and every main-lane name actually present in the frozen captures must be in the
    /// list, or measured traffic would be silently demoted to `ambiguous` and lose its
    /// causal-order check.
    @Test("every main-lane name observed in the frozen captures is allow-listed")
    func observedMainLaneNamesAreAllowListed() throws {
        var observed = Set<String>()
        for name in PhaseSamples.names {
            let url = try #require(PhaseSamples.url(named: name))
            for record in try ReplayStream.parse(fileAt: url).records {
                guard !EventLane.ambiguousEventNames.contains(record.eventName),
                      !record.eventName.hasPrefix("Gfx"),
                      !record.eventName.hasPrefix("Server")
                else { continue }
                observed.insert(record.eventName)
            }
        }
        #expect(observed.count == 17, "expected 17 measured main-lane names, saw \(observed.count)")
        #expect(
            observed.subtracting(EventLane.mainLaneEventNames).isEmpty,
            "measured but not allow-listed: \(observed.subtracting(EventLane.mainLaneEventNames).sorted())"
        )
    }

    // MARK: - A modelled name the list has not seen

    /// The case the false claim was about, made real. `WindowDelete` is modelled by
    /// MacdowsCore and occurs **zero** times in the frozen captures — exactly the shape of a
    /// name a future probe build would add. It must resolve to `ambiguous`, not be swept
    /// into `main` on an assumption.
    @Test("a modelled name that is not allow-listed resolves to ambiguous")
    func unlistedModelledNameIsAmbiguous() throws {
        let line = #"{"t_ms":1,"tid":"0x1f6be3540","ev":"WindowDelete","windowId":65832}"#
        let stream = ReplayStream.parse(contents: line + "\n", label: "delete")
        let record = try #require(stream.records.first)
        #expect(record.isModelled, "fixture assumption broken: WindowDelete must be modelled")
        #expect(!EventLane.mainLaneEventNames.contains("WindowDelete"))
        #expect(EventLane.lane(forEventName: "WindowDelete", isModelled: true) == .ambiguous)
    }

    /// Behaviourally: moving that unlisted-but-modelled event within what *would* be the
    /// main lane manufactures no within-lane finding.
    @Test("moving an unlisted modelled event manufactures no within-lane finding")
    func unlistedModelledNameIsExemptFromTheLaneCheck() {
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(Self.withUnlistedEvent, label: "with-delete"),
            candidate: CaptureFixture.stream(
                CaptureFixture.moving(Self.withUnlistedEvent, index: 3, toIndex: 1),
                label: "delete-moved"
            )
        )
        #expect(report.differences.isEmpty, "unexpected: \(report.differences)")
    }

    /// The counterfactual that proves the exemption is load-bearing: the identical movement
    /// of an *allow-listed* main-lane event with the same payload shape (`WindowIcon`, also
    /// `{windowId}`) does fire.
    @Test("the same movement of an allow-listed event IS reported")
    func sameMovementOfAnAllowListedEventIsReported() {
        let listedVariant = Self.withUnlistedEvent.map {
            $0.replacingOccurrences(of: #""ev":"WindowDelete""#, with: #""ev":"WindowCachedIcon""#)
        }
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(listedVariant, label: "with-cached-icon"),
            candidate: CaptureFixture.stream(
                CaptureFixture.moving(listedVariant, index: 3, toIndex: 1),
                label: "cached-icon-moved"
            )
        )
        let order = report.differences.filter { $0.diffClass == .eventOrderChanged }
        #expect(order.count == 3, "unexpected: \(report.differences)")
        #expect(order.allSatisfy { $0.detail.contains("WITHIN the `main` producer lane") })
    }

    /// Five main-lane events plus, at index 3, one event whose lane the allow-list decides.
    /// All on one tid, so if the middle event *were* main-lane the move would be a causal
    /// inversion and fire three findings.
    static let withUnlistedEvent: [String] = [
        #"{"t_ms":0,"tid":"0x1f6be3540","ev":"PreConnect"}"#,
        #"{"t_ms":10,"tid":"0x1f6be3540","ev":"PostConnect"}"#,
        #"{"t_ms":20,"tid":"0x1f6be3540","ev":"WindowCreate","windowId":65832,"fieldFlags":13567,"windowOffsetX":100,"windowOffsetY":120,"windowWidth":800,"windowHeight":600,"numVisibilityRects":1,"style":382664704,"styleEx":256,"show":5,"title":"Fixture Window"}"#,
        #"{"t_ms":30,"tid":"0x1f6be3540","ev":"WindowDelete","windowId":65832}"#,
        #"{"t_ms":40,"tid":"0x1f6be3540","ev":"WindowIcon","windowId":65832}"#,
        #"{"t_ms":50,"tid":"0x1f6be3540","ev":"PostDisconnect"}"#,
    ]

    // MARK: - Minimal well-formed line per allow-listed name

    /// One line per allow-listed `ev`, carrying exactly the fields `RailEvent`'s payload
    /// struct requires. Synthetic and under `Tests/` per ruling U7; no value here resembles
    /// a host identifier.
    static func minimalLine(for name: String) -> String? {
        let envelope = #""t_ms":1,"tid":"0x1f6be3540""#
        let windowOrder = #""windowId":65832,"fieldFlags":13567,"windowOffsetX":0,"windowOffsetY":0,"windowWidth":800,"windowHeight":600,"numVisibilityRects":1,"style":382664704,"styleEx":256,"show":5,"title":"Fixture Window""#
        let payload: String
        switch name {
        case "PreConnect", "PostConnect", "PostDisconnect", "PostFinalDisconnect", "ConnectSucceeded":
            payload = ""
        case "ClientRailServerStartCmd":
            payload = #""rc":0"#
        case "DurationElapsed":
            payload = #""sinceConnectMs":1234"#
        case "MonitoredDesktop":
            payload = #""fieldFlags":2,"activeWindowId":65832,"numWindowIds":1"#
        case "NotifyIconCreate", "NotifyIconUpdate", "NotifyIconDelete":
            payload = #""windowId":65832,"notifyIconId":7"#
        case "SecondExecBegin":
            payload = #""program":"fixture.exe""#
        case "SecondExecEnd":
            payload = #""program":"fixture.exe","rc":0"#
        case "WindowIcon", "WindowCachedIcon":
            payload = #""windowId":65832"#
        case "WindowCreate", "WindowUpdate":
            payload = windowOrder
        default:
            return nil
        }
        let body = payload.isEmpty ? "" : ",\(payload)"
        return "{\(envelope),\"ev\":\"\(name)\"\(body)}"
    }
}
