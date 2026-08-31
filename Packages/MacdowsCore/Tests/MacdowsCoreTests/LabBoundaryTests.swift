import Foundation
import Testing

@testable import MacdowsCore

/// Every fixture segment and every fixture host in this file is an RFC-reserved documentation
/// range — 192.0.2.0/24 and 198.51.100.0/24 and 203.0.113.0/24 (RFC 5737), 2001:db8::/32 (RFC
/// 3849) — plus loopback (RFC 1122) for the one case that needs a segment some, but not all,
/// of a multi-address answer falls inside. None of them is a private-network prefix, none can
/// name a real host, and every one of them is safe to commit: this file is tracked in a public
/// repository whose Tier 1 CI fails the push if a private-network literal appears anywhere in
/// it.
private enum Fixture {
    static let allowedV4 = "192.0.2.0/24"
    static let allowedV6 = "2001:db8:aaaa::/48"
    static let allowedBoth = "\(allowedV4) \(allowedV6)"
    static let allowedLoopbackV4 = "127.0.0.0/8"

    static let insideV4 = "192.0.2.10"
    static let insideV6 = "2001:db8:aaaa::1"
    /// Outside the allowed v4 segment, still inside RFC 5737's documentation space.
    static let outsideV4 = "198.51.100.7"
    /// Outside the allowed v6 segment, still inside RFC 3849's documentation space.
    static let outsideV6 = "2001:db8:bbbb::1"
}

/// A stand-in for `getaddrinfo` that records what it was asked. Two jobs: it makes the
/// multi-address cases constructible without a network (the whole suite is offline — no test
/// here performs a real lookup), and it lets the literal-target cases assert the *negative*
/// that matters most, that a numeric target is judged as written and never handed to a
/// resolver at all.
private final class ResolverSpy {
    private(set) var hostsAsked: [String] = []
    private let answer: LabBoundary.Resolution

    init(_ answer: LabBoundary.Resolution) {
        self.answer = answer
    }

    convenience init(resolvingTo literals: [String]) {
        self.init(.resolved(literals.compactMap(LabBoundary.Address.init(literal:))))
    }

    func resolve(_ host: String) -> LabBoundary.Resolution {
        hostsAsked.append(host)
        return answer
    }
}

