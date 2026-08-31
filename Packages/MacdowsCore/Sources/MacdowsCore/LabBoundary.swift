import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The Swift mirror of `Scripts/lib.sh`'s `crdp_assert_lab_boundary`: the live-host testing
/// boundary gate (owner rule, 2026-08-31) that says a real-host debugging step may only ever
/// target the owner's own machine inside the owner's own lab network.
///
/// **Why a second implementation exists.** The shell gate can only guard things that go
/// through a shell. Three live entry points never did: `AppDelegate.connectTapped` builds a
/// `CRSession` straight from `host.env` when a human presses Connect, `Tools/window-smoke`
/// does the same when it is run directly rather than through
/// `Scripts/run-window-smoke.command`, and `Tools/bridge-smoke` did the same, straight from
/// `main.mm`, with no gate at all. Prose in a rules file cannot stop any of them, so the rule
/// is enforced in-process, by this type, at all three. `Scripts/lib.sh` remains the
/// semantic authority — this is a mirror of it, not a second opinion, and any place the two
/// could disagree is called out in a comment below.
///
/// **`Tools/rail-probe` is a parked exception, not a fourth entry point covered here.** It is
/// gated only at the launcher level (`Scripts/probe.sh` runs `crdp_assert_lab_boundary` before
/// building or invoking it); the C binary itself has no in-process check and, run directly out
/// of its build directory with an arbitrary `--host`, is not gated at all. Adding one in C would
/// mean a third implementation of the rule, which is what this file exists to avoid, so the gap
/// is parked rather than closed.
///
/// **Fail-closed by construction.** Every path that cannot positively prove the target is
/// inside an allowed segment produces a `Verdict.refused`. Missing boundary file, empty
/// segment list, an unparseable segment, empty host, a name that does not resolve, a name that
/// resolves to several addresses of which any single one falls outside — all refusals. There
/// is no "assume allowed" branch anywhere in this file.
///
/// **The segments never come out.** The allowed segments are maintainer-local data that never
/// appears in a tracked file; they are read at call time from the untracked boundary file.
/// Nothing here ever renders a segment, or the address a name resolved to, into a string: a
/// refusal names the host the caller passed in and a reason *category*, and that is all
/// (`LabBoundaryTests` asserts the whole refusal vocabulary against the fixture segments, the
/// same no-leak assertion `Scripts/test-lab-boundary.sh` makes against the shell gate).
///
/// That is enforced, not merely implied by omission. `Segment` and `Address` both carry
/// redacting `CustomStringConvertible`/`CustomDebugStringConvertible` conformances, because
/// withholding a `description` is *not* enough on its own: Swift's default string
/// interpolation and `String(describing:)`/`String(reflecting:)` fall back to runtime
/// reflection, which ignores access control and would happily print `networkBytes` from
/// another module. `print(segment)` has to be safe in this file above all others, so it is
/// made safe rather than assumed to be.
public enum LabBoundary {
    // MARK: - Addresses and segments (pure; no filesystem, no DNS)

    /// One IP address, either family, as its wire bytes.
    ///
    /// `bytes` is public deliberately — a caller that has an address usually needs to do
    /// something with it — but nothing here ever *renders* one, and the redacting
    /// `description`/`debugDescription` below make that hold for reflection too. A resolved
    /// address is a fact about the owner's network, and `Scripts/lib.sh` never prints one
    /// either.
    public struct Address: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable
    {
        public enum Family: Hashable, Sendable {
            case v4
            case v6
        }

        public let family: Family
        /// Big-endian wire bytes: 4 for `.v4`, 16 for `.v6`.
        public let bytes: [UInt8]

        init(family: Family, bytes: [UInt8]) {
            self.family = family
            self.bytes = bytes
        }

