import Foundation
import Testing
@testable import ReplayDiffKit

/// Untitled anchoring, step 1 (docs `upgrade-gate/2026-09-untitled-payload-stability.md`
/// §4.1 / §7.1): `0xFFFFFFFF` in a `window`-namespace field is MonitoredDesktop's sentinel
/// ("no active window / focus not on the monitored desktop", adr/0008 §0), not a handle.
/// Until this landed it was ordinalised like any untitled handle — and because every frozen
/// capture reports it early and often (21–23 of each capture's 24–26 `MonitoredDesktop`
/// lines carry it; the first desktop update reports `activeWindowId` 0, the sentinel appears
/// from the second on), it sat at `window#0` and pushed EVERY later untitled ordinal up by
/// one on whichever side carried it. Any re-record that does not report the sentinel (or
/// first reports it later) paid a structural +1 cascade before one real difference was
/// counted. Same exemption shape as the `windowId=0` → `window#none` constant that already
/// existed; the two constants stay distinct tokens because they are different server
/// statements. Named for what these values ARE — identifier-field constants — not for what
/// they are not.
@Suite("untitled anchoring step 1: 0xFFFFFFFF is a constant, not an ordinal")
struct IdentifierConstantTests {
    static let noActiveWindow: UInt32 = 0xFFFF_FFFF

    static func monitoredDesktop(tMs: Int, active: UInt32, numWindowIds: Int = 1) -> String {
        #"{"t_ms":\#(tMs),"tid":"0x1f6be3540","ev":"MonitoredDesktop","fieldFlags":67108912,"activeWindowId":\#(active),"numWindowIds":\#(numWindowIds)}"#
    }

    /// The frozen-baseline shape: the constant arrives first, then the untitled windows. A
    /// candidate that never reports the constant must differ in exactly that — the
    /// `MonitoredDesktop` type being one-sided — and in nothing about the windows.
    @Test("an early baseline-only 0xFFFFFFFF shifts no untitled ordinal and raises no cascade note")
    func sentinelDoesNotConsumeAnOrdinal() throws {
        let a: UInt32 = 197_612, b: UInt32 = 983_208
        let windows = [
            TitleAnchoredIdentityTests.windowCreate(tMs: 10, id: a, title: ""),
            TitleAnchoredIdentityTests.windowIcon(tMs: 11, id: a),
            TitleAnchoredIdentityTests.windowCreate(tMs: 12, id: b, title: ""),
            TitleAnchoredIdentityTests.windowIcon(tMs: 13, id: b),
        ]
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream(
                [Self.monitoredDesktop(tMs: 5, active: Self.noActiveWindow, numWindowIds: 0)] + windows,
                label: "with-constant"),
            candidate: TitleAnchoredIdentityTests.stream(windows, label: "without-constant")
        )

