#!/usr/bin/env bash
# Offline test suite for Scripts/lab/display-mode.command and Scripts/lab/display_mode.swift's
# pure selectMode function (exercised through the helper's own --self-test, run for REAL). This
# tool switches the LOCAL Mac's display between "1x" and "2x" for a checkpoint batch; it opens no
# socket and needs no live-host boundary gate, so this suite is simpler than the checkpoint-lane
# ones: no host.env, no boundary files, no HOME-scoped credential mask.
#
# Every fixture number below is SYNTHETIC (3000x2000 / 1500x1000 / 60Hz) -- gate r1 B5 found the
# previous revision of this file carrying this maintainer's own panel geometry and refresh rate, a
# specific-enough tuple to narrow the panel to a small set of monitors. Deliberately not restated
# here: test-display-mode-pins.sh's literal pin now scans this file too (standalone-number half
# only -- the WxH TOKENS here are the whole point of a synthetic fixture), and a comment quoting
# the exact leaked values would itself be the leak the pin exists to catch.
#
# The guards that must not rot are:
#   * the argument shape check (64), before anything else is touched, and the log ends
#     `DONE exit=64` (gate r1 I1);
#   * the IN-FLIGHT GUARD (75): an ETW capture, a smoke run or a relay with a runtime log that
#     has no DONE exit= line yet refuses BEFORE the helper is built or run, and the log ends
#     `DONE exit=75` (gate r1 I1) -- and a log that DOES carry a DONE line does not block a later
#     run (the guard reads one signal, not "the file exists");
#   * the BUILD GUARD (69): the helper is (re)built only when missing or older than the source,
#     never unconditionally, and swiftc's own failure is distinguished from every other refusal;
#   * argv/stdout PASSTHROUGH: `status`/`1x`/`2x` map onto the helper's `status`/`set 1x`/`set 2x`
#     exactly, and the helper's own [display] lines reach this wrapper's stdout unchanged;
#   * the system_profiler CROSS-CHECK fires only for 1x/2x and only when the helper itself claims
#     rc=0 (already-in-target counts), never on a REFUSED (66) or the helper's own VERIFY-FAILED
#     (65) -- both of which have nothing further to cross-check;
#   * FAIL-CLOSED (gate r1 B2): no parseable `UI Looks like:` line for the main display, or no
#     parseable `after:` line from the helper itself (a grammar drift), refuses (65) rather than
#     silently skipping the cross-check and passing the helper's rc=0 through unexamined;
#   * MAIN DISPLAY ONLY (gate r1 B4): the cross-check reads the `UI Looks like:` line from the
#     stanza whose OWN `Main Display: Yes` is set, never merely the first stanza in the report, and
#     falls back to the same fail-closed refusal when no stanza is marked main;
#   * RESTORE ONLY WHEN SOMETHING SWITCHED (gate r1 B3): on disagreement (or an unparseable second
#     opinion), the wrapper asks the helper to switch to the OTHER of the two states as a
#     best-effort restore ONLY when the helper's own current:/after: lines show a switch actually
#     happened; an already-in-target request that hits a disagreement touched nothing and must
#     issue no further switch (`restored=0 (nothing to restore)`), never the opposite of what was
#     asked for.
#
# Safe in CI, by construction:
#   1. `swiftc` and `system_profiler` are PATH-shimmed inside the sandbox, and the suite asserts
#      before the first case that PATH resolves each to its shim. The swiftc shim always records
#      its argv and always fails (a fixed, distinctive rc) -- nothing in this suite needs it to
#      succeed, because every behavioural case points LABTEST_DISPLAY_HELPER at a ready-made fake
#      that is already newer than the sandbox's placeholder display_mode.swift, so the build guard
#      skips the build entirely. Its NOT being called is therefore itself an assertion in most
#      cases, and its failing loudly is the point of the one case that needs it called. The
#      system_profiler shim emits realistic multi-line stanzas (a `Main Display: Yes` marker, and
#      optionally a decoy stanza printed FIRST with no marker at all -- gate r1 B4's fixtures) so
#      the wrapper's own awk-based stanza scoping has real text to scope, not a bare line.
#   2. The helper itself is never a real CoreGraphics binary in the behavioural cases: it is
#      whatever LABTEST_DISPLAY_HELPER names, a bash shim under this suite's control, in the same
#      spirit as test-smoke-job-offline.sh stubbing run-window-smoke.command at its own path --
#      the difference is that this helper's real path is a BUILD OUTPUT the sandbox cannot simply
#      overwrite in place, so display-mode.command reads the override from a variable instead.
#   3. Two cases are NOT fakes and are gated on `command -v swiftc` (SKIP, own tally, never a pass,
#      when absent -- Tier 1 is compile-free by policy): "the helper's own --self-test" compiles
#      the REAL Scripts/lab/display_mode.swift and runs --self-test for real (gate r1 B1's two new
#      fixtures live there); "the real helper's line grammar" runs the REAL helper's `status` and
#      feeds its own `current:` line through the WRAPPER's own extraction pattern (gate r1 I2) --
#      the fakes above REPRODUCE the grammar rather than checking it, and this is the case that
#      would go red if the real one ever drifted out from under them. Neither touches a display.
#
# Exit: 0 if every case passed, 1 otherwise (SKIPPED never affects the exit code).
set -uo pipefail

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KEEP=0
if [ "${1:-}" = "--keep" ]; then KEEP=1; fi

