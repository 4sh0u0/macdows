// lab display-mode helper -- switches the LOCAL Mac's display between "1x" (a usable mode whose
// looks size equals its pixel size, i.e. no HiDPI scaling) and "2x" (a usable HiDPI mode whose
// pixel size is exactly double the looks size), both at the display's OWN native pixel
// resolution and OWN current refresh rate. Built by Scripts/lab/display-mode.command with
// `swiftc -O`; never run this file with `swift` directly (see that wrapper for the guards).
//
// WHY THIS EXISTS. The 2026-09-10 W3 offset-measurement pre-registration's `jobs/smoke-1x-D.env`
// / `jobs/smoke-2x-D.env` pair needs the owner to flip the Mac's display by hand between the two
// runs of a batch. This tool makes that a single command, driven by the display's OWN reported
// modes rather than a literal written into a tracked file (see NO PANEL GEOMETRY below).
//
// NO PANEL GEOMETRY, ANYWHERE IN THIS FILE. Every size compared below comes from the display at
// run time: `pixelWidth x pixelHeight` of the CURRENT mode is what "native" means, "1x" is a
// usable mode whose looks size equals that native pixel size, and "2x" is a usable mode whose
// pixel size equals that native pixel size and whose looks size is exactly half of it. A tracked
// file that instead named the maintainer's own panel (e.g. a specific looks/pixel pair) would be
// wrong on any other desk and would leak a fact about one desk into a public repository -- the
// project's security baseline (CLAUDE.md's tracked-file red line) reads that as the same class of
// leak as a host address, and this tool is designed so no code path can reintroduce one.
//
// selectMode(modes:current:want:) is the ENTIRE decision, in one pure function that touches no
// display: it is exercised directly (on synthetic ModeInfo tuples, never real CGDisplayMode
// values) by `--self-test`, which is this helper's unit test and the one subcommand that runs
// identically on every platform swiftc targets -- see the `#if canImport(CoreGraphics)` split
// below, which exists so this file still compiles (and --self-test still runs for real) on a
// Linux CI runner that has no CoreGraphics at all.
//
// REFRESH RATE. "Keep the current refresh rate" means an INTEGER compare (CGDisplayMode's
// refreshRate is a Double; a mode with an unusual analogue rate is rounded to the nearest whole
// Hz before comparison, same as the scratch helper that motivated this tool observed with real
// modes). A want with no candidate at the same integer rate is REFUSED (exit 66) rather than
// silently answered with a different rate: this tool would rather stop than change a variable the
// caller did not ask it to change.
//
// EXIT CODES (display-mode.command passes these through unchanged for `status`/`select`/`set`):
//   0   ok, or the display was already in the requested mode
//   64  usage -- unknown subcommand, wrong argument count, or an unrecognised 1x/2x argument
//   65  VERIFY-FAILED -- after switching, CGDisplayCopyDisplayMode did not read back the target
//       mode; this helper attempts to restore the ORIGINAL mode before reporting, and says so
//       (`restored=1` if that restore itself verified, `restored=0` if it did not or was not
//       attempted)
//   66  no usable mode satisfies the request (see REFRESH RATE above, and the width/height rule
//       stated on selectMode itself) -- `select` and `set` both refuse this way; `set` makes no
//       CoreGraphics configuration call at all in this case
//   70  a CoreGraphics call failed (reading the current mode, enumerating modes, beginning or
//       completing a configuration) -- distinct from 66, which is a search that came up empty, and
//       from 65, which is a search that found something but the switch did not verify

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// MARK: - The pure model (no display access anywhere in this section)

/// One display mode, reduced to exactly the fields selectMode needs. Never constructed from a
/// literal panel geometry in this file outside --self-test's synthetic fixtures, which use
/// arbitrary numbers precisely so nothing here matches a real desk.
struct ModeInfo: Equatable, CustomStringConvertible {
    var id: Int64
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var refreshHz: Int
    var hidpi: Bool
    var usable: Bool

    var description: String {
        "id=\(id) looks=\(width)x\(height) pixels=\(pixelWidth)x\(pixelHeight) \(refreshHz)Hz hidpi=\(hidpi ? 1 : 0)"
    }
}

