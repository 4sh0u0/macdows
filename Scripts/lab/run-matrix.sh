#!/usr/bin/env bash
# run-matrix.sh -- one command for the whole TSAppAllowList enforced-mode acceptance.
#
# Authorized e2e lab against the owner's own Windows test host, driven entirely through the
# existing lab relay (relay.command / xfreerdp via Terminal.app, the local-network TCC holder).
# Nothing here changes host state: the host-side script is read-only and the only elevated step
# in the whole matrix -- Set-TsAllowListMatrix.ps1 -Mode Enforce -- is owner-manual and printed
# as instructions rather than attempted. The lab account has no HKLM write access.
#
#   ./run-matrix.sh
#
# ==========================================================================================
# TRACKED SCRIPTS vs RUNTIME ARTIFACTS  (promotion to Scripts/lab/, 2026-09-01)
# ==========================================================================================
# This harness used to live entirely under .build/lab/, which git ignores, so scripts and the
# artefacts they produced shared one directory. On promotion into the tracked tree that split
# had to become explicit, because every file here is now world-readable:
#
#   Scripts/lab/            TRACKED, read-only at run time. Orchestrators, the .command
#                           launchers, jobs/*.env definitions and share/*.ps1 host-side
#                           scripts. Nothing writes into this directory during a run.
#   .build/lab-runtime/     IGNORED (.build/ is in .gitignore), created on demand. job.env,
#                           relay.log, probe-result.txt, smoke-job.command, and
#                           share/ -- the directory the relay redirects to the host.
#
# The redirected drive (\\tsclient\lab on the host side) is .build/lab-runtime/share, NOT the
# tracked share/. run-scenario.sh STAGES the host-side scripts into it before every relay job
# -- there, not here, because the hand-launched lanes (stage, readback, host-agent-tests) go
# through run-scenario.sh without ever touching this file -- exactly as the host-agent was
# already refreshed from Tools/host-agent. Consequences, on purpose:
#   * the host can only ever write into an ignored directory -- a host-written file cannot
#     land on a tracked path and so cannot be committed by accident;
#   * the tracked copies stay pristine; a run cannot mutate them;
#   * *.Tests.ps1 are deliberately NOT staged. The host never needs them, and the redirected
#     drive should carry the smallest surface that does the job.
#
# FIRST LIVE RUN AFTER THIS CHANGE: the staging-into-runtime design is new as of 2026-09-01 and
# has NOT been exercised against a live host. test-run-matrix-offline.sh covers the whole
# orchestration path (all four relay jobs, every verdict, the boundary gate, the one-relay
# guard) with the relay seam shimmed, so the sequencing is proved; what it cannot prove is that
# the host resolves \\tsclient\lab to the new staged directory as expected. Treat the next live
# run as a first run: watch the staging step's file count, and confirm the host-side report
# actually appears under .build/lab-runtime/share/ before trusting a verdict.
#
# Exit codes:
#   0  MATRIX: PASS      -- the host was enforced and every check passed
#   1  MATRIX: FAIL      -- a step failed, timed out, or an assertion did not hold
#   2  PRECONDITION      -- the allow list is not enforced yet; owner instructions printed
#   3  boundary gate refused the target, or it could not be evaluated
#   4  the host is not reachable
#
# 4 sits deliberately outside the 0/1/2/3 verdict contract the other lab scripts use: it means
# the matrix did not run at all, as distinct from 1 ("it ran and something failed"). A caller
# that only knows 0/1/2/3 should treat >=3 as "did not produce a verdict".
#
# The full transcript is written to .build/evidence/tsallowlist-matrix.log.
#
# Deliberately NOT `set -e`: every live step has to be able to fail and still reach the logoff
# that leaves the host in a clean state.
set -uo pipefail

# LAB is the TRACKED script home (Scripts/lab); RUNTIME is the ignored artefact home. Both are
# derived, never configured: a second source of truth for either would be a way for the relay
# and the poller to end up watching different directories.
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB/../.." && pwd)"
RUNTIME="$REPO_ROOT/.build/lab-runtime"
SHARE="$RUNTIME/share"
EVIDENCE_DIR="$REPO_ROOT/.build/evidence"
LOG="$EVIDENCE_DIR/tsallowlist-matrix.log"

RELAY_LOG="$RUNTIME/relay.log"
PROBE_RESULT="$RUNTIME/probe-result.txt"
REG_OUT="$SHARE/tsallowlist-probe-out.txt"
MATRIX_OUT="$SHARE/tsallowlist-matrix-out.txt"