@Suite("LabBoundary: address and segment parsing")
struct LabBoundaryParsingTests {
    @Test("IPv4 and IPv6 literals parse to their wire bytes")
    func literalsParse() throws {
        let v4 = try #require(LabBoundary.Address(literal: "192.0.2.10"))
        #expect(v4.family == .v4)
        #expect(v4.bytes == [192, 0, 2, 10])

        let v6 = try #require(LabBoundary.Address(literal: "2001:db8::1"))
        #expect(v6.family == .v6)
        #expect(v6.bytes == [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    }

    /// libc's `inet_pton` accepts these and reads them as decimal; Python's `ipaddress` (what
    /// `Scripts/lib.sh` runs) rejects them, because other resolvers on the same machine read a
    /// leading zero as octal and the string therefore does not have one meaning. Rejecting is
    /// the behaviour that keeps the two gates in agreement, and this case pins it — a
    /// "simplification" to a bare `inet_pton` call goes red here.
    @Test("IPv4 octets with leading zeros are rejected, matching ipaddress and not inet_pton")
    func leadingZeroOctetsRejected() {
        #expect(LabBoundary.Address(literal: "192.000.2.10") == nil)
        #expect(LabBoundary.Address(literal: "192.0.2.01") == nil)
        // A lone zero octet is legal; only a *leading* zero on a longer octet is not.
        #expect(LabBoundary.Address(literal: "192.0.2.0") != nil)
    }

    @Test("malformed literals are rejected rather than guessed at")
    func malformedLiteralsRejected() {
        for literal in [
            "",
            "192.0.2",
            "192.0.2.10.1",
            "192.0.2.256",
            " 192.0.2.10",
            "192.0.2.10 ",
            "192.0.2.1٠",  // non-ASCII decimal digit
            "localhost",
            "2001:db8:::1",
            "2001:db8::1%",  // empty zone
            "2001:db8::1%a%b",  // two zones
        ] {
            #expect(LabBoundary.Address(literal: literal) == nil, "\(literal.debugDescription) must not parse")
        }
    }

    /// A zone is metadata about which interface to leave by, never about which network the
    /// address belongs to, and `lib.sh` strips it (`info[4][0].split("%")[0]`) before judging.
    @Test("a %zone suffix is stripped and does not change the address")
    func zoneSuffixIsStripped() throws {
        let scoped = try #require(LabBoundary.Address(literal: "2001:db8::1%en0"))
        let plain = try #require(LabBoundary.Address(literal: "2001:db8::1"))
        #expect(scoped == plain)
    }

    @Test("a bare address is a whole-length segment")
    func bareAddressSegment() throws {
        let v4 = try #require(LabBoundary.Segment(cidr: "192.0.2.10"))
        let exact = try #require(LabBoundary.Address(literal: "192.0.2.10"))
        let neighbour = try #require(LabBoundary.Address(literal: "192.0.2.11"))
        #expect(v4.prefixLength == 32)
        #expect(v4.contains(exact))
        #expect(!v4.contains(neighbour))

        let v6 = try #require(LabBoundary.Segment(cidr: "2001:db8::1"))
        #expect(v6.prefixLength == 128)
    }

    /// `strict=False`, the flag `lib.sh` passes: an entry written with host bits set is the
    /// network it lies in, not an error. A maintainer who writes their own machine's address
    /// with a `/24` on the end gets the segment they meant.
    @Test("host bits below the prefix are masked away instead of rejected")
    func hostBitsAreMasked() throws {
        let segment = try #require(LabBoundary.Segment(cidr: "192.0.2.99/24"))
        let low = try #require(LabBoundary.Address(literal: "192.0.2.1"))
        let high = try #require(LabBoundary.Address(literal: "192.0.2.254"))
        let elsewhere = try #require(LabBoundary.Address(literal: "198.51.100.1"))
        #expect(segment.networkBytes == [192, 0, 2, 0])
        #expect(segment.contains(low))
        #expect(segment.contains(high))
        #expect(!segment.contains(elsewhere))
    }

    /// CPython's IPv4 netmask parsing accepts both forms and IPv6's accepts neither; matching
    /// that exactly is cheaper than explaining a boundary file that the shell gate reads and
    /// this one refuses.
    @Test("IPv4 dotted netmasks and hostmasks are accepted; IPv6 takes prefix lengths only")
    func dottedMasks() throws {
        let netmask = try #require(LabBoundary.Segment(cidr: "192.0.2.0/255.255.255.0"))
        #expect(netmask.prefixLength == 24)
        let hostmask = try #require(LabBoundary.Segment(cidr: "192.0.2.0/0.0.0.255"))
        #expect(hostmask.prefixLength == 24)
        #expect(LabBoundary.Segment(cidr: "192.0.2.0/255.0.255.0") == nil)  // not contiguous
        #expect(LabBoundary.Segment(cidr: "2001:db8::/255.255.0.0") == nil)
    }

    @Test("a prefix of zero matches every address of its own family and none of the other's")
    func zeroPrefix() throws {
        let everything = try #require(LabBoundary.Segment(cidr: "0.0.0.0/0"))
        let anyV4 = try #require(LabBoundary.Address(literal: "203.0.113.9"))
        let anyV6 = try #require(LabBoundary.Address(literal: "2001:db8::1"))
        #expect(everything.contains(anyV4))
        #expect(!everything.contains(anyV6))
    }

    @Test("malformed segments do not parse")
    func malformedSegments() {
        for cidr in [
            "",
            "/24",
            "192.0.2.0/",
            "192.0.2.0/33",
            "2001:db8::/129",
            "192.0.2.0/-1",
            "192.0.2.0/+24",
            "192.0.2.0/24/8",
            "192.0.2.0/twentyfour",
            "192.000.2.0/24",
            "not-an-address/24",
        ] {
            #expect(LabBoundary.Segment(cidr: cidr) == nil, "\(cidr.debugDescription) must not parse")
        }
    }

    /// The strict dotted-quad rule has to reach *inside* an IPv6 literal, because CPython's does
    /// and `inet_pton`'s does not. `inet_pton(AF_INET6, "::ffff:192.000.2.010")` returns 1 on
    /// Darwin; `ipaddress.ip_address` on the same text raises. Left to `inet_pton`, a boundary
    /// file containing `::ffff:192.000.2.0/120` would have been *enforced* by this gate and
    /// *refused* by `lib.sh` — the shell-refuses/mirror-permits direction, i.e. the exact class
    /// of disagreement this type exists to eliminate. Fail-closed: reject, matching CPython.
    @Test("leading zeros in an IPv6 literal's embedded IPv4 tail are rejected too")
    func embeddedIPv4LeadingZerosRejected() {
        #expect(LabBoundary.Address(literal: "::ffff:192.000.2.010") == nil)
        #expect(LabBoundary.Address(literal: "::ffff:192.0.2.010") == nil)
        #expect(LabBoundary.Segment(cidr: "::ffff:192.000.2.0/120") == nil)
        // The canonical spelling of the very same address still parses, so the rule rejects the
        // ambiguous text and not the mapped form itself.
        #expect(LabBoundary.Address(literal: "::ffff:192.0.2.10") != nil)
        #expect(LabBoundary.Segment(cidr: "::ffff:192.0.2.0/120") != nil)
        // A colon-free literal is unaffected, and a hex-only IPv6 literal never enters the
        // dotted-quad path at all.
        #expect(LabBoundary.Address(literal: "2001:db8::1") != nil)
    }

    /// I2: withholding a `description` is not a guarantee — Swift's reflection-based default
    /// ignores access control, so before the redacting conformances `print(segment)` from
    /// another module emitted `networkBytes` in full. This sweeps every rendering entry point
    /// the language offers, for both families, against fragments *derived from the fixtures'
    /// own bytes* — and carries a positive control proving those fragments still detect the
    /// pre-fix rendering, so the sweep cannot quietly become decorative.
    @Test("a segment cannot be stringified back out, through any rendering entry point")
    func segmentsCannotBeStringified() throws {
        let v4 = try #require(LabBoundary.Segment(cidr: Fixture.allowedV4))
        let v6 = try #require(LabBoundary.Segment(cidr: Fixture.allowedV6))
        let address = try #require(LabBoundary.Address(literal: Fixture.insideV4))

        var rendered: [String] = []
        for segment in [v4, v6] {
            rendered += [String(describing: segment), String(reflecting: segment), "\(segment)"]
            rendered.append(segment.description)
            rendered.append(segment.debugDescription)
        }
        rendered += [String(describing: address), String(reflecting: address), "\(address)"]
        // Collections and optionals render their elements through the same machinery, and a
        // `[Segment]` is what `Segment.parseList` hands back -- the shape most likely to reach a
        // log line by accident.
        rendered.append(String(describing: [v4, v6]))
        rendered.append(String(reflecting: [v4, v6]))
        rendered.append(String(describing: LabBoundary.Segment(cidr: Fixture.allowedV4)))
        var dumpedArray = ""
        dump([v4, v6], to: &dumpedArray)
        rendered.append(dumpedArray)
        // `dump` is the path a custom `description` alone does NOT close: it uses the custom
        // string for its header line and then walks Mirror's children anyway, which printed
        // networkBytes one element per line until `customMirror` was added. Found by probing
        // the fix from a separate module rather than by assuming the conformances were enough.
        for subject in [v4, v6] as [Any] {
            var dumped = ""
            dump(subject, to: &dumped)
            rendered.append(dumped)
        }
        var dumpedAddress = ""
        dump(address, to: &dumpedAddress)
        rendered.append(dumpedAddress)

        // The fragment list is DERIVED from the fixtures' own bytes, not hand-listed from their
        // textual CIDRs. Hand-listing looked thorough and was half decorative: the leak this
        // test exists to catch renders `networkBytes` as DECIMAL BYTES, which for the v4 fixture
        // happens to coincide with its text (`[192, 0, 2, 0]` contains "192") and for the v6
        // fixture does not at all (`2001:db8:aaaa::/48` is `[32, 1, 13, 184, 170, 170, …]`,
        // sharing not one character with "2001"/"db8"/"aaaa"). A v6-only leak would have sailed
        // through. Deriving also means the list cannot drift when a fixture changes.
        //
        // Single-digit byte values are dropped: a bare "0" or "2" would match nothing here today
        // but is one rendering change away from a false positive, and every fixture carries
        // several multi-digit bytes, so the discrimination does not depend on them. The
        // positive control below proves what is left still bites.
        func leakFragments(bytes: [UInt8], prefixLength: Int?) -> [String] {
            var fragments = bytes.map(String.init).filter { $0.count >= 2 }
            fragments.append(bytes.map(String.init).joined(separator: ", "))
            if let prefixLength { fragments.append(String(prefixLength)) }
            return fragments
        }
        var mustNotAppear = [
            Fixture.allowedV4, Fixture.allowedV6, Fixture.allowedLoopbackV4, Fixture.insideV4,
            "192", "198", "203", "2001", "db8", "aaaa", "bbbb", "127",
        ]
        mustNotAppear += leakFragments(bytes: v4.networkBytes, prefixLength: v4.prefixLength)
        mustNotAppear += leakFragments(bytes: v6.networkBytes, prefixLength: v6.prefixLength)
        mustNotAppear += leakFragments(bytes: address.bytes, prefixLength: nil)

        // Positive control: the sweep has to be able to SEE a leak, per family. These are the
        // strings Swift's reflection-based defaults actually produced before the conformances
        // (recorded verbatim from a probe of a pre-fix build, from a non-@testable module), so a
        // fragment list that no longer discriminates fails here rather than passing quietly.
        for leaked in [
            "Segment(family: v4, prefixLength: 24, networkBytes: [192, 0, 2, 0])",
            "Segment(family: v6, prefixLength: 48, networkBytes: "
                + "[32, 1, 13, 184, 170, 170, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])",
            "Address(family: v4, bytes: [192, 0, 2, 10])",
        ] {
            #expect(
                mustNotAppear.contains { leaked.contains($0) },
                "the fragment list no longer detects \(leaked.debugDescription) -- the sweep below is decorative")
        }

        for text in rendered {
            for fragment in mustNotAppear {
                #expect(!text.contains(fragment), "\(text.debugDescription) leaked \(fragment.debugDescription)")
            }
        }
    }