        /// Redacted on purpose. Without this, `"\(address)"` and `String(describing:)` fall
        /// back to reflection and print the octets from any module. The family is safe to
        /// state (it is not a fact about the owner's network) and makes a log line useful
        /// without making it a leak.
        public var description: String { "<lab-boundary address, \(family == .v4 ? "IPv4" : "IPv6")>" }

        /// Same redaction for `String(reflecting:)`, `debugPrint`, `po` in LLDB and the
        /// `%@`-style paths that prefer a debug description — reflection reaches all of them.
        public var debugDescription: String { description }

        /// `dump` prints the custom string as its header and then walks `Mirror`'s children
        /// regardless, so without this it would still emit the octets one per line. `bytes`
        /// stays public for callers that deliberately want them; what is closed here is the
        /// accidental path.
        public var customMirror: Mirror {
            let noChildren: KeyValuePairs<String, Any> = [:]
            return Mirror(self, children: noChildren)
        }

        /// Parses a numeric address literal. No DNS, no filesystem, no ambiguity — this is the
        /// path `192.0.2.10` and `2001:db8::1` take, and it is why a literal target is judged
        /// without a resolver ever being consulted.
        ///
        /// Mirrors Python's `ipaddress.ip_address` (what `lib.sh` uses) rather than libc's
        /// `inet_pton` alone, because the two disagree in a way that matters: `inet_pton` on
        /// this platform *accepts* IPv4 octets with leading zeros and reads them as decimal
        /// (`192.000.2.010` is taken as `192.0.2.10`), whereas `ipaddress` rejects them outright
        /// (CPython bpo-36384, closed as a security bug — other resolvers read a
        /// leading zero as *octal*, so accepting the string at all means two components can
        /// disagree about which host was meant). Rejecting them here reproduces `lib.sh`
        /// exactly: as a segment, a leading-zero literal is an unparseable segment and refuses
        /// the whole gate; as a host, it is simply not a literal, and falls through to
        /// `getaddrinfo` — whatever that decides, both implementations decide it the same way.
        ///
        /// The rule applies to the **embedded IPv4 tail of an IPv6 literal too**, not just to
        /// the bare dotted-quad form, which is why `parsingIPv4Octets` is called on that tail
        /// before `inet_pton` ever sees the string. `inet_pton(AF_INET6, "::ffff:192.000.2.010")`
        /// succeeds on Darwin while `ipaddress.ip_address` on the same text raises — CPython
        /// hands the last colon-separated component to its own strict `IPv4Address` parser
        /// (`_ip_int_from_string`), so a leading zero there is just as fatal as in `192.000.2.10`.
        /// Delegating the whole IPv6 branch to `inet_pton` would therefore have let a boundary
        /// file containing `::ffff:192.000.2.0/120` be *enforced* here and *refused* by
        /// `lib.sh`, which is the shell-refuses/mirror-permits direction this whole type exists
        /// to avoid.
        public init?(literal: String) {
            // A colon is what separates the two families for both parsers: Python tries
            // IPv4Address first and IPv6Address second, and no IPv4 literal contains a colon
            // while every IPv6 literal (including the IPv4-mapped `::ffff:a.b.c.d` form) does.
            if literal.contains(":") {
                // `%zone` is stripped before parsing, matching what `lib.sh` does to every
                // resolver answer (`info[4][0].split("%")[0]`) and what `ipaddress` does to a
                // scoped literal (it keeps the scope as metadata, but membership is decided on
                // the address bits alone, so the verdict is identical). An empty zone, or a
                // second `%`, is rejected — `ipaddress` rejects both.
                let (addressText, zone) = Self.splittingZone(literal)
                if let zone, zone.isEmpty || zone.contains("%") { return nil }
                guard Self.embeddedIPv4TailIsCanonical(addressText) else { return nil }
                var storage = in6_addr()
                let parsed = addressText.withCString { inet_pton(AF_INET6, $0, &storage) }
                guard parsed == 1 else { return nil }
                self.init(family: .v6, bytes: withUnsafeBytes(of: storage) { Array($0) })
            } else {
                guard let octets = Self.parsingIPv4Octets(literal) else { return nil }
                self.init(family: .v4, bytes: octets)
            }
        }