# Per-step waits, in seconds. Each is the job's own TIMEOUT (relay.command kills xfreerdp at
# that point) plus generous room for connection setup and the RemoteApp actually starting.
# Each is overridable from the environment. The defaults are what a live run uses; the
# overrides exist so the offline guard test can drive the real code path in seconds instead of
# minutes, rather than reimplementing the logic in the test and proving nothing about this file.
WAIT_REGPROBE="${WAIT_REGPROBE:-180}"
# 180, retuned down from 260 when jobs/matrix-verify.env's own TIMEOUT came down from 240 to
# 120 (run 4 measured the verify at 32s end to end). Still 60s clear of the point at which the
# relay kills xfreerdp itself, so this can only fire if the relay stopped answering at all --
# it just now says so in three minutes instead of four and a half.
WAIT_VERIFY="${WAIT_VERIFY:-180}"
WAIT_NEGATIVE="${WAIT_NEGATIVE:-90}"
WAIT_LOGOFF="${WAIT_LOGOFF:-60}"
# How long to wait for a previous relay's xfreerdp to exit before refusing to start a job.
# Longer than the largest TIMEOUT among the four jobs THIS script drives -- verify's 120 since
# the retune above -- plus teardown. Deliberately NOT longer than every job in jobs/:
# host-agent-tests is 300 and wait_for_relay_quiet matches ANY xfreerdp on the Mac, so a
# hand-launched `run-scenario.sh relay host-agent-tests` is refused at 180s rather than waited
# out. That is the safe direction; two live relays is the thing this guard exists to prevent.
WAIT_RELAY_QUIET="${WAIT_RELAY_QUIET:-180}"
WAIT_OUTFILE="${WAIT_OUTFILE:-30}"
WAIT_PROBE="${WAIT_PROBE:-45}"
SETTLE_SECONDS="${SETTLE_SECONDS:-45}"

# mlog/mrule, not log/rule: boundary_gate sources Scripts/lib.sh, which defines its own
# log() writing to STDERR with a "[script]" prefix. A plain log() here is silently replaced by
# it from the gate onwards -- harmless while main's output is merged with 2>&1, and a silent
# loss of half the transcript for anyone who runs this without that merge. Prefixed names
# cannot be captured by anything lib.sh adds later either.
# Every line carries seconds since start. Without it a timeout tells you only that a step
# blew its budget, never by how much -- which is the one number needed to retune a TIMEOUT.
MATRIX_T0="$(date +%s)"
mlog() { printf '[+%ss] %s\n' "$(($(date +%s) - MATRIX_T0))" "$*"; }
mrule() { printf -- '---------------------------------------------------------------------\n'; }

# Set by wait_for_relay_done: the exit code the relay itself recorded on its DONE line.
RELAY_DONE_RC=''
# Set when do_logoff had to skip the logoff because a relay was still live (see do_logoff).
MATRIX_LOGOFF_SKIPPED=0

# ------------------------------------------------------------------------------------------
# Live-host boundary gate
# ------------------------------------------------------------------------------------------

boundary_gate_fallback() {
	# Equivalent of Scripts/lib.sh's crdp_assert_lab_boundary for the window before that
	# function exists. NB this is NOT the one-liner quoted in the task brief: that one reads
	# the allowed networks as `open(...).read().split('"')[1]`, and lab-boundary.env carries an
	# earlier quoted string in a comment line, so it picks up prose instead of the CIDR list
	# and the gate fails closed for the wrong reason. Sourcing the file and reading the
	# variable is the same rule, evaluated against the value the file actually sets.
	[ -r "$HOME/.config/macdows/lab-boundary.env" ] || return 1
	# shellcheck source=/dev/null
	source "$HOME/.config/macdows/lab-boundary.env"
	MACDOWS_LAB_ALLOWED_NETS="${MACDOWS_LAB_ALLOWED_NETS:-}" WIN_HOST="${WIN_HOST:-}" python3 -c '
import ipaddress, os, sys
nets = os.environ.get("MACDOWS_LAB_ALLOWED_NETS", "").split()
if not nets:
    sys.exit(1)
try:
    host = ipaddress.ip_address(os.environ.get("WIN_HOST", ""))
except ValueError:
    sys.exit(1)
try:
    sys.exit(0 if any(host in ipaddress.ip_network(n, strict=False) for n in nets) else 1)
except ValueError:
    sys.exit(1)
'
}

