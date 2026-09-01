#!/usr/bin/env bash
# Offline test suite for Scripts/lab/relay.command -- the one-shot RemoteApp relay that
# Terminal.app runs against the owner's lab host. Its sibling, test-run-matrix-offline.sh,
# deliberately does NOT copy relay.command into its sandbox (a shim of `open` stands in for
# the whole Terminal hop), so until this file existed the relay's OWN logic -- the fail-closed
# boundary refusal, the job.env contract, the argv it hands xfreerdp, the TIMEOUT kill, the
# DONE line every caller polls on, the log-truncation-at-start -- had no offline coverage at
# all and rotted unnoticed by construction. This suite drives the REAL relay.command, with the
# REAL jobs/*.env as inputs where a job is involved.
#
# Safe in CI, by construction rather than by promise:
#   1. `xfreerdp`, `osascript` and `nc` are PATH-shimmed, and the suite ASSERTS before the first
#      case that the shim is what PATH resolves each of them to. The xfreerdp shim records its
#      argv and either exits at once or `exec`s a sleep (so the relay's TIMEOUT kill has a real
#      process to kill and killing it leaves no orphan). It opens no socket.
#   2. HOME is redirected into the sandbox. Its host.env carries an RFC 5737 documentation
#      address and placeholder account strings (never a real host, never a real credential).
#   3. relay.command is copied into a sandbox tree at the same depth as the real one, so its
#      own `$LAB_DIR/../..` derivation lands REPO_ROOT (and therefore .build/lab-runtime,
#      job.env, relay.log and the share) inside the sandbox. The real runtime is never touched.
#   4. TERM_PROGRAM is cleared, so the relay's Terminal self-close branch is never taken; the
#      osascript/nc shims exit 97 and record the call in a trace that is NOT reset between
#      cases, so the "never reached" assertion at the end covers the whole run.
#   5. The boundary gate's address check is pure arithmetic on the literal (Scripts/lib.sh
#      parses an IP literal directly; no DNS is ever consulted for one).
#
# Each case starts with `begin`, which resets the per-case trace and the sandbox log, so no
# case depends on what the previous one left behind. Two mutation proofs (M1, M2) copy the
# relay with one guard disabled and require the case that claims to pin it to FAIL against
# the mutant. A pin that would also pass against the broken code pins nothing.
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

SB="$(mktemp -d "${TMPDIR:-/tmp}/macdows-relay-offline.XXXXXX")" || exit 1
# Normalised, because the relay derives its own paths with `cd … && pwd` and this suite compares
# them as strings: a TMPDIR ending in `/` (macOS's does) would otherwise leave a `//` in $SB that
# the relay's argv does not carry, and a case would fail on a path spelling, not on behaviour.
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

SBROOT="$SB/root"
SBLAB="$SBROOT/Scripts/lab"
SBRUNTIME="$SBROOT/.build/lab-runtime"
SBHOME="$SB/home"
LOG="$SBRUNTIME/relay.log"
# Per-case trace of xfreerdp invocations (reset by `begin`) and a run-long trace of the
# shims that must never be reached (never reset).
export LABTEST_TRACE="$SB/trace.txt"
export LABTEST_REFUSED_TRACE="$SB/refused-trace.txt"
# Run-long ledger of every xfreerdp-shim pid (never reset; the orphan check at the end reads it
# -- reading the per-case trace there would read a file `begin` had just emptied, review r3 B2).
export LABTEST_PID_LEDGER="$SB/pid-ledger.txt"
: > "$LABTEST_REFUSED_TRACE"
: > "$LABTEST_PID_LEDGER"

mkdir -p "$SBLAB" "$SBRUNTIME" "$SBHOME/.config/macdows" "$SB/bin" || exit 1
cp "$LAB/relay.command" "$SBLAB/relay.command" || exit 1
cp "$REPO_ROOT/Scripts/lib.sh" "$SBROOT/Scripts/lib.sh" || exit 1