        /// Applies the strict dotted-quad rule to the embedded IPv4 tail of an IPv6 literal,
        /// exactly where CPython applies it: the *last* colon-separated component, and only when
        /// it contains a dot. `true` when there is no such tail, so a plain hex literal is
        /// unaffected. A dot anywhere other than that last component is left to `inet_pton`,
        /// which rejects it — as does CPython, which would fail to read it as a hextet.
        private static func embeddedIPv4TailIsCanonical(_ addressText: String) -> Bool {
            guard let lastColon = addressText.lastIndex(of: ":") else { return true }
            let tail = addressText[addressText.index(after: lastColon)...]
            guard tail.contains(".") else { return true }
            return parsingIPv4Octets(String(tail)) != nil
        }

        /// Splits `fe80::1%en0` into `("fe80::1", "en0")`. The zone is `nil` when there is no
        /// `%` at all, which is a different thing from an empty zone (`fe80::1%`, invalid).
        private static func splittingZone(_ literal: String) -> (address: String, zone: String?) {
            guard let separator = literal.firstIndex(of: "%") else { return (literal, nil) }
            return (String(literal[literal.startIndex..<separator]), String(literal[literal.index(after: separator)...]))
        }

        /// Dotted-quad parsing with `ipaddress`' own strictness, byte for byte: exactly four
        /// parts, each one to three ASCII decimal digits, no leading zero unless the octet *is*
        /// `0`, and each value at most 255.
        private static func parsingIPv4Octets(_ literal: String) -> [UInt8]? {
            let parts = literal.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var octets: [UInt8] = []
            octets.reserveCapacity(4)
            for part in parts {
                guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
                guard part == "0" || part.first != "0" else { return nil }
                guard let value = UInt8(part) else { return nil }
                octets.append(value)
            }
            return octets
        }
    }

    /// One allowed CIDR segment.
    ///
    /// Intentionally opaque from outside the module: the only public operations are "parse
    /// one" and "does this address fall inside", so no caller can render a segment into a log
    /// line, an error message or a crash report. That restriction is the entire reason the
    /// owner's network shape can live in an untracked file and stay there.
    ///
    /// Internal stored properties are **not** sufficient to achieve that, which is worth
    /// stating because the opposite is the intuitive belief: Swift's reflection-based default
    /// `description` ignores access control, so before the redacting conformances below,
    /// `print(segment)` from another module emitted
    /// `Segment(family: …, prefixLength: 24, networkBytes: [198, 51, 100, 0])` — the segment,
    /// in full, in whatever log the caller was writing. `segmentsCannotBeStringified` pins the
    /// fix against every rendering entry point Swift offers.
    public struct Segment: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable
    {
        let family: Address.Family
        let prefixLength: Int
        /// `base`, with every host bit already cleared — i.e. `ipaddress.ip_network(...,
        /// strict=False)`, which is the form `lib.sh` builds and which makes `contains` a
        /// single comparison.
        let networkBytes: [UInt8]

        /// Redacted, and deliberately carrying no distinguishing detail at all — not even the
        /// family or the prefix length, either of which narrows the search space for anyone
        /// reading a log. There is no legitimate reason to render a segment; the gate's whole
        /// output vocabulary is `Refusal`.
        public var description: String { "<lab-boundary segment, redacted>" }

        /// Same redaction for `String(reflecting:)`, `debugPrint` and LLDB's `po`.
        public var debugDescription: String { description }