        let oneSided = report.differences.filter { $0.diffClass == .eventTypeOnlyOnOneSide }
        #expect(oneSided.map(\.eventName) == ["MonitoredDesktop"], "unexpected: \(oneSided)")
        let countChanges = report.differences.filter { $0.diffClass == .eventCountChanged }
        #expect(countChanges.isEmpty,
                "the constant must not shift the untitled ordinals: \(countChanges.map(\.detail))")
        #expect(report.differences.count == 1, "unexpected: \(report.differences)")
        #expect(!report.notes.contains { $0.hasPrefix("CASCADE RISK") },
                "the constant is not an un-anchored handle; equal handle counts, no note")
    }

    /// The token is visible in the report, so its shape is contract: `window#` followed by
    /// something no ordinal (`window#<decimal>`) and no title token (`window@…`) can be.
    @Test("the constant renders as `window#0xFFFFFFFF` in the identity tuple")
    func constantTokenShape() throws {
        let a: UInt32 = 197_612
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream([
                Self.monitoredDesktop(tMs: 5, active: Self.noActiveWindow),
                Self.monitoredDesktop(tMs: 6, active: Self.noActiveWindow),
                TitleAnchoredIdentityTests.windowCreate(tMs: 10, id: a, title: ""),
            ], label: "two"),
            candidate: TitleAnchoredIdentityTests.stream([
                Self.monitoredDesktop(tMs: 5, active: Self.noActiveWindow),
                TitleAnchoredIdentityTests.windowCreate(tMs: 10, id: a, title: ""),
            ], label: "one")
        )
        let countChanges = report.differences.filter { $0.diffClass == .eventCountChanged }
        let only = try #require(countChanges.first, "one extra MonitoredDesktop is one count change")
        #expect(countChanges.count == 1, "unexpected: \(countChanges)")
        #expect(only.eventName == "MonitoredDesktop")
        #expect(only.detail.contains("activeWindowId=\"window#0xFFFFFFFF\""), "got: \(only.detail)")
    }

    /// Negative control (a lazy implementation would fold both constants into `#none`): the
    /// null handle and the no-active-window constant are different server statements and
    /// must stay distinguishable — a desktop that flips between them is a real finding.
    @Test("0 and 0xFFFFFFFF stay distinct constants")
    func nullHandleAndNoActiveWindowStayDistinct() {
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream(
                [Self.monitoredDesktop(tMs: 5, active: 0, numWindowIds: 0)], label: "null"),
            candidate: TitleAnchoredIdentityTests.stream(
                [Self.monitoredDesktop(tMs: 5, active: Self.noActiveWindow, numWindowIds: 0)], label: "none-active")
        )
        let countChanges = report.differences.filter { $0.diffClass == .eventCountChanged }
        #expect(countChanges.count == 2, "each side has one identity the other lacks: \(report.differences)")
        #expect(countChanges.contains { $0.detail.contains("window#none") })
        #expect(countChanges.contains { $0.detail.contains("window#0xFFFFFFFF") })
        #expect(!report.notes.contains { $0.hasPrefix("CASCADE RISK") }, "constants are not handles")
    }

    /// Coverage pin (review untitled-step1-r2 m3): the constant is a property of the `window`
    /// NAMESPACE, not of the one field it has been observed in — `windowIdMarker`
    /// (ServerZOrderSync) and the other window fields canonicalize it identically. Killed by
    /// narrowing the check to `fieldName == "activeWindowId"`.
    @Test("the constant covers every window-namespace field, not just activeWindowId")
    func constantCoversAllWindowNamespaceFields() throws {
        func zOrderSync(tMs: Int, marker: UInt32) -> String {
            #"{"t_ms":\#(tMs),"tid":"0x1f6be3540","ev":"ServerZOrderSync","windowIdMarker":\#(marker)}"#
        }
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream(
                [zOrderSync(tMs: 5, marker: Self.noActiveWindow), zOrderSync(tMs: 6, marker: Self.noActiveWindow)],
                label: "two"),
            candidate: TitleAnchoredIdentityTests.stream([zOrderSync(tMs: 5, marker: Self.noActiveWindow)], label: "one")
        )
        let countChanges = report.differences.filter { $0.diffClass == .eventCountChanged }
        let only = try #require(countChanges.first)
        #expect(countChanges.count == 1, "unexpected: \(countChanges)")
        #expect(only.detail.contains("windowIdMarker=\"window#0xFFFFFFFF\""), "got: \(only.detail)")
        #expect(!report.notes.contains { $0.hasPrefix("CASCADE RISK") }, "a constant is not a handle in any window field")
    }

    /// Scope pin (review untitled-step1-r1 I2): the exemption is `window`-namespace only.
    /// `notifyIconId` may legitimately be 0xFFFFFFFF, so there it stays a HANDLE — a per-side
    /// ordinal like any other — and two captures whose only difference is which raw notify-icon
    /// id they used must canonicalize identically. Killed by dropping the namespace check.
    @Test("0xFFFFFFFF in the notifyIcon namespace is still a handle, not a constant")
    func exemptionIsWindowNamespaceOnly() {
        let owner: UInt32 = 197_612
        func notifyIconCreate(id: UInt32) -> String {
            #"{"t_ms":20,"tid":"0x1f6be3540","ev":"NotifyIconCreate","notifyIconId":\#(id),"windowId":\#(owner)}"#
        }
        let report = SemanticDiffer().diff(
            baseline: TitleAnchoredIdentityTests.stream(
                [TitleAnchoredIdentityTests.windowCreate(tMs: 10, id: owner, title: ""), notifyIconCreate(id: 0xFFFF_FFFF)],
                label: "icon-ffffffff"),
            candidate: TitleAnchoredIdentityTests.stream(
                [TitleAnchoredIdentityTests.windowCreate(tMs: 10, id: owner, title: ""), notifyIconCreate(id: 5)],
                label: "icon-5")
        )
        #expect(report.differences.isEmpty,
                "a notify-icon handle is a handle whatever its raw value: \(report.differences)")
        #expect(!report.notes.contains { $0.hasPrefix("CASCADE RISK") })
    }
}