    /// `ipaddress`' own rule ("always false if one is v4 and the other is v6"), and the reason
    /// an IPv4-mapped answer is not silently unwrapped. If this gate treated `::ffff:192.0.2.1`
    /// as `192.0.2.1` while the shell gate did not, the two would disagree about a host whose
    /// resolver happens to hand back mapped answers — a hole that would only ever open on one
    /// of the two live paths.
    @Test("an IPv4-mapped IPv6 address is judged as IPv6, exactly as ipaddress judges it")
    func ipv4MappedAddressesStayIPv6() throws {
        let mapped = try #require(LabBoundary.Address(literal: "::ffff:192.0.2.1"))
        let v4Segment = try #require(LabBoundary.Segment(cidr: "192.0.2.0/24"))
        let mappedSegment = try #require(LabBoundary.Segment(cidr: "::ffff:0:0/96"))
        #expect(mapped.family == .v6)
        #expect(!v4Segment.contains(mapped))
        #expect(mappedSegment.contains(mapped))
    }

    @Test("a whitespace-separated list parses as a whole, and one bad entry fails all of it")
    func segmentLists() throws {
        let parsed = try #require(LabBoundary.Segment.parseList("  192.0.2.0/24\t2001:db8::/32  \n"))
        #expect(parsed.count == 2)
        #expect(LabBoundary.Segment.parseList("192.0.2.0/24 nonsense") == nil)
        #expect(LabBoundary.Segment.parseList("   ")?.isEmpty == true)
    }
}