# RFC 5737 TEST-NET-1 address and placeholder strings: never a real host, never a real
# credential. The password value is chosen to be greppable, because one case asserts that it
# never reaches relay.log.
cat > "$SBHOME/.config/macdows/host.env" <<'HOSTENV' || exit 1
WIN_HOST=192.0.2.10
WIN_USER=labtest-placeholder
WIN_PASS=LABTEST-PLACEHOLDER-SECRET-3f9a
HOSTENV
# The DEFAULT boundary file location (what the relay resolves when MACDOWS_LAB_BOUNDARY_FILE is
# unset) allows the placeholder segment; the deny file lives elsewhere and is injected by path.
ALLOW_FILE="$SBHOME/.config/macdows/lab-boundary.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="192.0.2.0/24"\n' > "$ALLOW_FILE" || exit 1
DENY_FILE="$SB/deny-boundary.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="198.51.100.0/24"\n' > "$DENY_FILE" || exit 1

# Census of the sandbox's TRACKED tree, taken once after construction: a run must write
# nothing there (only under .build/lab-runtime). Names and contents both count. The mutation
# proofs write their mutant copies into this directory on purpose (the relay derives REPO_ROOT
# from its own location), hence the exclusion; `labtest-mutant-*` is a namespace no shipping
# script produces or reads, so excluding it cannot mask a write by the code under test.
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

# -- PATH shims ------------------------------------------------------------------------------

cat > "$SB/bin/xfreerdp" <<'SHIM_XFREERDP' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM: records argv and either exits at once or `exec`s a sleep so the relay's
# TIMEOUT kill has a real process to kill. `exec` matters: it makes THIS pid the sleeping
# process, so the pid the relay kills (and the pid this suite reads from the trace) is the
# sleep itself -- no orphaned child outlives the case. Opens nothing.
set -u
{
	printf 'xfreerdp pid=%s' "$$"
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
} >> "$LABTEST_TRACE"
printf '%s\n' "$$" >> "$LABTEST_PID_LEDGER"
case "${LABTEST_XFREERDP_MODE:-exit0}" in
sleep) exec sleep 30 ;;
exit1) exit 1 ;;
*) exit 0 ;;
esac
SHIM_XFREERDP

for tool in osascript nc; do
	cat > "$SB/bin/$tool" <<SHIM_REFUSE || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM: must never be reached. Records the call (run-long trace) and refuses.
printf '$tool:unexpected-call\n' >> "\$LABTEST_REFUSED_TRACE"
exit 97
SHIM_REFUSE
done
chmod +x "$SB"/bin/* || exit 1
for shim in "$SB"/bin/*; do
	if ! bash -n "$shim"; then printf 'shim does not parse: %s\n' "$shim"; exit 1; fi
done
# The load-bearing safety assertion: with the sandbox PATH in force, each shimmed name MUST
# resolve to the shim -- otherwise a case would run the maintainer's real xfreerdp against
# the placeholder address. Checked before any case runs; a miss aborts the whole suite.
for tool in xfreerdp osascript nc; do
	resolved="$(PATH="$SB/bin:$PATH" command -v "$tool" || true)"
	if [ "$resolved" != "$SB/bin/$tool" ]; then
		printf 'ABORT: %s resolves to %s, not the shim\n' "$tool" "${resolved:-<nothing>}"
		exit 1
	fi
done

# Positive controls (review r2 I2 / r3 B2): prove both run-long recorders work by hitting each
# shim once through the same `env -i` the relay gets, then clear. An empty refused trace at the
# end then means "not reached", and an orphan check over the pid ledger has a ledger to read.
env -i LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" PATH="$SB/bin:$PATH" osascript -e 'x' >/dev/null 2>&1
if ! grep -qF 'osascript:unexpected-call' "$LABTEST_REFUSED_TRACE"; then
	printf 'ABORT: the refused-shim trace did not record a deliberate call\n'; exit 1
fi
: > "$LABTEST_REFUSED_TRACE"
env -i LABTEST_TRACE="$LABTEST_TRACE" LABTEST_PID_LEDGER="$LABTEST_PID_LEDGER" LABTEST_XFREERDP_MODE=exit0 PATH="$SB/bin:$PATH" xfreerdp /probe >/dev/null 2>&1
if ! grep -qE '^[0-9]+$' "$LABTEST_PID_LEDGER"; then
	printf 'ABORT: the pid ledger did not record a deliberate shim run\n'; exit 1
fi
: > "$LABTEST_PID_LEDGER"
: > "$LABTEST_TRACE"

# -- Helpers ---------------------------------------------------------------------------------

begin() { # <case label>
	CASE="$1"
	: > "$LABTEST_TRACE"
	: > "$LOG"
	rm -f "$SBRUNTIME/job.env"
}
assert_has() { # <file> <fixed string>
	if grep -qF -- "$2" "$1"; then return 0; fi
	fail "$CASE: expected [$2] in $(basename "$1")"; note "$(cat "$1")"; return 1
}
assert_lacks() { # <file> <fixed string>
	if ! grep -qF -- "$2" "$1"; then return 0; fi
	fail "$CASE: [$2] must not appear in $(basename "$1")"; note "$(cat "$1")"; return 1
}
assert_eq() { # <actual> <expected> <what>
	if [ "$1" = "$2" ]; then return 0; fi
	fail "$CASE: $3 -- expected [$2], got [$1]"; return 1
}
# Each argv element is its own assertion with its own `fail` (review r2 B1: an `else` that only
# noted meant a missing element made the case vanish instead of failing).
assert_argv_has() { # <argv line> <element>
	if [[ "$1" == *"[$2]"* ]]; then return 0; fi
	fail "$CASE: argv lacks [$2]"; note "argv: $1"; return 1
}
last_line() { tail -n 1 "$LOG" 2>/dev/null; }
done_lines() { grep -c '^DONE exit=' "$LOG" 2>/dev/null || true; }
xfreerdp_calls() { grep -c '^xfreerdp pid=' "$LABTEST_TRACE" 2>/dev/null || true; }
xfreerdp_argv() { grep '^xfreerdp pid=' "$LABTEST_TRACE" | head -n 1; }
# Every pid the shim recorded this case; with `exec sleep` that IS the sleeping process.
kill_recorded_shims() {
	sed -n 's/^xfreerdp pid=\([0-9]*\).*/\1/p' "$LABTEST_TRACE" | while IFS= read -r p; do
		kill "$p" 2>/dev/null || true
	done
}

