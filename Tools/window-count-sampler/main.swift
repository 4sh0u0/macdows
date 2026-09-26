// window-count-sampler: ADR-0020 lane V blueprint §2.1 / O-6. A tracked, source-pinned tool
// (Scripts/test-window-count-sampler.sh + a Tier 1 step) that samples the on-screen window table
// for one App PID, once every --period-s seconds, and prints one WC-1 line per sample plus a
// WC-0 start line and a WC-9 end line. It is lane V's external window counter for DA-1 (the RAIL
// window count before / after the Disconnect press and after the reconnect). l25 is printed as
// §2.1 asks, but on the measured system an NSStatusItem window is structurally absent from the
// on-screen table (gate r1 O-A: its window number is a placeholder no table lists), so l25 is not
// an observation surface for DA-2 -- a constant 0 there is evidence of that, not of a trayless
// remote program.
//
// RED LINE (docs, blueprint §5): of a window dictionary only the owner PID, layer, number and
// bounds keys are ever read -- never kCGWindowName, never kCGWindowOwnerName -- and no child
// process is ever spawned (wc -l is reimplemented below). That is held by the pin script's W1, a
// default-deny grammar over this file: the exact set of window-related identifiers, the exact
// shapes in which a window dictionary (`item`) and the window table (`windowTable`) may appear,
// one output function whose every call passes one of the five line builders, no other output
// sink, no serialiser, no spawn or process-name API, and no import beyond the two below.
//
// Single implementation, two consumers: the one CGWindowListCopyWindowInfo(.optionOnScreenOnly,
// kCGNullWindowID) call lives in copyWindowList() and the one four-key extraction in
// filterEntries(_:pid:); --self-check and the main sampling loop both call through them (W3 pins
// the one call site, W1 the extraction's shapes, W5 the main loop and the self-check verbatim).
//
// Build contract: `swiftc -O -o <dir>/window-count-sampler main.swift`, in the default language
// mode or with `-swift-version 6` (both compile; the pin script's W4m builds both). Never build
// into the repository tree.
//
// Usage: window-count-sampler --pid <p> --period-s <P> --judgement-file <path>
//                              [--timeout-s <T>] [--self-check]
// <p>, <P> and <T> are whole numbers >= 1. Anything else is a usage error: the usage line on
// stdout, exit 64.
// --self-check enumerates once. With --pid it passes when at least one on-screen entry belongs to
// that PID; without --pid it targets this process's own PID (which owns no window) and passes when
// the table itself is non-empty. Pass: the ok line, exit 0. Fail: the empty line, exit 3.
// CGWindowListCopyWindowInfo returning nil: no line, exit 2.
//
// Line grammar (stdout only; each line flushed as soon as it is written):
//   [wincount-start] app-pid=<p> period-s=<P> helper-sha8=<hex8>
//   [wincount] seq=<n> ts=<epoch-s> cur-a=<n> cur-b=<n> pid=<p> found=<0|1> l0=<n> l3=<n> l25=<n> lx=<n> wins=<num>:<layer>:<w>x<h>[,...]|none
//   [wincount-end] rows=<n> reason=<done|pid-gone|timeout|enum-nil>
//   [wincount-selfcheck] <ok|empty> entries=<n> total=<N> keys=owner-pid,layer,number,bounds
//   [wincount-usage] <the usage synopsis, a fixed literal>
// - found: the PID exists (kill(pid, 0) succeeds or fails with EPERM), whether or not it owns a
//   window. l0 / l3 / l25 count that PID's entries on layers 0 / 3 / 25, lx every other layer's;
//   an entry without a layer key is recorded with layer Int.min (outside CGWindowLevel's Int32
//   range, so never a real layer) and so counted in lx. <layer> may be negative (desktop layers);
//   <w>x<h> is the window frame in points, title bar included, rounded. wins is ascending by number.
// - cur-a / cur-b: the newline count (wc -l semantics) of --judgement-file, read immediately before
//   and immediately after the one enumeration of the row; 0 while the file does not exist.
// - ts: whole epoch seconds (truncated), taken after cur-b. The --timeout-s ceiling is measured on
//   ContinuousClock (monotonic), never on the wall clock.
// - reason: timeout (--timeout-s elapsed); done (SIGTERM, SIGINT or SIGHUP -- one handling for all
//   three); pid-gone (after the row that read found=0); enum-nil (CGWindowListCopyWindowInfo
//   returned nil mid-run: exit 2, rows = the rows printed before it). Every other end is exit 0.
// - helper-sha8: the first 8 hex characters of the SHA-256 of this executable's own bytes, read
//   from Bundle.main.executablePath (the executable actually loaded, also when found through
//   PATH); unreadable => exit 2 and no start line, never a digest of nothing.