        /// `description`/`debugDescription` are **not** sufficient on their own, which is only
        /// obvious once you check: `dump(segment)` takes the custom string for its header line
        /// and then walks `Mirror`'s children anyway, printing `networkBytes` element by
        /// element. Anything else built on `Mirror` (structured loggers, debug inspectors) does
        /// the same. An empty custom mirror closes that last path.
        public var customMirror: Mirror {
            let noChildren: KeyValuePairs<String, Any> = [:]
            return Mirror(self, children: noChildren)
        }

        /// Parses one CIDR entry with `ipaddress.ip_network(..., strict=False)` semantics:
        /// a bare address means the whole-length prefix (`/32`, `/128`), host bits set below
        /// the prefix are masked away rather than rejected, and — for IPv4 only, exactly as in
        /// CPython — a dotted netmask (`/255.255.255.0`) or hostmask (`/0.0.0.255`) is accepted
        /// in place of a prefix length.
        ///
        /// Returns `nil` for anything else. That `nil` is load-bearing: one unparseable entry
        /// refuses the *whole* gate rather than being skipped, because a boundary file the
        /// caller cannot fully understand is a boundary the caller cannot enforce.
        public init?(cidr: String) {
            let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 1 || parts.count == 2 else { return nil }
            guard let base = Address(literal: String(parts[0])) else { return nil }
            let maximum = base.family == .v4 ? 32 : 128

            let prefixLength: Int
            if parts.count == 1 {
                prefixLength = maximum
            } else {
                let mask = String(parts[1])
                if Self.isASCIIDecimal(mask) {
                    // `Int(...)` also rejects a digit string too long to be an `Int`, which
                    // CPython turns into an out-of-range prefix and the same refusal.
                    guard let value = Int(mask), value >= 0, value <= maximum else { return nil }
                    prefixLength = value
                } else if base.family == .v4, let derived = Self.prefixLength(fromDottedMask: mask) {
                    prefixLength = derived
                } else {
                    return nil
                }
            }

            self.family = base.family
            self.prefixLength = prefixLength
            self.networkBytes = Self.maskingHostBits(base.bytes, prefixLength: prefixLength)
        }

        /// Whether `address` falls inside this segment.
        ///
        /// A cross-family comparison is always `false`, never an error — this is exactly what
        /// `ipaddress`' own `__contains__` does ("always false if one is v4 and the other is
        /// v6"), and it is the reason an IPv4-mapped IPv6 answer such as `::ffff:192.0.2.1` is
        /// **not** considered a member of the IPv4 segment `192.0.2.0/24`. Matching that
        /// matters more than "being helpful": a mapped answer that the shell gate refuses and
        /// this one allowed would be a hole that only ever opened on one of the two paths.
        public func contains(_ address: Address) -> Bool {
            guard address.family == family else { return false }
            return Self.maskingHostBits(address.bytes, prefixLength: prefixLength) == networkBytes
        }

        /// Parses a whitespace-separated segment list, the shape `MACDOWS_LAB_ALLOWED_NETS`
        /// carries. `nil` when any single entry fails to parse (see `init?(cidr:)`).
        public static func parseList(_ text: String) -> [Segment]? {
            var segments: [Segment] = []
            for token in text.split(whereSeparator: { $0.isWhitespace }) {
                guard let segment = Segment(cidr: String(token)) else { return nil }
                segments.append(segment)
            }
            return segments
        }

        private static func isASCIIDecimal(_ text: String) -> Bool {
            // CPython guards the same two things here, and for the same reason: `int()` would
            // otherwise happily accept `+24`, ` 24 ` and non-ASCII decimal digits.
            !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
        }

        /// CPython's `_prefix_from_ip_string`: try the value as a netmask, then as a hostmask,
        /// and reject anything whose one-bits are not one contiguous run from the top.
        private static func prefixLength(fromDottedMask mask: String) -> Int? {
            guard let parsed = Address(literal: mask), parsed.family == .v4 else { return nil }
            if let length = contiguousLeadingOnes(parsed.bytes) { return length }
            return contiguousLeadingOnes(parsed.bytes.map { ~$0 })
        }

