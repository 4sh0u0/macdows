#!/usr/bin/env bash
# test-lab-boundary.sh: permanent regression suite for crdp_assert_lab_boundary
# (Scripts/lib.sh), the live-host testing boundary gate that every real-host debugging
# step has to clear (owner rule, 2026-08-31), and for the wiring of that gate into the
# scripts that actually dial a host.
#
# Self-contained and offline-safe: it builds its own throwaway boundary files and never
# reads the maintainer's real one, so the segments under test are always the RFC 5737
# documentation ranges 192.0.2.0/24 and 198.51.100.0/24 and the RFC 3849 range
# 2001:db8::/32, plus loopback 127.0.0.0/8 for the one case that needs a net some -- but
# not all -- of a name's answers fall inside. None of the four is a private-network prefix,
# all are safe to commit, and no real host can fall inside them. Three cases touch the
# resolver (localhost twice, and a name that must not resolve at all); none opens a
# connection.
#
# What is being pinned, beyond "does it say yes to the right hosts":
#   - fail-closed on every degraded input (no boundary file, no segments, no host), so a
#     misconfigured machine refuses rather than falls through to a connection;
#   - the refusal text never quotes the segment list. That is the whole reason the gate
#     exists in a public repo: a leaked verdict line would defeat the untracked-file
#     split that keeps the owner's network shape out of git and out of CI logs;
#   - that a name is judged on *all* of its answers, not any one of them -- see the
#     "mixed answers" case and the precondition guarding it against passing vacuously;
#   - and that the gate is reached at the live entry points, early. A gate no caller
#     invokes protects nothing, and that regression is invisible to any test of the
#     function alone, so the last section drives both shell entry points end to end against
#     fixture files. Scripts/probe.sh pins both halves of its contract: an out-of-boundary
#     target is refused before the script so much as requires a toolchain, and an
#     in-boundary one gets past the gate to the toolchain check it would then really need.
#     Scripts/run-window-smoke.command pins that a missing HOME degrades into an ordinary
#     gate refusal -- exit 78 with the DONE line its callers poll for -- rather than a
#     `set -u` death that leaves them reading an empty log.
#
# That last section makes this suite an executor of other repo scripts, not just of a
# function, and Tier 1 runs it on every push. It is deliberately contained: fixture files
# only, a literal address that needs no resolver, a reduced PATH that holds five commands
# and no build tool, and a $TEST_DIR the EXIT trap removes. See the section's own comment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macdows-lab-boundary.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

ALLOWED_V4="192.0.2.0/24"
ALLOWED_V6="2001:db8::/32"
ALLOWED_LOOPBACK="127.0.0.0/8"
# A second, disjoint documentation range. Well-formed and perfectly valid as a boundary --
# it simply does not contain the probe.sh section's fixture host, which is the point: that
# section needs a refusal that comes from the *host being outside*, not from a degraded
# configuration, so it can tell "the gate ran and said no" from "the gate could not run".
ALLOWED_OTHER_V4="198.51.100.0/24"

BOUNDARY_OK="$TEST_DIR/boundary-ok.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="%s %s"\n' "$ALLOWED_V4" "$ALLOWED_V6" >"$BOUNDARY_OK"

BOUNDARY_EMPTY="$TEST_DIR/boundary-empty.env"
printf 'MACDOWS_LAB_ALLOWED_NETS=""\n' >"$BOUNDARY_EMPTY"

BOUNDARY_OTHER="$TEST_DIR/boundary-other.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="%s"\n' "$ALLOWED_OTHER_V4" >"$BOUNDARY_OTHER"

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