enum WantScale: String {
    case oneX = "1x"
    case twoX = "2x"
}

/// The whole selection decision. Native pixel size is READ from `current`, never from a literal:
/// `current.pixelWidth x current.pixelHeight` is "native" for the purposes of this call, whatever
/// display it came from. A candidate must also share `current`'s (integer-rounded) refresh rate --
/// this function never trades a caller's refresh rate for a mode at a different one, it simply
/// excludes it, and if that leaves nothing, it returns nil rather than guessing.
///
///   1x: usable, and width == pixelWidth == native.pixelWidth, height == pixelHeight == native.pixelHeight
///   2x: usable, and pixelWidth == native.pixelWidth, pixelHeight == native.pixelHeight,
///       width * 2 == pixelWidth, height * 2 == pixelHeight
///
/// Ties (more than one candidate with identical width/height/pixel/refresh -- CoreGraphics can
/// list what amount to duplicates) are broken by taking the first match in `modes`' own order;
/// selectMode does not reorder or de-duplicate its input.
func selectMode(modes: [ModeInfo], current: ModeInfo, want: WantScale) -> ModeInfo? {
    let nativeWidth = current.pixelWidth
    let nativeHeight = current.pixelHeight
    for mode in modes {
        guard mode.usable else { continue }
        guard mode.refreshHz == current.refreshHz else { continue }
        switch want {
        case .oneX:
            if mode.width == mode.pixelWidth, mode.height == mode.pixelHeight,
                mode.pixelWidth == nativeWidth, mode.pixelHeight == nativeHeight
            {
                return mode
            }
        case .twoX:
            if mode.pixelWidth == nativeWidth, mode.pixelHeight == nativeHeight,
                mode.width * 2 == mode.pixelWidth, mode.height * 2 == mode.pixelHeight
            {
                return mode
            }
        }
    }
    return nil
}

// MARK: - --self-test: selectMode's unit test, synthetic, no display access, every platform

