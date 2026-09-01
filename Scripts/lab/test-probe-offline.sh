#!/usr/bin/env bash
# Offline test suite for Scripts/lab/probe.command -- the Terminal.app reachability probe whose
# one-word verdict (BOUNDARY-REFUSED / REACHABLE / UNREACHABLE) gates every run-matrix.sh job.
# test-run-matrix-offline.sh shims the whole Terminal hop (`open`) and writes the result word
# itself, so the probe's OWN logic -- the fail-closed boundary gate before any packet, the exact
# nc invocation, the three-word contract -- had no offline coverage. Same construction as
# test-relay-offline.sh: real probe.command in a mktemp sandbox at the real depth, PATH shims
# for `nc` (records argv, exit code from LABTEST_NC_MODE; opens no socket) and `osascript`
# (must never be reached), HOME redirected to a sandbox host.env carrying an RFC 5737 address,
# TERM_PROGRAM cleared. One mutation proof (gate bypassed) keeps the refusal pin honest.
#
# Exit: 0 if every case passed, 1 otherwise.
set -uo pipefail

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB/../.." && pwd)"

KEEP=0
if [ "${1:-}" = "--keep" ]; then KEEP=1; fi

PASSES=0
FAILURES=0
CASE=''
pass() { printf 'PASS  %s\n' "$*"; PASSES=$((PASSES + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
note() { printf '        %s\n' "$*"; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/macdows-probe-offline.XXXXXX")" || exit 1
SB="$(cd "$SB" && pwd)" || exit 1 # normalised: no `//` from a TMPDIR ending in `/`
# shellcheck disable=SC2329,SC2317  # invoked by the EXIT trap below
cleanup() {
	if [ "$KEEP" -eq 1 ]; then printf 'sandbox kept: %s\n' "$SB"; else rm -rf "$SB"; fi
}
trap cleanup EXIT

SBROOT="$SB/root"
SBLAB="$SBROOT/Scripts/lab"
SBRUNTIME="$SBROOT/.build/lab-runtime"
SBHOME="$SB/home"
RESULT="$SBRUNTIME/probe-result.txt"
export LABTEST_TRACE="$SB/trace.txt"
export LABTEST_REFUSED_TRACE="$SB/refused-trace.txt"
: > "$LABTEST_REFUSED_TRACE"

mkdir -p "$SBLAB" "$SBHOME/.config/macdows" "$SB/bin" || exit 1
cp "$LAB/probe.command" "$SBLAB/probe.command" || exit 1
cp "$REPO_ROOT/Scripts/lib.sh" "$SBROOT/Scripts/lib.sh" || exit 1
# NB $SBRUNTIME is deliberately NOT pre-created: probe.command's own `mkdir -p` has to make it
# (case 0 pins that explicitly).

# Census of the sandbox's TRACKED tree (names + contents), taken once after construction; the
# mutation proof writes its `labtest-mutant-*` copy there on purpose, hence the exclusion.
snapshot_tracked() {
	(
		cd "$SBLAB" || exit 1
		find . -type f ! -name 'labtest-mutant-*' | sort | while IFS= read -r f; do
			printf '%s  %s\n' "$(cksum < "$f")" "$f"
		done
	)
}
TRACKED_PRISTINE="$SB/tracked-pristine.txt"
snapshot_tracked > "$TRACKED_PRISTINE" || exit 1

cat > "$SBHOME/.config/macdows/host.env" <<'HOSTENV' || exit 1
WIN_HOST=192.0.2.10
WIN_USER=labtest-placeholder
WIN_PASS=LABTEST-PLACEHOLDER-SECRET-3f9a
HOSTENV
ALLOW_FILE="$SBHOME/.config/macdows/lab-boundary.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="192.0.2.0/24"\n' > "$ALLOW_FILE" || exit 1
DENY_FILE="$SB/deny-boundary.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="198.51.100.0/24"\n' > "$DENY_FILE" || exit 1

cat > "$SB/bin/nc" <<'SHIM_NC' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM for nc(1): records argv, answers with LABTEST_NC_MODE (open|closed), opens
# no socket.
set -u
{ printf 'nc'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$LABTEST_TRACE"
case "${LABTEST_NC_MODE:-closed}" in
open) exit 0 ;;
*) exit 1 ;;
esac
SHIM_NC
cat > "$SB/bin/osascript" <<'SHIM_OSA' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM: must never be reached (run-long trace, never reset).
printf 'osascript:unexpected-call\n' >> "$LABTEST_REFUSED_TRACE"
exit 97
SHIM_OSA
chmod +x "$SB"/bin/* || exit 1
for shim in "$SB"/bin/*; do bash -n "$shim" || { printf 'shim does not parse: %s\n' "$shim"; exit 1; }; done
for tool in nc osascript; do
	resolved="$(PATH="$SB/bin:$PATH" command -v "$tool" || true)"
	if [ "$resolved" != "$SB/bin/$tool" ]; then
		printf 'ABORT: %s resolves to %s, not the shim\n' "$tool" "${resolved:-<nothing>}"; exit 1
	fi
done
# Positive control for the never-reached trace: hit the refuse shim once, confirm it recorded,
# clear -- so an empty trace at the end means "not reached", not "recorder misconfigured".
env -i LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" PATH="$SB/bin:$PATH" osascript -e 'x' >/dev/null 2>&1
grep -qF 'osascript:unexpected-call' "$LABTEST_REFUSED_TRACE" || { printf 'ABORT: refused-shim trace did not record a deliberate call\n'; exit 1; }
: > "$LABTEST_REFUSED_TRACE"

begin() { CASE="$1"; : > "$LABTEST_TRACE"; rm -f "$RESULT"; }
result() { cat "$RESULT" 2>/dev/null; }
nc_calls() { grep -c '^nc ' "$LABTEST_TRACE" 2>/dev/null || true; }
assert_eq() { # <actual> <expected> <what>
	if [ "$1" = "$2" ]; then return 0; fi
	fail "$CASE: $3 -- expected [$2], got [$1]"; return 1
}
# <boundary-file> empty is passed EMPTY: lib.sh's `${MACDOWS_LAB_BOUNDARY_FILE:-…}` treats that
# like unset, so the probe resolves the default path under the sandbox HOME (no array -- an
# empty `"${arr[@]}"` is an unbound-variable error under bash 3.2 + `set -u`).
run_probe() { # <probe-path> <boundary-file|""> <nc-mode>
	env -i HOME="$SBHOME" PATH="$SB/bin:$PATH" TERM_PROGRAM= \
		LABTEST_TRACE="$LABTEST_TRACE" LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" \
		LABTEST_NC_MODE="$3" MACDOWS_LAB_BOUNDARY_FILE="$2" bash "$1" >/dev/null 2>&1
}

printf 'test-probe-offline.sh -- driving %s\n' "$LAB/probe.command"

# 0. The runtime directory is the probe's own to create: it must not exist before the first run
#    and must exist after it (the sandbox never pre-creates it).
begin '0 probe creates its runtime dir'
if [ ! -d "$SBRUNTIME" ]; then
	run_probe "$SBLAB/probe.command" "" closed
	if [ -d "$SBRUNTIME" ] && [ -f "$RESULT" ]; then
		pass "$CASE: .build/lab-runtime did not exist before the first run and the probe created it"
	else
		fail "$CASE: runtime dir or result file missing after the run"
	fi
else
	fail "$CASE: the sandbox pre-created $SBRUNTIME -- this pin measures nothing"
fi

# 1. Refused by the boundary: the word is BOUNDARY-REFUSED and nc never ran (no packet).
begin '1 boundary refused'
run_probe "$SBLAB/probe.command" "$DENY_FILE" open
if assert_eq "$(result)" 'BOUNDARY-REFUSED' 'result word' && assert_eq "$(nc_calls)" '0' 'nc invocations'; then
	pass "$CASE: BOUNDARY-REFUSED written, nc never invoked"
fi

# 2. Boundary file missing at the default path: fail-closed, same shape.
begin '2 boundary file missing (default path)'
mv "$ALLOW_FILE" "$ALLOW_FILE.away" || exit 1
run_probe "$SBLAB/probe.command" "" open
mv "$ALLOW_FILE.away" "$ALLOW_FILE" || exit 1
if assert_eq "$(result)" 'BOUNDARY-REFUSED' 'result word' && assert_eq "$(nc_calls)" '0' 'nc invocations'; then
	pass "$CASE: fail-closed refusal through the default boundary path, nc never invoked"
fi

# 3. Allowed, port open: REACHABLE; exactly one nc call with the documented argv.
begin '3 reachable'
run_probe "$SBLAB/probe.command" "" open
argv="$(grep '^nc ' "$LABTEST_TRACE" | head -n 1)"
if assert_eq "$(result)" 'REACHABLE' 'result word' && assert_eq "$(nc_calls)" '1' 'nc invocations' \
	&& assert_eq "$argv" 'nc [-z] [-G] [5] [192.0.2.10] [3389]' 'nc argv'; then
	pass "$CASE: REACHABLE; one nc -z -G 5 <host> 3389 invocation"
fi

# 4. Allowed, port closed: UNREACHABLE (an expected outcome, not an abort).
begin '4 unreachable'
run_probe "$SBLAB/probe.command" "" closed
if assert_eq "$(result)" 'UNREACHABLE' 'result word' && assert_eq "$(nc_calls)" '1' 'nc invocations'; then
	pass "$CASE: UNREACHABLE on a closed port, probe still exits cleanly"
fi

# 5. The result file is exactly ONE newline-terminated line (the word itself is pinned by cases
#    1/3/4; what this case owns is the line shape run-matrix.sh's reader depends on).
begin '5 result file is one terminated line'
run_probe "$SBLAB/probe.command" "" closed
if [ "$(wc -l < "$RESULT" | tr -d ' ')" = "1" ] && [ "$(tail -c 1 "$RESULT" | od -An -c | tr -d ' ')" = '\n' ]; then
	pass "$CASE: probe-result.txt is exactly one newline-terminated line"
else
	fail "$CASE: $(od -c "$RESULT" | head -3)"
fi

# 6. A stale word must never survive a run that dies before writing: the probe truncates the
#    result file first thing, so a host.env that `exit`s leaves an EMPTY file (which the caller's
#    wait_for_file -- `[ -s ]` -- treats as no result), not last run's REACHABLE (review probe-r1
#    I1). This is one of three early-death paths (host.env exit / host.env missing / lib.sh
#    missing); the other two already fail closed to BOUNDARY-REFUSED, so this is the one that
#    needed the truncation.
begin '6 stale word does not survive an early death'
printf 'REACHABLE\n' > "$RESULT"
cp "$SBHOME/.config/macdows/host.env" "$SB/host.env.keep" || exit 1
printf 'exit 0\n' >> "$SBHOME/.config/macdows/host.env"
run_probe "$SBLAB/probe.command" "" open
cp "$SB/host.env.keep" "$SBHOME/.config/macdows/host.env" || exit 1
if [ -f "$RESULT" ] && [ ! -s "$RESULT" ] && assert_eq "$(nc_calls)" '0' 'nc invocations'; then
	pass "$CASE: after a host.env that exits early the result file exists but is empty; the stale REACHABLE is gone; nc never ran"
else
	fail "$CASE: result=[$(cat "$RESULT" 2>/dev/null)] nc calls=$(nc_calls)"
fi

# 7. The Terminal self-close branch was never taken across the whole run.
begin '7 osascript never reached'
if [ ! -s "$LABTEST_REFUSED_TRACE" ]; then
	pass "$CASE: osascript shim recorded no call (TERM_PROGRAM cleared)"
else
	fail "$CASE: $(sort "$LABTEST_REFUSED_TRACE" | uniq -c | tr '\n' ';')"
fi

# 8. Tracked-tree census: every run above wrote only under .build/lab-runtime.
begin '8 tracked tree census'
if diff -q "$TRACKED_PRISTINE" <(snapshot_tracked) >/dev/null; then
	pass "$CASE: no case wrote into the tracked lab directory"
else
	fail "$CASE: tracked tree changed"; diff "$TRACKED_PRISTINE" <(snapshot_tracked) | sed 's/^/        /'
fi

# M1. Gate bypassed (`if ! crdp_assert_lab_boundary` -> `if false`): the refused scenario
#     must now reach nc -- case 1's pin bites.
begin 'M1 gate-bypass mutant'
MUTANT="$SBLAB/labtest-mutant-gate.command"
# shellcheck disable=SC2016  # deliberate literal `$` for sed
if sed 's/if ! crdp_assert_lab_boundary "\${WIN_HOST:-}"; then/if false; then/' "$SBLAB/probe.command" > "$MUTANT" \
	&& ! cmp -s "$MUTANT" "$SBLAB/probe.command" && bash -n "$MUTANT"; then
	run_probe "$MUTANT" "$DENY_FILE" open
	if [ "$(nc_calls)" = "1" ] && [ "$(result)" = "REACHABLE" ]; then
		pass "$CASE: detected -- the refused scenario reaches nc (case 1 pins the gate)"
	else
		fail "$CASE: NOT detected"; note "nc calls=$(nc_calls) result=$(result)"
	fi
else
	fail "$CASE: could not build the mutant (the guard line moved?)"
fi

# M2. The nc argv is pinned literally by case 3: change the connect timeout (`-G 5` -> `-G 6`) and
#     case 3's scenario must no longer match.
begin 'M2 argv-drift mutant'
MUTANT_ARGV="$SBLAB/labtest-mutant-argv.command"
# shellcheck disable=SC2016  # deliberate literal `$WIN_HOST` for sed
if sed 's/nc -z -G 5 "\$WIN_HOST" 3389/nc -z -G 6 "$WIN_HOST" 3389/' "$SBLAB/probe.command" > "$MUTANT_ARGV" \
	&& ! cmp -s "$MUTANT_ARGV" "$SBLAB/probe.command" && bash -n "$MUTANT_ARGV"; then
	run_probe "$MUTANT_ARGV" "" open
	argv="$(grep '^nc ' "$LABTEST_TRACE" | head -n 1)"
	if [ "$argv" = 'nc [-z] [-G] [6] [192.0.2.10] [3389]' ] && [ "$(result)" = "REACHABLE" ]; then
		pass "$CASE: detected -- the argv pin (case 3) sees the connect timeout change to 6"
	else
		fail "$CASE: NOT detected"; note "argv: $argv"
	fi
else
	fail "$CASE: could not build the mutant (the nc line moved?)"
fi

# Every case must have reported: a case that neither passed nor failed would otherwise vanish
# from the tally with exit 0. Placed after the LAST case on purpose.
EXPECTED_CASES=11
if [ $((PASSES + FAILURES)) -ne "$EXPECTED_CASES" ]; then
	fail "case tally: $((PASSES + FAILURES)) cases reported, expected $EXPECTED_CASES -- a case produced no verdict"
fi
printf '\n%d passed, %d failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