boundary_gate() {
	local rc=0 source_name
	if [ -r "$REPO_ROOT/Scripts/lib.sh" ] &&
		grep -c 'crdp_assert_lab_boundary' "$REPO_ROOT/Scripts/lib.sh" >/dev/null 2>&1; then
		# shellcheck source=/dev/null
		source "$REPO_ROOT/Scripts/lib.sh"
		# lib.sh sets -euo pipefail on whoever sources it; this script must keep handling its
		# own errors so that a failed step still reaches the logoff.
		set +e
		set -uo pipefail
		crdp_assert_lab_boundary "${WIN_HOST:-}" >/dev/null 2>&1 || rc=$?
		source_name='Scripts/lib.sh:crdp_assert_lab_boundary'
	else
		boundary_gate_fallback >/dev/null 2>&1 || rc=$?
		source_name='fallback (~/.config/macdows/lab-boundary.env)'
	fi
	# Only the verdict is logged. The target address never reaches the log or the report.
	if [ "$rc" -eq 0 ]; then
		mlog "[gate] boundary: PASS -- target is inside the allowed lab segments  [via $source_name]"
	else
		mlog "[gate] boundary: FAIL (rc=$rc) -- target is outside the allowed lab segments, or the gate could not be evaluated  [via $source_name]"
	fi
	return "$rc"
}

# ------------------------------------------------------------------------------------------
# Waiting
# ------------------------------------------------------------------------------------------

# grep -c ... >/dev/null rather than grep -q throughout: -q makes grep exit at the first match,
# and inside a pipefail pipeline the resulting SIGPIPE on the writer inverts the pipeline's
# status (STATUS engineering note).
has_line() { grep -c -- "$2" "$1" >/dev/null 2>&1; }

# Waits for the relay's DONE line and captures the code on it into RELAY_DONE_RC.
# Matching only the literal "DONE exit=" was wrong: relay.command records its OWN exit status
# there, and a boundary refusal writes "DONE exit=78" without ever contacting the host. Treated
# as a bare presence check that logged as "completed" -- a refused connection scored as a
# successful step, and the run carried on interpreting a stale or absent output file.
wait_for_relay_done() { # <timeout>
	local timeout="$1" waited=0 line
	RELAY_DONE_RC=''
	while [ "$waited" -lt "$timeout" ]; do
		if [ -f "$RELAY_LOG" ]; then
			line="$(grep -m1 '^DONE exit=' "$RELAY_LOG" 2>/dev/null)"
			if [ -n "$line" ]; then
				RELAY_DONE_RC="${line#DONE exit=}"
				return 0
			fi
		fi
		sleep 2
		waited=$((waited + 2))
	done
	return 1
}

# Bounded wait for the relay's xfreerdp to actually be gone.
# NB pgrep -x matches ANY xfreerdp on this Mac, not only the one this script started. That is
# the conservative direction: an xfreerdp a human started is equally a second connection.
wait_for_relay_quiet() { # <timeout>
	local timeout="$1" waited=0
	while [ "$waited" -lt "$timeout" ]; do
		pgrep -x xfreerdp >/dev/null 2>&1 || return 0
		sleep 2
		waited=$((waited + 2))
	done
	return 1
}

wait_for_file() { # <path> <timeout>
	local path="$1" timeout="$2" waited=0
	while [ "$waited" -lt "$timeout" ]; do
		if [ -s "$path" ]; then
			# Host-side scripts write CRLF. Strip the CR once, here, so every consumer's
			# grep/sed comparison sees the value it thinks it sees -- measured 2026-09-01:
			# 'fDisabledAllowList = 0<CR>' failed the != "0" test and scored an enforced
			# host as PRECONDITION (the earlier '1<CR>' runs were right by accident).
			# Safe at this point: run_relay_job already waited for the relay's DONE, so
			# the host-side writer has finished with the file.
			tr -d '\r' < "$path" > "$path.crlf-tmp" && mv -f "$path.crlf-tmp" "$path"
			return 0
		fi
		sleep 2
		waited=$((waited + 2))
	done
	return 1
}

# ------------------------------------------------------------------------------------------
# Relay steps
# ------------------------------------------------------------------------------------------