/// Every fixture here uses arbitrary made-up numbers (one native panel size, one distinct "other
/// display" panel size), chosen only to be easy to read -- never the maintainer's own panel
/// geometry, and never written as a single "WxH" token so no fixture here can be mistaken for one
/// (a source-shape pin enforces that -- see Scripts/lab/test-display-mode-pins.sh).
func runSelfTest() -> Bool {
    var allPass = true
    func check(_ name: String, _ ok: Bool) {
        if ok {
            print("[self-test] PASS \(name)")
        } else {
            print("[self-test] FAIL \(name)")
            allPass = false
        }
    }

    let native = ModeInfo(id: 1, width: 3000, height: 2000, pixelWidth: 3000, pixelHeight: 2000, refreshHz: 60, hidpi: false, usable: true)
    let twoX = ModeInfo(id: 2, width: 1500, height: 1000, pixelWidth: 3000, pixelHeight: 2000, refreshHz: 60, hidpi: true, usable: true)
    let wrongRefresh = ModeInfo(id: 3, width: 1500, height: 1000, pixelWidth: 3000, pixelHeight: 2000, refreshHz: 30, hidpi: true, usable: true)
    let notUsable = ModeInfo(id: 4, width: 1500, height: 1000, pixelWidth: 3000, pixelHeight: 2000, refreshHz: 60, hidpi: true, usable: false)
    let otherPanelNative = ModeInfo(id: 5, width: 4444, height: 3333, pixelWidth: 4444, pixelHeight: 3333, refreshHz: 60, hidpi: false, usable: true)
    let halfWidthOnly = ModeInfo(id: 6, width: 1500, height: 2000, pixelWidth: 3000, pixelHeight: 2000, refreshHz: 60, hidpi: true, usable: true)
    // gate r1 B1: a HiDPI mode that doubles correctly (width*2==pixelWidth, height*2==pixelHeight)
    // but at ANOTHER panel's native pixel size entirely -- distinct from otherPanelNative (which is
    // a 1x mode of a different panel, already excluded by the width==pixelWidth check regardless of
    // the native-pixel-size check). This is the fixture that catches a mutant which drops
    // `mode.pixelWidth == nativeWidth, mode.pixelHeight == nativeHeight` from the .twoX branch: such
    // a mutant would pick this mode for `current: native, want: .twoX` and change the display's
    // RESOLUTION, not merely its scale.
    let nonNativeTwoX = ModeInfo(id: 7, width: 1100, height: 700, pixelWidth: 2200, pixelHeight: 1400, refreshHz: 60, hidpi: true, usable: true)
    // gate r1 m1: a second, DISTINCT (different id, so not Equatable-identical to twoX) 2x
    // candidate, used only by the tie-break tests below -- `[twoX, twoX]` compares two identical
    // values and would pass under ANY implementation, including one that returns the LAST match.
    let twoXAlt = ModeInfo(id: 8, width: 1500, height: 1000, pixelWidth: 3000, pixelHeight: 2000, refreshHz: 60, hidpi: true, usable: true)

    let modes = [native, twoX, wrongRefresh, notUsable, otherPanelNative, halfWidthOnly, nonNativeTwoX]

    check("2x is found at the native pixel size and matching refresh", selectMode(modes: modes, current: native, want: .twoX) == twoX)
    check("1x is found (the current mode itself: looks == pixels == native)", selectMode(modes: modes, current: native, want: .oneX) == native)
    check("a mode at a different refresh rate is excluded, never substituted", selectMode(modes: [wrongRefresh], current: native, want: .twoX) == nil)
    check("a non-usable mode is excluded", selectMode(modes: [notUsable], current: native, want: .twoX) == nil)
    check("a mode from a different native pixel size is excluded", selectMode(modes: [otherPanelNative], current: native, want: .twoX) == nil)
    check("a mode scaled on width only (not height) does not satisfy 2x", selectMode(modes: [halfWidthOnly], current: native, want: .twoX) == nil)
    // gate r1 B1 (a): a correctly-doubling HiDPI mode of a DIFFERENT native pixel size must never
    // satisfy 2x -- this is what stops `set 2x` from changing the display's resolution.
    check("a 2x-shaped mode at a non-native pixel size is excluded", selectMode(modes: [nonNativeTwoX], current: native, want: .twoX) == nil)
    // gate r1 B1 (b): a HiDPI mode must never satisfy 1x, even when it is literally `current` --
    // this is what stops `select 1x` from reporting OK while it actually chose a 2x mode.
    check("a HiDPI mode never satisfies 1x, even as its own current", selectMode(modes: [twoX], current: twoX, want: .oneX) == nil)
    check("an empty mode list refuses rather than guessing", selectMode(modes: [], current: native, want: .oneX) == nil)
    check("already at 2x: selecting 2x again is idempotent", selectMode(modes: modes, current: twoX, want: .twoX) == twoX)
    check("already at 1x: selecting 1x again is idempotent", selectMode(modes: modes, current: native, want: .oneX) == native)
    // gate r1 m1: distinct candidates, both orders -- a mutant that returns the LAST match instead
    // of the first would flip BOTH of these (returning twoXAlt in the first, twoX in the second).
    check("first match wins over a later, distinct tie (in order)", selectMode(modes: [twoX, twoXAlt], current: native, want: .twoX) == twoX)
    check("first match wins over a later, distinct tie (reversed order)", selectMode(modes: [twoXAlt, twoX], current: native, want: .twoX) == twoXAlt)

    return allPass
}

// MARK: - CLI

func printUsage() {
    fputs("usage: display_mode status | select 1x|2x | set 1x|2x | --self-test | --sample-line\n", stderr)
}

func parseWant(_ raw: String) -> WantScale? {
    WantScale(rawValue: raw)
}

let arguments = Array(CommandLine.arguments.dropFirst())

guard let subcommand = arguments.first else {
    printUsage()
    exit(64)
}

if subcommand == "--self-test" {
    guard arguments.count == 1 else {
        printUsage()
        exit(64)
    }
    exit(runSelfTest() ? 0 : 1)
}