PASSES=0
FAILURES=0
SKIPPED=0
CASE=''
pass() { printf 'PASS  %s\n' "$*"; PASSES=$((PASSES + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
# skip() is its OWN tally, never folded into pass: a runner with no swiftc must not be able to
# make a real-swiftc case look like it verified anything (Tier 1 is compile-free by policy --
# adr/0006 §6 -- so this is the expected, permanent outcome there, not a degraded pass).
skip() { printf 'SKIP  %s\n' "$*"; SKIPPED=$((SKIPPED + 1)); }
note() { printf '        %s\n' "$*"; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/macdows-display-mode-offline.XXXXXX")" || exit 1
SB="$(cd "$SB" && pwd)" || exit 1 # normalised: no `//` from a TMPDIR ending in `/`
# shellcheck disable=SC2329,SC2317  # invoked by the EXIT trap below
cleanup() {
	if [ "$KEEP" -eq 1 ]; then printf 'sandbox kept: %s\n' "$SB"; else rm -rf "$SB"; fi
}
trap cleanup EXIT

SBROOT="$SB/root"
SBLAB="$SBROOT/Scripts/lab"
SBRUNTIME="$SBROOT/.build/lab-runtime"
export LABTEST_TRACE="$SB/trace.txt"
: > "$LABTEST_TRACE"

mkdir -p "$SBLAB" "$SB/bin" || exit 1
cp "$LAB/display-mode.command" "$SBLAB/display-mode.command" || exit 1
# A placeholder, never actually compiled for real in this suite (swiftc is shimmed and always
# fails) -- only its NAME and its MTIME relative to the fake helper matter. Deliberately not a
# copy of the real display_mode.swift: what every behavioural case measures is display-mode.command's
# own build-guard and passthrough logic, not the helper's contents.
printf '// OFFLINE TEST PLACEHOLDER: never compiled for real by this suite.\n' > "$SBLAB/display_mode.swift" || exit 1
touch -t 202001010000 "$SBLAB/display_mode.swift" || exit 1
# NB $SBRUNTIME is deliberately NOT pre-created: display-mode.command's own `mkdir -p` has to
# make it.

cat > "$SB/bin/swiftc" <<'SHIM_SWIFTC' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM for swiftc: records argv, ALWAYS fails (fixed rc 5) -- nothing in this suite
# needs a real build to succeed, and a loud, distinctive failure makes an unexpected call obvious
# rather than silently producing a helper that happens to work.
{ printf 'SWIFTC'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$LABTEST_TRACE"
echo "labtest: swiftc shim -- forced failure, this suite never needs a real build" >&2
exit 5
SHIM_SWIFTC

cat > "$SB/bin/system_profiler" <<'SHIM_PROFILER' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM for system_profiler SPDisplaysDataType: emits realistic multi-line stanzas so
# the wrapper's Main-Display-scoped parser (gate r1 B4) has real structure to scope, not a bare
# line.
#   LABTEST_PROFILER_SECOND_LOOKS  "<w> <h>", optional: a DECOY stanza printed FIRST, with no
#                                  Main Display: Yes anywhere in it (a non-main display listed
#                                  first, or -- when LABTEST_PROFILER_LOOKS is left empty -- the
#                                  "no stanza is marked main at all" fixture).
#   LABTEST_PROFILER_LOOKS         "<w> <h>", optional: the MAIN stanza (carries Main Display:
#                                  Yes), printed after the decoy if one was requested. Empty/unset
#                                  means no main-marked stanza at all.
{ printf 'PROFILER'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$LABTEST_TRACE"
if [ -n "${LABTEST_PROFILER_SECOND_LOOKS:-}" ]; then
	sw="${LABTEST_PROFILER_SECOND_LOOKS% *}"
	sh="${LABTEST_PROFILER_SECOND_LOOKS#* }"
	printf '        DecoyDisplay:\n'
	printf '          UI Looks like: %s x %s @ 60Hz\n' "$sw" "$sh"
	printf '          Mirror: Off\n'
fi
if [ -n "${LABTEST_PROFILER_LOOKS:-}" ]; then
	w="${LABTEST_PROFILER_LOOKS% *}"
	h="${LABTEST_PROFILER_LOOKS#* }"
	printf '        MainDisplay:\n'
	printf '          UI Looks like: %s x %s @ 60Hz\n' "$w" "$h"
	printf '          Main Display: Yes\n'
fi
exit 0
SHIM_PROFILER

cat > "$SB/bin/fake-helper" <<'SHIM_HELPER' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM standing in for the compiled display_mode.swift helper (pointed at via
# LABTEST_DISPLAY_HELPER). LABTEST_HELPER_MODE picks the scripted scenario; every mode prints the
# same [display] line grammar the real helper does, so display-mode.command's own parsing (the
# `after:` line, the OK/REFUSED/VERIFY-FAILED family) is exercised against real text shapes.
# Fixture numbers are synthetic (gate r1 B5): 3000x2000 is the "native"/1x shape, 1500x1000 the 2x
# shape, both at 60Hz.
{ printf 'HELPER'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$LABTEST_TRACE"
sub="${1:-}"
arg="${2:-}"
mode="${LABTEST_HELPER_MODE:-success}"
if [ "$sub" = "status" ]; then
	printf '[display] current: id=1 looks=3000x2000 pixels=3000x2000 60Hz hidpi=0\n'
	exit 0
fi
case "$mode" in
success)
	if [ "$arg" = "2x" ]; then
		printf '[display] current: id=1 looks=3000x2000 pixels=3000x2000 60Hz hidpi=0\n'
		printf '[display] target: id=2 looks=1500x1000 pixels=3000x2000 60Hz hidpi=1\n'
		printf '[display] after: id=2 looks=1500x1000 pixels=3000x2000 60Hz hidpi=1\n'
		printf '[display] OK 2x\n'
	else
		printf '[display] current: id=2 looks=1500x1000 pixels=3000x2000 60Hz hidpi=1\n'
		printf '[display] target: id=1 looks=3000x2000 pixels=3000x2000 60Hz hidpi=0\n'
		printf '[display] after: id=1 looks=3000x2000 pixels=3000x2000 60Hz hidpi=0\n'
		printf '[display] OK 1x\n'
	fi
	exit 0
	;;
already)
	printf '[display] current: id=1 looks=3000x2000 pixels=3000x2000 60Hz hidpi=0\n'
	printf '[display] target: id=1 looks=3000x2000 pixels=3000x2000 60Hz hidpi=0\n'
	printf '[display] after: id=1 looks=3000x2000 pixels=3000x2000 60Hz hidpi=0\n'
	printf '[display] OK 1x\n'
	exit 0
	;;
notfound)
	printf '[display] current: id=1 looks=3000x2000 pixels=3000x2000 60Hz hidpi=0\n'
	printf '[display] REFUSED: no usable 2x mode at the current refresh rate (60Hz) and native pixel size (3000x2000)\n'
	exit 66
	;;
verifyfail)
	printf '[display] current: id=1 looks=3000x2000 pixels=3000x2000 60Hz hidpi=0\n'
	printf '[display] target: id=2 looks=1500x1000 pixels=3000x2000 60Hz hidpi=1\n'
	printf '[display] after: id=1 looks=3000x2000 pixels=3000x2000 60Hz hidpi=0\n'
	printf '[display] VERIFY-FAILED: after does not match target restored=1\n'
	exit 65
	;;
esac
SHIM_HELPER
touch -t 202006010000 "$SB/bin/fake-helper" || exit 1 # newer than the placeholder source, by design
chmod +x "$SB"/bin/* || exit 1
for shim in "$SB"/bin/*; do bash -n "$shim" || { printf 'shim does not parse: %s\n' "$shim"; exit 1; }; done
for tool in swiftc system_profiler; do
	resolved="$(PATH="$SB/bin:$PATH" command -v "$tool" || true)"
	if [ "$resolved" != "$SB/bin/$tool" ]; then
		printf 'ABORT: %s resolves to %s, not the shim\n' "$tool" "${resolved:-<nothing>}"; exit 1
	fi
done

begin() { CASE="$1"; : > "$LABTEST_TRACE"; rm -rf "$SBRUNTIME"; }
helper_calls() { grep -c '^HELPER ' "$LABTEST_TRACE" 2>/dev/null || true; }
swiftc_calls() { grep -c '^SWIFTC ' "$LABTEST_TRACE" 2>/dev/null || true; }
log_tail() { tail -n 1 "$SBRUNTIME/display-mode.log" 2>/dev/null; }
assert_eq() { # <actual> <expected> <what>
	if [ "$1" = "$2" ]; then return 0; fi
	fail "$CASE: $3 -- expected [$2], got [$1]"; return 1
}

# <helper> "" for the build-failure case (no fake at all: LABTEST_DISPLAY_HELPER left unset so
# display-mode.command falls back to its own default runtime path, which the sandbox has never
# built). Output goes to $SB/stdout.txt / $SB/stderr.txt and the sandbox's own display-mode.log.
# LABTEST_HELPER_MODE and LABTEST_PROFILER_SECOND_LOOKS are read as ambient env (set by the caller
# before invoking this function, same convention as smoke-job.command's suite), not parameters.
run_wrapper() { # <helper-path-or-""> <profiler-looks-or-""> <arg...>
	local helper="$1" looks="$2"
	shift 2
	env -i PATH="$SB/bin:$PATH" LABTEST_TRACE="$LABTEST_TRACE" \
		LABTEST_DISPLAY_HELPER="$helper" LABTEST_PROFILER_LOOKS="$looks" \
		LABTEST_HELPER_MODE="${LABTEST_HELPER_MODE:-}" \
		LABTEST_PROFILER_SECOND_LOOKS="${LABTEST_PROFILER_SECOND_LOOKS:-}" \
		bash "$SBLAB/display-mode.command" "$@" >"$SB/stdout.txt" 2>"$SB/stderr.txt"
}

printf 'test-display-mode-offline.sh -- driving %s\n' "$LAB/display-mode.command"

# 1. Usage: no args, an unknown subcommand, and a valid subcommand with a stray extra argument all
#    refuse 64, nothing touched, and the log ends DONE exit=64 (gate r1 I1).
begin '1 usage'
LABTEST_HELPER_MODE=success run_wrapper "$SB/bin/fake-helper" "" >/dev/null 2>&1
RC1=$?
LABTEST_HELPER_MODE=success run_wrapper "$SB/bin/fake-helper" "" bogus
RC2=$?
LABTEST_HELPER_MODE=success run_wrapper "$SB/bin/fake-helper" "" status extra
RC3=$?
if assert_eq "$RC1 $RC2 $RC3" '64 64 64' 'exit codes (no-args/bogus/extra-arg)' \
	&& assert_eq "$(helper_calls)" '0' 'helper invocations' && assert_eq "$(swiftc_calls)" '0' 'swiftc invocations' \
	&& assert_eq "$(log_tail)" 'DONE exit=64' 'log tail'; then
	pass "$CASE: no args, an unknown subcommand and a stray extra argument all exit 64; nothing touched; log ends DONE exit=64"
fi

# 2. In-flight guard: each of etw.log / smoke.log / relay.log without a DONE exit= line refuses
#    75, the helper is never invoked, and the log ends DONE exit=75 (gate r1 I1).
begin '2 in-flight refusal (no DONE line)'
ALL_OK=1
for sig in etw.log smoke.log relay.log; do
	mkdir -p "$SBRUNTIME" || exit 1
	printf '[in flight]\n' > "$SBRUNTIME/$sig"
	: > "$LABTEST_TRACE"
	LABTEST_HELPER_MODE=success run_wrapper "$SB/bin/fake-helper" "" status
	rc=$?
	if [ "$rc" -ne 75 ] || [ "$(helper_calls)" != "0" ] || [ "$(log_tail)" != "DONE exit=75" ]; then
		ALL_OK=0
		note "$sig: rc=$rc helper_calls=$(helper_calls) log_tail=$(log_tail)"
	fi
	rm -f "$SBRUNTIME/$sig"
done
if [ "$ALL_OK" -eq 1 ]; then
	pass "$CASE: etw.log, smoke.log and relay.log each refuse 75 with no DONE line, helper never invoked, log ends DONE exit=75"
else
	fail "$CASE: at least one signal did not refuse correctly"
fi

# 3. A signal log that DOES carry a DONE exit= line is stale, not in-flight: the run proceeds.
begin '3 a DONE-terminated log does not block'
mkdir -p "$SBRUNTIME" || exit 1
printf '[etw] done\nDONE exit=0\n' > "$SBRUNTIME/etw.log"
LABTEST_HELPER_MODE=success run_wrapper "$SB/bin/fake-helper" "" status
rc=$?
if assert_eq "$rc" '0' 'exit code' && assert_eq "$(helper_calls)" '1' 'helper invocations'; then
	pass "$CASE: a stale etw.log with its own DONE line does not refuse; the run proceeds"
fi
rm -f "$SBRUNTIME/etw.log"

# 4. Helper build failure: LABTEST_DISPLAY_HELPER unset (falls back to the never-built default
#    runtime path) forces the build guard to invoke swiftc, which the shim always fails.
begin '4 helper build failure'
run_wrapper "" "" status
rc=$?
if assert_eq "$rc" '69' 'exit code' && assert_eq "$(swiftc_calls)" '1' 'swiftc invocations' \
	&& assert_eq "$(helper_calls)" '0' 'helper invocations' \
	&& grep -qF 'DONE exit=69' "$SBRUNTIME/display-mode.log"; then
	pass "$CASE: swiftc's forced failure surfaces as exit 69, the helper is never run, the log ends DONE exit=69"
fi

# 5. status passthrough: exact argv to the helper, its stdout reaches ours unchanged, and a fresh
#    fake helper means the build guard never calls swiftc.
begin '5 status passthrough'
LABTEST_HELPER_MODE=success run_wrapper "$SB/bin/fake-helper" "" status
rc=$?
if assert_eq "$rc" '0' 'exit code' && assert_eq "$(grep '^HELPER ' "$LABTEST_TRACE")" 'HELPER [status]' 'helper argv' \
	&& assert_eq "$(swiftc_calls)" '0' 'swiftc invocations' \
	&& grep -qF '[display] current: id=1 looks=3000x2000 pixels=3000x2000 60Hz hidpi=0' "$SB/stdout.txt"; then
	pass "$CASE: status maps to helper argv [status], stdout passes through, no build"
fi

# 6. 1x/2x passthrough: each maps to the helper's `set <scale>`, and (agreeing system_profiler)
#    the helper's OK line reaches our stdout with rc=0.
begin '6 1x/2x passthrough'
LABTEST_HELPER_MODE=success run_wrapper "$SB/bin/fake-helper" "1500 1000" 2x
rc2x=$?
argv2x="$(grep '^HELPER ' "$LABTEST_TRACE" | head -n 1)"
: > "$LABTEST_TRACE"
LABTEST_HELPER_MODE=success run_wrapper "$SB/bin/fake-helper" "3000 2000" 1x
rc1x=$?
argv1x="$(grep '^HELPER ' "$LABTEST_TRACE" | head -n 1)"
if assert_eq "$rc2x $rc1x" '0 0' 'exit codes (2x 1x)' \
	&& assert_eq "$argv2x" 'HELPER [set] [2x]' '2x helper argv' \
	&& assert_eq "$argv1x" 'HELPER [set] [1x]' '1x helper argv'; then
	pass "$CASE: 1x and 2x each pass through to the helper as [set] [<scale>]"
fi

# 7. Mode-not-found: the helper's own 66 passes straight through, and because the cross-check only
#    fires on rc=0, there is exactly ONE helper invocation -- no restore, no second call.
begin '7 mode-not-found'
LABTEST_HELPER_MODE=notfound run_wrapper "$SB/bin/fake-helper" "" 2x
rc=$?
if assert_eq "$rc" '66' 'exit code' && assert_eq "$(helper_calls)" '1' 'helper invocations (no set/restore attempted)'; then
	pass "$CASE: no usable mode -> 66, exactly one helper call, no set/restore was attempted"
fi

# 8. Verify-failed: the helper's own 65 (with its own restored=1) passes straight through.
begin '8 verify-failed'
LABTEST_HELPER_MODE=verifyfail run_wrapper "$SB/bin/fake-helper" "" 2x
rc=$?
if assert_eq "$rc" '65' 'exit code' && assert_eq "$(helper_calls)" '1' 'helper invocations' \
	&& grep -qF 'restored=1' "$SB/stdout.txt"; then
	pass "$CASE: the helper's own VERIFY-FAILED (restored=1) passes through as exit 65"
fi

# 9. system_profiler disagreement, a REAL switch happened: the helper claims OK (rc=0, after:
#    1500x1000), but the shimmed system_profiler reports the display never actually changed
#    (3000x2000). Because the helper's current:/after: lines differ (a switch DID happen -- gate r1
#    B3), the wrapper does not trust CoreGraphics's own yes: it asks the helper to switch back to
#    1x as a restore (a SECOND helper call, argv [set] [1x]) and answers 65 with the restore's own
#    outcome.
begin '9 system_profiler disagreement (a switch happened)'
LABTEST_HELPER_MODE=success run_wrapper "$SB/bin/fake-helper" "3000 2000" 2x
rc=$?
if assert_eq "$rc" '65' 'exit code' && assert_eq "$(helper_calls)" '2' 'helper invocations (set 2x, then restore set 1x)' \
	&& assert_eq "$(grep '^HELPER ' "$LABTEST_TRACE" | tail -n 1)" 'HELPER [set] [1x]' 'restore-call argv' \
	&& grep -qF 'restored=1' "$SB/stdout.txt"; then
	pass "$CASE: system_profiler disagreeing with the helper's own after: forces exit 65 and a restore attempt (restored=1)"
fi

# 10. Already-in-target: the helper reports OK with target==current (its own after: line is the
#     same mode), the agreeing system_profiler cross-check holds, and nothing needed restoring.
begin '10 already-in-target'
LABTEST_HELPER_MODE=already run_wrapper "$SB/bin/fake-helper" "3000 2000" 1x
rc=$?
if assert_eq "$rc" '0' 'exit code' && assert_eq "$(helper_calls)" '1' 'helper invocations (no restore needed)'; then
	pass "$CASE: already at the requested mode -- exit 0, one helper call, no restore"
fi

# 11. Success: 2x with an agreeing system_profiler -- exit 0, [display] OK 2x visible, and the
#     runtime log ends with DONE exit=0.
begin '11 success'
LABTEST_HELPER_MODE=success run_wrapper "$SB/bin/fake-helper" "1500 1000" 2x
rc=$?
if assert_eq "$rc" '0' 'exit code' && grep -qF '[display] OK 2x' "$SB/stdout.txt" \
	&& [ "$(log_tail)" = 'DONE exit=0' ]; then
	pass "$CASE: a clean 2x switch exits 0, prints [display] OK 2x, and the log ends DONE exit=0"
else
	fail "$CASE: stdout=$(cat "$SB/stdout.txt") log-tail=$(log_tail)"
fi

# 12. gate r1 B2: system_profiler gives NO parseable line at all (not even a decoy), but a REAL
#     switch happened (success/2x: current != after). Fail-closed, not fail-open: exit 65, the
#     exact refusal text, and BECAUSE a switch happened, the wrapper still attempts the
#     opposite-mode restore (a second helper call) -- this is the case B2's own PROBE 1 pins.
begin '12 system_profiler unavailable, a switch happened (gate r1 B2)'
LABTEST_HELPER_MODE=success run_wrapper "$SB/bin/fake-helper" "" 2x
rc=$?
if assert_eq "$rc" '65' 'exit code' && assert_eq "$(helper_calls)" '2' 'helper invocations (set 2x, then restore set 1x)' \
	&& grep -qF '[display] VERIFY-FAILED: system_profiler gave no "UI Looks like:" line for the main display' "$SB/stdout.txt" \
	&& grep -qF 'restored=1' "$SB/stdout.txt"; then
	pass "$CASE: no parseable UI Looks like: line -> fail-closed 65, restore attempted because a switch happened"
fi

# 13. gate r1 B3: already-in-target (no switch happened) hits a DISAGREEING system_profiler. The
#     wrapper must NOT issue the opposite-mode switch -- nothing was ever touched, so there is
#     nothing to restore. This is PROBE 2 from the gate report: the pre-fold wrapper reported
#     `restored=1` here after actually commanding `set 2x`, moving a display that was never touched.
begin '13 already-in-target + disagreement issues no switch (gate r1 B3)'
LABTEST_HELPER_MODE=already run_wrapper "$SB/bin/fake-helper" "1500 1000" 1x
rc=$?
if assert_eq "$rc" '65' 'exit code' && assert_eq "$(helper_calls)" '1' 'helper invocations (NO restore/opposite switch)' \
	&& grep -qF 'restored=0 (nothing to restore)' "$SB/stdout.txt"; then
	pass "$CASE: already-in-target + disagreement -> exit 65, restored=0 (nothing to restore), no second helper call"
fi

# 14. The same B3 guarantee when the second opinion is simply ABSENT rather than disagreeing (the
#     B2 and B3 fixes compose): no switch happened, no parseable line either -- still no restore.
begin '14 already-in-target + no parseable line issues no switch (gate r1 B2+B3)'
LABTEST_HELPER_MODE=already run_wrapper "$SB/bin/fake-helper" "" 1x
rc=$?
if assert_eq "$rc" '65' 'exit code' && assert_eq "$(helper_calls)" '1' 'helper invocations (NO restore/opposite switch)' \
	&& grep -qF 'restored=0 (nothing to restore)' "$SB/stdout.txt"; then
	pass "$CASE: already-in-target + unavailable cross-check -> exit 65, restored=0 (nothing to restore), no second helper call"
fi

# 15. gate r1 B4: a SECOND display listed FIRST in the report, carrying no Main Display: Yes and a
#     DISAGREEING geometry, followed by the real main display's stanza which AGREES with the
#     helper's after: line. A `head -n1`-style read would land on the decoy and wrongly disagree;
#     scoping to the Main Display: Yes stanza reads the right one and reports exit 0.
begin '15 two displays, main NOT first, correctly scoped (gate r1 B4)'
LABTEST_PROFILER_SECOND_LOOKS="9000 8000" LABTEST_HELPER_MODE=success run_wrapper "$SB/bin/fake-helper" "1500 1000" 2x
rc=$?
if assert_eq "$rc" '0' 'exit code' && assert_eq "$(helper_calls)" '1' 'helper invocations (no restore -- the decoy must not cause a false disagreement)'; then
	pass "$CASE: the decoy (non-main, listed first) stanza is ignored; the main stanza agrees -> exit 0"
fi

# 16. gate r1 B4's own fallback: a stanza IS present (so there is text to read) but NONE of them is
#     marked main. Fails closed exactly like B2's "no line at all", and because a real switch
#     happened, still attempts the restore.
begin '16 no stanza marked main (gate r1 B4 fallback)'
LABTEST_PROFILER_SECOND_LOOKS="9000 8000" LABTEST_HELPER_MODE=success run_wrapper "$SB/bin/fake-helper" "" 2x
rc=$?
if assert_eq "$rc" '65' 'exit code' && assert_eq "$(helper_calls)" '2' 'helper invocations (set 2x, then restore set 1x)' \
	&& grep -qF '[display] VERIFY-FAILED: system_profiler gave no "UI Looks like:" line for the main display' "$SB/stdout.txt"; then
	pass "$CASE: a decoy stanza with no Main Display: Yes anywhere -> fail-closed 65, same as no line at all"
fi

# 17. The helper's own unit test, run for REAL when this machine has a real swiftc: compiles the
#     REAL Scripts/lab/display_mode.swift (outside the sandbox -- this is not a fake), then
#     --self-test run for real (gate r1 B1's two new fixtures, and m1's distinct-id tie-break,
#     live there). Touches no display on any platform. Tier 1 is compile-free by policy (adr/0006
#     §6) and its runner carries no Swift toolchain, so THERE this case is expected to SKIP, every
#     time -- that is not a gap in this suite: the source-shape pins
#     (Scripts/lab/test-display-mode-pins.sh) are Tier 1's own coverage of this arithmetic, and a
#     real swiftc is on PATH for every lane gate and every maintainer run of this suite.
#     `command -v` (not `type`/`which`) is what display-mode.command's own build guard effectively
#     depends on too: if this can't find swiftc, neither can it.
REAL_BIN="$SB/real-display-mode-helper"
begin '17 helper self-test (real build, real run)'
if ! command -v swiftc >/dev/null 2>&1; then
	skip "$CASE: no swiftc on this runner (Tier 1 is compile-free; run locally)"
else
	REAL_BUILD_OUT="$(swiftc -O "$LAB/display_mode.swift" -o "$REAL_BIN" 2>&1)"
	REAL_BUILD_RC=$?
	if [ "$REAL_BUILD_RC" -ne 0 ]; then
		fail "$CASE: the real helper failed to build: $REAL_BUILD_OUT"
	else
		SELF_TEST_OUT="$("$REAL_BIN" --self-test)"
		SELF_TEST_RC=$?
		FAIL_LINES="$(printf '%s\n' "$SELF_TEST_OUT" | grep -c '^\[self-test\] FAIL' || true)"
		PASS_LINES="$(printf '%s\n' "$SELF_TEST_OUT" | grep -c '^\[self-test\] PASS' || true)"
		if [ "$SELF_TEST_RC" -eq 0 ] && [ "$FAIL_LINES" = "0" ] && [ "$PASS_LINES" -gt 0 ]; then
			pass "$CASE: real swiftc build + real --self-test run: $PASS_LINES PASS lines, 0 FAIL, exit 0"
		else
			fail "$CASE: rc=$SELF_TEST_RC pass=$PASS_LINES fail=$FAIL_LINES"; note "$SELF_TEST_OUT"
		fi
	fi
fi

# 18. gate r1 I2 (hotfixed after Tier 1 run 34916920114): the real helper's `[display]` line
#     grammar, fed through the WRAPPER's OWN extraction pattern (copied verbatim from
#     display-mode.command) rather than a fake that merely reproduces today's shape.
#     `--sample-line` is what makes this DISPLAY-FREE: the Tier 1 runner turned out to HAVE
#     swiftc but no display/CoreGraphics, so the original version of this case (which ran the real
#     `status`) built fine and then produced no `[display] current:` line at all -- CoreGraphics
#     was never reached, and `status` refused with `[display] REFUSED: CoreGraphics is unavailable
#     on this platform` instead. `--sample-line` prints one `[display] current: …` line built from
#     a synthetic ModeInfo through the exact same `description` formatter `status`/`after:` use
#     (test-display-mode-pins.sh pins that it is the shared one, not a private literal), entirely
#     inside the `#if canImport(CoreGraphics)`-FREE half of the file -- so it builds and runs
#     identically whether or not this runner has a display. Relabelling `current:` to `after:` is
#     still how this case gets an after:-shaped line without ever calling `set`. Reuses REAL_BIN
#     from case 17 when it built there; builds its own otherwise (independent of whether case 17
#     happened to skip or fail).
begin '18 the real helper line grammar, through the wrapper''s own parser (gate r1 I2)'
if ! command -v swiftc >/dev/null 2>&1; then
	skip "$CASE: no swiftc on this runner (Tier 1 is compile-free; run locally)"
else
	if [ ! -x "$REAL_BIN" ]; then
		swiftc -O "$LAB/display_mode.swift" -o "$REAL_BIN" >/dev/null 2>&1
	fi
	if [ ! -x "$REAL_BIN" ]; then
		fail "$CASE: no real helper binary available to test against"
	else
		REAL_SAMPLE_OUT="$("$REAL_BIN" --sample-line)"
		REAL_CURRENT_LINE="$(printf '%s\n' "$REAL_SAMPLE_OUT" | grep -E '^\[display\] current: ')"
		# current: and after: share one interpolation shape (pinned); relabel to synthesise what a
		# real after: line looks like, without ever calling `set`.
		SYNTH_AFTER_LINE="${REAL_CURRENT_LINE/\[display\] current: /[display] after: }"
		# The WRAPPER's OWN extraction, copied verbatim from display-mode.command.
		EXTRACTED="$(printf '%s\n' "$SYNTH_AFTER_LINE" | sed -n 's/.* looks=\([0-9][0-9]*\)x\([0-9][0-9]*\) .*/\1 \2/p')"
		if printf '%s\n' "$EXTRACTED" | grep -qE '^[0-9]+ [0-9]+$'; then
			pass "$CASE: the wrapper's sed extracts a real after:-shaped line from the real helper's grammar ($EXTRACTED)"
		else
			fail "$CASE: extraction failed against the REAL helper's --sample-line: $REAL_CURRENT_LINE"
		fi
	fi
fi

# Every case must have reported: a case that neither passed, failed nor skipped would otherwise
# vanish from the tally with exit 0. Placed after the LAST case on purpose. SKIPPED counts toward
# the tally but never toward the exit code: a runner with no swiftc must still exit 0 on an
# otherwise-clean run.
EXPECTED_CASES=18
if [ $((PASSES + FAILURES + SKIPPED)) -ne "$EXPECTED_CASES" ]; then
	fail "case tally: $((PASSES + FAILURES + SKIPPED)) cases reported, expected $EXPECTED_CASES -- a case produced no verdict"
fi
printf '\n%d passed, %d failed, %d skipped\n' "$PASSES" "$FAILURES" "$SKIPPED"
[ "$FAILURES" -eq 0 ]
