import Testing
@testable import MacdowsCore

/// P1 (upgrade-gate drill 2026-09-drill-01 §7.2): decode contract for the CapsAdvertise
/// instrumentation. `rail-probe.c` logs one `GfxCapsAdvertise` summary event — the whole
/// advertised capset list, wire order, as a single deterministic string — and one
/// `GfxCapsConfirm` event carrying the capset the server negotiated. One summary event
/// rather than one event per capset is deliberate: a future upstream that adds or drops a
/// capset then surfaces as a single value difference in the gate, not as a per-capset
/// pairing cascade (the pre-registered ordinal-cascade trap that dominated the
/// 2026-09-01 live diff).
@Suite("RailEvent caps instrumentation decode (P1)")
struct RailEventCapsDecodeTests {
    @Test("GfxCapsAdvertise decodes the count and the capset-list string verbatim")
    func capsAdvertiseDecodes() throws {
        let line = #"{"t_ms":41,"tid":"0x1f6be3540","ev":"GfxCapsAdvertise","capsSetCount":3,"capsSets":"0x00080004:0x00000000,0x00080105:0x00000010,0x000A0701:0x00000080"}"#
        let (events, failures) = RailEvent.parseJSONL(line)
        #expect(failures.isEmpty)
        let event = try #require(events.first)
        #expect(event.kind == .gfxCapsAdvertise(
            capsSetCount: 3,
            capsSets: "0x00080004:0x00000000,0x00080105:0x00000010,0x000A0701:0x00000080"
        ))
    }

    @Test("GfxCapsConfirm decodes the negotiated version and flags as hex strings")
    func capsConfirmDecodes() throws {
        let line = #"{"t_ms":58,"tid":"0x1f6be3540","ev":"GfxCapsConfirm","version":"0x000A0701","flags":"0x00000080"}"#
        let (events, failures) = RailEvent.parseJSONL(line)
        #expect(failures.isEmpty)
        let event = try #require(events.first)
        #expect(event.kind == .gfxCapsConfirm(version: "0x000A0701", flags: "0x00000080"))
    }

    @Test("a caps event missing a field is a parse failure, not a silent partial decode")
    func missingFieldIsParseFailure() {
        let line = #"{"t_ms":58,"tid":"0x1f6be3540","ev":"GfxCapsConfirm","version":"0x000A0701"}"#
        let (events, failures) = RailEvent.parseJSONL(line)
        #expect(events.isEmpty)
        #expect(failures.count == 1)
    }
}
