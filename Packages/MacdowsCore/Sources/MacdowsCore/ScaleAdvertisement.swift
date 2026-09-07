import Foundation

/// W3 lane D (ADR-0018 §2; the pure half of U-1). What the client WOULD declare in
/// TS_UD_CS_CORE's `desktopScaleFactor` / `deviceScaleFactor` for a given topology
/// `rasterScale`, as values only -- nothing here touches `CRSession` or FreeRDP settings.
/// Wiring (and whether the product advertises at all) is the owner's U-1 ruling; until then the
/// product stays at `.notAdvertising` and only the window-smoke fixture knob (lane E) will use these.
///
/// Facts this type encodes (ADR-0018 §0 (f), verified on the vendored FreeRDP 3.31.1):
/// - both fields are UINT32 percentages written unconditionally by `gcc_write_client_core_data`;
///   the defaults are 100 / 100, which is "not advertising";
/// - upstream's interoperability domains are desktop ∈ [100, 500] (`/scale-desktop`) and
///   device ∈ {100, 140, 180} (`/scale-device`, `/scale`);
/// - the two are distinct fields with distinct meanings and MUST NOT be swapped -- the vendored
///   `settings.c` monitor-synthesis path swaps them (an upstream cross-wiring noted in
///   ADR-0015 §8), which is exactly the mistake this type refuses to reproduce.
/// A value outside its domain is refused (`nil`), never clamped: a wrong `rasterScale` must not
/// silently advertise the maximum.
public struct ScaleAdvertisement: Equatable, Sendable {
    /// TS_UD_CS_CORE `desktopScaleFactor`, percent, within `desktopScaleRange`.
    public let desktopScaleFactor: UInt32
    /// TS_UD_CS_CORE `deviceScaleFactor`, percent, one of `deviceScaleValues`.
    public let deviceScaleFactor: UInt32

    public static let desktopScaleRange: ClosedRange<UInt32> = 100...500
    public static let deviceScaleValues: [UInt32] = [100, 140, 180]

    /// Not advertising: both fields at their wire defaults. The product's value today.
    public static let notAdvertising = ScaleAdvertisement(uncheckedDesktop: 100, uncheckedDevice: 100)

    /// Fails (returns `nil`) when either value is outside its wire domain.
    public init?(desktopScaleFactor: UInt32, deviceScaleFactor: UInt32) {
        guard Self.desktopScaleRange.contains(desktopScaleFactor),
              Self.deviceScaleValues.contains(deviceScaleFactor) else { return nil }
        self.desktopScaleFactor = desktopScaleFactor
        self.deviceScaleFactor = deviceScaleFactor
    }

    private init(uncheckedDesktop: UInt32, uncheckedDevice: UInt32) {
        desktopScaleFactor = uncheckedDesktop
        deviceScaleFactor = uncheckedDevice
    }

    public var isNotAdvertising: Bool { self == .notAdvertising }

    /// `docs/matrix/format.md` `advertised_scale`: `none` | `DesktopScaleFactor=<n>[,DeviceScaleFactor=<n>]`.
    /// The device part is written only when it differs from the default 100, so option D and
    /// option DD advertisements are distinguishable at a glance.
    public var matrixFieldValue: String {
        if isNotAdvertising { return "none" }
        var s = "DesktopScaleFactor=\(desktopScaleFactor)"
        if deviceScaleFactor != 100 { s += ",DeviceScaleFactor=\(deviceScaleFactor)" }
        return s
    }

    /// The desktop percentage for a `rasterScale` (`DisplayTopology.rasterScale`, remote px per
    /// mac pt), rounded to the nearest whole percent; `nil` outside the wire domain.
    static func desktopPercent(rasterScale: Double) -> UInt32? {
        guard rasterScale.isFinite, rasterScale > 0 else { return nil }
        let rounded = (rasterScale * 100).rounded()
        guard rounded >= Double(desktopScaleRange.lowerBound), rounded <= Double(desktopScaleRange.upperBound) else { return nil }
        return UInt32(rounded)
    }

    /// ADR-0018 U-1 option D: declare only the desktop scale; device stays at 100.
    public static func proposedDesktopOnly(rasterScale: Double) -> ScaleAdvertisement? {
        guard let desktop = desktopPercent(rasterScale: rasterScale) else { return nil }
        return ScaleAdvertisement(desktopScaleFactor: desktop, deviceScaleFactor: 100)
    }

    /// ADR-0018 U-1 option DD: declare both; device = the allowed value nearest to the desktop
    /// percentage (ties resolve to the lower value). 2x -> (200, 180); 1.5x -> (150, 140).
    public static func proposedBoth(rasterScale: Double) -> ScaleAdvertisement? {
        guard let desktop = desktopPercent(rasterScale: rasterScale) else { return nil }
        let device = deviceScaleValues.min { a, b in
            let da = abs(Int(a) - Int(desktop)), db = abs(Int(b) - Int(desktop))
            return da != db ? da < db : a < b
        }!
        return ScaleAdvertisement(desktopScaleFactor: desktop, deviceScaleFactor: device)
    }
}