import CoreGraphics
import Foundation

// MARK: - the one output function

// Line-buffered stdout plus an explicit fflush after every line (the same setvbuf call as
// Tools/window-smoke/main.swift): a consumer tailing a redirected file sees each line at once.
setvbuf(stdout, nil, _IOLBF, 1 << 12)

func writeLine(_ line: String) {
    print(line)
    fflush(stdout)
}

func usageErrorExit() -> Never {
    writeLine(buildUsageLine())
    exit(64)
}

// MARK: - SIGTERM / SIGINT / SIGHUP

// One flag, set by the same capture-less handler for all three signals, so each ends the run with
// reason=done. Installing the handler also replaces an inherited SIG_IGN (a sampler started with
// `&` from a non-interactive shell inherits SIGINT ignored). The handler only ever stores this one
// Bool; nonisolated(unsafe) lets the C handler and the loop share it under -swift-version 6.
nonisolated(unsafe) var terminateRequested = false
signal(SIGTERM) { _ in terminateRequested = true }
signal(SIGINT) { _ in terminateRequested = true }
signal(SIGHUP) { _ in terminateRequested = true }

// Sleeps up to `seconds`, waking early (and returning immediately) once terminateRequested is
// set, so a signal during a long --period-s does not add a full extra period of latency before
// the [wincount-end] line appears.
func sleepInterruptible(seconds: Int) {
    let slice = 0.2
    var remaining = Double(seconds)
    while remaining > 0 {
        if terminateRequested { return }
        let chunk = min(slice, remaining)
        Thread.sleep(forTimeInterval: chunk)
        remaining -= chunk
    }
}

// MARK: - SHA-256 (pure Swift; no CryptoKit dependency, per the tool's CoreGraphics/Foundation-only
// link contract)

private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
    return (x >> n) | (x << (32 - n))
}

private func sha256(_ message: [UInt8]) -> [UInt8] {
    let k: [UInt32] = [
        0x428a2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]
    var h: [UInt32] = [0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19]
    var msg = message
    let bitLength = UInt64(message.count) * 8
    msg.append(0x80)
    while msg.count % 64 != 56 { msg.append(0) }
    for i in (0..<8).reversed() {
        msg.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff))
    }
    var chunkStart = 0
    while chunkStart < msg.count {
        var w = [UInt32](repeating: 0, count: 64)
        for t in 0..<16 {
            let base = chunkStart + t * 4
            w[t] = (UInt32(msg[base]) << 24) | (UInt32(msg[base + 1]) << 16) | (UInt32(msg[base + 2]) << 8) | UInt32(msg[base + 3])
        }
        for t in 16..<64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for t in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = hh &+ s1 &+ ch &+ k[t] &+ w[t]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ temp1
            d = c; c = b; b = a; a = temp1 &+ temp2
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        chunkStart += 64
    }
    var digest = [UInt8]()
    for v in h {
        digest.append(UInt8((v >> 24) & 0xff))
        digest.append(UInt8((v >> 16) & 0xff))
        digest.append(UInt8((v >> 8) & 0xff))
        digest.append(UInt8(v & 0xff))
    }
    return digest
}

private func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