// --sample-line: a DISPLAY-FREE way to get one real `[display] current: …` line, for CI coverage
// of the wrapper's own parsing (test-display-mode-offline.sh's gate r1 I2 case). Added after Tier
// 1 run 34916920114 found a runner that HAS swiftc but no display/CoreGraphics at all: `status`
// there built fine and then refused with "CoreGraphics is unavailable on this platform" (see the
// `#else` branch below), producing no `current:` line for that case's extraction to parse. This
// subcommand needs neither: the ModeInfo is synthetic (the same made-up-number family --self-test
// uses -- never the maintainer's own panel), and the ONLY formatter that turns it into text is
// `ModeInfo.description`, the identical one `status`/`select`/`set` use for their own `current:`
// and `after:` lines (pinned in test-display-mode-pins.sh: a private, duplicated format string
// here would defeat the whole point of testing the SHARED grammar). Lives entirely above the
// `#if canImport(CoreGraphics)` split, like --self-test, so it compiles and runs identically on
// Linux and on a Mac with no attached display.
if subcommand == "--sample-line" {
    guard arguments.count == 1 else {
        printUsage()
        exit(64)
    }
    let sample = ModeInfo(id: 1, width: 2222, height: 1111, pixelWidth: 4444, pixelHeight: 2222, refreshHz: 60, hidpi: true, usable: true)
    print("[display] current: \(sample)")
    exit(0)
}