write_job() { # <PROGRAM> [CMDARGS] [TIMEOUT]
	{
		printf 'PROGRAM=%q\n' "$1"
		if [ -n "${2:-}" ]; then printf 'CMDARGS=%q\n' "$2"; fi
		if [ -n "${3:-}" ]; then printf 'TIMEOUT=%q\n' "$3"; fi
	} > "$SBRUNTIME/job.env"
}

# Runs the relay (or a mutant copy) with the sandbox environment. Everything the relay reads
# comes from HOME/PATH/job.env; TERM_PROGRAM is cleared so the Terminal self-close branch is
# not taken. <boundary-file> empty = MACDOWS_LAB_BOUNDARY_FILE is passed EMPTY, which lib.sh's
# `${MACDOWS_LAB_BOUNDARY_FILE:-…}` treats exactly like unset: the relay resolves the DEFAULT
# path under the sandbox HOME, as it does live. (Passed as a plain variable, not an array --
# `"${arr[@]}"` on an empty array is an unbound-variable error under bash 3.2 + `set -u`, the
# /bin/bash this suite must also run under.)
run_relay() { # <relay-path> <boundary-file|""> [xfreerdp-mode]
	env -i \
		HOME="$SBHOME" \
		PATH="$SB/bin:$PATH" \
		TERM_PROGRAM= \
		LABTEST_TRACE="$LABTEST_TRACE" \
		LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" \
		LABTEST_PID_LEDGER="$LABTEST_PID_LEDGER" \
		LABTEST_XFREERDP_MODE="${3:-exit0}" \
		MACDOWS_LAB_BOUNDARY_FILE="$2" \
		bash "$1" >/dev/null 2>&1
}