/// The semantic cases of `Scripts/test-lab-boundary.sh`, mirrored against the Swift gate. Same
/// fixtures, same verdicts, same no-leak assertion — because the two gates now guard the same
/// rule on different entry points, and a divergence between them is exactly the class of bug
/// this whole task existed to close.
@Suite("LabBoundary: the gate")
struct LabBoundaryGateTests {
    // MARK: Literals, both families, inside and outside

    @Test("an in-range IPv4 literal is allowed without the resolver ever being consulted")
    func inRangeIPv4Allowed() {
        let spy = ResolverSpy(.unresolvable)
        let verdict = LabBoundary.evaluate(
            host: Fixture.insideV4, allowedNets: Fixture.allowedBoth, resolve: spy.resolve)
        #expect(verdict == .allowed)
        #expect(spy.hostsAsked.isEmpty)
    }

    @Test("an out-of-range IPv4 literal is refused")
    func outOfRangeIPv4Refused() {
        let spy = ResolverSpy(.unresolvable)
        let verdict = LabBoundary.evaluate(
            host: Fixture.outsideV4, allowedNets: Fixture.allowedBoth, resolve: spy.resolve)
        #expect(verdict == .refused(.outsideAllowedSegments))
        #expect(spy.hostsAsked.isEmpty)
    }

    @Test("an in-range IPv6 literal is allowed")
    func inRangeIPv6Allowed() {
        let spy = ResolverSpy(.unresolvable)
        let verdict = LabBoundary.evaluate(
            host: Fixture.insideV6, allowedNets: Fixture.allowedBoth, resolve: spy.resolve)
        #expect(verdict == .allowed)
        #expect(spy.hostsAsked.isEmpty)
    }

    @Test("an out-of-range IPv6 literal is refused")
    func outOfRangeIPv6Refused() {
        let spy = ResolverSpy(.unresolvable)
        let verdict = LabBoundary.evaluate(
            host: Fixture.outsideV6, allowedNets: Fixture.allowedBoth, resolve: spy.resolve)
        #expect(verdict == .refused(.outsideAllowedSegments))
        #expect(spy.hostsAsked.isEmpty)
    }

