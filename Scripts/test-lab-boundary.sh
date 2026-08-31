#!/usr/bin/env bash
# test-lab-boundary.sh: permanent regression suite for crdp_assert_lab_boundary
# (Scripts/lib.sh), the live-host testing boundary gate that every real-host debugging
# step has to clear (owner rule, 2026-08-31).
#
# Self-contained and offline-safe: it builds its own throwaway boundary files and never
# reads the maintainer's real one, so the segments under test are always the RFC
# documentation ranges 192.0.2.0/24 (RFC 5737) and 2001:db8::/32 (RFC 3849), plus loopback
# 127.0.0.0/8 for the one case that needs a net some -- but not all -- of a name's answers
# fall inside. None of the three is a private-network prefix, all are safe to commit, and
# no real host can fall inside them. Three cases touch the resolver (localhost twice, and
# a name that must not resolve at all); none opens a connection.
#
# What is being pinned, beyond "does it say yes to the right hosts":
#   - fail-closed on every degraded input (no boundary file, no segments, no host), so a
#     misconfigured machine refuses rather than falls through to a connection;
#   - the refusal text never quotes the segment list. That is the whole reason the gate
#     exists in a public repo: a leaked verdict line would defeat the untracked-file
#     split that keeps the owner's network shape out of git and out of CI logs;
#   - and that a name is judged on *all* of its answers, not any one of them -- see the
#     "mixed answers" case and the precondition guarding it against passing vacuously.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macdows-lab-boundary.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

ALLOWED_V4="192.0.2.0/24"
ALLOWED_V6="2001:db8::/32"
ALLOWED_LOOPBACK="127.0.0.0/8"

BOUNDARY_OK="$TEST_DIR/boundary-ok.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="%s %s"\n' "$ALLOWED_V4" "$ALLOWED_V6" >"$BOUNDARY_OK"

BOUNDARY_EMPTY="$TEST_DIR/boundary-empty.env"
printf 'MACDOWS_LAB_ALLOWED_NETS=""\n' >"$BOUNDARY_EMPTY"

BOUNDARY_MISSING="$TEST_DIR/definitely-not-here.env"

FAILURES=0
# Skips are not failures, but they must never be silent: the summary repeats the count, and
# CI refuses a run that produced any.
SKIPPED=0
# Everything the gate ever said during this run, so the no-leak assertion at the end can
# be made against the whole transcript rather than case by case.
TRANSCRIPT="$TEST_DIR/transcript.txt"
: >"$TRANSCRIPT"

# expect <allow|deny> <label> <boundary-file> <host>
expect() {
	local want="$1" label="$2" boundary="$3" host="$4"
	local out got

	# The gate returns non-zero by design on the deny cases; `|| got=deny` both records
	# that and keeps `set -e` from ending the suite on an expected refusal.
	got=allow
	out="$(MACDOWS_LAB_BOUNDARY_FILE="$boundary" crdp_assert_lab_boundary "$host" 2>&1)" || got=deny
	printf '%s\n' "$out" >>"$TRANSCRIPT"

	if [ "$got" = "$want" ]; then
		printf 'PASS  %-34s expected %s\n' "$label" "$want"
	else
		printf 'FAIL  %-34s expected %s, got %s\n' "$label" "$want" "$got"
		printf '      gate said: %s\n' "$out"
		FAILURES=$((FAILURES + 1))
	fi
}

echo "== crdp_assert_lab_boundary =="

# Degraded configuration: no boundary file at all, and a boundary file that defines no
# segments. Both must refuse a host that the well-formed file would have allowed --
# proving the refusal comes from the missing configuration and not from the host.
expect deny "no boundary file"            "$BOUNDARY_MISSING" "192.0.2.10"
expect deny "boundary file, no segments"  "$BOUNDARY_EMPTY"   "192.0.2.10"
expect deny "empty host"                  "$BOUNDARY_OK"      ""

# Literals, both families, inside and just outside.
expect allow "IPv4 literal inside"        "$BOUNDARY_OK"      "192.0.2.10"
expect deny  "IPv4 literal outside"       "$BOUNDARY_OK"      "198.51.100.7"
expect allow "IPv6 literal inside"        "$BOUNDARY_OK"      "2001:db8::1"
expect deny  "IPv6 literal outside"       "$BOUNDARY_OK"      "2001:db9::1"