        /// The number of leading one-bits, but only when every remaining bit is zero.
        private static func contiguousLeadingOnes(_ bytes: [UInt8]) -> Int? {
            var value: UInt32 = 0
            for byte in bytes {
                value = (value << 8) | UInt32(byte)
            }
            let ones = (~value).leadingZeroBitCount
            let expected: UInt32 = ones == 0 ? 0 : ~(UInt32.max >> ones)
            return value == expected ? ones : nil
        }

        private static func maskingHostBits(_ bytes: [UInt8], prefixLength: Int) -> [UInt8] {
            var masked = bytes
            for index in masked.indices {
                let bitsBefore = index * 8
                if prefixLength >= bitsBefore + 8 { continue }
                if prefixLength <= bitsBefore {
                    masked[index] = 0
                    continue
                }
                let keptBits = prefixLength - bitsBefore
                masked[index] &= UInt8(truncatingIfNeeded: 0xFF << (8 - keptBits))
            }
            return masked
        }
    }

    // MARK: - Verdicts

    /// Why the gate refused. One case per distinct reason, so a caller (or a test) can tell
    /// "your boundary file is missing" from "your target is out of bounds" without matching on
    /// message text. The wording of `reasonText` deliberately reproduces `lib.sh`'s own.
    public enum Refusal: Hashable, Sendable {
        /// No target at all. `lib.sh` tests `[ -z "$host" ]`, i.e. the empty string only.
        case emptyHost
        /// The boundary file does not exist, is not a file, or this process may not read it.
        case boundaryFileUnreadable(path: String)
        /// The boundary file parsed, but `MACDOWS_LAB_ALLOWED_NETS` is absent, empty or
        /// entirely whitespace.
        case noAllowedSegments
        /// At least one entry in the segment list is not a CIDR this gate can evaluate. The
        /// offending text is *not* carried — it is a fragment of the segment list.
        case unparseableSegment
        /// `getaddrinfo` failed for the host.
        case hostDoesNotResolve
        /// `getaddrinfo` succeeded but returned an answer this gate cannot read as an address.
        case hostResolvedToUnparseableAddress
        /// `getaddrinfo` succeeded and returned nothing at all.
        case hostResolvesToNoAddress
        /// The host is real and resolvable, and at least one of its addresses is out of
        /// bounds. One stray answer is enough — see `evaluate(host:segments:resolve:)`.
        case outsideAllowedSegments

        /// The human-readable reason, matching the text `lib.sh` prints for the same case.
        /// Contains no segment, and no resolved address, ever.
        public var reasonText: String {
            switch self {
            case .emptyHost:
                return "empty target host"
            case .boundaryFileUnreadable(let path):
                return "boundary file not readable: \(path)"
            case .noAllowedSegments:
                return "boundary file defines no allowed segments"
            case .unparseableSegment:
                return "boundary file lists an unparseable segment"
            case .hostDoesNotResolve:
                return "host does not resolve"
            case .hostResolvedToUnparseableAddress:
                return "host resolved to an unparseable address"
            case .hostResolvesToNoAddress:
                return "host resolves to no address"
            case .outsideAllowedSegments:
                return "target is outside the allowed lab segments"
            }
        }
    }

    /// The gate's answer. `refused` is the default in spirit: there is exactly one place in
    /// this file that produces `.allowed`, and it is reached only after every address the host
    /// stands for has been shown to be inside an allowed segment.
    public enum Verdict: Hashable, Sendable {
        case allowed
        case refused(Refusal)

        public var isAllowed: Bool {
            if case .allowed = self { return true }
            return false
        }

        public var refusal: Refusal? {
            if case .refused(let refusal) = self { return refusal }
            return nil
        }
    }