    /// A v4-only boundary file refuses a v6 target and vice versa, rather than mis-comparing
    /// bytes across families.
    @Test("a target of the other family is outside a single-family boundary")
    func crossFamilyRefused() {
        #expect(
            LabBoundary.evaluate(host: Fixture.insideV6, allowedNets: Fixture.allowedV4, resolve: neverAsked)
                == .refused(.outsideAllowedSegments))
        #expect(
            LabBoundary.evaluate(host: Fixture.insideV4, allowedNets: Fixture.allowedV6, resolve: neverAsked)
                == .refused(.outsideAllowedSegments))
    }

    // MARK: Names (resolution injected; this suite never performs a real lookup)

    @Test("a name whose every answer is inside is allowed")
    func nameFullyInsideAllowed() {
        let spy = ResolverSpy(resolvingTo: [Fixture.insideV4, Fixture.insideV6])
        let verdict = LabBoundary.evaluate(
            host: "lab-box.example", allowedNets: Fixture.allowedBoth, resolve: spy.resolve)
        #expect(verdict == .allowed)
        #expect(spy.hostsAsked == ["lab-box.example"])
    }

    /// The ALL-addresses rule, and the only case in this suite that can tell `all` from `any`.
    /// A gate with `any` here would allow a name whose A record is in-lab and whose AAAA record
    /// points anywhere at all — and nothing else in this file, or in the shell suite, would go
    /// red. `Scripts/test-lab-boundary.sh` reaches the same discriminator through real
    /// dual-stack `localhost`, and has to *skip* itself on a host where localhost is v4-only;
    /// injecting the answers makes the coverage unconditional here.
    @Test("a name with one out-of-range answer among several is refused")
    func mixedAnswersRefused() {
        let spy = ResolverSpy(resolvingTo: [Fixture.insideV4, Fixture.outsideV4])
        let verdict = LabBoundary.evaluate(
            host: "half-in.example", allowedNets: Fixture.allowedBoth, resolve: spy.resolve)
        #expect(verdict == .refused(.outsideAllowedSegments))
    }

    /// The same discriminator in the shape the shell suite uses it: loopback as the allowed
    /// segment, and an answer set of `127.0.0.1` (inside) plus `::1` (outside).
    @Test("loopback fixture: 127.0.0.1 inside and ::1 outside still refuses")
    func loopbackMixedAnswersRefused() {
        let spy = ResolverSpy(resolvingTo: ["127.0.0.1", "::1"])
        let verdict = LabBoundary.evaluate(
            host: "localhost", allowedNets: Fixture.allowedLoopbackV4, resolve: spy.resolve)
        #expect(verdict == .refused(.outsideAllowedSegments))

        // Precondition for the case above, asserted rather than assumed: the v4 answer really
        // is inside the fixture segment, so the refusal comes from the v6 one and not from a
        // fixture that never matched anything.
        let onlyV4 = ResolverSpy(resolvingTo: ["127.0.0.1"])
        #expect(
            LabBoundary.evaluate(host: "localhost", allowedNets: Fixture.allowedLoopbackV4, resolve: onlyV4.resolve)
                == .allowed)
    }

    @Test("a name that does not resolve is refused, with its own reason")
    func unresolvableNameRefused() {
        let spy = ResolverSpy(.unresolvable)
        let verdict = LabBoundary.evaluate(
            host: "nonexistent.invalid", allowedNets: Fixture.allowedBoth, resolve: spy.resolve)
        #expect(verdict == .refused(.hostDoesNotResolve))
    }

    @Test("a name that resolves to no address at all is refused")
    func emptyAnswerRefused() {
        let spy = ResolverSpy(.resolved([]))
        let verdict = LabBoundary.evaluate(
            host: "empty.example", allowedNets: Fixture.allowedBoth, resolve: spy.resolve)
        #expect(verdict == .refused(.hostResolvesToNoAddress))
    }

    @Test("an answer the gate cannot read as an address is refused, not skipped")
    func unparseableAnswerRefused() {
        let spy = ResolverSpy(.unparseableAnswer)
        let verdict = LabBoundary.evaluate(
            host: "odd.example", allowedNets: Fixture.allowedBoth, resolve: spy.resolve)
        #expect(verdict == .refused(.hostResolvedToUnparseableAddress))
    }

    // MARK: Degraded configuration — every one of these must refuse a host the healthy
    // configuration would have allowed, proving the refusal comes from the configuration.

    @Test("an empty host is refused")
    func emptyHostRefused() {
        #expect(LabBoundary.evaluate(host: "", allowedNets: Fixture.allowedBoth, resolve: neverAsked) == .refused(.emptyHost))
    }

    @Test("a boundary file that lists nothing is refused")
    func emptySegmentListRefused() {
        #expect(
            LabBoundary.evaluate(host: Fixture.insideV4, allowedNets: "", resolve: neverAsked)
                == .refused(.noAllowedSegments))
        #expect(
            LabBoundary.evaluate(host: Fixture.insideV4, allowedNets: "  \t\n ", resolve: neverAsked)
                == .refused(.noAllowedSegments))
    }

    @Test("one unparseable entry refuses the whole list, even alongside a matching one")
    func unparseableSegmentRefuses() {
        let verdict = LabBoundary.evaluate(
            host: Fixture.insideV4, allowedNets: "\(Fixture.allowedV4) 192.0.2.0/33", resolve: neverAsked)
        #expect(verdict == .refused(.unparseableSegment))
    }

    @Test("a missing boundary file refuses a host the healthy file would have allowed")
    func missingBoundaryFileRefused() throws {
        let directory = try TemporaryDirectory()
        let missing = directory.path(for: "definitely-not-here.env")
        #expect(
            LabBoundary.evaluate(host: Fixture.insideV4, boundaryFilePath: missing, resolve: neverAsked)
                == .refused(.boundaryFileUnreadable(path: missing)))
    }

    /// Two shapes of "cannot read", because only one of them holds on every uid: a path that is
    /// a directory always fails, while `chmod 000` does nothing to a process running as root
    /// (which is how a container CI job usually runs). The root branch asserts the other
    /// meaningful thing — that the fixture file is otherwise a perfectly good boundary file —
    /// so the case can never pass vacuously or skip silently.
    @Test("an unreadable boundary file refuses")
    func unreadableBoundaryFileRefused() throws {
        let directory = try TemporaryDirectory()

        #expect(
            LabBoundary.evaluate(host: Fixture.insideV4, boundaryFilePath: directory.url.path, resolve: neverAsked)
                == .refused(.boundaryFileUnreadable(path: directory.url.path)))

        let path = directory.path(for: "boundary-unreadable.env")
        try "\(LabBoundary.allowedNetsKey)=\"\(Fixture.allowedBoth)\"\n".write(
            toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o000))], ofItemAtPath: path)

        let verdict = LabBoundary.evaluate(host: Fixture.insideV4, boundaryFilePath: path, resolve: neverAsked)
        if FileManager.default.isReadableFile(atPath: path) {
            #expect(verdict == .allowed)
        } else {
            #expect(verdict == .refused(.boundaryFileUnreadable(path: path)))
        }
    }

    // MARK: The boundary file itself

    @Test("a boundary file in the documented shape is read through the shared parser")
    func boundaryFileIsParsedByEnvFile() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path(for: "lab-boundary.env")
        try """
            # maintainer-local, never tracked
            export \(LabBoundary.allowedNetsKey)="\(Fixture.allowedBoth)"
            """.write(toFile: path, atomically: true, encoding: .utf8)

        #expect(LabBoundary.evaluate(host: Fixture.insideV4, boundaryFilePath: path, resolve: neverAsked) == .allowed)
        #expect(
            LabBoundary.evaluate(host: Fixture.outsideV4, boundaryFilePath: path, resolve: neverAsked)
                == .refused(.outsideAllowedSegments))
    }

    /// The boundary file's own version of the fail-open finding: a bare line followed by an
    /// `export` line. The gate must read what a shell reading the same file would read — the
    /// last assignment — or the segments it enforces are not the segments the maintainer wrote.
    @Test("a bare line followed by an export line: the export line is the one enforced")
    func boundaryFileLastAssignmentWins() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path(for: "lab-boundary.env")
        try """
            \(LabBoundary.allowedNetsKey)="\(Fixture.allowedLoopbackV4)"
            export \(LabBoundary.allowedNetsKey)="\(Fixture.allowedV4)"
            """.write(toFile: path, atomically: true, encoding: .utf8)

        #expect(LabBoundary.evaluate(host: Fixture.insideV4, boundaryFilePath: path, resolve: neverAsked) == .allowed)
        #expect(
            LabBoundary.evaluate(host: "127.0.0.1", boundaryFilePath: path, resolve: neverAsked)
                == .refused(.outsideAllowedSegments))
    }

    /// I1: an **unquoted** whitespace-separated list. `sh` reads that line as an assignment
    /// prefix on the command `198.51.100.0/24`, which does not exist, so `lib.sh`'s source fails,
    /// `nets` collapses to empty and the shell gate refuses *everything* — including hosts
    /// inside the first segment. This gate reads the whole right-hand side and enforces both
    /// segments.
    ///
    /// Pinned rather than fixed, deliberately: the enforced segments are exactly the ones the
    /// maintainer typed, so nothing outside their own boundary file becomes reachable, and the
    /// divergence is "the mirror still works where the authority gives up". The point of the
    /// test is that the behaviour is *chosen* — a future edit that changes it has to change this
    /// case and read the reasoning in `evaluate(host:boundaryFilePath:resolve:)` first.
    @Test("an unquoted whitespace-separated segment list is enforced here, where lib.sh refuses everything")
    func unquotedSegmentListIsEnforced() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path(for: "lab-boundary.env")
        try "\(LabBoundary.allowedNetsKey)=\(Fixture.allowedV4) 198.51.100.0/24\n".write(
            toFile: path, atomically: true, encoding: .utf8)

        #expect(LabBoundary.evaluate(host: Fixture.insideV4, boundaryFilePath: path, resolve: neverAsked) == .allowed)
        #expect(
            LabBoundary.evaluate(host: Fixture.outsideV4, boundaryFilePath: path, resolve: neverAsked) == .allowed,
            "the second, unquoted segment is enforced too -- that is the whole divergence")
        // And nothing beyond the file's own two segments is reachable, which is why this is
        // documented and pinned rather than treated as a hole.
        #expect(
            LabBoundary.evaluate(host: "203.0.113.9", boundaryFilePath: path, resolve: neverAsked)
                == .refused(.outsideAllowedSegments))
    }

    /// Divergence item 4: `sh` strips a trailing `# comment` and allows; `EnvFile` keeps it (it
    /// matches `run-window-smoke.command`'s `sed`, and teaching it shell comment rules would
    /// also truncate a `host.env` password that legitimately contains ` #`), so the comment
    /// words arrive as segment tokens and refuse the whole list. Fail-closed, in both the bare
    /// and the quoted spelling — the quoted one matters because the quotes are no longer the
    /// value's outermost characters, so not even the quote-stripping layer hides the comment.
    @Test("a trailing inline comment in the boundary file refuses, where lib.sh would allow")
    func trailingInlineCommentInTheBoundaryFileRefuses() throws {
        let directory = try TemporaryDirectory()
        for (name, line) in [
            ("bare", "\(LabBoundary.allowedNetsKey)=\(Fixture.allowedV4) # the lab segment"),
            ("quoted", "\(LabBoundary.allowedNetsKey)=\"\(Fixture.allowedV4)\" # the lab segment"),
        ] {
            let path = directory.path(for: "lab-boundary-\(name).env")
            try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            #expect(
                LabBoundary.evaluate(host: Fixture.insideV4, boundaryFilePath: path, resolve: neverAsked)
                    == .refused(.unparseableSegment),
                "the \(name) spelling must refuse rather than silently enforce a truncated list")
        }
    }

    @Test("a boundary file with no MACDOWS_LAB_ALLOWED_NETS key refuses")
    func boundaryFileWithoutTheKeyRefused() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path(for: "lab-boundary.env")
        try "SOMETHING_ELSE=1\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(
            LabBoundary.evaluate(host: Fixture.insideV4, boundaryFilePath: path, resolve: neverAsked)
                == .refused(.noAllowedSegments))
    }

    /// m4: both gates refuse a boundary file that is not text; only the reason category differs
    /// (`lib.sh` sources the bytes, gets nothing usable and says "defines no allowed segments").
    /// Pinned so the category is a decision rather than a side effect of `EnvFile`'s error being
    /// caught wholesale.
    @Test("a non-UTF-8 boundary file refuses as unreadable, not as an empty segment list")
    func nonUTF8BoundaryFileRefused() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path(for: "lab-boundary.env")
        try Data([0x4D, 0x41, 0x43, 0x3D, 0xFF, 0x0A]).write(to: URL(fileURLWithPath: path))
        #expect(
            LabBoundary.evaluate(host: Fixture.insideV4, boundaryFilePath: path, resolve: neverAsked)
                == .refused(.boundaryFileUnreadable(path: path)))
    }

    @Test("an empty host is refused before the boundary file is even looked at")
    func emptyHostRefusedBeforeFileAccess() throws {
        let directory = try TemporaryDirectory()
        let missing = directory.path(for: "definitely-not-here.env")
        #expect(LabBoundary.evaluate(host: "", boundaryFilePath: missing, resolve: neverAsked) == .refused(.emptyHost))
    }

    @Test("the boundary file path follows the env override, then HOME")
    func boundaryFilePathResolution() {
        #expect(
            LabBoundary.defaultBoundaryFilePath(environment: [
                "MACDOWS_LAB_BOUNDARY_FILE": "/tmp/override.env", "HOME": "/Users/someone",
            ]) == "/tmp/override.env")
        // Empty is treated as unset, matching `${VAR:-default}`.
        #expect(
            LabBoundary.defaultBoundaryFilePath(environment: [
                "MACDOWS_LAB_BOUNDARY_FILE": "", "HOME": "/Users/someone",
            ]) == "/Users/someone/.config/macdows/lab-boundary.env")
        #expect(
            LabBoundary.defaultBoundaryFilePath(environment: ["HOME": "/Users/someone"])
                == "/Users/someone/.config/macdows/lab-boundary.env")

        // The HOME-unset branch, the one divergence from `lib.sh` the reviewer ruled on: the
        // shell degrades to "/.config/macdows/lab-boundary.env" (which cannot exist, so it
        // refuses everything), this falls back to NSHomeDirectory(), the process's real home.
        // Accepted as written -- NSHomeDirectory() is the correct answer for a bundled app,
        // whose home is its container and for which HOME is exactly the variable you cannot
        // trust -- and untested until now, which is why it is pinned here rather than left as
        // the one branch a future edit could flip unnoticed.
        let expectedFallback = NSHomeDirectory() + "/.config/macdows/lab-boundary.env"
        #expect(LabBoundary.defaultBoundaryFilePath(environment: [:]) == expectedFallback)
        #expect(LabBoundary.defaultBoundaryFilePath(environment: ["HOME": ""]) == expectedFallback)
        #expect(
            LabBoundary.defaultBoundaryFilePath(environment: ["MACDOWS_LAB_BOUNDARY_FILE": "", "HOME": ""])
                == expectedFallback)
    }

    // MARK: The no-leak contract

    /// `Scripts/test-lab-boundary.sh` makes this assertion against the shell gate's whole
    /// transcript; this is its Swift twin, made against the entire refusal vocabulary at once
    /// rather than against whichever cases happened to run. It is the reason the segments can
    /// live in an untracked file and stay there: a verdict line that quoted them would put them
    /// in a terminal scrollback, a tee'd log or a CI transcript.
    @Test("no refusal ever renders a segment, on any code path")
    func refusalsNeverQuoteASegment() {
        let everyRefusal: [LabBoundary.Refusal] = [
            .emptyHost,
            .boundaryFileUnreadable(path: "/Users/someone/.config/macdows/lab-boundary.env"),
            .noAllowedSegments,
            .unparseableSegment,
            .hostDoesNotResolve,
            .hostResolvedToUnparseableAddress,
            .hostResolvesToNoAddress,
            .outsideAllowedSegments,
        ]
        let mustNotAppear = [
            Fixture.allowedV4, Fixture.allowedV6, Fixture.allowedLoopbackV4, Fixture.allowedBoth,
            "192.0.2.", "2001:db8", "127.0.0.",
        ]

        for refusal in everyRefusal {
            let rendered = refusal.reasonText + "\n" + LabBoundary.refusalLine(host: Fixture.insideV4, refusal: refusal)
            // `refusalLine` is allowed to name the host the caller passed in -- that is the
            // caller's own string, and `lib.sh` prints it too -- so the host is masked out
            // first and everything that remains is swept.
            let withoutHost = rendered.replacingOccurrences(of: Fixture.insideV4, with: "<host>")
            for fragment in mustNotAppear {
                #expect(!withoutHost.contains(fragment), "refusal text leaked \(fragment.debugDescription)")
            }
        }
    }

    @Test("a refusal line names the host and a reason, in lib.sh's own format")
    func refusalLineFormat() {
        #expect(
            LabBoundary.refusalLine(host: Fixture.insideV4, refusal: .outsideAllowedSegments)
                == "[lab-boundary] REFUSED: 192.0.2.10 -- target is outside the allowed lab segments")
        // No host to name in the empty-host case, exactly as in `lib.sh`.
        #expect(LabBoundary.refusalLine(host: "", refusal: .emptyHost) == "[lab-boundary] REFUSED: empty target host")
    }

    @Test("Verdict's convenience accessors agree with the case they wrap")
    func verdictAccessors() {
        #expect(LabBoundary.Verdict.allowed.isAllowed)
        #expect(LabBoundary.Verdict.allowed.refusal == nil)
        #expect(!LabBoundary.Verdict.refused(.emptyHost).isAllowed)
        #expect(LabBoundary.Verdict.refused(.emptyHost).refusal == .emptyHost)
    }
}

/// A resolver for the cases that must never reach one. Any call is a test failure, which is
/// how the literal-target and degraded-configuration cases prove the gate short-circuits
/// before it would have gone near the network.
private func neverAsked(_ host: String) -> LabBoundary.Resolution {
    Issue.record("the resolver must not be consulted for \(host.debugDescription)")
    return .unresolvable
}
