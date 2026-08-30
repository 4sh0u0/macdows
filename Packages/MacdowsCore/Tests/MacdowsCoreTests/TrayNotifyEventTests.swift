import Testing
@testable import MacdowsCore

/// adr/0014 §1's v1 wire contract, offline: the two constants are bit-exact against
/// `ThirdParty/FreeRDP/include/freerdp/rail.h:137-138`, and the click sequence is ORDER-
/// sensitive (down before up). Both facts are wire behavior a real host cannot report back on
/// -- MS-RDPERP 3.3.5.2.5.4 acknowledges nothing -- so this suite is the only place they can
/// be pinned at all.
@Suite("TrayNotifyEvent")
struct TrayNotifyEventTests {
    @Test("constants are bit-exact against freerdp/rail.h:137-138")
    func constantsMatchTheWire() {
        #expect(TrayNotifyEvent.wmLButtonDown == 0x0000_0201)
        #expect(TrayNotifyEvent.wmLButtonUp == 0x0000_0202)
    }

    @Test("left click is exactly [WM_LBUTTONDOWN, WM_LBUTTONUP], in that order")
    func leftClickSequenceIsOrdered() {
        #expect(TrayNotifyEvent.leftClickSequence == [0x0000_0201, 0x0000_0202])
        // Spelled out separately from the literal comparison above: an implementation that
        // reversed the pair would still satisfy a Set/count-based check, and "down then up"
        // is the entire semantic content of a click.
        #expect(TrayNotifyEvent.leftClickSequence.count == 2)
        #expect(TrayNotifyEvent.leftClickSequence.first == TrayNotifyEvent.wmLButtonDown)
        #expect(TrayNotifyEvent.leftClickSequence.last == TrayNotifyEvent.wmLButtonUp)
    }

    @Test("v1 sends no NIN_ message (adr/0014 §1: the version precondition is unverifiable)")
    func sequenceCarriesNoNinMessage() {
        // NIN_SELECT (0x400) / NIN_KEYSELECT (0x401) / the NIN_BALLOON* family (0x402-0x405),
        // rail.h:145-150 -- every one of them is >= 0x400, so the whole family is excluded by
        // one bound rather than by listing values this test would then have to track.
        for message in TrayNotifyEvent.leftClickSequence {
            #expect(message < 0x0000_0400)
        }
    }

    @Test("the message type is UInt32, matching RAIL_NOTIFY_EVENT_ORDER.message (rail.h:437)")
    func messageWidthIsThirtyTwoBits() {
        // The predicted implementation bug this whole lane invites is reusing
        // -sendSysCommand:command:'s UINT16 width (rail.h:430). A 16-bit element type would
        // not compile against this expectation.
        #expect(type(of: TrayNotifyEvent.leftClickSequence) == [UInt32].self)
        #expect(MemoryLayout.size(ofValue: TrayNotifyEvent.wmLButtonDown) == 4)
    }
}