    /// What a name lookup produced. Three outcomes rather than an optional array, because
    /// `lib.sh` gives each of them its own refusal reason and collapsing them would lose the
    /// one piece of diagnosis a refused operator actually gets.
    public enum Resolution: Hashable, Sendable {
        case resolved([Address])
        /// The lookup itself failed (`getaddrinfo` error, malformed name, no such host).
        case unresolvable
        /// The lookup returned something that is not an address this gate can read.
        case unparseableAnswer
    }

    // MARK: - Evaluation

    /// The whole rule, with the boundary data supplied directly and name resolution injected.
    /// No filesystem and no DNS: this is the layer the tests exercise.
    ///
    /// The membership rule is `all`, not `any`: a name that resolves to several addresses is
    /// refused unless *every* one of them is inside. That is the clause most likely to be
    /// "simplified" by a future edit, and the one whose loss would be invisible — a host whose
    /// A record is in-lab and whose AAAA record is not would sail straight through an `any`.
    public static func evaluate(
        host: String,
        segments: [Segment],
        resolve: (String) -> Resolution
    ) -> Verdict {
        guard !host.isEmpty else { return .refused(.emptyHost) }
        guard !segments.isEmpty else { return .refused(.noAllowedSegments) }

        let addresses: [Address]
        if let literal = Address(literal: host) {
            // A literal is judged as written; the resolver is never consulted, so a gate
            // decision about a numeric target cannot be changed by anything on the network.
            addresses = [literal]
        } else {
            switch resolve(host) {
            case .resolved(let resolved):
                guard !resolved.isEmpty else { return .refused(.hostResolvesToNoAddress) }
                addresses = resolved
            case .unresolvable:
                return .refused(.hostDoesNotResolve)
            case .unparseableAnswer:
                return .refused(.hostResolvedToUnparseableAddress)
            }
        }

        let everyAddressIsInside = addresses.allSatisfy { address in
            segments.contains { $0.contains(address) }
        }
        return everyAddressIsInside ? .allowed : .refused(.outsideAllowedSegments)
    }

    /// Same rule, taking the raw `MACDOWS_LAB_ALLOWED_NETS` text. Splits on whitespace exactly
    /// as `lib.sh`'s Python does, and reproduces its two distinct degraded-configuration
    /// refusals (nothing listed vs. something listed that will not parse).
    public static func evaluate(
        host: String,
        allowedNets: String,
        resolve: (String) -> Resolution
    ) -> Verdict {
        guard !host.isEmpty else { return .refused(.emptyHost) }
        guard allowedNets.contains(where: { !$0.isWhitespace }) else { return .refused(.noAllowedSegments) }
        guard let segments = Segment.parseList(allowedNets) else { return .refused(.unparseableSegment) }
        guard !segments.isEmpty else { return .refused(.noAllowedSegments) }
        return evaluate(host: host, segments: segments, resolve: resolve)
    }