# Runs the relay with a watchdog: kills it if it has not exited within <budget> seconds.
# Prints the elapsed seconds; returns 0 if the relay exited by itself. Budgets are chosen
# against the shim's 30s sleep: a relay that does NOT kill its xfreerdp blocks on `wait` for
# the full 30s, so any budget well under 30 separates "killed it" from "waited for it".
run_relay_bounded() { # <relay-path> <boundary-file|""> <xfreerdp-mode> <budget>
	local start end pid waited=0 self_exited=0
	start=$(date +%s)
	env -i \
		HOME="$SBHOME" \
		PATH="$SB/bin:$PATH" \
		TERM_PROGRAM= \
		LABTEST_TRACE="$LABTEST_TRACE" \
		LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" \
		LABTEST_PID_LEDGER="$LABTEST_PID_LEDGER" \
		LABTEST_XFREERDP_MODE="$3" \
		MACDOWS_LAB_BOUNDARY_FILE="$2" \
		bash "$1" >/dev/null 2>&1 &
	pid=$!
	while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$4" ]; do
		sleep 1
		waited=$((waited + 1))
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
	else
		wait "$pid" 2>/dev/null
		self_exited=1
	fi
	end=$(date +%s)
	printf '%s' "$((end - start))"
	[ "$self_exited" -eq 1 ]
}

# ------------------------------------------------------------------------------------------
# Cases
# ------------------------------------------------------------------------------------------

printf 'test-relay-offline.sh -- driving %s\n' "$LAB/relay.command"

# 1. Boundary refused (host outside the allowed segments): no connection attempted, the log
#    names the refusal, the DONE line carries the refusal code, xfreerdp is never invoked.
#    (The gate's own REFUSED line names the target host by lib.sh's design; the relay adds
#    nothing to it.)
begin '1 boundary refused'
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" "$DENY_FILE"
if assert_has "$LOG" 'BOUNDARY-REFUSED' && assert_eq "$(last_line)" 'DONE exit=78' 'last log line' \
	&& assert_eq "$(xfreerdp_calls)" '0' 'xfreerdp invocations' && assert_lacks "$LOG" 'LABTEST-PLACEHOLDER-SECRET-3f9a'; then
	pass "$CASE: BOUNDARY-REFUSED logged, DONE exit=78, xfreerdp never invoked, no credential in the log"
fi

# 2. Boundary file missing at the DEFAULT location (HOME has no lab-boundary.env): fail-closed,
#    same shape as 1. Exercises the relay's default-path resolution, not an injected path.
begin '2 boundary file missing (default path)'
mv "$ALLOW_FILE" "$ALLOW_FILE.away" || exit 1
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" ""
mv "$ALLOW_FILE.away" "$ALLOW_FILE" || exit 1
if assert_has "$LOG" 'BOUNDARY-REFUSED' && assert_eq "$(last_line)" 'DONE exit=78' 'last log line' \
	&& assert_eq "$(xfreerdp_calls)" '0' 'xfreerdp invocations'; then
	pass "$CASE: fail-closed refusal through the default boundary path, xfreerdp never invoked"
fi

# 3. Allowed host through the DEFAULT boundary path, xfreerdp exits 0: exactly one invocation,
#    the argv carries the job's program spec, the runtime share and the codec flag; DONE exit=0;
#    the default 25s timeout is what the relay logs.
begin '3 allowed path'
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" "" exit0
argv="$(xfreerdp_argv)"
if assert_eq "$(xfreerdp_calls)" '1' 'xfreerdp invocations' && assert_eq "$(last_line)" 'DONE exit=0' 'last log line' \
	&& assert_argv_has "$argv" '/v:192.0.2.10' && assert_argv_has "$argv" '/u:labtest-placeholder' \
	&& assert_argv_has "$argv" '/app:program:C:\Windows\System32\notepad.exe' \
	&& assert_argv_has "$argv" "/drive:lab,$SBRUNTIME/share" && assert_argv_has "$argv" '/gfx:AVC420' \
	&& assert_has "$LOG" '[relay] program=C:\Windows\System32\notepad.exe timeout=25s'; then
	pass "$CASE: one xfreerdp invocation with /v /u /app:program /drive:lab /gfx:AVC420; DONE exit=0; default timeout 25s logged"
fi

# 4. On the allowed path the relay echoes program and timeout only: the credential, the account
#    and the host address were all in its environment and none may reach relay.log. (The
#    refused path is different by design -- the gate names the host; case 1 covers its
#    credential half.)
begin '4 allowed path log carries no environment values'
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" "" exit0
if assert_lacks "$LOG" 'LABTEST-PLACEHOLDER-SECRET-3f9a' && assert_lacks "$LOG" '192.0.2.10' && assert_lacks "$LOG" 'labtest-placeholder'; then
	pass "$CASE: neither the password, the account nor the host address reaches relay.log"