// Reads THIS process's own executable bytes -- never another file -- from the path dyld loaded it
// from. argv[0] is not used: it has no directory part when the tool is found through PATH, and
// resolving it against the working directory then reads nothing (gate r1 m-4). nil => the caller
// exits 2 without a start line.
private func helperSha8() -> String? {
    guard let path = Bundle.main.executablePath, let data = FileManager.default.contents(atPath: path) else { return nil }
    return String(hexString(sha256([UInt8](data))).prefix(8))
}

// MARK: - wc -l semantics, self-implemented (never spawns a process)

// Counts newline bytes only -- exactly what `wc -l` counts, including an unterminated trailing
// partial line NOT being counted. Returns 0 if the file does not yet exist (the App may not have
// created the judgement file yet when the first sample runs).
func countNewlines(path: String) -> Int {
    guard let handle = FileHandle(forReadingAtPath: path) else { return 0 }
    defer { handle.closeFile() }
    var count = 0
    while true {
        let chunk = handle.readData(ofLength: 1 << 16)
        if chunk.isEmpty { break }
        for byte in chunk where byte == 0x0A {
            count += 1
        }
    }
    return count
}

// MARK: - process existence (never spawns a process: signal 0 is the standard POSIX no-op probe)

func processExists(pid: Int32) -> Bool {
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

// MARK: - the one CGWindowListCopyWindowInfo call site

func copyWindowList() -> [[String: AnyObject]]? {
    return CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: AnyObject]]
}

// MARK: - the one four-key extraction site

struct WindowEntry {
    let number: Int
    let layer: Int
    let width: Int
    let height: Int
}

// Only ever reads owner PID, layer, number and bounds -- see the file header's red line.
func filterEntries(_ windowTable: [[String: AnyObject]], pid: Int32) -> [WindowEntry] {
    var result: [WindowEntry] = []
    for item in windowTable {
        guard let ownerPID = item[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid else { continue }
        let layer = (item[kCGWindowLayer as String] as? Int) ?? Int.min
        let number = (item[kCGWindowNumber as String] as? Int) ?? 0
        var width = 0
        var height = 0
        if let bounds = item[kCGWindowBounds as String] as? [String: CGFloat] {
            width = Int((bounds["Width"] ?? 0).rounded())
            height = Int((bounds["Height"] ?? 0).rounded())
        }
        result.append(WindowEntry(number: number, layer: layer, width: width, height: height))
    }
    return result
}

// l0/l3/l25 are per-layer entry counts, lx is every other layer's entries (the missing-layer
// sentinel included); wins is the number-ascending "<num>:<layer>:<w>x<h>" list, or "none".
func summarizeEntries(_ entries: [WindowEntry]) -> (l0: Int, l3: Int, l25: Int, lx: Int, wins: String) {
    var l0 = 0, l3 = 0, l25 = 0, lx = 0
    for e in entries {
        switch e.layer {
        case 0: l0 += 1
        case 3: l3 += 1
        case 25: l25 += 1
        default: lx += 1
        }
    }
    let sorted = entries.sorted { $0.number < $1.number }
    let wins = sorted.isEmpty
        ? "none"
        : sorted.map { "\($0.number):\($0.layer):\($0.width)x\($0.height)" }.joined(separator: ",")
    return (l0, l3, l25, lx, wins)
}

// MARK: - the five line builders (one literal prefix and one build site each)

func buildStartLine(pid: Int32, periodS: Int, sha8: String) -> String {
    return "[wincount-start] app-pid=\(pid) period-s=\(periodS) helper-sha8=\(sha8)"
}

func buildSampleLine(
    seq: Int, ts: Int, curA: Int, curB: Int, pid: Int32, found: Bool,
    l0: Int, l3: Int, l25: Int, lx: Int, wins: String
) -> String {
    return "[wincount] seq=\(seq) ts=\(ts) cur-a=\(curA) cur-b=\(curB) pid=\(pid) found=\(found ? 1 : 0) l0=\(l0) l3=\(l3) l25=\(l25) lx=\(lx) wins=\(wins)"
}

func buildEndLine(rows: Int, reason: String) -> String {
    return "[wincount-end] rows=\(rows) reason=\(reason)"
}

func buildSelfCheckLine(status: String, entries: Int, total: Int) -> String {
    return "[wincount-selfcheck] \(status) entries=\(entries) total=\(total) keys=owner-pid,layer,number,bounds"
}

func buildUsageLine() -> String {
    return "[wincount-usage] window-count-sampler --pid <p> --period-s <P> --judgement-file <path> [--timeout-s <T>] [--self-check] (p, P, T: whole numbers >= 1)"
}

// MARK: - argument parsing

struct Options {
    var pid: Int32?
    var periodS: Int?
    var judgementFile: String?
    var timeoutS: Int?
    var selfCheck = false
}

func parseArgs(_ args: [String]) -> Options {
    var opts = Options()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--pid":
            i += 1
            guard i < args.count, let v = Int32(args[i]), v >= 1 else { usageErrorExit() }
            opts.pid = v
        case "--period-s":
            i += 1
            guard i < args.count, let v = Int(args[i]), v >= 1 else { usageErrorExit() }
            opts.periodS = v
        case "--judgement-file":
            i += 1
            guard i < args.count else { usageErrorExit() }
            opts.judgementFile = args[i]
        case "--timeout-s":
            i += 1
            guard i < args.count, let v = Int(args[i]), v >= 1 else { usageErrorExit() }
            opts.timeoutS = v
        case "--self-check":
            opts.selfCheck = true
        default:
            usageErrorExit()
        }
        i += 1
    }
    return opts
}