    /// Same rule, reading the segment list out of a boundary file. The check order mirrors
    /// `lib.sh`'s: empty host first, then the file, then its contents, then the target.
    ///
    /// `lib.sh` *sources* the boundary file; this parses it with `EnvFile`. For a file of the
    /// documented shape (`MACDOWS_LAB_ALLOWED_NETS="..."`, optionally `export`-prefixed) the
    /// two agree exactly. Everywhere they do not is listed here — the list is meant to be
    /// exhaustive, and a future divergence found outside it is a bug in this comment:
    ///
    /// 1. **Shell expansion and line continuations.** A value built with `$OTHER`, command
    ///    substitution or a trailing backslash is evaluated by the shell and taken literally
    ///    here. `EnvFile` reads the file as data and never executes it, on purpose (that is the
    ///    whole point for a file whose contents are sensitive), so such a value is almost
    ///    certainly unparseable here and refuses. Fail-closed.
    /// 2. **An unquoted value containing whitespace** — `MACDOWS_LAB_ALLOWED_NETS=a/24 b/24`
    ///    with no quotes. This one runs the *other* way and is the reason the list above is
    ///    spelled out rather than gestured at. To `sh` that line is an assignment prefix on the
    ///    command `b/24`, which does not exist: the source fails, the assignment never reaches
    ///    the shell's own environment, `nets` collapses to empty and `lib.sh:81-84` refuses
    ///    *everything*, including hosts inside `a/24`. `EnvFile` keeps the whole right-hand
    ///    side, `Segment.parseList` splits it on whitespace, and both segments are enforced
    ///    here. **This behaviour is chosen, not inherited** (`unquotedSegmentListIsEnforced`
    ///    pins it): the segments enforced are exactly the ones the maintainer typed, so nothing
    ///    outside their own boundary file is ever reachable — the divergence is "the mirror
    ///    still works where the authority gives up", and the alternative (refusing a
    ///    syntactically fine list because of a missing pair of quotes) would train a maintainer
    ///    to distrust the gate rather than the file. The canonical file is quoted, and
    ///    `lib.sh`'s blanket refusal makes the unquoted form self-correcting the moment any
    ///    shell-side step runs.
    /// 3. **A non-UTF-8 boundary file** refuses here as `boundaryFileUnreadable`, where `lib.sh`
    ///    would source the bytes, get nothing usable and refuse as "defines no allowed
    ///    segments". Both refuse; only the reason category differs.
    /// 4. **A trailing inline comment** — `MACDOWS_LAB_ALLOWED_NETS=192.0.2.0/24 # the lab`, in
    ///    both the bare and the quoted spelling. `sh` strips it and allows; `EnvFile` keeps it
    ///    (see that type's own "deliberately not supported" note, which matches
    ///    `run-window-smoke.command`'s `sed`), so `#` and `the` and `lab` arrive as segment
    ///    tokens, fail to parse, and refuse. Fail-closed, and pinned by
    ///    `trailingInlineCommentInTheBoundaryFileRefuses`. Left as-is rather than "fixed":
    ///    teaching this parser shell comment rules would have to happen in `EnvFile`, where it
    ///    would also change how `host.env` values are read — a password may legitimately
    ///    contain ` #`, and silently truncating one there would be far worse than refusing a
    ///    boundary file whose comment the maintainer can simply move to its own line.
    ///
    /// 5. Not a divergence but worth stating next to them: `EnvFile`'s last-occurrence-wins rule
    ///    is the same as `sh`'s, so a file with two assignments enforces the same one on both
    ///    paths (`boundaryFileLastAssignmentWins`).
    public static func evaluate(
        host: String,
        boundaryFilePath: String,
        resolve: (String) -> Resolution = systemResolve
    ) -> Verdict {
        guard !host.isEmpty else { return .refused(.emptyHost) }
        let values: [String: String]
        do {
            values = try EnvFile.parse(path: boundaryFilePath)
        } catch {
            return .refused(.boundaryFileUnreadable(path: boundaryFilePath))
        }
        return evaluate(host: host, allowedNets: values[allowedNetsKey] ?? "", resolve: resolve)
    }

    /// The production entry point: judge `host` against the maintainer's own boundary file,
    /// resolving names through the system resolver. This is what `AppDelegate`, `window-smoke`
    /// and (via `Tools/bridge-smoke/GateShim.swift`) `bridge-smoke` call immediately before
    /// they would otherwise dial.
    public static func check(host: String, resolve: (String) -> Resolution = systemResolve) -> Verdict {
        evaluate(host: host, boundaryFilePath: defaultBoundaryFilePath(), resolve: resolve)
    }

    /// The only key the boundary file is allowed to matter for.
    public static let allowedNetsKey = "MACDOWS_LAB_ALLOWED_NETS"

