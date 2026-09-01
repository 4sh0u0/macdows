import Foundation
import Testing
@testable import ReplayDiffKit

/// Round-1 finding **I-2**: the order tolerance used to be a single global window justified
/// by a two-lane threading model, and that let a same-thread causal inversion pass clean.
/// The frozen captures have three producer lanes, each on exactly one thread, and the lane
/// is fully determined by the `ev` name — so within-lane order is checkable, and causal.
@Suite("L5-6 producer-lane order partition")
struct LaneOrderTests {
    // MARK: - The partition itself, verified against the frozen captures

    /// This is the claim the whole lane rule rests on, so it is checked against the real
    /// data rather than asserted in a comment: in every phase05 capture, each derived lane
    /// maps to exactly **one** tid, the three lanes' tids are **distinct**, and
    /// `ChannelConnected`/`ChannelDisconnected` are the only names ever seen on more than
    /// one thread. If a future probe build breaks any of that, this fails before a drill
    /// silently starts reporting phantom within-lane reorders.
    @Test("each derived lane is exactly one thread, in every frozen capture", arguments: PhaseSamples.names)
    func laneDerivationMatchesThreadIds(name: String) throws {
        let url = try #require(PhaseSamples.url(named: name), "sample not found: \(name)")
        let stream = try ReplayStream.parse(fileAt: url)
        #expect(stream.parseFailures.isEmpty)
        #expect(stream.records.count > 100)

        var tidsByLane: [EventLane: Set<String>] = [:]
        var tidsByEventName: [String: Set<String>] = [:]
        for record in stream.records {
            guard case .string(let tid)? = record.fields["tid"] else {
                Issue.record("\(name): record on line \(record.lineNumber) has no string tid")
                continue
            }
            let lane = EventLane.lane(forEventName: record.eventName, isModelled: record.isModelled)
            tidsByLane[lane, default: []].insert(tid)
            tidsByEventName[record.eventName, default: []].insert(tid)
        }

        for lane in [EventLane.main, .gfx, .server] {
            let tids = tidsByLane[lane] ?? []
            #expect(tids.count == 1, "\(name): lane \(lane.rawValue) spans \(tids.count) thread(s), expected 1")
        }
        let determinate = [EventLane.main, .gfx, .server].compactMap { tidsByLane[$0]?.first }
        #expect(Set(determinate).count == determinate.count, "\(name): two determinate lanes share a thread")

        let multiThreaded = Set(tidsByEventName.filter { $0.value.count > 1 }.keys)
        #expect(
            multiThreaded == EventLane.ambiguousEventNames,
            "\(name): names on >1 thread are \(multiThreaded.sorted()); EventLane exempts \(EventLane.ambiguousEventNames.sorted())"
        )
    }

    @Test("lane derivation maps the name families it claims to")
    func laneDerivationMapping() {
        #expect(EventLane.lane(forEventName: "WindowCreate") == .main)
        #expect(EventLane.lane(forEventName: "MonitoredDesktop") == .main)
        #expect(EventLane.lane(forEventName: "GfxMapSurfaceToWindow") == .gfx)
        #expect(EventLane.lane(forEventName: "GfxResetGraphics") == .gfx)
        #expect(EventLane.lane(forEventName: "ServerMinMaxInfo") == .server)
        #expect(EventLane.lane(forEventName: "ChannelConnected") == .ambiguous)
        #expect(EventLane.lane(forEventName: "ChannelDisconnected") == .ambiguous)
        // An unmodelled name gets no lane rather than falling through to `main`: guessing a
        // thread for an event this package has never seen would manufacture findings.
        #expect(EventLane.lane(forEventName: "SomeFutureProbeEvent", isModelled: false) == .ambiguous)
        #expect(EventLane.lane(forEventName: "GfxSomethingNew", isModelled: false) == .ambiguous)
    }

    // MARK: - The behaviour the partition buys (round-1 probe b.1)

    /// Round-1 probe b.1, verbatim: six lines, one thread, `WindowCreate` moved two
    /// positions later so `WindowIcon` and `MonitoredDesktop` reference a window that does
    /// not exist yet. This reported **clean, exit 0** before the fix.
    @Test("a same-lane causal inversion is reported at the default tolerance")
    func sameLaneCausalInversionIsReported() {
        let inverted = CaptureFixture.moving(
            CaptureFixture.mainLaneOnly,
            index: CaptureFixture.MainLaneLine.windowCreate.rawValue,
            toIndex: CaptureFixture.MainLaneLine.monitoredDesktop.rawValue
        )
        #expect(inverted != CaptureFixture.mainLaneOnly)

        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(CaptureFixture.mainLaneOnly, label: "main-lane"),
            candidate: CaptureFixture.stream(inverted, label: "main-lane-inverted")
        )
        let order = report.differences.filter { $0.diffClass == .eventOrderChanged }
        #expect(order.count == 3, "unexpected: \(report.differences)")
        #expect(report.hasRegressions)
        #expect(order.allSatisfy { $0.detail.contains("WITHIN the `main` producer lane") })
        #expect(order.contains { $0.eventName == "WindowCreate" && $0.detail.contains("moved 2 position(s)") })
    }

    /// Negative control for the suite above: the within-lane rule is a *tolerance*, not a
    /// hard-coded zero. Raising it makes the same inversion clean again, so the finding
    /// above is produced by the lane check and not by something incidental.
    @Test("the same inversion is clean once the lane tolerance is raised")
    func sameLaneInversionIsCleanAtLaneToleranceTwo() {
        var options = DifferOptions()
        options.laneOrderTolerance = 2
        let inverted = CaptureFixture.moving(
            CaptureFixture.mainLaneOnly,
            index: CaptureFixture.MainLaneLine.windowCreate.rawValue,
            toIndex: CaptureFixture.MainLaneLine.monitoredDesktop.rawValue
        )

        let report = SemanticDiffer(options: options).diff(
            baseline: CaptureFixture.stream(CaptureFixture.mainLaneOnly, label: "main-lane"),
            candidate: CaptureFixture.stream(inverted, label: "main-lane-inverted")
        )
        #expect(report.differences.isEmpty, "unexpected: \(report.differences)")
    }

    /// The lane check must not make *cross*-lane interleaving noisy — that is the noise the
    /// global tolerance exists for, and acceptance row 3 depends on it staying tolerated.
    @Test("cross-lane interleaving stays tolerated")
    func crossLaneInterleaveStaysTolerated() {
        let swapped = CaptureFixture.swapping(
            CaptureFixture.baseline, .gfxMapSurfaceToWindow, .monitoredDesktop
        )
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(swapped, label: "swapped")
        )
        #expect(report.differences.isEmpty, "unexpected: \(report.differences)")
    }

    /// An event alone in its lane has a constant lane rank, so the within-lane check cannot
    /// see it move. The global check must still catch a large cross-lane hoist — otherwise
    /// adding the lane rule would have *removed* coverage.
    @Test("a large cross-lane move is still caught by the global check")
    func largeCrossLaneMoveStillCaught() throws {
        let moved = CaptureFixture.moving(CaptureFixture.baseline, .gfxMapSurfaceToWindow, toIndex: 0)
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.stream(moved, label: "moved")
        )
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        let difference = try #require(report.differences.first)
        #expect(difference.diffClass == .eventOrderChanged)
        #expect(difference.detail.contains("across lanes"))
    }

    /// Events with no determinate lane are governed by the global tolerance alone. Without
    /// the exemption, `ChannelConnected` — genuinely logged from two different threads in
    /// every frozen capture — would be folded into `main` and its cross-thread jitter would
    /// be reported as a causal inversion that never happened.
    ///
    /// Moving it two positions is inside the global tolerance, so the run is clean; the
    /// counterfactual below shows that is the *exemption* doing the work.
    @Test("ambiguous-lane events are exempt from the within-lane check")
    func ambiguousLaneEventsAreExempt() {
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(Self.ambiguousLaneBaseline, label: "with-channel"),
            candidate: CaptureFixture.stream(
                CaptureFixture.moving(Self.ambiguousLaneBaseline, index: 3, toIndex: 1),
                label: "channel-moved"
            )
        )
        #expect(report.differences.isEmpty, "unexpected: \(report.differences)")
    }

    /// The counterfactual: the identical movement, applied to a *main*-lane event with the
    /// same payload shape (`SecondExecBegin`, one string field, no identifiers). Now the
    /// within-lane check fires — for the moved event and for the two it passed.
    @Test("the same movement of a main-lane event IS reported")
    func sameMovementOfAMainLaneEventIsReported() {
        let mainLaneVariant = Self.ambiguousLaneBaseline.map {
            $0.replacingOccurrences(of: #""ev":"ChannelConnected","name""#, with: #""ev":"SecondExecBegin","program""#)
        }
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.stream(mainLaneVariant, label: "with-exec"),
            candidate: CaptureFixture.stream(
                CaptureFixture.moving(mainLaneVariant, index: 3, toIndex: 1),
                label: "exec-moved"
            )
        )
        let order = report.differences.filter { $0.diffClass == .eventOrderChanged }
        #expect(order.count == 3, "unexpected: \(report.differences)")
        #expect(order.allSatisfy { $0.detail.contains("WITHIN the `main` producer lane") })
        #expect(order.contains { $0.eventName == "SecondExecBegin" })
    }

    /// Six lines: five main-lane events plus one `ChannelConnected` at index 3, which the
    /// two tests above move to index 1.
    static let ambiguousLaneBaseline: [String] = [
        #"{"t_ms":0,"tid":"0x1f6be3540","ev":"PreConnect"}"#,
        #"{"t_ms":10,"tid":"0x1f6be3540","ev":"PostConnect"}"#,
        #"{"t_ms":20,"tid":"0x1f6be3540","ev":"WindowCreate","windowId":65832,"fieldFlags":13567,"windowOffsetX":100,"windowOffsetY":120,"windowWidth":800,"windowHeight":600,"numVisibilityRects":1,"style":382664704,"styleEx":256,"show":5,"title":"Fixture Window"}"#,
        #"{"t_ms":30,"tid":"0x2f6be3540","ev":"ChannelConnected","name":"rdpdr"}"#,
        #"{"t_ms":40,"tid":"0x1f6be3540","ev":"WindowIcon","windowId":65832}"#,
        #"{"t_ms":50,"tid":"0x1f6be3540","ev":"PostDisconnect"}"#,
    ]

    /// The notes have to state both tolerances, or an artifact cannot be read back.
    @Test("the report records both tolerances")
    func reportRecordsBothTolerances() {
        let report = SemanticDiffer().diff(
            baseline: CaptureFixture.baselineStream(),
            candidate: CaptureFixture.baselineStream()
        )
        #expect(report.notes.contains { $0.contains("2 matched position(s) across lanes") })
        #expect(report.notes.contains { $0.contains("0 within a lane") })
    }
}