let opts = parseArgs(Array(CommandLine.arguments.dropFirst()))

// MARK: - --self-check

if opts.selfCheck {
    let targetPid = opts.pid ?? getpid()
    guard let windowTable = copyWindowList() else { exit(2) }
    let entries = filterEntries(windowTable, pid: targetPid).count
    let total = windowTable.count
    let passed = opts.pid == nil ? total > 0 : entries > 0
    if passed {
        writeLine(buildSelfCheckLine(status: "ok", entries: entries, total: total))
        exit(0)
    }
    writeLine(buildSelfCheckLine(status: "empty", entries: entries, total: total))
    exit(3)
}

// MARK: - main sampling loop

guard let pid = opts.pid, let periodS = opts.periodS, let judgementFile = opts.judgementFile else {
    usageErrorExit()
}
guard let sha8 = helperSha8() else { exit(2) }
writeLine(buildStartLine(pid: pid, periodS: periodS, sha8: sha8))

let clock = ContinuousClock()
let startedAt = clock.now
var seq = 0
while true {
    if let timeoutS = opts.timeoutS, clock.now - startedAt >= .seconds(timeoutS) {
        writeLine(buildEndLine(rows: seq, reason: "timeout"))
        exit(0)
    }
    if terminateRequested {
        writeLine(buildEndLine(rows: seq, reason: "done"))
        exit(0)
    }

    let curA = countNewlines(path: judgementFile)
    guard let windowTable = copyWindowList() else {
        writeLine(buildEndLine(rows: seq, reason: "enum-nil"))
        exit(2)
    }
    let entries = filterEntries(windowTable, pid: pid)
    let curB = countNewlines(path: judgementFile)
    let found = processExists(pid: pid)
    let (l0, l3, l25, lx, wins) = summarizeEntries(entries)
    let ts = Int(Date().timeIntervalSince1970)
    seq += 1
    writeLine(buildSampleLine(
        seq: seq, ts: ts, curA: curA, curB: curB, pid: pid, found: found,
        l0: l0, l3: l3, l25: l25, lx: lx, wins: wins
    ))

    if !found {
        writeLine(buildEndLine(rows: seq, reason: "pid-gone"))
        exit(0)
    }
    sleepInterruptible(seconds: periodS)
}