# Names. localhost resolves (to 127.0.0.1 and/or ::1, neither of which is inside a
# documentation range), so it exercises the resolve-then-judge path rather than the
# resolution-failed path; nonexistent.invalid exercises the latter, .invalid being
# reserved by RFC 2606 precisely so it can never be delegated.
expect deny "name resolving outside"      "$BOUNDARY_OK"      "localhost"
expect deny "name that does not resolve"  "$BOUNDARY_OK"      "nonexistent.invalid"

# The ALL-addresses rule, which every case above is blind to: they only ever exercise names
# whose answers are *uniformly* outside, so a gate that had `any(...)` where it needs
# `all(...)` would pass all of them. localhost against a boundary of 127.0.0.0/8 is the
# discriminator -- it resolves to 127.0.0.1 (inside) and ::1 (outside), so "any address
# inside" would allow it and only "every address inside" refuses.
#
# 127.0.0.0/8 is loopback, reserved by RFC 1122; it is not a private-network prefix, so
# using it as a fixture does not weaken the documentation-ranges-only rule for this file.
# The case only means anything on a host whose localhost is dual-stack, and that is not
# universal: macOS ships "::1 localhost", but a stock Ubuntu hosts file gives ::1 the names
# ip6-localhost/ip6-loopback and NOT localhost. There every answer is inside 127.0.0.0/8,
# the gate correctly allows, and a hard-failing case would redden CI over a host property
# rather than a defect. So the precondition runs FIRST and gates the case: met -> run it;
# not met -> one loud SKIP saying the ALL-addresses rule is uncovered on this host, and the
# suite still exits 0. Silence is the one thing that is not allowed, because a quiet pass
# here is exactly the blind spot the case exists to close.
#
# CI does not get to take the skip: .github/workflows/tier1.yml makes its runner dual-stack
# first and then fails the step if this suite's output contains a SKIP line at all.
BOUNDARY_LOOPBACK_V4="$TEST_DIR/boundary-loopback-v4.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="%s"\n' "$ALLOWED_LOOPBACK" >"$BOUNDARY_LOOPBACK_V4"

echo "== resolver precondition for the ALL-addresses case =="
if python3 -c '
import ipaddress
import socket
import sys

loopback_v4 = ipaddress.ip_network("127.0.0.0/8")
try:
    addrs = [ipaddress.ip_address(i[4][0].split("%")[0]) for i in socket.getaddrinfo("localhost", None)]
except (OSError, UnicodeError, ValueError):
    sys.exit(1)
# Needs at least one answer inside the fixture net and at least one outside it; only then
# does a deny verdict actually distinguish all() from any().
sys.exit(0 if any(a in loopback_v4 for a in addrs) and any(a not in loopback_v4 for a in addrs) else 1)
'; then
	printf 'PASS  %-34s localhost gives both an inside and an outside answer\n' "mixed-answer precondition"
	expect deny "mixed answers, one outside"  "$BOUNDARY_LOOPBACK_V4" "localhost"
else
	printf 'SKIP  %-34s localhost does not resolve to both an inside and an outside address\n' "mixed answers, one outside"
	printf '      on this host, so the case cannot tell all() from any() semantics and is not run.\n'
	printf '      THE ALL-ADDRESSES RULE IS UNCOVERED HERE. Not a failure: give localhost an IPv6\n'
	printf '      loopback name (CI does this to itself) to restore the coverage.\n'
	SKIPPED=$((SKIPPED + 1))
fi

# The no-leak assertion. Checked against the transcript, and reported without echoing the
# offending line -- a failing leak test must not itself print the thing that leaked.
echo "== verdict text carries no segment list =="
LEAKED=0
for seg in "$ALLOWED_V4" "$ALLOWED_V6" "$ALLOWED_LOOPBACK"; do
	if grep -Fq -- "$seg" "$TRANSCRIPT"; then
		LEAKED=$((LEAKED + 1))
	fi
done
if [ "$LEAKED" -eq 0 ]; then
	printf 'PASS  %-34s no allowed segment appears in gate output\n' "no segment leak"
else
	printf 'FAIL  %-34s %d of 3 allowed segments appeared in gate output\n' "no segment leak" "$LEAKED"
	FAILURES=$((FAILURES + 1))
fi

echo
if [ "$FAILURES" -eq 0 ]; then
	if [ "$SKIPPED" -ne 0 ]; then
		echo "all boundary-gate cases passed, $SKIPPED skipped -- see the SKIP block above"
	else
		echo "all boundary-gate cases passed"
	fi
	exit 0
fi
echo "$FAILURES boundary-gate case(s) FAILED"
exit 1