#if canImport(CoreGraphics)
    import CoreGraphics

    func modeInfo(_ mode: CGDisplayMode) -> ModeInfo {
        ModeInfo(
            id: Int64(bitPattern: UInt64(mode.ioDisplayModeID)),
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshHz: Int(mode.refreshRate.rounded()),
            hidpi: mode.pixelWidth != mode.width || mode.pixelHeight != mode.height,
            usable: mode.isUsableForDesktopGUI()
        )
    }

    func readCurrentMode(_ display: CGDirectDisplayID) -> ModeInfo? {
        guard let mode = CGDisplayCopyDisplayMode(display) else { return nil }
        return modeInfo(mode)
    }

    // CGDisplayCopyAllDisplayModes hides the HiDPI ("2x") modes by default -- they are what
    // CoreGraphics calls a duplicate of a lower-resolution mode -- so every enumeration below
    // must ask for them explicitly, or `select 2x` / `set 2x` would refuse on every Retina-style
    // display for a reason that has nothing to do with the display's own capability. Measured,
    // not theorised: the scratch helper described in the brief that motivated this tool found its
    // target HiDPI mode invisible without this option, on the maintainer's own display.
    let allModesOptions: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary

    func readAllModes(_ display: CGDirectDisplayID) -> [ModeInfo] {
        guard let modes = CGDisplayCopyAllDisplayModes(display, allModesOptions) as? [CGDisplayMode] else { return [] }
        return modes.map(modeInfo)
    }

    /// The real CGDisplayMode object matching a ModeInfo the pure function already chose --
    /// selectMode never sees or returns one of these, so the live path re-finds it by the same
    /// field comparison ModeInfo's Equatable already encodes.
    func findCGDisplayMode(_ display: CGDirectDisplayID, matching target: ModeInfo) -> CGDisplayMode? {
        guard let modes = CGDisplayCopyAllDisplayModes(display, allModesOptions) as? [CGDisplayMode] else { return nil }
        return modes.first { modeInfo($0) == target }
    }

    func runStatus() -> Never {
        let display = CGMainDisplayID()
        guard let current = readCurrentMode(display) else {
            print("[display] REFUSED: could not read the current display mode")
            exit(70)
        }
        print("[display] current: \(current)")
        exit(0)
    }

    func runSelect(_ want: WantScale) -> Never {
        let display = CGMainDisplayID()
        guard let current = readCurrentMode(display) else {
            print("[display] REFUSED: could not read the current display mode")
            exit(70)
        }
        print("[display] current: \(current)")
        let modes = readAllModes(display)
        guard let target = selectMode(modes: modes, current: current, want: want) else {
            print("[display] REFUSED: no usable \(want.rawValue) mode at the current refresh rate (\(current.refreshHz)Hz) and native pixel size (\(current.pixelWidth)x\(current.pixelHeight))")
            exit(66)
        }
        print("[display] target: \(target)")
        print("[display] OK \(want.rawValue)")
        exit(0)
    }

    func runSet(_ want: WantScale) -> Never {
        let display = CGMainDisplayID()
        guard let current = readCurrentMode(display) else {
            print("[display] REFUSED: could not read the current display mode")
            exit(70)
        }
        print("[display] current: \(current)")
        let modes = readAllModes(display)
        guard let target = selectMode(modes: modes, current: current, want: want) else {
            print("[display] REFUSED: no usable \(want.rawValue) mode at the current refresh rate (\(current.refreshHz)Hz) and native pixel size (\(current.pixelWidth)x\(current.pixelHeight))")
            exit(66)
        }
        print("[display] target: \(target)")

        if target == current {
            // Already in the requested mode: nothing to switch, verify trivially holds.
            print("[display] after: \(current)")
            print("[display] OK \(want.rawValue)")
            exit(0)
        }

        guard let originalCGMode = CGDisplayCopyDisplayMode(display) else {
            print("[display] REFUSED: could not re-read the original mode before switching")
            exit(70)
        }
        guard let targetCGMode = findCGDisplayMode(display, matching: target) else {
            print("[display] REFUSED: the chosen target mode could not be re-found among the display's modes")
            exit(70)
        }

        var config: CGDisplayConfigRef?
        var rc = CGBeginDisplayConfiguration(&config)
        guard rc == CGError.success, let liveConfig = config else {
            print("[display] REFUSED: CGBeginDisplayConfiguration failed rc=\(rc.rawValue)")
            exit(70)
        }
        rc = CGConfigureDisplayWithDisplayMode(liveConfig, display, targetCGMode, nil)
        guard rc == CGError.success else {
            _ = CGCancelDisplayConfiguration(liveConfig)
            print("[display] REFUSED: CGConfigureDisplayWithDisplayMode failed rc=\(rc.rawValue)")
            exit(70)
        }
        rc = CGCompleteDisplayConfiguration(liveConfig, .permanently)
        guard rc == CGError.success else {
            print("[display] REFUSED: CGCompleteDisplayConfiguration failed rc=\(rc.rawValue)")
            exit(70)
        }

        guard let after = readCurrentMode(display) else {
            print("[display] VERIFY-FAILED: could not re-read the display after switching restored=0")
            exit(65)
        }
        print("[display] after: \(after)")

        if after == target {
            print("[display] OK \(want.rawValue)")
            exit(0)
        }

        // Verify failed: attempt to restore the ORIGINAL mode before reporting.
        var restored = 0
        var restoreConfig: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&restoreConfig) == CGError.success, let rConfig = restoreConfig {
            if CGConfigureDisplayWithDisplayMode(rConfig, display, originalCGMode, nil) == CGError.success,
                CGCompleteDisplayConfiguration(rConfig, .permanently) == CGError.success,
                readCurrentMode(display) == modeInfo(originalCGMode)
            {
                restored = 1
            } else {
                _ = CGCancelDisplayConfiguration(rConfig)
            }
        }
        print("[display] VERIFY-FAILED: after does not match target restored=\(restored)")
        exit(65)
    }

    switch subcommand {
    case "status":
        guard arguments.count == 1 else {
            printUsage()
            exit(64)
        }
        runStatus()
    case "select":
        guard arguments.count == 2, let want = parseWant(arguments[1]) else {
            printUsage()
            exit(64)
        }
        runSelect(want)
    case "set":
        guard arguments.count == 2, let want = parseWant(arguments[1]) else {
            printUsage()
            exit(64)
        }
        runSet(want)
    default:
        printUsage()
        exit(64)
    }
#else
    // No CoreGraphics on this platform (e.g. a Linux CI runner): only --self-test, handled above,
    // runs here. Every display-touching subcommand refuses with 70 rather than failing to build --
    // display-mode.command never calls this on such a platform, but a direct invocation still gets
    // an honest answer instead of a link error.
    switch subcommand {
    case "status", "select", "set":
        print("[display] REFUSED: CoreGraphics is unavailable on this platform")
        exit(70)
    default:
        printUsage()
        exit(64)
    }
#endif