fi

# 5. Every TRACKED job (jobs/*.env) drives the relay through the shipped path: the /app argument
#    is exactly `program:<PROGRAM>` plus `,cmd:<CMDARGS>` when the job has one, as ONE argv
#    element -- including the `||<alias>` program form five of the seven jobs use.
begin '5 tracked jobs'
jobs_ok=0; jobs_total=0
for jobfile in "$LAB"/jobs/*.env; do
	jobs_total=$((jobs_total + 1))
	: > "$LABTEST_TRACE"
	cp "$jobfile" "$SBRUNTIME/job.env" || exit 1
	expected="$(
		# shellcheck source=/dev/null
		. "$jobfile" >/dev/null 2>&1
		spec="/app:program:${PROGRAM}"
		if [ -n "${CMDARGS:-}" ]; then spec="${spec},cmd:${CMDARGS}"; fi
		printf '%s' "$spec"
	)"
	run_relay "$SBLAB/relay.command" "" exit0
	argv="$(xfreerdp_argv)"
	if [ "$(xfreerdp_calls)" = "1" ] && [[ "$argv" == *"[$expected]"* ]] && [ "$(last_line)" = "DONE exit=0" ]; then
		jobs_ok=$((jobs_ok + 1))
	else
		jobs_failed="${jobs_failed:-}$(basename "$jobfile") "
		note "$(basename "$jobfile"): expected [$expected] in argv: $argv (last line: $(last_line))"
	fi
done
# One verdict for the case (the tally counts verdicts); the failing jobs are named in it.
if [ "$jobs_total" -ge 7 ] && [ "$jobs_ok" -eq "$jobs_total" ]; then
	pass "$CASE: all $jobs_total tracked jobs/*.env reach xfreerdp with /app:program:<PROGRAM>[,cmd:<CMDARGS>] as one argv element (incl. the ||alias form)"
else
	fail "$CASE: $jobs_ok of $jobs_total tracked jobs produced the expected /app argument (failed: ${jobs_failed:-none}; total<7 means jobs/ shrank)"
fi

# 6. xfreerdp's own failure is not the relay's: the relay still writes DONE exit=0 (its
#    contract is "the run happened"; the job's verdict lives in the share output).
begin '6 xfreerdp exit 1'
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" "" exit1
if assert_eq "$(last_line)" 'DONE exit=0' 'last log line' && assert_has "$LOG" '[relay] xfreerdp exited'; then
	pass "$CASE: a non-zero xfreerdp exit still yields DONE exit=0 with \"xfreerdp exited\" logged"
fi

# 7. TIMEOUT kill: the shim sleeps 30s, the job says TIMEOUT=1 -- the relay must kill it,
#    log the timeout and write DONE well inside the shim's sleep. Budget 15s: the relay's
#    poll is 1s-granular and the observed exit is ~2s, while a relay that failed to kill
#    would sit on `wait` for the full 30s; 8s is the pass bound on the elapsed time.
begin '7 TIMEOUT kill'
write_job 'C:\Windows\System32\notepad.exe' '' 1
elapsed="$(run_relay_bounded "$SBLAB/relay.command" "" sleep 15)"; self_exited=$?
xpid="$(sed -n 's/^xfreerdp pid=\([0-9]*\).*/\1/p' "$LABTEST_TRACE" | head -n 1)"
alive=0
if [ -n "$xpid" ] && kill -0 "$xpid" 2>/dev/null; then alive=1; fi
kill_recorded_shims
# One verdict: collect every reason first, then pass or fail exactly once.
reasons=''
[ "$self_exited" -eq 0 ] || reasons="$reasons relay-did-not-exit-by-itself;"
[ "$elapsed" -le 8 ] || reasons="$reasons elapsed=${elapsed}s>8;"
[ "$alive" -eq 0 ] || reasons="$reasons shim-still-alive;"
grep -qF 'timeout reached -- closing connection' "$LOG" || reasons="$reasons no-timeout-line;"
[ "$(last_line)" = "DONE exit=0" ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: TIMEOUT=1 kills a 30s xfreerdp -- timeout logged, DONE written in ${elapsed}s, the killed pid is gone"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 8. The log is truncated at startup: two consecutive runs leave exactly one DONE line.
begin '8 log truncation'
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" "" exit0
run_relay "$SBLAB/relay.command" "" exit0
if assert_eq "$(done_lines)" '1' 'DONE lines after two runs'; then
	pass "$CASE: relay.log is truncated at startup (exactly one DONE line after two runs)"
fi

# 9. job.env missing: the relay must still report -- a DONE line with a distinct sysexits code
#    (66 EX_NOINPUT) and a named reason -- rather than die on `set -u` and leave the caller to
#    its own timeout.
begin '9 job.env missing'
run_relay "$SBLAB/relay.command" "" exit0
if assert_has "$LOG" 'JOB-ENV-MISSING' && assert_eq "$(last_line)" 'DONE exit=66' 'last log line' \
	&& assert_eq "$(xfreerdp_calls)" '0' 'xfreerdp invocations'; then
	pass "$CASE: JOB-ENV-MISSING logged, DONE exit=66, xfreerdp never invoked"
fi

# 10. job.env present but without PROGRAM: same contract, its own reason and code (65 EX_DATAERR).
begin '10 job.env without PROGRAM'
printf 'TIMEOUT=5\n' > "$SBRUNTIME/job.env"
run_relay "$SBLAB/relay.command" "" exit0
if assert_has "$LOG" 'JOB-ENV-INVALID' && assert_eq "$(last_line)" 'DONE exit=65' 'last log line' \
	&& assert_eq "$(xfreerdp_calls)" '0' 'xfreerdp invocations'; then
	pass "$CASE: JOB-ENV-INVALID logged, DONE exit=65, xfreerdp never invoked"
fi

# 10b. job.env cannot bypass the boundary gate: a job.env that redefines
#      crdp_assert_lab_boundary must still be refused, because the relay sources job.env only
#      AFTER the gate has passed (review r2 B2 -- the first draft of the job.env guard sourced it
#      before the gate and this exact file walked straight through).
begin '10b job.env cannot redefine the gate'
printf 'crdp_assert_lab_boundary() { return 0; }\nPROGRAM=%q\n' 'C:\Windows\System32\notepad.exe' > "$SBRUNTIME/job.env"
run_relay "$SBLAB/relay.command" "$DENY_FILE" exit0
if assert_has "$LOG" 'BOUNDARY-REFUSED' && assert_eq "$(last_line)" 'DONE exit=78' 'last log line' \
	&& assert_eq "$(xfreerdp_calls)" '0' 'xfreerdp invocations'; then
	pass "$CASE: a job.env redefining crdp_assert_lab_boundary is still refused (job.env is sourced after the gate)"
fi

# 10d. TIMEOUT that is not a positive integer: refused as JOB-ENV-INVALID (65) -- before this the
#      poll loop's `-lt` failed, the connection was torn down at once and the run still reported
#      DONE exit=0 (review r4 I1).
begin '10d job.env TIMEOUT not a positive integer'
write_job 'C:\Windows\System32\notepad.exe' '' 'abc'
run_relay "$SBLAB/relay.command" "" exit0
if assert_has "$LOG" 'JOB-ENV-INVALID' && assert_has "$LOG" 'TIMEOUT is not a positive integer' \
	&& assert_eq "$(last_line)" 'DONE exit=65' 'last log line' && assert_eq "$(xfreerdp_calls)" '0' 'xfreerdp invocations'; then
	pass "$CASE: JOB-ENV-INVALID (TIMEOUT) logged, DONE exit=65, xfreerdp never invoked"
fi

# 10c. job.env cannot redirect the connection either: overriding WIN_HOST/WIN_USER/WIN_PASS/SHARE
#      (and the gate function) in job.env must change nothing about the argv -- the relay reads
#      job.env in a subshell and takes only PROGRAM/CMDARGS/TIMEOUT out (review r3 B1: with a plain
#      `source`, the gate approved one host and xfreerdp dialled another).
begin '10c job.env cannot redirect the connection'
{
	printf 'PROGRAM=%q\n' 'C:\Windows\System32\notepad.exe'
	printf 'WIN_HOST=198.51.100.7\nWIN_USER=intruder\nWIN_PASS=stolen\nSHARE=/etc\n'
	printf 'crdp_assert_lab_boundary() { return 0; }\n'
} > "$SBRUNTIME/job.env"
run_relay "$SBLAB/relay.command" "" exit0
argv="$(xfreerdp_argv)"
if assert_eq "$(xfreerdp_calls)" '1' 'xfreerdp invocations' \
	&& assert_argv_has "$argv" '/v:192.0.2.10' && assert_argv_has "$argv" '/u:labtest-placeholder' \
	&& assert_argv_has "$argv" "/drive:lab,$SBRUNTIME/share" && assert_lacks "$LABTEST_TRACE" '198.51.100.7' \
	&& assert_lacks "$LABTEST_TRACE" '/etc]' && assert_argv_has "$argv" '/app:program:C:\Windows\System32\notepad.exe'; then
	pass "$CASE: WIN_HOST/WIN_USER/WIN_PASS/SHARE overrides in job.env never reach the argv (subshell read, three keys only)"
fi

# 11. Across EVERY case above the refuse shims were never reached: the Terminal self-close
#     branch was not taken and no socket helper was invoked (run-long trace, never reset).
begin '11 refuse shims never reached'
if [ ! -s "$LABTEST_REFUSED_TRACE" ]; then
	pass "$CASE: osascript/nc shims recorded no call across the whole run (TERM_PROGRAM cleared; no socket helper invoked)"
else
	fail "$CASE: $(sort "$LABTEST_REFUSED_TRACE" | uniq -c | tr '\n' ';')"
fi

# 12. Tracked-tree census: every run above wrote only under .build/lab-runtime.
begin '12 tracked tree census'
if diff -q "$TRACKED_PRISTINE" <(snapshot_tracked) >/dev/null; then
	pass "$CASE: no case wrote into the tracked lab directory"
else
	fail "$CASE: tracked tree changed"; diff "$TRACKED_PRISTINE" <(snapshot_tracked) | sed 's/^/        /'
fi

# ------------------------------------------------------------------------------------------
# Mutation proofs: the pins above must FAIL against a relay with the guard removed.
# ------------------------------------------------------------------------------------------

# M1. Boundary gate bypassed (`if ! crdp_assert_lab_boundary` -> `if false`): the refused
#     scenario must now invoke xfreerdp, i.e. case 1's pin bites.
begin 'M1 gate-bypass mutant'
MUTANT_GATE="$SBLAB/labtest-mutant-gate.command"
# shellcheck disable=SC2016  # the single quotes are deliberate: sed must see the literal `$`
if sed 's/if ! crdp_assert_lab_boundary "\${WIN_HOST:-}"; then/if false; then/' "$SBLAB/relay.command" > "$MUTANT_GATE" \
	&& ! cmp -s "$MUTANT_GATE" "$SBLAB/relay.command" && bash -n "$MUTANT_GATE"; then
	write_job 'C:\Windows\System32\notepad.exe'
	run_relay "$MUTANT_GATE" "$DENY_FILE" exit0
	if [ "$(xfreerdp_calls)" = "1" ] && ! grep -qF 'BOUNDARY-REFUSED' "$LOG"; then
		pass "$CASE: detected -- the refused scenario invokes xfreerdp (case 1 pins the gate)"
	else
		fail "$CASE: NOT detected -- case 1 would pass against a relay without the gate"
	fi
else
	fail "$CASE: could not build the mutant (the guard line moved?)"
fi

# M2. TIMEOUT kill removed (`kill "$XPID"` -> `:`): the mutant still `wait`s for xfreerdp,
#     so with a 30s shim and TIMEOUT=1 it cannot write DONE inside a 4s watchdog (26s of
#     margin against the sleep) -- i.e. case 7 pins the kill.
begin 'M2 kill-removed mutant'
MUTANT_KILL="$SBLAB/labtest-mutant-kill.command"
# shellcheck disable=SC2016  # deliberate literal `$XPID` for sed
if sed 's/^\([[:space:]]*\)kill "\$XPID" 2>\/dev\/null$/\1: # kill removed by mutation/' "$SBLAB/relay.command" > "$MUTANT_KILL" \
	&& ! cmp -s "$MUTANT_KILL" "$SBLAB/relay.command" && bash -n "$MUTANT_KILL"; then
	write_job 'C:\Windows\System32\notepad.exe' '' 1
	elapsed="$(run_relay_bounded "$MUTANT_KILL" "" sleep 4)"; self_exited=$?
	kill_recorded_shims
	if [ "$self_exited" -ne 0 ] && [ "$(done_lines)" = "0" ]; then
		pass "$CASE: detected -- no DONE inside ${elapsed}s (case 7 pins the TIMEOUT kill)"
	else
		fail "$CASE: NOT detected"; note "self_exited=$self_exited elapsed=${elapsed}s DONE lines=$(done_lines)"
	fi
else
	fail "$CASE: could not build the mutant (the kill line moved?)"
fi

# M3. job.env sourced into the relay's own shell again (the three subshell reads replaced by one
#     `source`): case 10c's override scenario must now dial the overridden host -- i.e. 10c pins
#     the isolation.
begin 'M3 plain-source mutant'
MUTANT_SOURCE="$SBLAB/labtest-mutant-source.command"
# The JOB_KEYS subshell line becomes a plain `source` (the `read` block then reads three empty
# lines from the here-doc, so the subsequent `${TIMEOUT:-25}` default and PROGRAM come from the
# sourced variables -- exactly the pre-isolation behaviour).
if awk '
	/JOB_KEYS="\$\( \. "\$RUNTIME\/job\.env"/ {
		if (!done) { print "        source \"$RUNTIME/job.env\"; JOB_KEYS=\"${PROGRAM:-}"; print "${CMDARGS:-}"; print "${TIMEOUT:-}\""; done = 1 }
		next
	}
	{ print }
	END { if (!done) exit 3 }
