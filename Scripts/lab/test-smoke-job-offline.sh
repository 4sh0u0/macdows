#!/usr/bin/env bash
# Offline test suite for Scripts/lab/smoke-job.command, Scripts/lab/checkpoint.sh and the two
# run-scenario.sh modes that drive them. Together those are the checkpoint lane: a job file becomes
# a window-smoke run inside an ETW capture, followed by a server snapshot, with everything gathered
# into one evidence directory. The guards that must not rot are:
#   * the fail-closed live-host boundary gate, FIRST, before the job file is even read;
#   * the job-file key whitelist, which is checked as TEXT before a single line of the file is
#     executed -- this shell holds WIN_PASS, and a subshell inherits it;
#   * the ADVERTISED_SCALE mapping, where "D" means the knob is UNSET in the child's environment
#     and getting that backwards turns a measurement of the product default into a measurement of
#     a fixture knob (or the reverse) with nothing in the evidence to say so;
#   * the two preflight refusals (the checkout must carry the symbol the run is named for; the
#     display must be the geometry the run's arithmetic assumes);
#   * the order DONE-line -> per-TAG copy -> close the window, because closing the window hangs up
#     this process and anything after it may simply not happen;
#   * checkpoint.sh's overlap guard, because two ETW captures disable each other's providers and
#     the damage lands in the OTHER run's evidence.
#
# Safe in CI, by construction rather than by promise:
#   1. `open`, `osascript`, `tty`, `system_profiler`, `pgrep` and `mktemp` are PATH-shimmed, and the suite
#      ASSERTS before the first case that PATH resolves each of them to the shim. The `open` shim
#      records its argv and, only when a case asks for it (LABTEST_OPEN_EXEC=1), runs the target in
#      the background -- which is how the checkpoint cases get a timeline without a Terminal hop.
#   2. `python3` is deliberately NOT shimmed: Scripts/lib.sh's boundary gate evaluates the segments
#      with the REAL python3, and a shim there would replace the thing under test.
#   3. Scripts/run-window-smoke.command is stubbed AT ITS OWN PATH inside the sandbox (the wrapper
#      invokes it as "$REPO_ROOT/Scripts/run-window-smoke.command", so this is the only place it can
#      be substituted -- the same technique test-wdp-etw-offline.sh uses for wdp_etw.py). The stub
#      records the NAMES of its whole environment (so "what did the wrapper let through" is
#      answerable without printing a value), the values of every WINDOW_SMOKE_* variable and its
#      TERM_PROGRAM, writes a DONE line into the evidence log it was given, and exits with
#      LABTEST_CHILD_RC. It builds nothing and opens no socket.
#   4. The ETW capture and the relay are NOT run at all, not even stubbed at their own paths: those
#      two wrappers have their own suites (test-wdp-etw-offline.sh, test-relay-offline.sh), and
#      this one only needs their SIGNALS to appear on a timeline. The `open` shim therefore
#      dispatches on the basename and runs a scripted fake that writes the files checkpoint.sh
#      waits for. The sandbox's wdp-etw.command / relay.command are one-line markers that would
#      exit non-zero if anything ever executed them.
#   5. HOME is redirected into the sandbox. Its host.env carries an RFC 5737 documentation address
#      and placeholder account strings (never a real host, never a real credential), and the
#      placeholder password is greppable because two cases assert it never reaches a log.
#   6. The sandbox checkout sits UNDER the sandbox HOME, exactly as the real one does on the lab
#      Mac, so every path the wrapper logs is a path under $HOME -- which is the value the log
#      mask's <HOME> rule exists for.
#   7. TERM_PROGRAM is cleared for every case but the ordering one, so the Terminal self-close
#      branch is not taken; the osascript shim records into a run-long trace that is never reset,
#      and the "never reached" assertion at the end covers the whole run.
#
# Eight mutation proofs (M1 gate bypassed, M2 key whitelist bypassed, M3 overlap guard removed,
# M4 the window closed before the DONE line is written, M5 the overlap guard reading the process
# table instead of the capture's own pid line, M6 the manifest reading the template's batch instead
# of the run's, M7 the missing-artefact count removed, M8 the batch override appended without a
# separating newline) copy the script under test with one guard removed and require the case that
# claims to pin it to FAIL against the mutant. A pin that would also pass against the broken code
# pins nothing.
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

SB="$(mktemp -d "${TMPDIR:-/tmp}/macdows-smoke-offline.XXXXXX")" || exit 1
# Normalised, because the scripts derive their own paths with `cd … && pwd` and this suite compares
# them as strings: a TMPDIR ending in `/` (macOS's does) would otherwise leave a `//` in $SB.
SB="$(cd "$SB" && pwd)" || exit 1
# shellcheck disable=SC2329,SC2317  # invoked by the EXIT trap below
cleanup() {
	if [ "$KEEP" -eq 1 ]; then
		printf 'sandbox kept: %s\n' "$SB"
	else
		rm -rf "$SB"
	fi
}
trap cleanup EXIT

SBHOME="$SB/home"
SBROOT="$SBHOME/checkout"
SBLAB="$SBROOT/Scripts/lab"
SBRUNTIME="$SBROOT/.build/lab-runtime"
SBEVIDENCE="$SBROOT/.build/evidence"
SBTMP="$SB/tmp"
SMOKELOG="$SBRUNTIME/smoke.log"
JOB="$SBRUNTIME/smoke-job.env"
MAINSWIFT="$SBROOT/Tools/window-smoke/main.swift"

export LABTEST_TRACE="$SB/trace.txt"
export LABTEST_REFUSED_TRACE="$SB/refused-trace.txt"
: > "$LABTEST_REFUSED_TRACE"

mkdir -p "$SBLAB/jobs" "$SBLAB/share" "$SBHOME/.config/macdows" "$SB/bin" "$SBTMP" \
	"$SBROOT/Tools/window-smoke" "$SBROOT/Tools/host-agent" || exit 1
cp "$LAB/smoke-job.command" "$SBLAB/smoke-job.command" || exit 1
cp "$LAB/checkpoint.sh" "$SBLAB/checkpoint.sh" || exit 1
cp "$LAB/run-scenario.sh" "$SBLAB/run-scenario.sh" || exit 1
cp "$LAB"/jobs/*.env "$SBLAB/jobs/" || exit 1
mkdir -p "$SBROOT/Scripts" || exit 1
cp "$REPO_ROOT/Scripts/lib.sh" "$SBROOT/Scripts/lib.sh" || exit 1
# NB $SBRUNTIME is deliberately NOT pre-created: the wrapper's own `mkdir -p` has to make it
# (case 0 pins that explicitly).

# The two wrappers this suite never runs. Markers, not copies: their own suites own them, and a
# copy would couple this suite to whatever state those files happen to be in. Executing one is a
# bug in the `open` shim, and these say so loudly.
for marker in wdp-etw.command relay.command; do
	{
		printf '#!/usr/bin/env bash\n'
		printf '# OFFLINE TEST MARKER: test-smoke-job-offline.sh never runs this wrapper (its own\n'
		printf '# suite does). Reaching this line means the open shim dispatched wrongly.\n'
		printf 'echo "labtest: %s must not be executed" >&2\n' "$marker"
		printf 'exit 91\n'
	} > "$SBLAB/$marker" || exit 1
done
# stage_share (run-scenario.sh's relay mode) needs at least one host-side script and the host-agent
# tree. Synthetic, so the relay-mode pin below does not depend on what share/ happens to contain.
printf '# OFFLINE TEST FIXTURE: not a real host-side script.\n' > "$SBLAB/share/labtest.ps1" || exit 1
printf 'labtest\n' > "$SBROOT/Tools/host-agent/labtest.txt" || exit 1
# The checkout fixture the REQUIRE_SYMBOL preflight greps. Not a copy of the real main.swift: what
# the preflight measures is "does this text occur", and a two-line fixture makes both answers cheap.
printf 'let advertisedScaleKnob = env["WINDOW_SMOKE_ADVERTISED_SCALE"]\n' > "$MAINSWIFT" || exit 1

# RFC 5737 TEST-NET-1 address and placeholder strings: never a real host, never a real credential.
HOSTENV_FILE="$SBHOME/.config/macdows/host.env"
cat > "$HOSTENV_FILE" <<'HOSTENV' || exit 1
WIN_HOST=192.0.2.10
WIN_USER=labtest-placeholder
WIN_PASS=LABTEST-PLACEHOLDER-SECRET-3f9a
HOSTENV
ALLOW_FILE="$SBHOME/.config/macdows/lab-boundary.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="192.0.2.0/24"\n' > "$ALLOW_FILE" || exit 1
DENY_FILE="$SB/deny-boundary.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="198.51.100.0/24"\n' > "$DENY_FILE" || exit 1

# -- The launcher, stubbed at its own path -----------------------------------------------------
cat > "$SBROOT/Scripts/run-window-smoke.command" <<'STUB_LAUNCHER' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST STUB for Scripts/run-window-smoke.command: records what the wrapper handed it,
# writes a DONE line into the evidence log it was given, and exits with LABTEST_CHILD_RC. It
# builds nothing, reads no credential and opens no socket.
set -u
{
	printf 'smoke-child-run\n'
	for key in $(env | sed -n 's/^\(WINDOW_SMOKE_[A-Za-z0-9_]*\)=.*/\1/p' | sort); do
		eval "printf 'smoke-child-env %s=%s\n' \"\$key\" \"\${$key}\""
	done
	# Names only, never values: what this line answers is "which variables did the wrapper let
	# through", and the ones it must NOT let through are the three from host.env. Pipe-delimited
	# so a whole-name match is a fixed-string grep.
	printf 'smoke-child-env-names |%s|\n' "$(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | sort | tr '\n' '|' | sed 's/|$//')"
	printf 'smoke-child-term-program=[%s]\n' "${TERM_PROGRAM-<unset>}"
	printf 'smoke-child-cwd=[%s]\n' "$(pwd)"
} >> "$LABTEST_TRACE"
LOG="${WINDOW_SMOKE_LOG:-}"
# LABTEST_CHILD_NO_WS_LOG=1 is a launcher that RAN and reported, and simply never produced the
# evidence log -- a build that died after its own DONE line, a WINDOW_SMOKE_LOG on a full disk. The
# wrapper still says DONE exit=0, so this is the shape where a missing artefact is otherwise
# completely silent, and it is what the checkpoint's INCOMPLETE verdict exists for.
if [ -n "$LOG" ] && [ "${LABTEST_CHILD_NO_WS_LOG:-0}" != "1" ]; then
	mkdir -p "$(dirname "$LOG")"
	{
		printf '[launcher] labtest stub\n'
		printf 'DONE exit=%s\n' "${LABTEST_CHILD_RC:-0}"
	} > "$LOG"
fi
# The four values the wrapper's mask exists for, printed to stdout and stderr on purpose: the
# wrapper pipes this launcher's output into smoke.log, and case 24 measures what survives.
if [ "${LABTEST_CHILD_LEAK:-0}" = "1" ]; then
	hostenv="$HOME/.config/macdows/host.env"
	printf 'labtest leak: host=%s\n' "$(sed -n 's/^WIN_HOST=//p' "$hostenv")"
	printf 'labtest leak: user=%s\n' "$(sed -n 's/^WIN_USER=//p' "$hostenv")" >&2
	printf 'labtest leak: pass=%s\n' "$(sed -n 's/^WIN_PASS=//p' "$hostenv")"
	printf 'labtest leak: path=%s/checkout/Scripts\n' "$HOME"
fi
exit "${LABTEST_CHILD_RC:-0}"
STUB_LAUNCHER
chmod +x "$SBROOT/Scripts/run-window-smoke.command" || exit 1

# -- The two scripted fakes the open shim runs for the checkpoint cases -------------------------
# They stand in for wrappers that have their own suites; all checkpoint.sh needs from either is
# that the files it polls appear (or do not) on a timeline it can be measured against.
cat > "$SB/bin/labtest-fake-etw" <<'FAKE_ETW' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST FAKE for the Device Portal ETW capture. Reads the TAG out of the runtime job
# instance the REAL run-scenario.sh just copied there -- so the tag this fake uses is the tag the
# tracked template carries, and a broken copy shows up as a checkpoint that waits for the wrong
# file. Opens no socket, writes no capture.
set -u
R="$LABTEST_RUNTIME"
mkdir -p "$R/wdp"
tag="$(sed -n 's/^TAG=//p' "$R/etw-job.env" 2>/dev/null | tail -n 1 | tr -d '\r')"
printf 'fake-etw tag=[%s]\n' "$tag" >> "$LABTEST_TRACE"
sleep "${LABTEST_ETW_OPEN_DELAY:-1}"
if [ "${LABTEST_ETW_OPENS:-1}" = "1" ] && [ -n "$tag" ]; then
	printf '{"labtest":"stand-in capture, no field values"}\n' > "$R/wdp/etw-$tag.jsonl"
fi
sleep "${LABTEST_ETW_DONE_DELAY:-1}"
if [ "${LABTEST_ETW_DONES:-1}" = "1" ]; then
	printf 'DONE exit=%s\n' "${LABTEST_ETW_RC:-0}" >> "$R/etw.log"
	if [ -n "$tag" ]; then cp "$R/etw.log" "$R/wdp/etw-$tag.log"; fi
fi
FAKE_ETW
cat > "$SB/bin/labtest-fake-relay" <<'FAKE_RELAY' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST FAKE for the relay's server-snapshot job. Opens no socket.
set -u
R="$LABTEST_RUNTIME"
mkdir -p "$R/share"
printf 'fake-relay\n' >> "$LABTEST_TRACE"
sleep "${LABTEST_RELAY_DELAY:-1}"
if [ "${LABTEST_RELAY_DONES:-1}" = "1" ]; then
	printf 'RESULT labtest\n' > "$R/share/server-snapshot-out.txt"
	printf 'DONE exit=%s\n' "${LABTEST_RELAY_RC:-0}" >> "$R/relay.log"
fi
FAKE_RELAY

# -- PATH shims ---------------------------------------------------------------------------------
cat > "$SB/bin/open" <<'SHIM_OPEN' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM for open(1): records what run-scenario.sh asked Terminal to launch. The
# Terminal hop is exactly the thing that must not happen in CI, so nothing is executed unless a
# case asks for it with LABTEST_OPEN_EXEC=1 -- and then only the ONE wrapper this suite owns is
# really run; the capture and the relay are scripted fakes (see the header).
set -u
line='open'
target=''
for a in "$@"; do line="$line [$a]"; target="$a"; done
printf '%s\n' "$line" >> "$LABTEST_TRACE"
if [ "${LABTEST_OPEN_EXEC:-0}" != "1" ]; then exit 0; fi
case "$(basename "$target")" in
smoke-job.command)
	# LABTEST_SMOKE_NOOP is how a case measures the WAIT rather than the run: the launch is
	# recorded above and then nothing happens, so no DONE line ever appears.
	if [ "${LABTEST_SMOKE_NOOP:-0}" != "1" ]; then (bash "$target" > /dev/null 2>&1 &); fi
	;;