# One relay connection at a time, always. run-scenario.sh copies jobs/<job>.env over job.env,
# removes relay.log and opens relay.command in Terminal.app; this waits for that run's DONE.
run_relay_job() { # <job> <timeout>
	local job="$1" timeout="$2" t0 elapsed

	# One relay connection at a time is a hard lab rule, enforced HERE -- at the single point
	# every job passes through -- rather than only before the logoff.
	#
	# It lived in do_logoff first, and that was a guard in name only: do_logoff returned 1 on
	# refusal but every caller ignored the return, so run_matrix carried straight on to
	# matrix-verify or matrix-negative and opened the second connection one step later. A
	# check that the caller can walk past protects nothing. At this choke point no job can
	# start while an xfreerdp is live, and no future call site can reintroduce the hole.
	if ! wait_for_relay_quiet "$WAIT_RELAY_QUIET"; then
		mlog "[step] REFUSED to start job '$job': an xfreerdp is STILL running after ${WAIT_RELAY_QUIET}s"
		mlog "[step]   one relay connection at a time is a hard rule -- not stacking a second on top."
		return 1
	fi

	t0="$(date +%s)"
	mlog "[step] relay job '$job' (waiting up to ${timeout}s for DONE)"
	if ! "$LAB/run-scenario.sh" relay "$job"; then
		mlog "[step] FAILED to launch relay job '$job'"
		return 1
	fi
	if ! wait_for_relay_done "$timeout"; then
		mlog "[step] TIMEOUT: relay job '$job' produced no DONE line within ${timeout}s"
		return 1
	fi
	elapsed=$(($(date +%s) - t0))
	if [ "${RELAY_DONE_RC:-}" != "0" ]; then
		mlog "[step] relay job '$job' FAILED after ${elapsed}s: the relay reported exit=${RELAY_DONE_RC:-<unparsed>}"
		if [ "${RELAY_DONE_RC:-}" = "78" ]; then
			mlog "[step]   exit=78 is relay.command's own boundary refusal -- it never contacted the host"
		fi
		return 1
	fi
	mlog "[step] relay job '$job' completed in ${elapsed}s (relay exit=0, budget ${timeout}s)"
	return 0
}

# Scenario hygiene: log the session off and let the host settle before the next connection.
# Called on every path, including failures -- leaving a session logged in is what makes the
# next run flaky.
do_logoff() {
	# No wait_for_relay_quiet call here any more: run_relay_job owns that check now, so the
	# logoff job is refused by the same guard as every other job and this function only has to
	# record what happened. One guard, one place -- two would drift apart.
	mlog "[step] logoff, then ${SETTLE_SECONDS}s settle"
	if ! run_relay_job logoff "$WAIT_LOGOFF"; then
		MATRIX_LOGOFF_SKIPPED=1
		mlog "[warn] the logoff did not complete -- the host session may still be logged in."
		mlog "[warn] Log it off by hand, or re-run once any stray xfreerdp has exited."
	fi
	sleep "$SETTLE_SECONDS"
	mlog "[step] settled"
	return 0
}

print_owner_instructions() {
	mrule
	cat <<'OWNER_BLOCK'
OWNER ACTION REQUIRED -- the TS allow list is not enforced on the host.

fDisabledAllowList is not 0, so there is no enforced-mode behaviour to accept yet. Putting the
host into enforced mode writes to HKLM and needs an elevated console; the lab account is a
standard user and cannot do it (and must not try).

On the host, in an ELEVATED PowerShell console:

  # 1. Get the script. It is already on the redirected drive during a lab session:
  #      \\tsclient\lab\Set-TsAllowListMatrix.ps1
  #    Outside a session, copy it across on a USB stick to e.g. C:\macdows-matrix\.
  cd C:\macdows-matrix

  # 2. Enforce. -ArmRestoreIn 4 registers a SYSTEM scheduled task that runs -Mode Restore in
  #    four hours: a dead-man switch, so a lockout self-heals without console access.
  .\Set-TsAllowListMatrix.ps1 -Mode Enforce -BackupDir C:\macdows-matrix -ArmRestoreIn 4

  #    Expected last line:
  #      READBACK: fDisabledAllowList=0 publishedApplications=4

  # 3. Tell the lab to run the matrix. On the Mac:
  #      Scripts/lab/run-matrix.sh

  # 4. Afterwards, put the host back (also from an ELEVATED console). This unregisters the
  #    dead-man switch too.
  .\Set-TsAllowListMatrix.ps1 -Mode Restore -BackupDir C:\macdows-matrix

  #    Expected last line (for a host that had fDisabledAllowList=1 before):
  #      READBACK: fDisabledAllowList=1 publishedApplications=0

Note: while enforced, ONLY winver, logoff, notepad and powershell can be launched over RAIL.
That is deliberate -- it is what the matrix measures -- and it is also why the restore step
matters: anything else the host is used for as a RemoteApp will be refused until you run it.
OWNER_BLOCK
	mrule
}

# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------

# run_matrix does the work; main() wraps it so the "was the host actually left logged off?"
# line is emitted on every exit path, including the early ones. The report has to be able to
# state that plainly rather than inferring it from the absence of a warning.
main() {
	local rc=0
	run_matrix "$@" || rc=$?
	mrule
	if [ "$MATRIX_LOGOFF_SKIPPED" -ne 0 ]; then
		mlog "[state] HOST SESSION: STILL LOGGED IN -- a logoff was skipped or did not complete (see [warn] above)"
		# A verdict that reads as "nothing to do here" must never sit next to that line. Both
		# 0 (PASS) and 2 (PRECONDITION) read that way, so both are downgraded -- a host left
		# logged in is something the operator has to fix before anything else, and the original
		# verdict is printed rather than lost.
		#
		# Done centrally rather than by incrementing the enforced branch's `failures`: that
		# counter does not exist on the PRECONDITION path or on any of the early returns, so
		# incrementing it would have left most exit paths still disagreeing with the state line.
		if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
			mlog "[verdict] downgrading exit $rc to 1: the run did not leave the host in a clean state"
			rc=1
		fi
	else
		mlog "[state] host session: logged off"
	fi
	return "$rc"
}

run_matrix() {
	mlog "run-matrix.sh -- TSAppAllowList enforced-mode acceptance"
	mlog "started: $(date '+%Y-%m-%d %H:%M:%S %z')"
	mlog "lab: $LAB"
	mrule

	# -- host.env supplies WIN_HOST for the gate. Sourced, never echoed. -------------------
	if [ ! -r "$HOME/.config/macdows/host.env" ]; then
		mlog "[gate] boundary: FAIL -- ~/.config/macdows/host.env is missing or unreadable"
		return 3
	fi
	# shellcheck source=/dev/null
	source "$HOME/.config/macdows/host.env"

	boundary_gate || return 3

	# The negative control asserts on a STRING that this specific binary emits
	# ("RAIL exec error: execResult=RAIL_EXEC_E_NOT_IN_ALLOWLIST"). Record which build produced
	# the evidence, so a later formatting change in FreeRDP is diagnosable rather than baffling.
	mlog "[env] xfreerdp: $(xfreerdp --version 2>&1 | head -1 || echo '<not found>')"

	# -- the runtime directory ------------------------------------------------------------------
	# Every artefact this run reads or writes lives here. Filling the redirected drive itself is
	# run-scenario.sh's job, not this script's: it is the choke point every relay job passes
	# through, including the hand-launched lanes this script never drives (see stage_share
	# there). This only has to make sure the directory exists before the probe writes into it.
	mrule
	mlog "[stage] runtime: $RUNTIME"
	if ! mkdir -p "$SHARE"; then
		mlog "[stage] FAILED to create the runtime directory"
		return 1
	fi

	# -- reachability -----------------------------------------------------------------------
	mlog "[step] reachability probe"
	rm -f "$PROBE_RESULT"
	open -a Terminal "$LAB/probe.command"
	if ! wait_for_file "$PROBE_RESULT" "$WAIT_PROBE"; then
		mlog "[step] TIMEOUT: probe.command wrote no result within ${WAIT_PROBE}s"
		return 4
	fi
	local reach
	reach="$(cat "$PROBE_RESULT")"
	mlog "[step] probe: $reach"
	if [ "$reach" != "REACHABLE" ]; then
		mlog "[step] host is not reachable -- stopping before any relay connection"
		return 4
	fi

	# -- 1. read the current allow-list state -------------------------------------------------
	mrule
	rm -f "$REG_OUT"
	if ! run_relay_job regprobe "$WAIT_REGPROBE"; then
		do_logoff
		return 1
	fi
	if ! wait_for_file "$REG_OUT" "$WAIT_OUTFILE"; then
		mlog "[step] TIMEOUT: the registry probe wrote no output file"
		do_logoff
		return 1
	fi

	local fdisabled
	fdisabled="$(grep -m1 '^TSAppAllowList.fDisabledAllowList = ' "$REG_OUT" | sed 's/.* = //')"
	mlog "[probe] fDisabledAllowList = ${fdisabled:-<not reported>}"
	mlog "[probe] $(grep -m1 '^Applications:' "$REG_OUT" || echo 'Applications: <not reported>')"

	do_logoff

	if [ "${fdisabled:-}" != "0" ]; then
		mrule
		mlog "RESULT: PRECONDITION (fDisabledAllowList=${fdisabled:-<not reported>}; the allow list is not enforced)"
		mlog "The harness is in place and the precondition gate ran clean. Nothing else can be"
		mlog "measured until the host is put into enforced mode by the owner."
		print_owner_instructions
		mlog "MATRIX: PRECONDITION"
		return 2
	fi

	# -- 2. enforced mode: the agent's view against the registry -------------------------------
	mrule
	mlog "[step] the allow list IS enforced -- running the full matrix"
	local failures=0

	rm -f "$MATRIX_OUT"
	if ! run_relay_job matrix-verify "$WAIT_VERIFY"; then
		failures=$((failures + 1))
	fi
	local verify_result='<no report>'
	if wait_for_file "$MATRIX_OUT" "$WAIT_OUTFILE"; then
		mrule
		mlog "--- tsallowlist-matrix-out.txt ---"
		cat "$MATRIX_OUT"
		mlog "--- end of report ---"
		mrule
		verify_result="$(grep '^RESULT: ' "$MATRIX_OUT" | tail -1 | sed 's/^RESULT: //')"
	else
		mlog "[step] TIMEOUT: the verify job wrote no report"
	fi
	mlog "[matrix] host-side verify RESULT: $verify_result"
	if [ "$verify_result" = "PRECONDITION" ]; then
		# The host says the allow list is not enforced, minutes after the registry probe said
		# it was. Someone restored it in between (the -ArmRestoreIn dead-man switch is exactly
		# such a someone). Nothing under test failed -- the precondition simply stopped holding
		# mid-run, so this is the same outcome as finding it unenforced at the start.
		mlog "[matrix] the host reports PRECONDITION inside the enforced branch: the allow list"
		mlog "[matrix] was disabled between the registry probe and this job. Not a failure."
		do_logoff
		mrule
		print_owner_instructions
		mlog "MATRIX: PRECONDITION"
		return 2
	fi
	if [ "$verify_result" != "PASS" ]; then
		failures=$((failures + 1))
	fi

	do_logoff

	# -- 3. the negative control over RAIL ------------------------------------------------------
	# charmap.exe is deliberately not published, so termsrv must refuse the RAIL exec and
	# FreeRDP must log RAIL_EXEC_E_NOT_IN_ALLOWLIST (xf_rail.c: xf_rail_server_execute_result).
	mrule
	mlog "[step] negative control: launching an unpublished program over RAIL"
	if ! run_relay_job matrix-negative "$WAIT_NEGATIVE"; then
		failures=$((failures + 1))
	fi
	if has_line "$RELAY_LOG" 'RAIL exec error: execResult=RAIL_EXEC_E_NOT_IN_ALLOWLIST'; then
		mlog "[matrix] negative control: PASS -- RAIL_EXEC_E_NOT_IN_ALLOWLIST observed"
	else
		mlog "[matrix] negative control: FAIL -- no RAIL_EXEC_E_NOT_IN_ALLOWLIST in relay.log"
		mlog "--- relay.log tail ---"
		tail -30 "$RELAY_LOG" 2>/dev/null || mlog "(relay.log missing)"
		mlog "--- end of tail ---"
		failures=$((failures + 1))
	fi

	do_logoff

	# -- summary ---------------------------------------------------------------------------------
	mrule
	if [ "$failures" -eq 0 ]; then
		mlog "MATRIX: PASS"
		return 0
	fi
	mlog "MATRIX: FAIL ($failures step(s) failed)"
	return 1
}

# Run only when executed, not when sourced. Sourcing is how the offline guard test gets at
# run_relay_job / do_logoff to drive them directly; without this it would launch a live run.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	mkdir -p "$EVIDENCE_DIR"
	main "$@" 2>&1 | tee "$LOG"
	rc="${PIPESTATUS[0]}"
	printf 'exit=%s (log: %s)\n' "$rc" "$LOG" | tee -a "$LOG"
	exit "$rc"
fi