' "$SBLAB/relay.command" > "$MUTANT_SOURCE" && ! cmp -s "$MUTANT_SOURCE" "$SBLAB/relay.command" && bash -n "$MUTANT_SOURCE"; then
	# All three keys present, so the mutant fails for the RIGHT reason (a plain source that then
	# hit `set -u` on an unset key would die before argv and read as "detected" for nothing).
	{
		printf 'PROGRAM=%q\nCMDARGS=\nTIMEOUT=5\n' 'C:\Windows\System32\notepad.exe'
		printf 'WIN_HOST=198.51.100.7\nSHARE=/etc\n'
	} > "$SBRUNTIME/job.env"
	run_relay "$MUTANT_SOURCE" "" exit0
	argv="$(xfreerdp_argv)"
	if [[ "$argv" == *"[/v:198.51.100.7]"* ]] && [[ "$argv" == *"[/drive:lab,/etc]"* ]]; then
		pass "$CASE: detected -- with a plain source the argv dials the job.env host AND mounts its share (case 10c pins the isolation)"
	else
		fail "$CASE: NOT detected"; note "argv: $argv"
	fi
else
	fail "$CASE: could not build the mutant (the subshell read lines moved?)"
fi

# No sleeping shim recorded by THIS run may outlive the suite (the `exec sleep` shape plus
# kill_recorded_shims). Checked against the pids this run recorded, not a machine-wide pgrep --
# an unrelated `sleep 30` on the maintainer's Mac is not this suite's business.
begin 'orphan check'
leftover=0; ledgered=0
while IFS= read -r p; do
	[ -n "$p" ] || continue
	ledgered=$((ledgered + 1))
	if kill -0 "$p" 2>/dev/null; then leftover=$((leftover + 1)); kill "$p" 2>/dev/null || true; fi
done < <(sort -u "$LABTEST_PID_LEDGER")
if [ "$ledgered" -eq 0 ]; then
	fail "$CASE: the pid ledger is empty -- the recorder stopped working, so this check saw nothing"
elif [ "$leftover" = "0" ]; then
	pass "$CASE: none of the $ledgered shim pids this run recorded is still alive"
else
	fail "$CASE: $leftover of $ledgered recorded shim pid(s) still alive"
fi

# Every case must have reported (review r2 B1): a case that neither passed nor failed would
# otherwise vanish from the tally with exit 0.
EXPECTED_CASES=19
if [ $((PASSES + FAILURES)) -ne "$EXPECTED_CASES" ]; then
	fail "case tally: $((PASSES + FAILURES)) cases reported, expected $EXPECTED_CASES -- a case produced no verdict"
fi
printf '\n%d passed, %d failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