wdp-etw.command) ("$LABTEST_FAKE_ETW" >/dev/null 2>&1 &) ;;
relay.command) ("$LABTEST_FAKE_RELAY" >/dev/null 2>&1 &) ;;
*)
	printf 'open:unexpected-target [%s]\n' "$target" >> "$LABTEST_REFUSED_TRACE"
	exit 92
	;;
esac
SHIM_OPEN
cat > "$SB/bin/tty" <<'SHIM_TTY' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM for tty(1), and the suite's ORDERING PROBE. The wrapper's self-close block runs
# `tty` SYNCHRONOUSLY and only then backgrounds osascript, so this process is the one place where
# "the close has been requested and nothing after it has happened yet" is a fact rather than a
# race: everything before smoke_close_window has run, everything after it has not.
#
# The osascript shim cannot answer that question. It is spawned with `&`, so by the time it starts
# the wrapper has usually already run the two statements that follow -- measured, and it is exactly
# why the M4 mutation proof went undetected against a snapshot taken there.
#
# What it records is the state the close would have frozen: the last line of smoke.log, and whether
# the per-TAG copy an orchestrator polls exists yet.
set -u
last=''
if [ -n "${LABTEST_SMOKE_LOG:-}" ] && [ -f "$LABTEST_SMOKE_LOG" ]; then
	last="$(tail -n 1 "$LABTEST_SMOKE_LOG")"
fi
tagcopy='no'
if [ -n "${LABTEST_TAG_LOG:-}" ] && [ -f "$LABTEST_TAG_LOG" ]; then tagcopy='yes'; fi
printf 'close-requested last-log-line=[%s] tag-log=%s\n' "$last" "$tagcopy" >> "$LABTEST_TRACE"
printf '/dev/labtest-tty\n'
SHIM_TTY
cat > "$SB/bin/osascript" <<'SHIM_OSA' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM for osascript(1): it closes nothing. Every call is recorded in a run-long trace
# unless the case declared it expected, so "the self-close branch was never taken" stays checkable
# across the whole run. The ordering pin lives in the tty shim above, not here.
set -u
printf 'osascript-close\n' >> "$LABTEST_TRACE"
if [ "${LABTEST_OSASCRIPT_EXPECTED:-0}" != "1" ]; then
	printf 'osascript:unexpected-call\n' >> "$LABTEST_REFUSED_TRACE"