    /// `$MACDOWS_LAB_BOUNDARY_FILE` when set and non-empty, else
    /// `~/.config/macdows/lab-boundary.env` — the same resolution `lib.sh` performs, and the
    /// reason a test can point the gate at a throwaway fixture without touching the real file.
    ///
    /// One documented divergence: with `HOME` unset or empty, `lib.sh` degrades to the
    /// unusable absolute path `/.config/macdows/lab-boundary.env` (and therefore refuses),
    /// while this falls back to `NSHomeDirectory()`, the process's actual home. That is the
    /// more correct answer for a bundled app — whose home is its container, not `$HOME` — and
    /// in every configuration where `HOME` is set the two produce the identical path.
    ///
    /// **The rule itself now lives in `MacdowsPaths`, and this is a forwarder.** Not a
    /// cosmetic move: `host.env` — the file the *host* being judged comes out of — used to be
    /// located by a second, different rule (`NSHomeDirectory()`, at all three call sites), so
    /// under a redirected `HOME` the gate's two inputs could come from two different homes. A
    /// review measured that skew and parked the fix; `MacdowsPaths` is it, and the reconciled
    /// order is the `$HOME`-preferring one *this* function already used, chosen deliberately
    /// (see that type's doc comment for the four reasons). Consequently **this function's
    /// behaviour is unchanged in every environment**, including a redirected `HOME`: the gate
    /// reads the same boundary file it read before, so nothing in the divergence list above
    /// moves and the pinned cases in `boundaryFilePathResolution` still hold verbatim. What
    /// changed is that `host.env` joined this rule rather than keeping its own.
    public static func defaultBoundaryFilePath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        MacdowsPaths.boundaryFilePath(environment: environment)
    }

    // MARK: - Rendering

    /// What `lib.sh` prints when it lets a target through.
    public static let allowedLine = "[lab-boundary] target inside allowed segments"

    /// A refusal line in `lib.sh`'s own format, for a caller that may name the host.
    ///
    /// Naming the host is a judgement call the *caller* makes, not this type: it is fine in an
    /// app's on-screen status label (the operator typed it and is looking at it), and it is
    /// deliberately avoided by `window-smoke`, whose file header commits to never printing
    /// `WIN_HOST` because its output is tee'd into a log file. Use `Refusal.reasonText` alone
    /// for the second kind of caller.
    public static func refusalLine(host: String, refusal: Refusal) -> String {
        if case .emptyHost = refusal {
            return "[lab-boundary] REFUSED: \(refusal.reasonText)"
        }
        return "[lab-boundary] REFUSED: \(host) -- \(refusal.reasonText)"
    }

    // MARK: - System resolution

    /// `getaddrinfo` for both families, matching `socket.getaddrinfo(host, None)` — the call
    /// `lib.sh` makes — including its lack of hints beyond `AF_UNSPEC`.
    ///
    /// Reads the address bytes straight out of each `sockaddr` instead of round-tripping
    /// through a numeric string the way the Python does. Same answers, one less parser in the
    /// path, and no chance of a `%zone` suffix appearing in the middle of the comparison.
    public static func systemResolve(_ host: String) -> Resolution {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC

        var head: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { getaddrinfo($0, nil, &hints, &head) }
        guard status == 0 else { return .unresolvable }
        guard let first = head else { return .resolved([]) }
        defer { freeaddrinfo(first) }

        var addresses: [Address] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor {
            guard let socketAddress = node.pointee.ai_addr else { return .unparseableAnswer }
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_INET:
                let value = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr
                }
                addresses.append(Address(family: .v4, bytes: withUnsafeBytes(of: value) { Array($0) }))
            case AF_INET6:
                let value = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr
                }
                addresses.append(Address(family: .v6, bytes: withUnsafeBytes(of: value) { Array($0) }))
            default:
                // Not reachable with AF_UNSPEC hints today, and a refusal rather than a skip if
                // it ever becomes reachable: an answer this gate cannot judge is an answer it
                // must not wave through.
                return .unparseableAnswer
            }
            cursor = node.pointee.ai_next
        }
        return .resolved(addresses)
    }
}