# check <0|non-zero> <label> <what was expected> [evidence-file]
#
# The plain-assertion counterpart to expect(), for the entry-point section further down,
# whose cases each make several claims about one script run instead of one claim about one
# gate call. Takes an already-evaluated verdict rather than a command so that the caller
# keeps control of how the evidence is gathered (grep against a saved log, never a pipeline
# -- this repo has been bitten by `grep -q` taking SIGPIPE inside a pipefail pipeline).
#
# On FAIL it echoes a bounded excerpt of the evidence file, the same habit as expect()'s own
# "gate said:" line and for a sharper reason: the entry-point section's realistic failure
# mode is a CI runner the maintainer cannot reproduce locally, and the log that decided the
# verdict is overwritten by the next run and then deleted with $TEST_DIR. A verdict with no
# forensics would be six words on a platform nobody can re-run. Safe to print -- these logs
# are fixture output only (documentation-range host, placeholder credentials, gate and die
# lines) and are already inside the no-leak assertion's scope.
check() {
	if [ "$1" -eq 0 ]; then
		printf 'PASS  %-34s %s\n' "$2" "$3"
	else
		printf 'FAIL  %-34s %s\n' "$2" "$3"
		if [ -n "${4:-}" ] && [ -f "${4:-}" ]; then
			sed -n '1,12p' "$4" | while IFS= read -r evidence_line; do
				printf '      run said: %s\n' "$evidence_line"
			done
		fi
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

# Entry-point wiring. Everything above tests the gate as a function; a gate no caller
# invokes protects nothing, so this section drives the two shell entry points that can dial
# a live host -- Scripts/probe.sh and Scripts/run-window-smoke.command -- and checks that
# each reaches the gate, and reaches it before it commits to anything.
#
# Every case runs the unmodified script against fixture files only: CRDP_HOST_ENV names a
# throwaway host.env carrying a documentation-range host and placeholder credentials,
# MACDOWS_LAB_BOUNDARY_FILE one of the fixture boundaries above, WINDOW_SMOKE_LOG a
# throwaway log. Nothing is built and no socket is opened -- probe.sh's refusal case stops
# at the gate, its allow case at the very next line (the cmake requirement), and the
# launcher case exits 78 long before xcodegen or xcodebuild are named.
#
# probe.sh's two cases differ in exactly one input, the boundary file, which is what makes
# the gate provably the thing that decided each outcome. The allow case is also what keeps
# the refusal case honest: on its own, a probe.sh that died early for some unrelated reason
# would satisfy every assertion the refusal case makes.
#
# PATH is reduced to a single directory holding just the commands those scripts legitimately
# need on the way to their gate: their interpreter, dirname/basename for the path and log
# helpers, mkdir for the launcher's log directory, and python3 for the gate itself. That
# does two jobs. One directory means its contents are the entire lookup namespace, so
# "cmake is not findable" is decidable by looking at it -- asserted below rather than
# assumed -- which turns "a refusal costs no toolchain" into a mechanical claim and lets
# this section run on a machine (or a CI runner) with no C toolchain and no FreeRDP build.
# And it is the containment: Tier 1 now executes two more repo scripts on every push, so any
# command a future edit to either of them reached for simply would not be found here, `set
# -e` would abort, and CI's exposure to those scripts stays bounded by this directory's
# contents.
PROBE_FIXTURE_HOST="192.0.2.7"
PROBE_HOST_ENV="$TEST_DIR/probe-host.env"
{
	printf 'WIN_HOST=%s\n' "$PROBE_FIXTURE_HOST"
	printf 'WIN_USER=%s\n' "fixture-user"
	printf 'WIN_PASS=%s\n' "fixture-value-not-a-credential"
} >"$PROBE_HOST_ENV"

PROBE_LOG="$TEST_DIR/probe-run.log"
# The launcher writes two different things: its own stdout/stderr, and the DONE line, which
# goes to the log file every caller of that script polls on. Both are evidence, and the case
# below asserts against each, so they get separate files.
LAUNCHER_OUT="$TEST_DIR/launcher-run.out"
LAUNCHER_LOG="$TEST_DIR/launcher-done.log"

MINIMAL_BIN="$TEST_DIR/minimal-bin"
mkdir -p "$MINIMAL_BIN"
MINIMAL_BIN_READY=1
MINIMAL_BIN_MISSING=""
for tool in bash dirname basename mkdir python3; do
	TOOL_PATH="$(command -v "$tool" 2>/dev/null)" || TOOL_PATH=""
	if [ "$tool" = "python3" ]; then
		# python3 on a developer machine is routinely a version-manager shim (pyenv, asdf,
		# mise): a shell script that reaches for tr/sed/head and dies under a PATH this
		# small. Measured, not hypothesised -- on this repo's own maintainer machine the
		# pyenv shim failed exactly that way, the gate refused with "boundary evaluation
		# failed" instead of an out-of-boundary verdict, and the refusal case below would
		# have passed for entirely the wrong reason. So ask the interpreter where it really
		# lives and link that: sys.executable is a real binary and needs no PATH at all.
		REAL_PYTHON="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)" || REAL_PYTHON=""
		if [ -n "$REAL_PYTHON" ] && [ -x "$REAL_PYTHON" ]; then
			TOOL_PATH="$REAL_PYTHON"
		fi
	fi
	if [ -z "$TOOL_PATH" ]; then
		MINIMAL_BIN_READY=0
		MINIMAL_BIN_MISSING="$MINIMAL_BIN_MISSING $tool"
		continue
	fi
	ln -s "$TOOL_PATH" "$MINIMAL_BIN/$tool"
done

# Linking the interpreter only proves it exists. Prove it RUNS here, with the stdlib the gate
# actually imports, under the PATH the cases will use -- invoked by absolute path so the
# answer cannot come from bash's command hash table instead of this directory. sys.executable
# defeats the shim shapes seen so far, but a wrapper it cannot see through (a venv launcher, a
# relocated build) would make the gate refuse with "boundary evaluation failed", and the cases
# below would then be reporting a host problem as a defect in the code under test. Routed into
# the same loud SKIP as a missing tool: still red in CI, but red with the cause on the screen.
if [ "$MINIMAL_BIN_READY" -eq 1 ] &&
	! PATH="$MINIMAL_BIN" "$MINIMAL_BIN/python3" -c 'import ipaddress, socket' >/dev/null 2>&1; then
	MINIMAL_BIN_READY=0
	MINIMAL_BIN_MISSING="$MINIMAL_BIN_MISSING python3(does-not-run-under-the-reduced-PATH)"
fi

# run_probe <boundary-file>: run probe.sh under the reduced PATH, leaving its combined
# output in $PROBE_LOG and its status in $PROBE_RC. Never fails itself -- both cases expect
# a non-zero exit, and `set -e` must not end the suite on one.
run_probe() {
	PROBE_RC=0
	PATH="$MINIMAL_BIN" CRDP_HOST_ENV="$PROBE_HOST_ENV" MACDOWS_LAB_BOUNDARY_FILE="$1" \
		"$SCRIPT_DIR/probe.sh" >"$PROBE_LOG" 2>&1 || PROBE_RC=$?
	cat "$PROBE_LOG" >>"$TRANSCRIPT"
}

# run_launcher: run run-window-smoke.command under the reduced PATH with HOME and WIN_HOST
# unset, leaving its combined output in $LAUNCHER_OUT, the DONE-line contract it wrote in
# $LAUNCHER_LOG, and its status in $LAUNCHER_RC.
#
# HOME is unset in a subshell rather than through `env -u`, so the case needs nothing on the
# reduced PATH that the launcher itself does not need. WIN_HOST is unset too, and that is not
# tidiness: the launcher prefers WIN_HOST from the environment, so a maintainer running this
# suite from a shell that has their real host exported would otherwise have fed it to the
# case. (It would still refuse -- the fixture boundary allows documentation ranges only -- but
# a test whose input depends on the operator's environment is not a test.)
run_launcher() {
	LAUNCHER_RC=0
	(
		unset HOME
		unset WIN_HOST
		PATH="$MINIMAL_BIN" WINDOW_SMOKE_LOG="$LAUNCHER_LOG" \
			MACDOWS_LAB_BOUNDARY_FILE="$BOUNDARY_OK" "$SCRIPT_DIR/run-window-smoke.command"
	) >"$LAUNCHER_OUT" 2>&1 || LAUNCHER_RC=$?
	cat "$LAUNCHER_OUT" >>"$TRANSCRIPT"
	if [ -f "$LAUNCHER_LOG" ]; then
		cat "$LAUNCHER_LOG" >>"$TRANSCRIPT"
	fi
}

echo "== the live entry points reach the gate, and reach it first =="
if [ "$MINIMAL_BIN_READY" -eq 0 ]; then
	# Same discipline as the SKIP above: not a failure, never silent. CI cannot take this
	# skip either -- tier1.yml fails the step on any SKIP line -- and the tools involved are
	# on every runner and every developer machine this repo supports, so reaching here at
	# all means something unusual about the host, not about the code.
	printf 'SKIP  %-34s unusable on PATH:%s\n' "entry-point cases" "$MINIMAL_BIN_MISSING"
	printf '      the entry points cannot be driven under a reduced PATH without them, so THE WIRING\n'
	printf '      OF THE GATE INTO THEM IS UNVERIFIED HERE. Not a failure: the gate itself is still\n'
	printf '      covered by every case above.\n'
	SKIPPED=$((SKIPPED + 1))
else
	if [ -e "$MINIMAL_BIN/cmake" ]; then
		check 1 "reduced PATH hides cmake" "the one PATH directory must hold no cmake"
	else
		check 0 "reduced PATH hides cmake" "the one PATH directory holds no cmake"
	fi

	# Refusal case: the fixture host is outside the fixture boundary.
	run_probe "$BOUNDARY_OTHER"

	PROBE_OK=0
	[ "$PROBE_RC" -ne 0 ] || PROBE_OK=1
	check "$PROBE_OK" "out-of-boundary host is refused" "non-zero exit" "$PROBE_LOG"

	# Both halves matter. A bare REFUSED line is not enough: the gate also prints one when it
	# is the one that is broken (no boundary file, no python3), and a case satisfied by that
	# would keep passing on a machine where the fixture never got as far as comparing an
	# address to a segment. The reason text is what says the comparison happened and the
	# address lost.
	PROBE_OK=0
	grep -Fq -- '[lab-boundary] REFUSED' "$PROBE_LOG" || PROBE_OK=1
	grep -Fq -- 'target is outside the allowed lab segments' "$PROBE_LOG" || PROBE_OK=1
	check "$PROBE_OK" "the gate is what refused" "refusal, and for the out-of-boundary reason" "$PROBE_LOG"

	PROBE_OK=0
	grep -Fq -- 'outside the owner lab boundary' "$PROBE_LOG" || PROBE_OK=1
	check "$PROBE_OK" "probe.sh states its own refusal" "script-level refusal line too" "$PROBE_LOG"

	# The ordering claim. Everything in probe.sh that can put the word cmake on a stream sits
	# after the gate -- the requirement check's own die message, and the configure and build
	# invocations -- so the word being absent from the whole run is a compact way of saying
	# none of them was reached: the target was rejected before the script asked the machine
	# for a toolchain, let alone used one.
	PROBE_OK=0
	if grep -qiF -- 'cmake' "$PROBE_LOG"; then
		PROBE_OK=1
	fi
	check "$PROBE_OK" "refusal predates any toolchain" "no mention of cmake in the whole run" "$PROBE_LOG"

	# Allow case: same fixture host, same script, a boundary that contains it. Proves the
	# refusal above was the gate's verdict and not an early death with a convenient shape.
	run_probe "$BOUNDARY_OK"

	PROBE_OK=0
	grep -Fq -- '[lab-boundary] target inside allowed segments' "$PROBE_LOG" || PROBE_OK=1
	check "$PROBE_OK" "in-boundary host clears the gate" "gate approval line in the output" "$PROBE_LOG"

	PROBE_OK=0
	grep -Fq -- 'required command not found: cmake' "$PROBE_LOG" || PROBE_OK=1
	check "$PROBE_OK" "cleared run stops at cmake next" "the toolchain check is the next thing" "$PROBE_LOG"

	# The launcher, with HOME unset. Two things are pinned at once, and they are the two
	# halves of what that script owes its callers.
	#
	# Survivability: run-window-smoke.command runs under `set -u`, so a bare $HOME anywhere
	# ahead of the gate kills it outright -- measured, before the ${HOME:-} fix: exit 1 and an
	# empty log. Callers poll the log for the DONE line and would have read nothing at all.
	#
	# Fail-closed degradation: with no HOME there is no host.env to read, so the host stays
	# empty, the gate refuses an empty target, and the run has to end the way every other
	# refusal ends -- exit 78 and DONE exit=78 in the log, before xcodegen, xcodebuild or any
	# socket. BOUNDARY_OK is deliberately the *permissive* fixture here: the refusal has to
	# come from having no host at all, not from a boundary that would have rejected anything.
	run_launcher

	LAUNCHER_ASSERT=0
	[ "$LAUNCHER_RC" -eq 78 ] || LAUNCHER_ASSERT=1
	check "$LAUNCHER_ASSERT" "launcher survives HOME unset" "exit 78, not a shell fatal" "$LAUNCHER_OUT"

	# `if grep`, not `grep && x=1`: an AND-list whose left side fails is itself a failed
	# command, and this suite runs under `set -e`, so the negative assertions have to be
	# written as conditions or a passing case would end the run.
	LAUNCHER_ASSERT=0
	if grep -Fq -- 'unbound variable' "$LAUNCHER_OUT"; then
		LAUNCHER_ASSERT=1
	fi
	check "$LAUNCHER_ASSERT" "no unbound-variable death" "no expansion kills it ahead of the gate" "$LAUNCHER_OUT"

	LAUNCHER_ASSERT=0
	grep -Fq -- '[lab-boundary] REFUSED: empty target host' "$LAUNCHER_OUT" || LAUNCHER_ASSERT=1
	check "$LAUNCHER_ASSERT" "no HOME degrades to empty host" "the gate refuses an empty target" "$LAUNCHER_OUT"

	LAUNCHER_ASSERT=0
	if [ -f "$LAUNCHER_LOG" ]; then
		grep -Fq -- 'DONE exit=78' "$LAUNCHER_LOG" || LAUNCHER_ASSERT=1
	else
		LAUNCHER_ASSERT=1
	fi
	check "$LAUNCHER_ASSERT" "the DONE contract is still written" "DONE exit=78 in the log" "$LAUNCHER_LOG"

	# Nothing may have been built on the way to that refusal. The launcher names xcodegen and
	# xcodebuild only inside its build branch, so their absence says that branch was never
	# entered -- the same shape as probe.sh's cmake assertion above.
	LAUNCHER_ASSERT=0
	if grep -qiE -- 'xcodegen|xcodebuild' "$LAUNCHER_OUT"; then
		LAUNCHER_ASSERT=1
	fi
	check "$LAUNCHER_ASSERT" "refusal predates any build" "no xcodegen/xcodebuild in the run" "$LAUNCHER_OUT"
fi

# The no-leak assertion. Checked against the transcript, and reported without echoing the
# offending line -- a failing leak test must not itself print the thing that leaked.
echo "== verdict text carries no segment list =="
LEAKED=0
SEGMENTS_CHECKED=0
for seg in "$ALLOWED_V4" "$ALLOWED_V6" "$ALLOWED_LOOPBACK" "$ALLOWED_OTHER_V4"; do
	SEGMENTS_CHECKED=$((SEGMENTS_CHECKED + 1))
	if grep -Fq -- "$seg" "$TRANSCRIPT"; then
		LEAKED=$((LEAKED + 1))
	fi
done
if [ "$LEAKED" -eq 0 ]; then
	printf 'PASS  %-34s no allowed segment appears in gate output\n' "no segment leak"
else
	# Counted, never quoted -- and the total comes from the loop rather than a literal, so
	# adding a fixture segment cannot leave this line quietly reporting "of 3" forever.
	printf 'FAIL  %-34s %d of %d allowed segments appeared in gate output\n' "no segment leak" "$LEAKED" "$SEGMENTS_CHECKED"
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