fi
SHIM_OSA
cat > "$SB/bin/system_profiler" <<'SHIM_SP' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM for system_profiler(8): records argv and prints whatever the case wants the
# display to look like. Reads no hardware.
set -u
line='system_profiler'
for a in "$@"; do line="$line [$a]"; done
printf '%s\n' "$line" >> "$LABTEST_TRACE"
printf '%s\n' "${LABTEST_DISPLAY_TEXT:-}"
SHIM_SP
cat > "$SB/bin/pgrep" <<'SHIM_PGREP' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM for pgrep(1): records argv and answers LABTEST_PGREP_RC. Inspects no process
# table -- a real pgrep here would answer about the machine running CI.
set -u
line='pgrep'
for a in "$@"; do line="$line [$a]"; done
printf '%s\n' "$line" >> "$LABTEST_TRACE"
exit "${LABTEST_PGREP_RC:-1}"
SHIM_PGREP
cat > "$SB/bin/mktemp" <<'SHIM_MKTEMP' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM for mktemp(1): records argv and then RUNS THE REAL mktemp. Nothing in this
# lane is supposed to want a temporary file at all -- the credential-file wrapper is the OTHER one
# -- and this is what makes "never asked for one" a statement about CREATION rather than about
# what happened to survive. The real binary is resolved by absolute path, never through PATH: a
# PATH lookup from inside a PATH shim finds the shim again and recurses.
set -u
line='mktemp'
for a in "$@"; do line="$line [$a]"; done
printf '%s\n' "$line" >> "$LABTEST_TRACE"
exec /usr/bin/mktemp "$@"
SHIM_MKTEMP
chmod +x "$SB"/bin/* || exit 1
for shim in "$SB"/bin/*; do
	if ! bash -n "$shim"; then printf 'shim does not parse: %s\n' "$shim"; exit 1; fi
done
for tool in open osascript system_profiler pgrep mktemp tty; do
	resolved="$(PATH="$SB/bin:$PATH" command -v "$tool" || true)"
	if [ "$resolved" != "$SB/bin/$tool" ]; then
		printf 'ABORT: %s resolves to %s, not the shim\n' "$tool" "${resolved:-<nothing>}"
		exit 1
	fi
done
if ! PATH="$SB/bin:$PATH" command -v python3 >/dev/null 2>&1; then
	printf 'ABORT: python3 is not on PATH -- the boundary gate cannot be evaluated\n'
	exit 1
fi
# Positive control for the never-reached trace: hit the refuse path once, confirm it recorded,
# clear -- so an empty trace at the end means "not reached", not "recorder misconfigured".
env -i LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" LABTEST_TRACE="$LABTEST_TRACE" \
	PATH="$SB/bin:$PATH" osascript -e 'x' >/dev/null 2>&1
if ! grep -qF 'osascript:unexpected-call' "$LABTEST_REFUSED_TRACE"; then
	printf 'ABORT: the refused-shim trace did not record a deliberate call\n'
	exit 1
fi
: > "$LABTEST_REFUSED_TRACE"

# -- Test-only job definitions, written BEFORE the census ---------------------------------------
# The shipped jobs/checkpoint-2x-D.env settles for 10 s and its capture runs for 150; this lane's
# own jobs say the same things with numbers a suite can wait for. They live in the sandbox's jobs/
# directory, so run-scenario.sh finds them exactly where it finds the tracked ones.
cat > "$SBLAB/jobs/smoke-labtest.env" <<'JOB_SMOKE' || exit 1
TAG=labtest
BATCH=labtest
DISPLAY_LOOKS_LIKE=
ADVERTISED_SCALE=D
MOVE=0
MAXIMIZE=0
TRAY=0
TRAY_CLICK=0
EXTRA_APPS=
MOVE_TARGET=
APP=
APP_ARGS=
REQUIRE_SYMBOL=
JOB_SMOKE
cat > "$SBLAB/jobs/etw-labtest.env" <<'JOB_ETW' || exit 1
TAG=labtest
DURATION=5
PROVIDERS='1139c61b-b549-4251-8ed3-27250a1edec8:5'
PIN_RECORD=0
JOB_ETW
cat > "$SBLAB/jobs/checkpoint-labtest.env" <<'JOB_CP' || exit 1
ETW_JOB=labtest
SMOKE_JOB=labtest
SNAPSHOT=1
SETTLE_SECONDS=0
BATCH=labtest
JOB_CP
# A smoke job whose own BATCH is NOT the one a checkpoint will pass it. The shipped pair happen to
# agree (both say w3-2x-checkpoint), and while they do, every "which batch does the manifest read"
# question answers itself correctly by accident. These two disagree on purpose.
cat > "$SBLAB/jobs/smoke-otherbatch.env" <<'JOB_OTHER' || exit 1
TAG=labtest
BATCH=template-batch
DISPLAY_LOOKS_LIKE=
ADVERTISED_SCALE=D
MOVE=0
MAXIMIZE=0
TRAY=0
TRAY_CLICK=0
EXTRA_APPS=
MOVE_TARGET=
APP=
APP_ARGS=
REQUIRE_SYMBOL=
JOB_OTHER
cat > "$SBLAB/jobs/checkpoint-otherbatch.env" <<'JOB_CP_OTHER' || exit 1
ETW_JOB=labtest
SMOKE_JOB=otherbatch
SNAPSHOT=1
SETTLE_SECONDS=0
BATCH=labtest
JOB_CP_OTHER
# A template with NO TRAILING NEWLINE, whose last line is a free-text key. `printf` without a final
# \n rather than a heredoc, which would add one. Nothing produces such a file on purpose -- an
# editor configured without "insert final newline" produces it by accident, and the point of the
# case that reads it is that the accident must not change what a run measures.
printf 'TAG=labtest\nBATCH=nonl-batch\nDISPLAY_LOOKS_LIKE=\nADVERTISED_SCALE=D\nMOVE=0\nMAXIMIZE=0\nTRAY=0\nTRAY_CLICK=0\nEXTRA_APPS=\nAPP=\nAPP_ARGS=\nREQUIRE_SYMBOL=\nMOVE_TARGET=abc' \
	> "$SBLAB/jobs/smoke-nonl.env" || exit 1
# `$( )` strips trailing newlines, so a file that ENDS in one gives the empty string here. That is
# the fixture being wrong, and it would make the case that reads it pass for no reason.
if [ "$(tail -c 1 "$SBLAB/jobs/smoke-nonl.env")" = '' ]; then
	printf 'ABORT: the no-trailing-newline fixture ended up with one\n'
	exit 1
fi

# Census of the sandbox's TRACKED tree, taken once after construction. A run must write nothing
# here -- only under .build/. The mutation proofs write their copies into this directory on purpose
# (each script derives REPO_ROOT from its own location), hence the exclusion; `labtest-mutant-*` is
# a namespace no shipping script produces or reads.
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

# -- Helpers ------------------------------------------------------------------------------------

OSASCRIPT_EXPECTED=0
DISPLAY_TEXT='          UI Looks like: 1280 x 720 @ 180.00Hz'

reset_run() {
	: > "$LABTEST_TRACE"
	rm -f "$SMOKELOG" "$JOB" "$SB/witness.txt"
	rm -f "$SBRUNTIME"/smoke-*.log
	rm -rf "$SBEVIDENCE"
}
begin() { # <case label>
	CASE="$1"
	OSASCRIPT_EXPECTED=0
	DISPLAY_TEXT='          UI Looks like: 1280 x 720 @ 180.00Hz'
	reset_run
	rm -f "$SBRUNTIME/etw.log" "$SBRUNTIME/relay.log" "$SBRUNTIME/etw-job.env" "$SBRUNTIME/job.env"
	rm -rf "$SBRUNTIME/wdp" "$SBRUNTIME/share"
}
assert_has() { # <file> <fixed string>
	if grep -qF -- "$2" "$1" 2>/dev/null; then return 0; fi
	fail "$CASE: expected [$2] in $(basename "$1")"
	note "$(cat "$1" 2>/dev/null)"
	return 1
}
assert_lacks() { # <file> <fixed string>
	if ! grep -qF -- "$2" "$1" 2>/dev/null; then return 0; fi
	fail "$CASE: [$2] must not appear in $(basename "$1")"
	note "$(cat "$1" 2>/dev/null)"
	return 1
}
assert_eq() { # <actual> <expected> <what>
	if [ "$1" = "$2" ]; then return 0; fi
	fail "$CASE: $3 -- expected [$2], got [$1]"
	return 1
}
last_line() { tail -n 1 "$SMOKELOG" 2>/dev/null; }
child_calls() { grep -c '^smoke-child-run$' "$LABTEST_TRACE" 2>/dev/null || true; }
# -xF, never a regex: the values under test are Windows paths, so half of them carry backslashes
# and a plain `grep -c "^...$1$"` reads those as escapes (measured: WINDOW_SMOKE_APP's
# C:\Windows\System32 matched nothing at all).
child_env() { grep -cxF "smoke-child-env $1" "$LABTEST_TRACE" 2>/dev/null || true; }
child_has_var() { grep -qF "|$1|" "$LABTEST_TRACE" 2>/dev/null; }
sysprofiler_calls() { grep -c '^system_profiler ' "$LABTEST_TRACE" 2>/dev/null || true; }
open_calls() { grep -c '^open ' "$LABTEST_TRACE" 2>/dev/null || true; }
pgrep_calls() { grep -c '^pgrep ' "$LABTEST_TRACE" 2>/dev/null || true; }
mktemp_calls() { grep -c '^mktemp ' "$LABTEST_TRACE" 2>/dev/null || true; }

# The valid baseline job: every key present, every scenario off, no preflight armed. Cases append
# one line to override exactly the key they are about (a later assignment wins when the file is
# read, which is also how run-scenario.sh's batch override works).
job_base() {
	cat > "$JOB" <<'JOB_BASE'
# a comment, so "comments are accepted" is pinned by every case rather than by one

TAG=labtest
BATCH=labtest
DISPLAY_LOOKS_LIKE=
ADVERTISED_SCALE=D
MOVE=0
MAXIMIZE=0
TRAY=0
TRAY_CLICK=0
EXTRA_APPS=
MOVE_TARGET=
APP=
APP_ARGS=
REQUIRE_SYMBOL=
JOB_BASE
}
job_override() { # <line>...
	local l
	for l in "$@"; do printf '%s\n' "$l" >> "$JOB"; done
}

# Runs the wrapper (or a mutant copy) with the sandbox environment. <boundary-file> empty = the
# variable is passed EMPTY, which lib.sh's `${MACDOWS_LAB_BOUNDARY_FILE:-…}` treats exactly like
# unset: the wrapper resolves the DEFAULT path under the sandbox HOME, as it does live.
run_smoke() { # <wrapper-path> <boundary-file|""> [child-rc] [child-leak 0|1] [term-program]
	env -i \
		HOME="$SBHOME" \
		PATH="$SB/bin:$PATH" \
		TMPDIR="$SBTMP" \
		TERM_PROGRAM="${5:-}" \
		LABTEST_TRACE="$LABTEST_TRACE" \
		LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" \
		LABTEST_SMOKE_LOG="$SMOKELOG" \
		LABTEST_TAG_LOG="$SBRUNTIME/smoke-labtest.log" \
		LABTEST_OSASCRIPT_EXPECTED="$OSASCRIPT_EXPECTED" \
		LABTEST_DISPLAY_TEXT="$DISPLAY_TEXT" \
		LABTEST_CHILD_RC="${3:-0}" \
		LABTEST_CHILD_LEAK="${4:-0}" \
		MACDOWS_LAB_BOUNDARY_FILE="$2" \
		bash "$1" >/dev/null 2>&1
}

# Runs run-scenario.sh or checkpoint.sh with the same sandbox environment. Output goes to $2.
run_lab() { # <output file> <script> <args...>
	local out="$1" script="$2"
	shift 2
	env -i \
		HOME="$SBHOME" \
		PATH="$SB/bin:$PATH" \
		TMPDIR="$SBTMP" \
		TERM_PROGRAM= \
		LABTEST_TRACE="$LABTEST_TRACE" \
		LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" \
		LABTEST_SMOKE_LOG="$SMOKELOG" \
		LABTEST_TAG_LOG="$SBRUNTIME/smoke-labtest.log" \
		LABTEST_OSASCRIPT_EXPECTED="$OSASCRIPT_EXPECTED" \
		LABTEST_DISPLAY_TEXT="$DISPLAY_TEXT" \
		LABTEST_RUNTIME="$SBRUNTIME" \
		LABTEST_FAKE_ETW="$SB/bin/labtest-fake-etw" \
		LABTEST_FAKE_RELAY="$SB/bin/labtest-fake-relay" \
		LABTEST_OPEN_EXEC="${LABTEST_OPEN_EXEC:-0}" \
		LABTEST_SMOKE_NOOP="${LABTEST_SMOKE_NOOP:-0}" \
		LABTEST_CHILD_RC=0 \
		LABTEST_CHILD_LEAK=0 \
		LABTEST_CHILD_NO_WS_LOG="${LABTEST_CHILD_NO_WS_LOG:-0}" \
		LABTEST_PGREP_RC="${LABTEST_PGREP_RC:-1}" \
		LABTEST_ETW_OPENS="${LABTEST_ETW_OPENS:-1}" \
		LABTEST_ETW_DONES="${LABTEST_ETW_DONES:-1}" \
		LABTEST_ETW_RC="${LABTEST_ETW_RC:-0}" \
		LABTEST_ETW_OPEN_DELAY="${LABTEST_ETW_OPEN_DELAY:-1}" \
		LABTEST_ETW_DONE_DELAY="${LABTEST_ETW_DONE_DELAY:-1}" \
		LABTEST_RELAY_DONES="${LABTEST_RELAY_DONES:-1}" \
		LABTEST_RELAY_RC="${LABTEST_RELAY_RC:-0}" \
		LABTEST_RELAY_DELAY="${LABTEST_RELAY_DELAY:-1}" \
		CHECKPOINT_TIMEOUT_ETW_OPEN="${CHECKPOINT_TIMEOUT_ETW_OPEN:-20}" \
		CHECKPOINT_TIMEOUT_SMOKE="${CHECKPOINT_TIMEOUT_SMOKE:-40}" \
		CHECKPOINT_TIMEOUT_ETW_DONE="${CHECKPOINT_TIMEOUT_ETW_DONE:-30}" \
		CHECKPOINT_TIMEOUT_RELAY="${CHECKPOINT_TIMEOUT_RELAY:-20}" \
		MACDOWS_LAB_BOUNDARY_FILE= \
		bash "$script" "$@" > "$out" 2>&1
}

# The wrapper backgrounds its osascript, so the shim's trace line can land after the wrapper has
# already exited. Bounded, because a missing line is a failure and not a reason to hang.
wait_for_trace() { # <fixed string> <timeout seconds>
	local i=0
	until grep -qF "$1" "$LABTEST_TRACE" 2>/dev/null; do
		sleep 1
		i=$((i + 1))
		if [ "$i" -ge "$2" ]; then return 1; fi
	done
	return 0
}

# Feeds one bad value per key through the wrapper and returns a description of every one that was
# NOT refused. One verdict per key: the values are variations on a single rule, and a case per
# value would bury the rule in the tally.
reject_values() { # <key> <value>...
	local key="$1" v bad=''
	shift
	for v in "$@"; do
		reset_run
		job_base
		# Single-quoted on purpose: the LINE GRAMMAR would refuse an unquoted value carrying a
		# space or a separator, and then these cases would be measuring the grammar instead of the
		# per-key shape checks they are named for. Case 4 owns the grammar.
		job_override "$key='$v'"
		run_smoke "$SBLAB/smoke-job.command" ""
		if [ "$(last_line)" != 'DONE exit=65' ] || [ "$(child_calls)" != '0' ]; then
			bad="$bad [$v -> $(last_line), child=$(child_calls)]"
		fi
	done
	printf '%s' "$bad"
}

# ------------------------------------------------------------------------------------------
# Cases
# ------------------------------------------------------------------------------------------

printf 'test-smoke-job-offline.sh -- driving %s, %s and %s\n' \
	"$LAB/smoke-job.command" "$LAB/checkpoint.sh" "$LAB/run-scenario.sh"

# 0. The runtime directory is the wrapper's own to create: it must not exist before the first run
#    and must exist after it (the sandbox never pre-creates it).
begin '0 wrapper creates its runtime dir'
if [ ! -d "$SBRUNTIME" ]; then
	run_smoke "$SBLAB/smoke-job.command" "$DENY_FILE"
	if [ -d "$SBRUNTIME" ] && [ -f "$SMOKELOG" ]; then
		pass "$CASE: .build/lab-runtime did not exist before the first run and the wrapper created it with its log in place"
	else
		fail "$CASE: runtime dir or log missing after the run"
	fi
else
	fail "$CASE: the sandbox pre-created $SBRUNTIME -- this pin measures nothing"
fi

# 1. Refused by the boundary: the log names the refusal, DONE carries 78, and NOTHING past the gate
#    ran -- the launcher was never started, the display was never queried, no evidence directory was
#    created. The gate is first precisely so that a mistyped host cannot cause any of this
#    wrapper's side effects to exist. (M1 pins this.)
begin '1 boundary refused'
job_base
run_smoke "$SBLAB/smoke-job.command" "$DENY_FILE"
if assert_has "$SMOKELOG" 'BOUNDARY-REFUSED' && assert_eq "$(last_line)" 'DONE exit=78' 'last log line' \
	&& assert_eq "$(child_calls)" '0' 'launcher invocations' \
	&& assert_eq "$(sysprofiler_calls)" '0' 'system_profiler invocations' \
	&& assert_eq "$(mktemp_calls)" '0' 'mktemp calls' \
	&& [ ! -d "$SBEVIDENCE" ] && assert_lacks "$SMOKELOG" 'LABTEST-PLACEHOLDER-SECRET-3f9a'; then
	pass "$CASE: BOUNDARY-REFUSED logged, DONE exit=78, no launcher, no display query, no evidence directory, no credential in the log"
fi

# 2. Boundary file missing at the DEFAULT location: fail-closed, same shape as 1. Exercises the
#    wrapper's default-path resolution, not an injected path.
begin '2 boundary file missing (default path)'
mv "$ALLOW_FILE" "$ALLOW_FILE.away" || exit 1
job_base
run_smoke "$SBLAB/smoke-job.command" ""
mv "$ALLOW_FILE.away" "$ALLOW_FILE" || exit 1
if assert_has "$SMOKELOG" 'BOUNDARY-REFUSED' && assert_eq "$(last_line)" 'DONE exit=78' 'last log line' \
	&& assert_eq "$(child_calls)" '0' 'launcher invocations'; then
	pass "$CASE: fail-closed refusal through the default boundary path, no launcher"
fi

# 3. smoke-job.env missing: the wrapper must still report -- a DONE line with a distinct sysexits
#    code (66 EX_NOINPUT) and a named reason -- rather than die on `set -u` and leave the caller to
#    its own timeout.
begin '3 smoke-job.env missing'
run_smoke "$SBLAB/smoke-job.command" ""
if assert_has "$SMOKELOG" 'JOB-ENV-MISSING' && assert_eq "$(last_line)" 'DONE exit=66' 'last log line' \
	&& assert_eq "$(child_calls)" '0' 'launcher invocations'; then
	pass "$CASE: JOB-ENV-MISSING logged, DONE exit=66, no launcher"
fi

# 4. THE KEY WHITELIST. A job file carrying a key outside the whitelist is refused, and -- the part
#    that matters -- the file is judged as TEXT, so a line that is not an assignment at all never
#    RUNS. This shell holds WIN_PASS (host.env is sourced for the log mask) and a subshell inherits
#    it, so `printf %s "$WIN_PASS" > witness` would exfiltrate the credential without needing a key
#    of its own. The witness file is the measurement. (M2 pins this.)
begin '4 the line grammar: unknown keys and disguised commands are refused before execution'
reasons=''
job_base
# shellcheck disable=SC2016  # the literal $WIN_PASS is the point: the job must never be executed
job_override 'printf "%s" "$WIN_PASS" > "'"$SB"'/witness.txt"' 'WIN_PASS=labtest-override'
run_smoke "$SBLAB/smoke-job.command" ""
grep -qF 'JOB-ENV-INVALID' "$SMOKELOG" || reasons="$reasons unknown-key-not-refused;"
[ "$(last_line)" = 'DONE exit=65' ] || reasons="$reasons unknown-key-last-line=[$(last_line)];"
[ "$(child_calls)" = '0' ] || reasons="$reasons unknown-key-launcher-ran;"
[ -f "$SB/witness.txt" ] && reasons="$reasons THE-JOB-FILE-WAS-EXECUTED;"
grep -qF 'labtest-override' "$SMOKELOG" && reasons="$reasons value-echoed-into-the-log;"
# The same refusal, but hidden inside a line that LOOKS like an assignment to a whitelisted key.
# `KEY=value command args` is one word of assignment followed by a command, which is why the
# grammar has to judge the VALUE and not only the key. (An unquoted `1280 x 720` is what found
# this: /opt/X11/bin/x exists on the lab Mac and reads stdin, so the draft that only checked key
# names hung with no DONE line at all.)
reset_run
job_base
job_override "DISPLAY_LOOKS_LIKE=1280 touch $SB/witness.txt"
run_smoke "$SBLAB/smoke-job.command" ""
grep -qF 'JOB-ENV-INVALID' "$SMOKELOG" || reasons="$reasons disguised-command-not-refused;"
[ "$(last_line)" = 'DONE exit=65' ] || reasons="$reasons disguised-command-last-line=[$(last_line)];"
[ -f "$SB/witness.txt" ] && reasons="$reasons DISGUISED-COMMAND-RAN;"
# And a value that must be quoted to survive being read at all: an unquoted backslash path would
# reach the child as C:WindowsSystem32notepad.exe, which is not a refusal but something worse -- a
# run that starts the wrong program and reports success.
reset_run
job_base
job_override 'APP=C:\Windows\System32\notepad.exe'
run_smoke "$SBLAB/smoke-job.command" ""
grep -qF 'JOB-ENV-INVALID' "$SMOKELOG" || reasons="$reasons unquoted-backslash-not-refused;"
[ "$(child_calls)" = '0' ] || reasons="$reasons unquoted-backslash-launcher-ran;"
# And the shape a maintainer reaches for by reflex, in a file that is 36 lines of comment out of
# 49: a comment appended to an assignment. The grammar admits a comment only on a line of its OWN,
# which is defensible -- but the refusal has to SAY so, or the reader follows the advice about
# quoting, quotes the comment, and is refused again. The text is the pin.
reset_run
job_base
job_override 'MOVE=1 # turn the move leg on'
run_smoke "$SBLAB/smoke-job.command" ""
[ "$(last_line)" = 'DONE exit=65' ] || reasons="$reasons trailing-comment-last-line=[$(last_line)];"
[ "$(child_calls)" = '0' ] || reasons="$reasons trailing-comment-launcher-ran;"
grep -qF 'a comment must be on a line of its own' "$SMOKELOG" \
	|| reasons="$reasons trailing-comment-reason-does-not-name-the-rule;"
if [ -z "$reasons" ]; then
	pass "$CASE: an unknown key, a bare command line, a command disguised as an assignment's value, an unquotable backslash path and a comment appended to an assignment are each refused with DONE exit=65 -- and nothing in the job file ever ran"
else
	fail "$CASE:$reasons"
fi

# 5. The three keys a job file must never be able to set, because each of them would change what
#    the gate approved or where the run's own tools come from.
begin '5 PATH, HOME and WIN_HOST are outside the whitelist'
bad=''
for key in PATH HOME WIN_HOST; do
	reset_run
	job_base
	job_override "$key=/labtest"
	run_smoke "$SBLAB/smoke-job.command" ""
	if [ "$(last_line)" != 'DONE exit=65' ] || [ "$(child_calls)" != '0' ]; then
		bad="$bad [$key -> $(last_line), child=$(child_calls)]"
	fi
done
if [ -z "$bad" ]; then
	pass "$CASE: PATH, HOME and WIN_HOST are each refused with DONE exit=65 and no launcher"
else
	fail "$CASE: accepted:$bad"
fi

# 6-14. Every whitelisted key's SHAPE. One verdict per key; the offending values are named in it.
begin '6 TAG shape'
bad="$(reject_values TAG '' 'has space' 'a/b' 'toolongtoolongtoolongtoolongtoolong' 'a;b')"
if [ -z "$bad" ]; then
	pass "$CASE: empty, spaced, path-separated, over-32-character and punctuated TAGs are each refused (TAG names two log files)"
else
	fail "$CASE: accepted:$bad"
fi

begin '7 BATCH shape'
bad="$(reject_values BATCH '' 'a/b' '..' '.' 'has space')"
if [ -z "$bad" ]; then
	pass "$CASE: empty, path-separated and spaced BATCH values are refused (BATCH names .build/evidence/<BATCH>/); '..' is refused as a directory name"
else
	fail "$CASE: accepted:$bad"
fi

begin '8 DISPLAY_LOOKS_LIKE shape'
bad="$(reject_values DISPLAY_LOOKS_LIKE '1280' '1280X720' '1280 x 720' '0x720' '1280x')"
if [ -z "$bad" ]; then
	pass "$CASE: a bare number, an upper-case X, a spaced form, a zero extent and a missing extent are each refused"
else
	fail "$CASE: accepted:$bad"
fi

begin '9 ADVERTISED_SCALE domain'
bad="$(reject_values ADVERTISED_SCALE 'd' 'dd' 'None' '600' '99' '200,150' '200,' '2x' ' DD' '200,180,100')"
if [ -z "$bad" ]; then
	pass "$CASE: lower-case forms, an out-of-domain desktop either way, an out-of-domain device, a trailing comma, a stray unit, a leading space and a third field are each refused (MacdowsCore ScaleAdvertisement's domains, checked before a window opens)"
else
	fail "$CASE: accepted:$bad"
fi

begin '10 the four scenario switches are 0 or 1'
bad=''
for key in MOVE MAXIMIZE TRAY TRAY_CLICK; do
	part="$(reject_values "$key" '2' 'yes' '01' 'true')"
	if [ -n "$part" ]; then bad="$bad $key:$part"; fi
done
if [ -z "$bad" ]; then
	pass "$CASE: MOVE, MAXIMIZE, TRAY and TRAY_CLICK each refuse 2, yes, 01 and true (an EMPTY value is not an error: like an absent key it means the switch is off)"
else
	fail "$CASE: accepted:$bad"
fi

begin '11 EXTRA_APPS charset'
# shellcheck disable=SC2016  # the literals are the values under test
bad="$(reject_values EXTRA_APPS 'notepad calc' 'notepad|calc' 'note$pad' 'note.pad')"
if [ -z "$bad" ]; then
	pass "$CASE: a space, a pipe, a dollar and a dot are each refused (the child splits EXTRA_APPS on ';')"
else
	fail "$CASE: accepted:$bad"
fi

begin '12 MOVE_TARGET refuses the two shell-active characters and an unbounded length'
# The over-long value is 256 characters, one past the same 255 ceiling APP and APP_ARGS are held to
# (smoke_ascii_arg_ok). Not a threat -- this is nowhere near E2BIG -- but MOVE_TARGET was the one
# forwarded value with no stated ceiling at all, so "how long may a job file's value be" had two
# answers. Built with brace expansion rather than `seq`, so the case says 256 instead of spelling
# it out and still needs nothing on PATH.
# shellcheck disable=SC2016  # the literals are the values under test
bad="$(reject_values MOVE_TARGET 'Notepad$(id)' 'Notepad`id`' '$HOME' "$(printf 'a%.0s' {1..256})")"
if [ -z "$bad" ]; then
	pass "$CASE: a command substitution, a backtick, a bare variable reference and a 256-character title are refused; everything else within 255, CJK included, is free text (case 21 pins that)"
else
	fail "$CASE: accepted:$bad"
fi

begin '13 APP and APP_ARGS charset'
bad=''
for key in APP APP_ARGS; do
	# shellcheck disable=SC2016  # the literals are the values under test
	part="$(reject_values "$key" 'C:\x$(id).exe' 'C:\x`id`.exe' 'C:\x.exe;calc' 'C:\x.exe|calc' 'C:\记事本.exe')"
	if [ -n "$part" ]; then bad="$bad $key:$part"; fi
done
if [ -z "$bad" ]; then
	pass "$CASE: APP and APP_ARGS each refuse a command substitution, a backtick, a separator, a pipe and non-ASCII -- Windows path/argument characters only"
else
	fail "$CASE: accepted:$bad"
fi

begin '14 REQUIRE_SYMBOL shape'
bad="$(reject_values REQUIRE_SYMBOL 'has space' 'sym;bol' 'sym-bol')"
if [ -z "$bad" ]; then
	pass "$CASE: REQUIRE_SYMBOL must be a bare symbol name -- a space, a separator and a hyphen are refused"
else
	fail "$CASE: accepted:$bad"
fi

# 15. A value that spans lines shifts every following key, so the run would proceed with keys that
#     are silently wrong. TWO guards catch it and the case measures both, because they catch
#     different files: the line grammar refuses a naive continuation (its second line is not an
#     assignment), while a continuation whose second line HAPPENS to look like one gets past the
#     grammar and is caught by the sentinel instead.
begin '15 a value that spans lines'
reasons=''
job_base
printf 'MOVE_TARGET="first\nsecond"\n' >> "$JOB"
run_smoke "$SBLAB/smoke-job.command" ""
grep -qF 'is neither blank, a comment, nor an assignment' "$SMOKELOG" || reasons="$reasons grammar-did-not-catch-the-plain-continuation;"
[ "$(last_line)" = 'DONE exit=65' ] || reasons="$reasons grammar-case-last-line=[$(last_line)];"
[ "$(child_calls)" = '0' ] || reasons="$reasons grammar-case-launcher-ran;"
reset_run
job_base
# The one shape the line grammar cannot see: a trailing `\"` inside a double-quoted value escapes
# the closing quote, so the value runs on to the next line -- and that next line is a COMMENT,
# which the grammar admits. Both lines pass; MOVE_TARGET still ends up carrying a newline.
printf 'MOVE_TARGET="a\\"\n# still inside the string"\n' >> "$JOB"
run_smoke "$SBLAB/smoke-job.command" ""
grep -qF 'spans more than one line' "$SMOKELOG" || reasons="$reasons sentinel-did-not-catch-it[$(last_line)];"
[ "$(last_line)" = 'DONE exit=65' ] || reasons="$reasons sentinel-case-last-line=[$(last_line)];"
[ "$(child_calls)" = '0' ] || reasons="$reasons sentinel-case-launcher-ran;"
if [ -z "$reasons" ]; then
	pass "$CASE: a plain continuation is refused by the line grammar and a grammar-shaped one by the sentinel; DONE exit=65 and no launcher either way"
else
	fail "$CASE:$reasons"
fi

# 16. PREFLIGHT 1. A checkout that does not carry the symbol the run is named for builds cleanly and
#     produces a log that looks exactly like a run of the default -- because it is one. The refusal
#     happens before the display is even queried.
#     75 (EX_TEMPFAIL), the same code as the display refusal below, because both say the same kind
#     of thing: THIS MACHINE, RIGHT NOW, is not the environment the job describes. Neither is fixed
#     by editing the job file -- one wants a checkout that carries the knob, the other wants the
#     display plugged in -- and the very same job file runs afterwards. What 75 is not is 65: a job
#     file whose shape is wrong is wrong everywhere, forever, and no amount of re-running helps.
begin '16 REQUIRE_SYMBOL absent from the checkout'
mv "$MAINSWIFT" "$MAINSWIFT.away" || exit 1
printf 'let somethingElse = 1\n' > "$MAINSWIFT" || exit 1
job_base
job_override 'REQUIRE_SYMBOL=WINDOW_SMOKE_ADVERTISED_SCALE' 'DISPLAY_LOOKS_LIKE=1280x720'
run_smoke "$SBLAB/smoke-job.command" ""
mv "$MAINSWIFT.away" "$MAINSWIFT" || exit 1
if assert_has "$SMOKELOG" 'REFUSED: the checkout does not carry WINDOW_SMOKE_ADVERTISED_SCALE' \
	&& assert_eq "$(last_line)" 'DONE exit=75' 'last log line' \
	&& assert_eq "$(child_calls)" '0' 'launcher invocations' \
	&& assert_eq "$(sysprofiler_calls)" '0' 'system_profiler invocations (the symbol gate is first)'; then
	pass "$CASE: REFUSED with DONE exit=75 (EX_TEMPFAIL -- this checkout is not the one the job describes; check one out that is, and the same job file runs) before the display was even queried, and no launcher"
fi

# 17. PREFLIGHT 2. The display the run's remote-pixel arithmetic assumes. `system_profiler` is asked
#     exactly once, and a mismatch refuses rather than runs. 75, the same code case 16 gets, and
#     that is the point: the two preflights guard two halves of ONE premise -- that this machine and
#     this checkout are the environment the job describes -- and both are answered the same way, by
#     changing the environment rather than the job. Plug the display in, or check out the branch
#     that carries the knob, and the identical job file runs. The code that would be WRONG here is
#     65: nothing about the job file's shape is at fault, and a reader who saw JOB-ENV-INVALID's
#     code would go and edit a file that is correct.
begin '17 the display is not the required looks-like geometry'
DISPLAY_TEXT='          UI Looks like: 1920 x 1080 @ 60.00Hz'
job_base
job_override 'DISPLAY_LOOKS_LIKE=1280x720'
run_smoke "$SBLAB/smoke-job.command" ""
if assert_has "$SMOKELOG" 'REFUSED: display is not looks-like 1280x720' \
	&& assert_eq "$(last_line)" 'DONE exit=75' 'last log line' \
	&& assert_eq "$(child_calls)" '0' 'launcher invocations' \
	&& assert_eq "$(sysprofiler_calls)" '1' 'system_profiler invocations'; then
	pass "$CASE: REFUSED with DONE exit=75 (EX_TEMPFAIL -- the machine is not set up for this run right now), system_profiler asked exactly once, no launcher"
fi

# 18. The check is opt-in: an empty DISPLAY_LOOKS_LIKE must not merely pass, it must not ASK. A
#     wrapper that queried and then ignored the answer would be one edit away from a check that
#     silently always passes.
begin '18 an empty DISPLAY_LOOKS_LIKE asks nothing'
job_base
run_smoke "$SBLAB/smoke-job.command" ""
if assert_eq "$(sysprofiler_calls)" '0' 'system_profiler invocations' \
	&& assert_eq "$(child_calls)" '1' 'launcher invocations' \
	&& assert_eq "$(last_line)" 'DONE exit=0' 'last log line'; then
	pass "$CASE: no DISPLAY_LOOKS_LIKE means system_profiler is never run and the launcher starts"
fi

# 19. THE D MAPPING. `D` is the product default, and the product default is what the child does with
#     the knob UNSET (main.swift: "unset/empty = unset (product default)"). Expressing it as
#     WINDOW_SMOKE_ADVERTISED_SCALE=D would be a fixture-knob run wearing the default's label -- the
#     evidence suffix even says which source it came from. So the pin is on ABSENCE.
begin '19 ADVERTISED_SCALE=D leaves the knob unset in the child environment'
job_base
job_override 'ADVERTISED_SCALE=D'
run_smoke "$SBLAB/smoke-job.command" ""
reasons=''
[ "$(child_calls)" = '1' ] || reasons="$reasons launcher-calls=$(child_calls);"
child_has_var 'WINDOW_SMOKE_ADVERTISED_SCALE' && reasons="$reasons the-knob-reached-the-child;"
[ "$(child_env 'WINDOW_SMOKE_ADVERTISED_SCALE=D')" = '0' ] || reasons="$reasons a-literal-D-was-exported;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: D is expressed by ABSENCE -- WINDOW_SMOKE_ADVERTISED_SCALE is not in the child's environment at all"
else
	fail "$CASE:$reasons"
fi

# 20. The other three forms are passed through verbatim and re-validated by the child.
begin '20 none, DD and an explicit pair reach the child verbatim'
bad=''
for value in none DD 200,180 200 500,140; do
	reset_run
	job_base
	job_override "ADVERTISED_SCALE=$value"
	run_smoke "$SBLAB/smoke-job.command" ""
	if [ "$(child_env "WINDOW_SMOKE_ADVERTISED_SCALE=$value")" != '1' ] || [ "$(last_line)" != 'DONE exit=0' ]; then
		bad="$bad [$value -> $(last_line)]"
	fi
done
if [ -z "$bad" ]; then
	pass "$CASE: none, DD, 200,180, 200 and 500,140 each reach the child as WINDOW_SMOKE_ADVERTISED_SCALE verbatim"
else
	fail "$CASE: wrong:$bad"
fi

# 21. THE HAPPY PATH, pinned element by element: this environment IS the wrapper's contract with the
#     launcher. Note what is NOT there -- the three host.env values, and TERM_PROGRAM, whose absence
#     is what disarms the launcher's own self-close so that this wrapper owns the window.
begin '21 the happy path environment'
job_base
job_override 'MOVE=1' 'MAXIMIZE=1' 'TRAY=1' 'TRAY_CLICK=1' "EXTRA_APPS='notepad;calc'" \
	"MOVE_TARGET='Notepad|记事本'" "APP='C:\Windows\System32\notepad.exe'" "APP_ARGS='C:\rdp-lab\seed.txt'" \
	'DISPLAY_LOOKS_LIKE=1280x720' 'REQUIRE_SYMBOL=WINDOW_SMOKE_ADVERTISED_SCALE'
run_smoke "$SBLAB/smoke-job.command" ""
reasons=''
[ "$(child_calls)" = '1' ] || reasons="$reasons launcher-calls=$(child_calls);"
[ "$(child_env "WINDOW_SMOKE_LOG=$SBEVIDENCE/labtest/window-smoke-labtest.log")" = '1' ] || reasons="$reasons WINDOW_SMOKE_LOG;"
for expected in 'WINDOW_SMOKE_MOVE=1' 'WINDOW_SMOKE_MAXIMIZE=1' 'WINDOW_SMOKE_TRAY=1' \
	'WINDOW_SMOKE_TRAY_CLICK=1' 'WINDOW_SMOKE_EXTRA_APPS=notepad;calc' 'WINDOW_SMOKE_MOVE_TARGET=Notepad|记事本' \
	'WINDOW_SMOKE_APP=C:\Windows\System32\notepad.exe' 'WINDOW_SMOKE_APP_ARGS=C:\rdp-lab\seed.txt'; do
	[ "$(child_env "$expected")" = '1' ] || reasons="$reasons missing[$expected];"
done
for forbidden in WIN_HOST WIN_USER WIN_PASS; do
	if child_has_var "$forbidden"; then reasons="$reasons $forbidden-reached-the-child;"; fi
done
grep -qF 'smoke-child-term-program=[]' "$LABTEST_TRACE" || reasons="$reasons TERM_PROGRAM=[$(sed -n 's/^smoke-child-term-program=//p' "$LABTEST_TRACE")];"
[ -f "$SBEVIDENCE/labtest/window-smoke-labtest.log" ] || reasons="$reasons evidence-log-missing;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
cmp -s "$SMOKELOG" "$SBRUNTIME/smoke-labtest.log" || reasons="$reasons per-TAG-copy-differs;"
if [ -z "$reasons" ]; then
	pass "$CASE: every knob reaches the launcher, the evidence log is under .build/evidence/<BATCH>/, TERM_PROGRAM is cleared, no host.env value crosses, and smoke-labtest.log is a byte copy of smoke.log"
else
	fail "$CASE:$reasons"
	note "trace: $(tr '\n' ';' < "$LABTEST_TRACE")"
fi

# 22. A switch set to 0 is expressed by ABSENCE. main.swift tests each switch for the string "1", so
#     `=0` and absent are the same to the child -- and absence is the one a reader of the child's
#     environment cannot misread.
begin '22 switches at 0 do not reach the child at all'
job_base
run_smoke "$SBLAB/smoke-job.command" ""
reasons=''
for forbidden in WINDOW_SMOKE_MOVE WINDOW_SMOKE_MAXIMIZE WINDOW_SMOKE_TRAY WINDOW_SMOKE_TRAY_CLICK \
	WINDOW_SMOKE_EXTRA_APPS WINDOW_SMOKE_MOVE_TARGET WINDOW_SMOKE_APP WINDOW_SMOKE_APP_ARGS; do
	if child_has_var "$forbidden"; then reasons="$reasons $forbidden;"; fi
done
if [ -z "$reasons" ] && [ "$(child_calls)" = '1' ]; then
	pass "$CASE: with every switch at 0 and every string empty, the child's environment carries WINDOW_SMOKE_LOG and nothing else this wrapper owns"
else
	fail "$CASE: present in the child:$reasons (launcher calls=$(child_calls))"
fi

# 23. The launcher's exit code IS the run's verdict, and a failing run still gets its per-TAG copy:
#     an orchestrator polls that file, and a failure it never hears about is a timeout instead of a
#     diagnosis.
#     3 is checked as well as 4, and it is the point of the code change this lane made: the
#     wrapper's own preflights used to refuse with 3, which is also run-window-smoke.command's
#     declared-desktop knob refusal. They now refuse with 78 and 75, so a DONE exit=3 can only have
#     come from the launcher -- and this is the case that says so.
begin '23 the launcher rc becomes the DONE code, and the copy is still made'
reasons=''
job_base
run_smoke "$SBLAB/smoke-job.command" "" 4
[ "$(last_line)" = 'DONE exit=4' ] || reasons="$reasons rc4-last-line=[$(last_line)];"
[ -f "$SBRUNTIME/smoke-labtest.log" ] || reasons="$reasons rc4-no-per-tag-copy;"
[ "$(tail -n 1 "$SBRUNTIME/smoke-labtest.log" 2>/dev/null)" = 'DONE exit=4' ] || reasons="$reasons rc4-copy-last-line;"
begin "$CASE"
job_base
run_smoke "$SBLAB/smoke-job.command" "" 3
[ "$(last_line)" = 'DONE exit=3' ] || reasons="$reasons rc3-last-line=[$(last_line)];"
[ "$(child_calls)" = '1' ] || reasons="$reasons rc3-launcher-calls=$(child_calls);"
grep -qF 'REFUSED' "$SMOKELOG" && reasons="$reasons rc3-looks-like-a-wrapper-refusal;"
if [ -z "$reasons" ]; then
	pass "$CASE: a launcher exit of 4 reaches DONE exit=4 and smoke-labtest.log carries the same verdict; a launcher exit of 3 arrives unchanged and is not a refusal of this wrapper's own"
else
	fail "$CASE:$reasons"
fi

# 24. smoke.log is what a human pastes into a report, so the address, the account, the password and
#     the home path must not survive in it -- even though the launcher printed all four, on stdout
#     AND on stderr. The EVIDENCE log is deliberately not masked (it never leaves .build/), which is
#     why this case checks only the wrapper's own log.
begin '24 the log mask'
job_base
run_smoke "$SBLAB/smoke-job.command" "" 0 1
if assert_lacks "$SMOKELOG" '192.0.2.10' && assert_lacks "$SMOKELOG" 'labtest-placeholder' \
	&& assert_lacks "$SMOKELOG" 'LABTEST-PLACEHOLDER-SECRET-3f9a' && assert_lacks "$SMOKELOG" "$SBHOME" \
	&& assert_has "$SMOKELOG" '<WIN_HOST>' && assert_has "$SMOKELOG" '<WIN_USER>' \
	&& assert_has "$SMOKELOG" '<WIN_PASS>' && assert_has "$SMOKELOG" '<HOME>'; then
	pass "$CASE: the address, the account, the password and \$HOME are each replaced by their placeholder, on both of the launcher's streams"
fi

# 25. The log is truncated at startup: a stale DONE line from a previous run must not be what a
#     caller polling this file reads.
begin '25 the log is truncated at startup'
mkdir -p "$SBRUNTIME" || exit 1
printf 'DONE exit=0\n' > "$SMOKELOG"
run_smoke "$SBLAB/smoke-job.command" "$DENY_FILE"
if assert_eq "$(grep -c '^DONE exit=' "$SMOKELOG")" '1' 'DONE lines in the log' \
	&& assert_eq "$(last_line)" 'DONE exit=78' 'last log line'; then
	pass "$CASE: exactly one DONE line, and it is this run's refusal -- last run's verdict is gone"
fi

# 26. A hand-edited CRLF job file must not ship a bare CR into a file name or into the child's
#     environment.
begin '26 a CRLF job file'
{
	printf 'TAG=labtest\r\nBATCH=labtest\r\nADVERTISED_SCALE=DD\r\nMOVE=1\r\n'
	printf 'MAXIMIZE=0\r\nTRAY=0\r\nTRAY_CLICK=0\r\nEXTRA_APPS=notepad\r\n'
} > "$JOB"
run_smoke "$SBLAB/smoke-job.command" ""
if assert_eq "$(child_calls)" '1' 'launcher invocations' \
	&& assert_eq "$(child_env 'WINDOW_SMOKE_ADVERTISED_SCALE=DD')" '1' 'the knob without a trailing CR' \
	&& assert_eq "$(child_env 'WINDOW_SMOKE_EXTRA_APPS=notepad')" '1' 'EXTRA_APPS without a trailing CR' \
	&& [ -f "$SBRUNTIME/smoke-labtest.log" ] && assert_eq "$(last_line)" 'DONE exit=0' 'last log line'; then
	pass "$CASE: every value is CR-stripped, so the per-TAG log is smoke-labtest.log and not smoke-labtest\$'\\r'.log"
fi

# 26b. A CR in the MIDDLE of a value, which is the half case 26 does not reach. The line grammar
#      judges the file with every CR removed, so `MOVE_TARGET=a<CR>b` is admitted as text -- but the
#      subshell reads the ORIGINAL file, so the value it hands back still carries the CR, and a
#      strip that only took the TRAILING one shipped it into the child's environment. That is not a
#      dangerous character, but it makes this wrapper disagree with checkpoint.sh's cp_job_value,
#      which has always removed every CR: one of the two would then be naming a file the other one
#      is not. The rule is now the same on both sides, and this is the case that says so.
begin '26b a CR inside a value, not only at the end of the line'
{
	printf 'TAG=labtest\r\nBATCH=labtest\r\n'
	printf 'MOVE_TARGET=a\rb\r\nEXTRA_APPS=note\rpad\r\n'
} > "$JOB"
run_smoke "$SBLAB/smoke-job.command" ""
reasons=''
[ "$(child_calls)" = '1' ] || reasons="$reasons launcher-calls=$(child_calls);"
[ "$(child_env 'WINDOW_SMOKE_MOVE_TARGET=ab')" = '1' ] || reasons="$reasons MOVE_TARGET;"
[ "$(child_env 'WINDOW_SMOKE_EXTRA_APPS=notepad')" = '1' ] || reasons="$reasons EXTRA_APPS;"
grep -q "$(printf '\r')" "$LABTEST_TRACE" && reasons="$reasons bare-CR-reached-the-child;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: a CR anywhere in a value is removed, so the child's environment carries none of them and this wrapper reads a CRLF file the way checkpoint.sh does"
else
	fail "$CASE:$reasons"
	note "trace: $(tr '\n' ';' < "$LABTEST_TRACE" | tr '\r' '?')"
fi

# 27. THE ORDER. Closing the window hangs this process up, so the DONE line and the per-TAG copy the
#     orchestrator polls must already be on disk when the close is asked for. The osascript shim
#     snapshots exactly that at the moment it is called. (M4 pins this.)
begin '27 DONE and the per-TAG copy precede the window close'
OSASCRIPT_EXPECTED=1
job_base
run_smoke "$SBLAB/smoke-job.command" "" 0 0 'Apple_Terminal'
snapshot="$(grep '^close-requested' "$LABTEST_TRACE" | tail -n 1)"
if [ -z "$snapshot" ]; then
	fail "$CASE: the wrapper never asked for the window to be closed (TERM_PROGRAM=Apple_Terminal)"
elif [ "$snapshot" != 'close-requested last-log-line=[DONE exit=0] tag-log=yes' ]; then
	fail "$CASE: state at close-request time was [$snapshot]"
elif ! wait_for_trace 'osascript-close' 10; then
	fail "$CASE: the close was prepared but osascript was never reached"
else
	pass "$CASE: at the moment the close was requested, smoke.log already ended in DONE exit=0 and smoke-labtest.log already existed -- and osascript followed"
fi

# 28. run-scenario.sh's smoke mode: the tracked definition becomes the runtime instance, BOTH stale
#     logs go (a caller polling either must not read the last run's verdict), and Terminal is asked
#     to open the tracked wrapper -- not a generated one.
begin '28 run-scenario.sh smoke <job>'
mkdir -p "$SBRUNTIME" || exit 1
printf 'DONE exit=0\n' > "$SMOKELOG"
printf 'DONE exit=0\n' > "$SBRUNTIME/smoke-labtest.log"
OUT="$SB/out.txt"
run_lab "$OUT" "$SBLAB/run-scenario.sh" smoke labtest
rc=$?
reasons=''
[ "$rc" -eq 0 ] || reasons="$reasons rc=$rc;"
grep -qF 'smoke labtest launched' "$OUT" || reasons="$reasons no-launch-line;"
cmp -s "$SBLAB/jobs/smoke-labtest.env" "$JOB" || reasons="$reasons job-instance-differs-from-the-tracked-template;"
[ -f "$SMOKELOG" ] && reasons="$reasons stale-smoke.log-survived;"
[ -f "$SBRUNTIME/smoke-labtest.log" ] && reasons="$reasons stale-per-TAG-log-survived;"
grep -qF "open [-a] [Terminal] [$SBLAB/smoke-job.command]" "$LABTEST_TRACE" || reasons="$reasons open-argv=[$(grep '^open ' "$LABTEST_TRACE")];"
[ -f "$SBLAB/smoke-job.env" ] && reasons="$reasons job-written-into-the-tracked-tree;"
if [ -z "$reasons" ]; then
	pass "$CASE: jobs/smoke-labtest.env copied verbatim to the runtime smoke-job.env, both stale logs removed, Terminal asked to open smoke-job.command, nothing written into the tracked tree"
else
	fail "$CASE:$reasons"
	note "$(cat "$OUT")"
fi

# 29. The batch override reaches the RUNTIME instance and never the tracked template -- which is
#     what lets one checkpoint have a dated evidence directory without an edit to a file under
#     review. A malformed override is refused before anything is opened.
begin '29 run-scenario.sh smoke <job> <batch>'
run_lab "$SB/out.txt" "$SBLAB/run-scenario.sh" smoke labtest dated-20260910
rc=$?
reasons=''
[ "$rc" -eq 0 ] || reasons="$reasons rc=$rc;"
[ "$(tail -n 1 "$JOB")" = 'BATCH=dated-20260910' ] || reasons="$reasons override-not-appended[$(tail -n 1 "$JOB")];"
grep -qF 'BATCH=labtest' "$JOB" || reasons="$reasons template-body-lost;"
cmp -s "$SBLAB/jobs/smoke-labtest.env" "$JOB" && reasons="$reasons override-did-not-change-the-instance;"
grep -qF 'dated-20260910' "$SBLAB/jobs/smoke-labtest.env" && reasons="$reasons tracked-template-was-edited;"
: > "$LABTEST_TRACE"
run_lab "$SB/out.txt" "$SBLAB/run-scenario.sh" smoke labtest 'bad batch/name'
rc=$?
[ "$rc" -eq 2 ] || reasons="$reasons malformed-override-rc=$rc;"
[ "$(open_calls)" = '0' ] || reasons="$reasons malformed-override-still-opened-a-window;"
if [ -z "$reasons" ]; then
	pass "$CASE: a valid override is appended to the runtime instance (the template untouched, its own BATCH still there and overridden by position); a malformed one exits 2 with nothing opened"
else
	fail "$CASE:$reasons"
fi

# 29b. THE OVERRIDE AND THE MISSING NEWLINE. The override used to be APPENDED to a copy of the
#      template, which is correct exactly as long as every template ends in a newline. One that does
#      not glues `BATCH=<override>` onto its last line, and what happens next depends on WHICH key
#      that last line is: a key with a strict shape (the shipped 2x-D template ends in
#      REQUIRE_SYMBOL) is refused, which is survivable, but a FREE-TEXT key -- MOVE_TARGET, APP,
#      APP_ARGS -- swallows it silently. The run then goes to the template's own batch with a
#      corrupted move target, reports DONE exit=0, and the checkpoint that asked for a dated
#      directory gets one it never wrote anything into. So the instance is REBUILT rather than
#      appended to, with the separating newline written by this script instead of assumed of the
#      template. (M8 pins the newline.)
begin '29b a template with no trailing newline cannot swallow the override'
run_lab "$SB/out.txt" "$SBLAB/run-scenario.sh" smoke nonl dated-99
rc=$?
reasons=''
[ "$rc" -eq 0 ] || reasons="$reasons run-scenario-rc=$rc;"
[ "$(tail -n 1 "$JOB")" = 'BATCH=dated-99' ] || reasons="$reasons override-not-the-last-line[$(tail -n 1 "$JOB")];"
grep -qxF 'MOVE_TARGET=abc' "$JOB" || reasons="$reasons last-template-line-was-glued[$(grep -c . "$JOB") lines];"
grep -qF 'dated-99' "$SBLAB/jobs/smoke-nonl.env" && reasons="$reasons tracked-template-was-edited;"
# Then RUN that instance: the two things the glue would have corrupted are where the evidence log
# goes and what the move leg looks for, and both are only observable in the child's environment.
run_smoke "$SBLAB/smoke-job.command" ""
[ "$(child_calls)" = '1' ] || reasons="$reasons launcher-calls=$(child_calls);"
[ "$(child_env "WINDOW_SMOKE_LOG=$SBEVIDENCE/dated-99/window-smoke-labtest.log")" = '1' ] \
	|| reasons="$reasons WINDOW_SMOKE_LOG-not-under-the-override;"
[ "$(child_env 'WINDOW_SMOKE_MOVE_TARGET=abc')" = '1' ] || reasons="$reasons MOVE_TARGET-was-polluted;"
if [ -z "$reasons" ]; then
	pass "$CASE: a template with no final newline still yields BATCH=dated-99 on a line of its own; the run's evidence log lands under the override and the template's last value is untouched"
else
	fail "$CASE:$reasons"
	note "instance: $(tr '\n' ';' < "$JOB")"
fi

# 30. The TRACKED jobs/smoke-2x-D.env must actually be accepted by the wrapper and produce the run
#     it describes -- the same property test-relay-offline.sh's case 5 keeps for relay jobs. A
#     regression pin: what it guards is a future edit to the template that would surface as a
#     refused run on the lab host and nowhere else.
begin '30 the tracked jobs/smoke-2x-D.env drives the wrapper'
cp "$SBLAB/jobs/smoke-2x-D.env" "$JOB" || exit 1
DISPLAY_TEXT='          UI Looks like: 1280 x 720 @ 180.00Hz'
run_smoke "$SBLAB/smoke-job.command" ""
reasons=''
[ "$(child_calls)" = '1' ] || reasons="$reasons launcher-calls=$(child_calls);"
[ "$(sysprofiler_calls)" = '1' ] || reasons="$reasons display-not-checked;"
child_has_var 'WINDOW_SMOKE_ADVERTISED_SCALE' && reasons="$reasons D-should-mean-the-knob-is-unset;"
[ "$(child_env 'WINDOW_SMOKE_MOVE=1')" = '1' ] || reasons="$reasons MOVE;"
[ "$(child_env 'WINDOW_SMOKE_EXTRA_APPS=notepad')" = '1' ] || reasons="$reasons EXTRA_APPS;"
[ "$(child_env 'WINDOW_SMOKE_MOVE_TARGET=Notepad|记事本')" = '1' ] || reasons="$reasons MOVE_TARGET;"
[ "$(child_env "WINDOW_SMOKE_LOG=$SBEVIDENCE/w3-2x-checkpoint/window-smoke-2xD.log")" = '1' ] || reasons="$reasons WINDOW_SMOKE_LOG;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: the shipped 2x-D template arms both preflights, leaves the knob unset (product default D) and drives the MOVE + notepad leg"
else
	fail "$CASE:$reasons"
	note "trace: $(tr '\n' ';' < "$LABTEST_TRACE")"
fi

# 31. The etw mode is unchanged by this lane's additions: same copy, same removal, same wrapper.
#     (test-wdp-etw-offline.sh owns the wrapper itself; this pins the dispatch.)
begin '31 run-scenario.sh etw is unchanged'
mkdir -p "$SBRUNTIME" || exit 1
printf 'DONE exit=0\n' > "$SBRUNTIME/etw.log"
run_lab "$SB/out.txt" "$SBLAB/run-scenario.sh" etw labtest
rc=$?
reasons=''
[ "$rc" -eq 0 ] || reasons="$reasons rc=$rc;"
cmp -s "$SBLAB/jobs/etw-labtest.env" "$SBRUNTIME/etw-job.env" || reasons="$reasons job-instance-differs;"
[ -f "$SBRUNTIME/etw.log" ] && reasons="$reasons stale-etw.log-survived;"
grep -qF "open [-a] [Terminal] [$SBLAB/wdp-etw.command]" "$LABTEST_TRACE" || reasons="$reasons open-argv;"
if [ -z "$reasons" ]; then
	pass "$CASE: jobs/etw-labtest.env copied to the runtime etw-job.env, the stale etw.log removed, Terminal asked to open wdp-etw.command"
else
	fail "$CASE:$reasons"
	note "$(cat "$SB/out.txt")"
fi

# 32. The relay mode likewise: it still stages the share before it opens the relay.
begin '32 run-scenario.sh relay is unchanged'
mkdir -p "$SBRUNTIME" || exit 1
printf 'DONE exit=0\n' > "$SBRUNTIME/relay.log"
run_lab "$SB/out.txt" "$SBLAB/run-scenario.sh" relay server-snapshot
rc=$?
reasons=''
[ "$rc" -eq 0 ] || reasons="$reasons rc=$rc;"
cmp -s "$SBLAB/jobs/server-snapshot.env" "$SBRUNTIME/job.env" || reasons="$reasons job-instance-differs;"
[ -f "$SBRUNTIME/relay.log" ] && reasons="$reasons stale-relay.log-survived;"
[ -f "$SBRUNTIME/share/labtest.ps1" ] || reasons="$reasons share-not-staged;"
grep -qF "open [-a] [Terminal] [$SBLAB/relay.command]" "$LABTEST_TRACE" || reasons="$reasons open-argv;"
if [ -z "$reasons" ]; then
	pass "$CASE: the share is staged, jobs/server-snapshot.env copied to the runtime job.env, the stale relay.log removed, Terminal asked to open relay.command"
else
	fail "$CASE:$reasons"
	note "$(cat "$SB/out.txt")"
fi

# 33. An unknown mode is refused rather than silently doing nothing. This is what a caller of the
#     RETIRED `smoke <log> KEY=V ...` form now hits, instead of a run with no parameters.
begin '33 an unknown mode is refused'
run_lab "$SB/out.txt" "$SBLAB/run-scenario.sh" bogus x
rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'unknown mode' "$SB/out.txt" && [ "$(open_calls)" = '0' ]; then
	pass "$CASE: exit 2, the mode is named, nothing opened"
else
	fail "$CASE: rc=$rc opens=$(open_calls) out=[$(cat "$SB/out.txt")]"
fi

# 34. checkpoint.sh end to end, with the capture and the relay as scripted fakes and the REAL
#     wrapper doing the run. Everything the checkpoint waits for appears on a timeline, and
#     everything it is supposed to gather lands in one directory.
begin '34 checkpoint.sh end to end'
export LABTEST_OPEN_EXEC=1
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" labtest
rc=$?
unset LABTEST_OPEN_EXEC
reasons=''
[ "$rc" -eq 0 ] || reasons="$reasons rc=$rc;"
for artefact in etw-labtest.jsonl etw-labtest.log smoke-labtest.log window-smoke-labtest.log \
	relay-labtest.log server-snapshot-labtest.txt; do
	[ -f "$SBEVIDENCE/labtest/$artefact" ] || reasons="$reasons missing[$artefact];"
done
grep -qF '(b) capture open' "$SB/out.txt" || reasons="$reasons no-capture-open-line;"
grep -qF '(c) run: DONE exit=0' "$SB/out.txt" || reasons="$reasons no-run-verdict;"
grep -qF '(d) capture: DONE exit=0' "$SB/out.txt" || reasons="$reasons no-capture-verdict;"
grep -qF '(e) snapshot relay: DONE exit=0' "$SB/out.txt" || reasons="$reasons no-snapshot-verdict;"
grep -qF 'checkpoint labtest complete' "$SB/out.txt" || reasons="$reasons no-completion-line;"
grep -qF "$SBHOME" "$SB/out.txt" && reasons="$reasons absolute-home-path-printed;"
if [ -z "$reasons" ]; then
	pass "$CASE: capture -> settle -> run -> capture verdict -> snapshot -> gather; all six artefacts under .build/evidence/labtest/ and every path printed repo-relative"
else
	fail "$CASE:$reasons"
	note "$(tail -n 20 "$SB/out.txt")"
fi

# 34b. WHICH BATCH THE MANIFEST READS. A checkpoint given a dated batch name passes it to
#      run-scenario.sh, which puts it in the runtime instance, which is where the wrapper reads it
#      -- so the run's evidence log is ALWAYS under the checkpoint's batch, whatever the tracked
#      template says. Reading it from the template's batch instead is wrong in two ways at once:
#      the run's real log is reported MISSING, and if the template's directory still holds the
#      PREVIOUS run's log of the same name (which is what a second run of the same job leaves
#      there) that stale file is copied OVER the real one under the new batch name. The evidence is
#      then not absent but FALSE, and the exit code, the manifest and the verdicts line all look
#      normal. Every shipped pair of job files agrees on BATCH today, which is precisely why no
#      other case can see this: these two disagree on purpose. (M6 pins it.)
begin '34b a dated batch override: the manifest reads the run own batch, not the template one'
STALE_DIR="$SBEVIDENCE/template-batch"
mkdir -p "$STALE_DIR" || exit 1
printf 'STALE-FROM-A-PREVIOUS-RUN\n' > "$STALE_DIR/window-smoke-labtest.log" || exit 1
export LABTEST_OPEN_EXEC=1
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" otherbatch dated-20260910
rc=$?
unset LABTEST_OPEN_EXEC
reasons=''
GATHERED="$SBEVIDENCE/dated-20260910/window-smoke-labtest.log"
[ "$rc" -eq 0 ] || reasons="$reasons rc=$rc;"
[ -f "$GATHERED" ] || reasons="$reasons no-window-smoke-log-under-the-override;"
grep -qF '[launcher] labtest stub' "$GATHERED" 2>/dev/null || reasons="$reasons GATHERED-LOG-IS-NOT-THIS-RUN;"
grep -qF 'STALE-FROM-A-PREVIOUS-RUN' "$GATHERED" 2>/dev/null && reasons="$reasons STALE-LOG-COPIED-OVER-THE-REAL-ONE;"
grep -qF 'window-smoke-labtest.log  MISSING' "$SB/out.txt" && reasons="$reasons manifest-reported-it-missing;"
# The template's own BATCH is not silently ignored either: the two disagree, and the run says so.
grep -qF 'declares BATCH=template-batch' "$SB/out.txt" || reasons="$reasons override-not-stated;"
# The stale file is READ from nowhere and written to nowhere -- it must survive untouched.
[ "$(cat "$STALE_DIR/window-smoke-labtest.log" 2>/dev/null)" = 'STALE-FROM-A-PREVIOUS-RUN' ] \
	|| reasons="$reasons stale-file-was-rewritten;"
if [ -z "$reasons" ]; then
	pass "$CASE: the manifest gathers the log THIS run wrote under the override, the previous run's log in the template's batch is neither read nor overwritten, and the disagreement is stated"
else
	fail "$CASE:$reasons"
	note "$(tail -n 15 "$SB/out.txt")"
fi

# 34c. A REQUIRED ARTEFACT THAT NEVER APPEARED. Every step can report DONE exit=0 and the evidence
#      directory can still be missing the one file the checkpoint exists to produce -- a launcher
#      that died after its own verdict, a log written somewhere unreadable. Before this, gather()
#      returned 1 and no caller looked: the run printed MISSING in the middle of the manifest and
#      "complete" at the bottom, and exited 0. A checkpoint that says complete while its evidence
#      is incomplete is the failure this whole lane is built to avoid, so the count is now the
#      verdict. (M7 pins the counting.)
begin '34c a missing required artefact makes the checkpoint INCOMPLETE'
export LABTEST_OPEN_EXEC=1
export LABTEST_CHILD_NO_WS_LOG=1
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" labtest
rc=$?
unset LABTEST_OPEN_EXEC LABTEST_CHILD_NO_WS_LOG
reasons=''
[ "$rc" -eq 8 ] || reasons="$reasons rc=$rc;"
grep -qF 'window-smoke-labtest.log  MISSING' "$SB/out.txt" || reasons="$reasons no-missing-line;"
grep -qF 'INCOMPLETE: 1 artefact(s) missing' "$SB/out.txt" || reasons="$reasons no-incomplete-line;"
grep -qF 'checkpoint labtest complete' "$SB/out.txt" && reasons="$reasons still-claims-complete;"
# The other five are there, so what the verdict reports is one missing artefact and not a run that
# fell over: the run itself reported DONE exit=0.
grep -qF '(c) run: DONE exit=0' "$SB/out.txt" || reasons="$reasons run-did-not-report;"
for artefact in etw-labtest.jsonl etw-labtest.log smoke-labtest.log relay-labtest.log \
	server-snapshot-labtest.txt; do
	[ -f "$SBEVIDENCE/labtest/$artefact" ] || reasons="$reasons missing[$artefact];"
done
if [ -z "$reasons" ]; then
	pass "$CASE: every step reported, one required artefact never appeared, and the checkpoint says INCOMPLETE and exits 8 instead of claiming completion"
else
	fail "$CASE:$reasons"
	note "$(tail -n 15 "$SB/out.txt")"
fi

# 35. THE OVERLAP GUARD. Two realtime captures against the same portal disable each other's
#     providers, and the damage lands in the OTHER run's evidence. A log with no verdict plus a live
#     capture process is the refusal condition -- and the refusal must happen before anything is
#     launched. This log carries no pid line, so it also exercises the FALLBACK, which must say so:
#     a guard that quietly changed which signal it was reading would otherwise look identical in
#     the scrollback. (M3 pins the guard itself; M5 pins which signal it prefers.)
begin '35 checkpoint.sh refuses to overlap a live capture'
mkdir -p "$SBRUNTIME" || exit 1
printf '[etw] etw capture tag=labtest\n' > "$SBRUNTIME/etw.log"
export LABTEST_PGREP_RC=0
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" labtest
rc=$?
unset LABTEST_PGREP_RC
if [ "$rc" -eq 3 ] && grep -qF 'an ETW capture is still in flight' "$SB/out.txt" \
	&& grep -qF 'falling back to the process table' "$SB/out.txt" && [ "$(open_calls)" = '0' ]; then
	pass "$CASE: exit 3 with the reason named, the fallback to the process table stated, and nothing launched"
else
	fail "$CASE: rc=$rc opens=$(open_calls)"
	note "$(cat "$SB/out.txt")"
fi

# 36. The other side of the same rule: a log left behind by a capture whose process is gone is not
#     an overlap. A guard that refused on the log alone would need a manual `rm` after every
#     interrupted run, which is how guards get commented out.
begin '36 a stale log with no live capture is not an overlap'
mkdir -p "$SBRUNTIME" || exit 1
printf '[etw] etw capture tag=labtest\n' > "$SBRUNTIME/etw.log"
export LABTEST_OPEN_EXEC=1
export LABTEST_PGREP_RC=1
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" labtest
rc=$?
unset LABTEST_OPEN_EXEC LABTEST_PGREP_RC
if [ "$rc" -eq 0 ] && grep -qF 'checkpoint labtest complete' "$SB/out.txt"; then
	pass "$CASE: the checkpoint proceeds when pgrep says the previous capture's process is gone"
else
	fail "$CASE: rc=$rc"
	note "$(tail -n 15 "$SB/out.txt")"
fi

# 35b. WHICH SIGNAL THE GUARD READS. wdp-etw.command writes `[etw] pid=<its own pid>` into etw.log
#      before it dials, and that is the signal the guard prefers: it names THIS checkout's capture,
#      while a `pgrep -f` pattern answers about whatever the machine happens to be running. Here the
#      pid names a live process and pgrep would say nothing -- the refusal must still happen, and
#      pgrep must not even be consulted. (M5 pins this.)
begin '35b the pid line in etw.log is what the guard reads'
mkdir -p "$SBRUNTIME" || exit 1
sleep 30 &
LIVE_PID=$!
{
	printf '[etw] etw capture tag=labtest duration=5s providers=1 start=labtest\n'
	printf '[etw] pid=%s\n' "$LIVE_PID"
} > "$SBRUNTIME/etw.log"
export LABTEST_PGREP_RC=1
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" labtest
rc=$?
unset LABTEST_PGREP_RC
kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null
if [ "$rc" -eq 3 ] && grep -qF "names pid $LIVE_PID and it is still alive" "$SB/out.txt" \
	&& [ "$(open_calls)" = '0' ] && [ "$(pgrep_calls)" = '0' ]; then
	pass "$CASE: exit 3 on the pid line alone -- the process table was never consulted and nothing was launched"
else
	fail "$CASE: rc=$rc opens=$(open_calls) pgreps=$(pgrep_calls)"
	note "$(cat "$SB/out.txt")"
fi

# 36b. The other side of THAT rule: a pid line naming a process that is gone is not an overlap, even
#      when the process table says something matching is running. This is the case the pid line
#      exists for -- `pgrep -f` matches a pattern, so a neighbouring checkout's capture, an editor
#      with the file open or a `less` on the wrapper would all have refused the run. The checkpoint
#      is allowed to proceed and then fails at the capture's own timeout, which is a different
#      case's business; what is measured here is that it got PAST the guard without consulting
#      pgrep at all.
begin '36b a dead pid is not an overlap even when the process table matches'
mkdir -p "$SBRUNTIME" || exit 1
sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
if kill -0 "$DEAD_PID" 2>/dev/null; then
	fail "$CASE: the sandbox could not produce a pid that is gone (pid $DEAD_PID is still alive)"
else
	{
		printf '[etw] etw capture tag=labtest duration=5s providers=1 start=labtest\n'
		printf '[etw] pid=%s\n' "$DEAD_PID"
	} > "$SBRUNTIME/etw.log"
	export LABTEST_PGREP_RC=0
	export LABTEST_OPEN_EXEC=1
	export LABTEST_ETW_OPENS=0
	export LABTEST_ETW_DONES=0
	export CHECKPOINT_TIMEOUT_ETW_OPEN=3
	run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" labtest
	rc=$?
	unset LABTEST_PGREP_RC LABTEST_OPEN_EXEC LABTEST_ETW_OPENS LABTEST_ETW_DONES CHECKPOINT_TIMEOUT_ETW_OPEN
	if [ "$rc" -eq 4 ] && [ "$(open_calls)" != '0' ] && [ "$(pgrep_calls)" = '0' ] \
		&& ! grep -qF 'still in flight' "$SB/out.txt"; then
		pass "$CASE: the guard let the checkpoint through on the dead pid without asking the process table; it then stopped at the capture's own timeout (exit 4)"
	else
		fail "$CASE: rc=$rc opens=$(open_calls) pgreps=$(pgrep_calls)"
		note "$(tail -n 10 "$SB/out.txt")"
	fi
fi

# 36c. THE MANIFEST ON A REFUSAL PATH. The file header promises that every exit prints a manifest of
#      this batch's artefacts, and for the refusals that exit through cp_die -- the overlap guard
#      among them -- that promise used to be false: the gather sat at the bottom of the script and
#      those paths never reached it. The refusal that stops the run earliest is also the one where a
#      reader most needs the list, because "which of these six files does this batch have" is the
#      question that decides whether the checkpoint has to be re-run from the start. It is now
#      printed from an EXIT trap, so there is one answer for every exit -- READ-ONLY on this path
#      (see 36d): nothing was launched, so there is nothing of THIS run's to gather, and the MISSING
#      line below is a statement about the batch directory, not about .build/lab-runtime/.
begin '36c the refusal path prints the manifest too'
mkdir -p "$SBRUNTIME" || exit 1
printf '[etw] etw capture tag=labtest\n' > "$SBRUNTIME/etw.log"
export LABTEST_PGREP_RC=0
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" labtest
rc=$?
unset LABTEST_PGREP_RC
reasons=''
[ "$rc" -eq 3 ] || reasons="$reasons rc=$rc;"
grep -qF 'an ETW capture is still in flight' "$SB/out.txt" || reasons="$reasons no-refusal-reason;"
grep -qF '(f) evidence ->' "$SB/out.txt" || reasons="$reasons no-manifest;"
grep -qF 'smoke-labtest.log  MISSING' "$SB/out.txt" || reasons="$reasons manifest-does-not-name-the-run-log;"
grep -qF 'INCOMPLETE:' "$SB/out.txt" || reasons="$reasons no-incomplete-line;"
grep -qF 'checkpoint labtest complete' "$SB/out.txt" && reasons="$reasons claims-complete;"
# The refusal is still a refusal: nothing was launched, and the refusal's own code survives the
# gather rather than being replaced by the INCOMPLETE one.
[ "$(open_calls)" = '0' ] || reasons="$reasons opened-something;"
if [ -z "$reasons" ]; then
	pass "$CASE: the overlap refusal exits 3, launches nothing, and still prints the manifest saying which artefacts this batch does not have"
else
	fail "$CASE:$reasons"
	note "$(cat "$SB/out.txt")"
fi

# 36d. THE READ-ONLY LISTING COPIES NOTHING. Before this, a cp_die refusal's manifest ran the SAME
#      gather() a completed run does: it read whatever a PREVIOUS, unrelated run left in
#      .build/lab-runtime/ under this batch's artefact names and copied it into THIS batch's
#      directory, so a reader who only looked at the batch directory afterwards saw a plausible-
#      looking set of files this run never produced -- the manifest attributing someone else's
#      leftovers to a batch that never launched anything. Here the batch directory pre-exists, EMPTY,
#      and .build/lab-runtime/ carries a previous run's leftovers under every copyable artefact name;
#      the refusal must leave the batch directory exactly as empty as it found it and say so with the
#      literal words "listing only, nothing gathered" rather than a manifest indistinguishable from a
#      real gather's.
begin '36d a refusal path lists the batch directory read-only and copies nothing into it'
mkdir -p "$SBEVIDENCE/labtest" || exit 1
mkdir -p "$SBRUNTIME/wdp" "$SBRUNTIME/share" || exit 1
printf 'STALE-FROM-A-PREVIOUS-RUN\n' > "$SBRUNTIME/wdp/etw-labtest.jsonl" || exit 1
printf 'STALE-FROM-A-PREVIOUS-RUN\n' > "$SBRUNTIME/wdp/etw-labtest.log" || exit 1
printf 'STALE-FROM-A-PREVIOUS-RUN\n' > "$SBRUNTIME/smoke-labtest.log" || exit 1
printf 'STALE-FROM-A-PREVIOUS-RUN\n' > "$SBRUNTIME/relay.log" || exit 1
printf 'STALE-FROM-A-PREVIOUS-RUN\n' > "$SBRUNTIME/share/server-snapshot-out.txt" || exit 1
printf '[etw] etw capture tag=labtest\n' > "$SBRUNTIME/etw.log"
export LABTEST_PGREP_RC=0
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" labtest
rc=$?
unset LABTEST_PGREP_RC
reasons=''
[ "$rc" -eq 3 ] || reasons="$reasons rc=$rc;"
[ -d "$SBEVIDENCE/labtest" ] || reasons="$reasons batch-directory-disappeared;"
LEFTOVER="$(find "$SBEVIDENCE/labtest" -mindepth 1 2>/dev/null | tr '\n' ',')"
[ -z "$LEFTOVER" ] || reasons="$reasons batch-directory-is-no-longer-empty[$LEFTOVER];"
grep -qF 'listing only, nothing gathered' "$SB/out.txt" || reasons="$reasons no-listing-only-line;"
[ "$(cat "$SBRUNTIME/smoke-labtest.log")" = 'STALE-FROM-A-PREVIOUS-RUN' ] \
	|| reasons="$reasons runtime-smoke-log-was-touched;"
[ "$(cat "$SBRUNTIME/relay.log")" = 'STALE-FROM-A-PREVIOUS-RUN' ] || reasons="$reasons runtime-relay-log-was-touched;"
[ "$(open_calls)" = '0' ] || reasons="$reasons opened-something;"
if [ -z "$reasons" ]; then
	pass "$CASE: the refusal states 'listing only, nothing gathered', the previous run's leftovers in .build/lab-runtime/ are neither read into the manifest as this batch's nor copied anywhere, and the pre-existing empty batch directory is still empty"
else
	fail "$CASE:$reasons"
	note "$(cat "$SB/out.txt")"
fi

# 37-40. Every wait has a ceiling, a distinct exit code and a line naming the step. Nothing is ever
#     killed: the process a timeout would be aiming at is somebody's Terminal window.
begin '37 the capture never opens'
export LABTEST_OPEN_EXEC=1
export LABTEST_ETW_OPENS=0
export LABTEST_ETW_DONES=0
export CHECKPOINT_TIMEOUT_ETW_OPEN=3
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" labtest
rc=$?
unset LABTEST_OPEN_EXEC LABTEST_ETW_OPENS LABTEST_ETW_DONES CHECKPOINT_TIMEOUT_ETW_OPEN
if [ "$rc" -eq 4 ] && grep -qF '(b) the capture did not open its output' "$SB/out.txt" \
	&& ! grep -qF '(c) starting the run' "$SB/out.txt"; then
	pass "$CASE: exit 4, the step is named, and the run was never launched into a capture that is not there"
else
	fail "$CASE: rc=$rc"
	note "$(tail -n 12 "$SB/out.txt")"
fi

begin '38 the run never reports'
export LABTEST_OPEN_EXEC=1
export CHECKPOINT_TIMEOUT_SMOKE=3
# The launcher stub is bypassed by pointing the smoke job at a TAG whose wrapper will refuse before
# it ever writes a per-TAG log, and by removing the fixed log the wrapper would otherwise write:
# what is being measured is the WAIT, so the run is simply never started (the open shim is told to
# ignore it).
export LABTEST_SMOKE_NOOP=1
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" labtest
rc=$?
unset LABTEST_OPEN_EXEC CHECKPOINT_TIMEOUT_SMOKE LABTEST_SMOKE_NOOP
if [ "$rc" -eq 5 ] && grep -qF '(c) the run did not report a DONE line' "$SB/out.txt"; then
	pass "$CASE: exit 5 with the step named"
else
	fail "$CASE: rc=$rc"
	note "$(tail -n 12 "$SB/out.txt")"
fi

begin '39 the capture never reports'
export LABTEST_OPEN_EXEC=1
export LABTEST_ETW_DONES=0
export CHECKPOINT_TIMEOUT_ETW_DONE=3
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" labtest
rc=$?
unset LABTEST_OPEN_EXEC LABTEST_ETW_DONES CHECKPOINT_TIMEOUT_ETW_DONE
if [ "$rc" -eq 6 ] && grep -qF '(d) the capture did not report a DONE line' "$SB/out.txt"; then
	pass "$CASE: exit 6 with the step named"
else
	fail "$CASE: rc=$rc"
	note "$(tail -n 12 "$SB/out.txt")"
fi

begin '40 the snapshot relay never reports'
export LABTEST_OPEN_EXEC=1
export LABTEST_RELAY_DONES=0
export CHECKPOINT_TIMEOUT_RELAY=3
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" labtest
rc=$?
unset LABTEST_OPEN_EXEC LABTEST_RELAY_DONES CHECKPOINT_TIMEOUT_RELAY
if [ "$rc" -eq 7 ] && grep -qF '(e) the snapshot relay did not report a DONE line' "$SB/out.txt" \
	&& [ -f "$SBEVIDENCE/labtest/smoke-labtest.log" ]; then
	pass "$CASE: exit 7 with the step named, and the evidence gathered so far is still copied out"
else
	fail "$CASE: rc=$rc"
	note "$(tail -n 12 "$SB/out.txt")"
fi

# 41. SNAPSHOT=0 must not merely skip the wait -- it must not open the relay at all. The snapshot is
#     an RDP session of its own, and "skipped" that still dials is the failure worth pinning.
begin '41 SNAPSHOT=0 never opens the relay'
cat > "$SBLAB/jobs/checkpoint-nosnap.env" <<'JOB_NOSNAP' || exit 1
ETW_JOB=labtest
SMOKE_JOB=labtest
SNAPSHOT=0
SETTLE_SECONDS=0
BATCH=labtest
JOB_NOSNAP
export LABTEST_OPEN_EXEC=1
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" nosnap
rc=$?
unset LABTEST_OPEN_EXEC
rm -f "$SBLAB/jobs/checkpoint-nosnap.env"
reasons=''
[ "$rc" -eq 0 ] || reasons="$reasons rc=$rc;"
grep -qF 'relay.command' "$LABTEST_TRACE" && reasons="$reasons relay-was-opened;"
grep -qF '(e) skipped -- SNAPSHOT=0' "$SB/out.txt" || reasons="$reasons no-skip-line;"
[ -f "$SBEVIDENCE/labtest/server-snapshot-labtest.txt" ] && reasons="$reasons snapshot-artefact-gathered;"
if [ -z "$reasons" ]; then
	pass "$CASE: the relay is never opened, the skip is stated, and no snapshot artefact is claimed"
else
	fail "$CASE:$reasons"
fi

# 42. The checkpoint job file is held to the same standard as the smoke one: a key outside its
#     whitelist, a value outside its shape, or a job it names that does not exist, all refuse with
#     exit 2 and launch nothing.
begin '42 checkpoint job validation'
bad=''
checkpoint_reject() { # <label> <file body...>
	local label="$1"
	shift
	: > "$LABTEST_TRACE"
	printf '%s\n' "$@" > "$SBLAB/jobs/checkpoint-reject.env"
	run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" reject
	local rc=$?
	if [ "$rc" -ne 2 ] || [ "$(open_calls)" != '0' ]; then
		bad="$bad [$label -> rc=$rc opens=$(open_calls)]"
	fi
}
checkpoint_reject 'unknown key' 'ETW_JOB=labtest' 'SMOKE_JOB=labtest' 'WIN_PASS=x'
checkpoint_reject 'a command line' 'ETW_JOB=labtest' 'SMOKE_JOB=labtest' 'id > /dev/null'
checkpoint_reject 'ETW_JOB with a separator' 'ETW_JOB=../etw' 'SMOKE_JOB=labtest'
checkpoint_reject 'BATCH with a separator' 'ETW_JOB=labtest' 'SMOKE_JOB=labtest' 'BATCH=a/b'
checkpoint_reject 'SNAPSHOT out of domain' 'ETW_JOB=labtest' 'SMOKE_JOB=labtest' 'BATCH=labtest' 'SNAPSHOT=2'
checkpoint_reject 'SETTLE_SECONDS too large' 'ETW_JOB=labtest' 'SMOKE_JOB=labtest' 'BATCH=labtest' 'SETTLE_SECONDS=999'
checkpoint_reject 'a job it names does not exist' 'ETW_JOB=nosuch' 'SMOKE_JOB=labtest' 'BATCH=labtest'
rm -f "$SBLAB/jobs/checkpoint-reject.env"
if [ -z "$bad" ]; then
	pass "$CASE: an unknown key, a command line, a separator in either job name or in BATCH, an out-of-domain SNAPSHOT or SETTLE_SECONDS, and a missing job file each exit 2 with nothing launched"
else
	fail "$CASE: accepted:$bad"
fi

# 43. The tracked jobs/checkpoint-2x-D.env names jobs that exist and passes its own validation. It
#     is not RUN here (its capture is 150 s and its settle 10 s); what is pinned is that the four
#     names in it resolve, which is the failure that would otherwise surface on the lab host.
begin '43 the tracked jobs/checkpoint-2x-D.env resolves'
reasons=''
etw_job="$(sed -n 's/^ETW_JOB=//p' "$SBLAB/jobs/checkpoint-2x-D.env" | tail -n 1)"
smoke_job="$(sed -n 's/^SMOKE_JOB=//p' "$SBLAB/jobs/checkpoint-2x-D.env" | tail -n 1)"
[ -f "$SBLAB/jobs/etw-$etw_job.env" ] || reasons="$reasons etw-job-missing[$etw_job];"
[ -f "$SBLAB/jobs/smoke-$smoke_job.env" ] || reasons="$reasons smoke-job-missing[$smoke_job];"
export LABTEST_OPEN_EXEC=1
export LABTEST_PGREP_RC=0
mkdir -p "$SBRUNTIME" || exit 1
printf '[etw] in flight\n' > "$SBRUNTIME/etw.log"
run_lab "$SB/out.txt" "$SBLAB/checkpoint.sh" 2x-D
rc=$?
unset LABTEST_OPEN_EXEC LABTEST_PGREP_RC
# The overlap guard is the LAST thing before the first launch, so reaching it means every value in
# the file passed validation -- and it stops the run before a single window opens.
[ "$rc" -eq 3 ] || reasons="$reasons validation-rc=$rc;"
grep -qF 'TAG=2xD' "$SB/out.txt" || reasons="$reasons tags-not-resolved;"
[ "$(open_calls)" = '0' ] || reasons="$reasons opened-something;"
if [ -z "$reasons" ]; then
	pass "$CASE: the shipped checkpoint template validates, its ETW and smoke jobs both exist, and their TAGs are the ones the waits are built from"
else
	fail "$CASE:$reasons"
	note "$(cat "$SB/out.txt")"
fi

# 44. run-scenario.sh's checkpoint mode reaches checkpoint.sh and hands back its exit code, so a
#     caller can tell a refused checkpoint from a complete one.
begin '44 run-scenario.sh checkpoint <job>'
mkdir -p "$SBRUNTIME" || exit 1
printf '[etw] in flight\n' > "$SBRUNTIME/etw.log"
export LABTEST_PGREP_RC=0
run_lab "$SB/out.txt" "$SBLAB/run-scenario.sh" checkpoint labtest
rc=$?
unset LABTEST_PGREP_RC
if [ "$rc" -eq 3 ] && grep -qF 'an ETW capture is still in flight' "$SB/out.txt"; then
	pass "$CASE: the mode dispatches to checkpoint.sh and its exit code (3, the overlap refusal) reaches the caller"
else
	fail "$CASE: rc=$rc"
	note "$(cat "$SB/out.txt")"
fi

# 45. Across every case above the self-close branch was taken exactly once -- in case 27, which
#     declared it. Everywhere else TERM_PROGRAM was cleared (run-long trace, never reset).
begin '45 osascript is reached only where it was expected'
if [ ! -s "$LABTEST_REFUSED_TRACE" ]; then
	pass "$CASE: no unexpected osascript call across the whole run"
else
	fail "$CASE: $(sort "$LABTEST_REFUSED_TRACE" | uniq -c | tr '\n' ';')"
fi

# 46. Tracked-tree census: every run above wrote only under .build/. A wrapper that wrote its job
#     instance, its log or its evidence next to itself would be putting a run's parameters -- and on
#     the tray lane a host account name -- into git.
begin '46 tracked tree census'
if diff -q "$TRACKED_PRISTINE" <(snapshot_tracked) > /dev/null; then
	pass "$CASE: no case wrote into the tracked lab directory"
else
	fail "$CASE: tracked tree changed"
	diff "$TRACKED_PRISTINE" <(snapshot_tracked) | sed 's/^/        /'
fi

# ------------------------------------------------------------------------------------------
# Mutation proofs: the pins above must FAIL against a script with the guard removed.
# ------------------------------------------------------------------------------------------

# M1. Boundary gate bypassed (the refusal branch's condition -> `if false`): the refused scenario
#     must now walk all the way to the launcher -- i.e. case 1's pin bites.
begin 'M1 gate-bypass mutant'
MUTANT_GATE="$SBLAB/labtest-mutant-gate.command"
# shellcheck disable=SC2016  # the single quotes are deliberate: sed must see the literal `$`
if sed 's/if \[ "\$GATE_RC" -ne 0 \]; then/if false; then/' "$SBLAB/smoke-job.command" > "$MUTANT_GATE" \
	&& ! cmp -s "$MUTANT_GATE" "$SBLAB/smoke-job.command" && bash -n "$MUTANT_GATE"; then
	job_base
	run_smoke "$MUTANT_GATE" "$DENY_FILE"
	if [ "$(child_calls)" = '1' ] && ! grep -qF 'BOUNDARY-REFUSED' "$SMOKELOG"; then
		pass "$CASE: detected -- the refused scenario reaches the launcher (case 1 pins the gate)"
	else
		fail "$CASE: NOT detected -- case 1 would pass against a wrapper without the gate"
		note "launcher calls=$(child_calls) log: $(tr '\n' ';' < "$SMOKELOG")"
	fi
else
	fail "$CASE: could not build the mutant (the guard line moved?)"
fi

# M2. The key whitelist bypassed (the grammar's verdict -> always empty, i.e. "no bad line"): the
#     job file is then EXECUTED, and the line that reads WIN_PASS out of this shell writes the
#     witness file -- i.e. case 4's pin bites. This is the mutation that matters most here: the
#     wrapper holds the credential because its log mask needs it.
begin 'M2 key-whitelist mutant'
MUTANT_KEYS="$SBLAB/labtest-mutant-keys.command"
# shellcheck disable=SC2016  # sed must see the literal `$(`
if sed 's/^    BAD_LINE="\$(tr -d .*$/    BAD_LINE=""/' "$SBLAB/smoke-job.command" > "$MUTANT_KEYS" \
	&& ! cmp -s "$MUTANT_KEYS" "$SBLAB/smoke-job.command" && bash -n "$MUTANT_KEYS"; then
	job_base
	# shellcheck disable=SC2016  # the literal $WIN_PASS is the point
	# The exfiltration line comes FIRST, so what it reads is host.env's own value and not the
	# job's -- "the credential this shell holds left the process" is the statement worth making.
	job_override 'printf "%s" "$WIN_PASS" > "'"$SB"'/witness.txt"' 'WIN_PASS=labtest-override'
	run_smoke "$MUTANT_KEYS" ""
	if [ -f "$SB/witness.txt" ] && [ "$(cat "$SB/witness.txt")" = 'LABTEST-PLACEHOLDER-SECRET-3f9a' ]; then
		pass "$CASE: detected -- the job file's own command line ran and exfiltrated the credential this shell holds (case 4 pins the whitelist)"
	else
		fail "$CASE: NOT detected -- case 4 would pass against a wrapper that executes any job file"
		note "witness: $(cat "$SB/witness.txt" 2>/dev/null || printf '<absent>')"
	fi
	rm -f "$SB/witness.txt"
else
	fail "$CASE: could not build the mutant (the grammar check moved?)"
fi

# M3. The overlap guard removed (its condition -> `if false`): a checkpoint launched on top of a
#     live capture must now proceed -- i.e. case 35's pin bites.
begin 'M3 overlap-guard mutant'
MUTANT_OVERLAP="$SBLAB/labtest-mutant-overlap.sh"
if sed 's/^if cp_etw_capture_live; then$/if false; then/' "$SBLAB/checkpoint.sh" > "$MUTANT_OVERLAP" \
	&& ! cmp -s "$MUTANT_OVERLAP" "$SBLAB/checkpoint.sh" && bash -n "$MUTANT_OVERLAP"; then
	mkdir -p "$SBRUNTIME" || exit 1
	printf '[etw] etw capture tag=labtest\n' > "$SBRUNTIME/etw.log"
	export LABTEST_PGREP_RC=0
	export LABTEST_OPEN_EXEC=1
	export CHECKPOINT_TIMEOUT_ETW_OPEN=3
	export LABTEST_ETW_OPENS=0
	export LABTEST_ETW_DONES=0
	run_lab "$SB/out.txt" "$MUTANT_OVERLAP" labtest
	rc=$?
	unset LABTEST_PGREP_RC LABTEST_OPEN_EXEC CHECKPOINT_TIMEOUT_ETW_OPEN LABTEST_ETW_OPENS LABTEST_ETW_DONES
	if [ "$rc" -ne 3 ] && [ "$(open_calls)" != '0' ]; then
		pass "$CASE: detected -- the checkpoint launches a second capture on top of a live one (case 35 pins the guard)"
	else
		fail "$CASE: NOT detected -- case 35 would pass against a checkpoint without the guard"
		note "rc=$rc opens=$(open_calls)"
	fi
else
	fail "$CASE: could not build the mutant (the guard moved?)"
fi

# M4. The window closed BEFORE the DONE line is written (the two lines of smoke_finish swapped):
#     the osascript snapshot must now show a log that does not end in DONE and no per-TAG copy --
#     i.e. case 27's pin bites. Three sed expressions and a placeholder, because a two-expression
#     swap would rewrite the first line back over itself.
begin 'M4 close-before-DONE mutant'
MUTANT_ORDER="$SBLAB/labtest-mutant-order.command"
# shellcheck disable=SC2016  # sed must see the literal `$1`
if sed -e 's|^    smoke_log "DONE exit=\$1"$|    LABTEST_M4_PLACEHOLDER|' \
	-e 's|^    smoke_close_window$|    smoke_log "DONE exit=$1"|' \
	-e 's|^    LABTEST_M4_PLACEHOLDER$|    smoke_close_window|' \
	"$SBLAB/smoke-job.command" > "$MUTANT_ORDER" \
	&& ! cmp -s "$MUTANT_ORDER" "$SBLAB/smoke-job.command" && bash -n "$MUTANT_ORDER"; then
	OSASCRIPT_EXPECTED=1
	job_base
	run_smoke "$MUTANT_ORDER" "" 0 0 'Apple_Terminal'
	snapshot="$(grep '^close-requested' "$LABTEST_TRACE" | tail -n 1)"
	if [ -z "$snapshot" ]; then
		fail "$CASE: the mutant never asked for the window to be closed"
	elif [ "$snapshot" != 'close-requested last-log-line=[DONE exit=0] tag-log=yes' ]; then
		pass "$CASE: detected -- at close-request time the state was [$snapshot] (case 27 pins the order)"
	else
		fail "$CASE: NOT detected -- case 27 would pass against a wrapper that closes the window first"
	fi
	OSASCRIPT_EXPECTED=0
else
	fail "$CASE: could not build the mutant (smoke_finish moved?)"
fi

# The mutants deliberately reach the osascript shim with OSASCRIPT_EXPECTED set, so the run-long
# refuse trace is checked BEFORE them (case 45) rather than after.

# M5. The guard's pid branch removed (its condition -> `if false`), so it always falls back to the
#     process table: a checkpoint whose etw.log names a DEAD capture must now be refused because
#     pgrep matched something -- i.e. case 36b's pin bites. This is the mutation that says the pid
#     line is READ, rather than merely written and ignored.
begin 'M5 pid-guard mutant'
MUTANT_PID="$SBLAB/labtest-mutant-pidguard.sh"
# shellcheck disable=SC2016  # sed must see the literal $etw_pid
if sed 's|^    if \[ -n "$etw_pid" \]; then$|    if false; then|' "$SBLAB/checkpoint.sh" > "$MUTANT_PID" \
	&& ! cmp -s "$MUTANT_PID" "$SBLAB/checkpoint.sh" && bash -n "$MUTANT_PID"; then
	mkdir -p "$SBRUNTIME" || exit 1
	sleep 0 &
	M5_DEAD_PID=$!
	wait "$M5_DEAD_PID" 2>/dev/null
	{
		printf '[etw] etw capture tag=labtest duration=5s providers=1 start=labtest\n'
		printf '[etw] pid=%s\n' "$M5_DEAD_PID"
	} > "$SBRUNTIME/etw.log"
	export LABTEST_PGREP_RC=0
	export LABTEST_OPEN_EXEC=1
	export LABTEST_ETW_OPENS=0
	export LABTEST_ETW_DONES=0
	export CHECKPOINT_TIMEOUT_ETW_OPEN=3
	run_lab "$SB/out.txt" "$MUTANT_PID" labtest
	rc=$?
	unset LABTEST_PGREP_RC LABTEST_OPEN_EXEC LABTEST_ETW_OPENS LABTEST_ETW_DONES CHECKPOINT_TIMEOUT_ETW_OPEN
	if [ "$rc" -eq 3 ] && [ "$(pgrep_calls)" != '0' ]; then
		pass "$CASE: detected -- with the pid branch gone the guard refuses on a dead capture because the process table matched (case 36b pins which signal wins)"
	else
		fail "$CASE: NOT detected -- case 36b would pass against a guard that ignores the pid line"
		note "rc=$rc pgreps=$(pgrep_calls) $(tail -n 5 "$SB/out.txt")"
	fi
else
	fail "$CASE: could not build the mutant (the pid branch moved?)"
fi

# M6. The manifest's source directory put back to the TEMPLATE's batch (`${SMOKE_BATCH:-$BATCH}`,
#     which is what it used to be): with the two batches disagreeing, the checkpoint must now report
#     the run's own log missing and copy the stale one over it -- i.e. case 34b's pin bites. The
#     mutant is the previous line verbatim, so what this proves is that the fix is load-bearing and
#     not a cosmetic rewrite.
begin 'M6 template-batch mutant'
MUTANT_BATCH="$SBLAB/labtest-mutant-batch.sh"
# shellcheck disable=SC2016  # sed must see the literals $EVIDENCE, $SMOKE_BATCH and $BATCH
if sed 's|^WS_LOG_SRC="$EVIDENCE/window-smoke-$SMOKE_TAG.log"$|WS_LOG_SRC="$REPO_ROOT/.build/evidence/${SMOKE_BATCH:-$BATCH}/window-smoke-$SMOKE_TAG.log"|' \
	"$SBLAB/checkpoint.sh" > "$MUTANT_BATCH" \
	&& ! cmp -s "$MUTANT_BATCH" "$SBLAB/checkpoint.sh" && bash -n "$MUTANT_BATCH"; then
	STALE_DIR="$SBEVIDENCE/template-batch"
	mkdir -p "$STALE_DIR" || exit 1
	printf 'STALE-FROM-A-PREVIOUS-RUN\n' > "$STALE_DIR/window-smoke-labtest.log" || exit 1
	export LABTEST_OPEN_EXEC=1
	run_lab "$SB/out.txt" "$MUTANT_BATCH" otherbatch dated-20260910
	unset LABTEST_OPEN_EXEC
	GATHERED="$SBEVIDENCE/dated-20260910/window-smoke-labtest.log"
	if grep -qF 'STALE-FROM-A-PREVIOUS-RUN' "$GATHERED" 2>/dev/null; then
		pass "$CASE: detected -- the previous run's log was copied over this run's under the new batch name (case 34b pins the source directory)"
	else
		fail "$CASE: NOT detected -- case 34b would pass against a manifest reading the template's batch"
		note "gathered: $(head -n 2 "$GATHERED" 2>/dev/null | tr '\n' ';')"
	fi
else
	fail "$CASE: could not build the mutant (WS_LOG_SRC moved?)"
fi

# M7. The manifest's missing-artefact COUNT removed (the increment -> `:`), which is exactly the
#     state gather() was in before this fold: it still prints MISSING, nobody adds it up, and the
#     run exits 0 saying complete -- i.e. case 34c's pin bites. Printing a warning nobody reads is
#     the failure mode this distinguishes from having no warning at all.
begin 'M7 missing-count mutant'
MUTANT_COUNT="$SBLAB/labtest-mutant-count.sh"
# shellcheck disable=SC2016  # sed must see the literal $((MISSING + 1))
if sed 's|^        MISSING=\$((MISSING + 1))$|        :|' "$SBLAB/checkpoint.sh" > "$MUTANT_COUNT" \
	&& ! cmp -s "$MUTANT_COUNT" "$SBLAB/checkpoint.sh" && bash -n "$MUTANT_COUNT"; then
	export LABTEST_OPEN_EXEC=1
	export LABTEST_CHILD_NO_WS_LOG=1
	run_lab "$SB/out.txt" "$MUTANT_COUNT" labtest
	rc=$?
	unset LABTEST_OPEN_EXEC LABTEST_CHILD_NO_WS_LOG
	if [ "$rc" -eq 0 ] && grep -qF 'checkpoint labtest complete' "$SB/out.txt" \
		&& grep -qF 'window-smoke-labtest.log  MISSING' "$SB/out.txt"; then
		pass "$CASE: detected -- the manifest prints MISSING and the checkpoint still exits 0 saying complete (case 34c pins the count)"
	else
		fail "$CASE: NOT detected -- case 34c would pass against a checkpoint that never counts what it could not gather"
		note "rc=$rc $(tail -n 4 "$SB/out.txt")"
	fi
else
	fail "$CASE: could not build the mutant (the missing count moved?)"
fi

# M8. The separating newline removed from the batch override (-> `:`), which is the append the mode
#     used to do: a template with no final newline then glues BATCH= onto its last value -- i.e.
#     case 29b's pin bites. The mutant leaves the REBUILD in place and takes only the newline, so
#     what it isolates is the guarantee rather than the refactor.
begin 'M8 override-newline mutant'
MUTANT_NL="$SBLAB/labtest-mutant-newline.sh"
# shellcheck disable=SC2016  # sed must see the literal \n
if sed "s|^            printf '\\\\n'\$|            :|" "$SBLAB/run-scenario.sh" > "$MUTANT_NL" \
	&& ! cmp -s "$MUTANT_NL" "$SBLAB/run-scenario.sh" && bash -n "$MUTANT_NL"; then
	run_lab "$SB/out.txt" "$MUTANT_NL" smoke nonl dated-99
	glued="$(tail -n 1 "$JOB")"
	if [ "$glued" = 'MOVE_TARGET=abcBATCH=dated-99' ]; then
		pass "$CASE: detected -- the override was glued onto the template's last value as [$glued] (case 29b pins the newline)"
	else
		fail "$CASE: NOT detected -- case 29b would pass against a mode that assumes the template ends in a newline"
		note "last line: [$glued]"
	fi
else
	fail "$CASE: could not build the mutant (the newline guarantee moved?)"
fi

# Every case must have reported: a case that neither passed nor failed would otherwise vanish from
# the tally with exit 0. Placed after the LAST case on purpose.
EXPECTED_CASES=63
if [ $((PASSES + FAILURES)) -ne "$EXPECTED_CASES" ]; then
	fail "case tally: $((PASSES + FAILURES)) cases reported, expected $EXPECTED_CASES -- a case produced no verdict"
fi
printf '\n%d passed, %d failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
