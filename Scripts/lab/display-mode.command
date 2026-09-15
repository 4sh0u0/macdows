#!/usr/bin/env bash
# lab display-mode WRAPPER -- switches the LOCAL Mac's own display between "1x" and "2x" so a
# checkpoint batch that needs both (jobs/smoke-1x-D.env / jobs/smoke-2x-D.env's PREFLIGHT 1: the
# owner used to flip this by hand between the two runs) can be driven from one command instead.
#   display-mode.command status|1x|2x
#
# WHAT THIS IS NOT: it never opens a socket, reads no credential and touches nothing on the
# Windows host -- every byte it reads or writes stays on THIS Mac. That is also why it carries NO
# live-host boundary gate (crdp_assert_lab_boundary): that gate exists to keep a run away from a
# machine outside the owner's own lab segments, and this tool never addresses any machine at all.
#
# NO PANEL GEOMETRY, HERE OR IN THE HELPER (Scripts/lab/display_mode.swift). Every size this tool
# ever prints or compares is read from the display at run time -- "native" is whatever the CURRENT
# mode's pixel size is, "1x" and "2x" are defined relative to that, never to a literal written into
# a tracked file. See display_mode.swift's header for the full statement; this wrapper repeats the
# rule only because it is the file most likely to be copy-edited by hand later.
#
# THE HELPER IS BUILT, NEVER RUN AS A SCRIPT. `swiftc -O` compiles display_mode.swift once into
# .build/lab-runtime/display-mode-helper and this wrapper reuses that binary until the source is
# newer than it -- never inside a run (a run that had to wait on a cold `swiftc -O` every time
# would be the kind of friction this tool exists to remove). LABTEST_DISPLAY_HELPER overrides the
# helper's path (both the "is it missing or stale" check and the path actually executed): the
# offline suite points it at a bash shim it controls, the same technique run-window-smoke.command's
# stub uses at its OWN path in test-smoke-job-offline.sh -- the difference is that this helper's
# real path is a BUILD OUTPUT rather than a source file the sandbox can just overwrite, so the
# override is a variable instead of a copy.
#
# GUARD ORDER, and why: argument shape first (64) -- nothing below makes sense without knowing
# which of the three forms this is. Then the IN-FLIGHT GUARD (75), BEFORE the helper is built or
# run: an ETW capture, a window-smoke run or a relay in flight is watching or driving THIS Mac's
# own display/session, and switching the display out from under one of them would invalidate its
# evidence without anything in that evidence saying so. The signal is deliberately the SIMPLE one
# checkpoint.sh's own callers wait on -- "the runtime log exists and has no DONE exit= line" -- and
# not checkpoint.sh's own overlap guard, which also falls back to the process table so a STALE log
# left over from a finished run does not block a new one forever (see checkpoint.sh case 36). This
# wrapper takes the more conservative reading on purpose: it is meant to run BETWEEN two legs of a
# batch, a human is present, and a stale log (rare -- every wrapper truncates its own log first
# thing) is a one-line `rm` away, whereas a false negative here would switch the display mid-run.
# Then the BUILD guard (69). Only after all three does the helper ever touch a display.
#
# THE HELPER'S OWN VERIFY vs THIS WRAPPER'S. display_mode.swift verifies a switch by reading the
# mode back through CoreGraphics -- the same API family it used to set it, which is why `set` also
# asks `system_profiler SPDisplaysDataType` (a wholly separate code path down to the Info.framework
# query it runs) to agree with the helper's own `after:` line before this wrapper calls it OK.
# Only for `1x`/`2x`, and only once the helper itself reports rc=0 (already-in-target counts): a
# helper that already refused (65/66/70) has nothing further to cross-check.
#
# FAIL-CLOSED, NOT FAIL-OPEN (gate r1 B2/I2). An absent second opinion is not agreement: if
# system_profiler gives no parseable `UI Looks like:` line for the MAIN display (see below), or the
# helper's own `after:` line does not parse (a grammar drift between this wrapper's sed and
# display_mode.swift's `ModeInfo.description` -- see test-display-mode-pins.sh's pins on that
# format), this wrapper refuses (65) rather than silently skipping the cross-check and reporting
# the helper's rc=0 as-is. Reachable via a sleeping/locked display, a slow or failing
# system_profiler (bounded below, gate r1 m5), or any future change to the helper's line grammar.
#
# MAIN DISPLAY ONLY (gate r1 B4). `SPDisplaysDataType` lists every attached display, in no order
# this wrapper controls, while the helper always operates on `CGMainDisplayID()`. Taking the first
# `UI Looks like:` line in the whole report (as an earlier version of this file did) reads the
# WRONG display's geometry as soon as a second monitor is attached and is not first in the report --
# undoing a switch that was actually correct. This wrapper scopes the read to the stanza whose own
# `Main Display: Yes` line is set (a small awk state machine: a new stanza starts at every bare
# `Name:` header line, regardless of nesting depth, and only a stanza that saw `Main Display: Yes`
# before the next header is kept) and falls back to the same fail-closed refusal above when no
# stanza is marked main at all.
#
# DOES THIS SWITCH ACTUALLY HAPPEN? (gate r1 B3). On disagreement (or an unparseable second
# opinion), the restore -- asking the helper to switch to the OPPOSITE of what was requested -- is
# only attempted when the helper's OWN OUTPUT shows a switch actually happened: its `current:` line
# and its `after:` line name different looks sizes. Already-in-target reports the SAME size on
# both lines (nothing was switched, by construction -- see display_mode.swift's runSet), so a
# disagreement reached from an already-in-target request means the CROSS-CHECK is wrong somehow
# (a stale/wrong system_profiler read, a second display, a grammar drift), not that the display
# needs undoing: issuing a switch here would move a display that was NEVER TOUCHED to the opposite
# of what the caller asked for, which is worse than merely failing to confirm. That case reports
# `restored=0 (nothing to restore)` and calls the helper no further.
#
# When a restore IS attempted, it reports `restored=<0|1>` in the same shape the helper's own
# VERIFY-FAILED line uses, and answers 65 either way -- the same code the helper uses for its own
# verify failure, because to a caller reading DONE exit=65 the two mean the same thing: the switch
# did not verify.
#
# EXIT CODES -- the helper's codes (display_mode.swift's header) pass straight through except
# where this wrapper adds its own layer:
#   0   ok, or the display was already in the requested mode (both sources agree)
#   64  usage -- not exactly one argument, or it is none of status/1x/2x
#   65  VERIFY-FAILED -- the helper's own (passed through), this wrapper's own system_profiler
#       disagreement, or the fail-closed refusal when the cross-check has nothing parseable to
#       compare (see FAIL-CLOSED and MAIN DISPLAY ONLY above); `restored=<0|1>` (or `0 (nothing to
#       restore)` when the helper never switched -- see B3 above) names which
#   66  no usable mode for the request (passed through from the helper) -- no switch was attempted
#   69  the helper failed to build (swiftc's exit code is in the log; never attempted mid-guard,
#       i.e. never after the in-flight guard would have refused first)
#   70  a CoreGraphics call failed inside the helper (passed through)
#   75  refused: an ETW capture, a smoke run or a relay is in flight on this Mac (see GUARD ORDER)
set -u
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
RUNTIME="$REPO_ROOT/.build/lab-runtime"
mkdir -p "$RUNTIME"
LOG="$RUNTIME/display-mode.log"
: > "$LOG"

dm_log() { # <text...>
	printf '%s\n' "$*" >>"$LOG"
	printf '%s\n' "$*"
}

# gate r1 m3: the usage REASON belongs in the log, not only on stderr -- an unattended batch's
# postmortem is the log, and it used to hold nothing but DONE exit=64 for a usage refusal. Kept off
# real stdout on purpose (stdout carries only [display] lines and the DONE line; a caller parsing
# stdout must not see a bare, unprefixed line).
dm_log_only() { # <text...>
	printf '%s\n' "$*" >>"$LOG"
}

dm_finish() { # <rc>
	dm_log "DONE exit=$1"
	exit "$1"
}

USAGE_TEXT='usage: display-mode.command status|1x|2x'

SUBCOMMAND="${1:-}"
case "$SUBCOMMAND" in
status | 1x | 2x)
	if [ "$#" -ne 1 ]; then
		printf '%s\n' "$USAGE_TEXT" >&2
		dm_log_only "$USAGE_TEXT"
		dm_finish 64
	fi
	;;
*)
	printf '%s\n' "$USAGE_TEXT" >&2
	dm_log_only "$USAGE_TEXT"
	dm_finish 64
	;;
esac

# ---- in-flight guard (75) -- checked BEFORE the helper is built or run -----------------------
for signal in etw.log smoke.log relay.log; do
	SIGNAL_LOG="$RUNTIME/$signal"
	if [ -f "$SIGNAL_LOG" ] && ! grep -q '^DONE exit=' "$SIGNAL_LOG"; then
		dm_log "[display] REFUSED: $(basename "$SIGNAL_LOG") is in flight (no DONE exit= line yet); nothing was built, nothing was touched"
		dm_finish 75
	fi
done

# ---- build guard (69) -- never inside a run, only when missing or older than the source -------
SOURCE="$LAB_DIR/display_mode.swift"
HELPER="${LABTEST_DISPLAY_HELPER:-$RUNTIME/display-mode-helper}"
if [ ! -x "$HELPER" ] || [ "$SOURCE" -nt "$HELPER" ]; then
	dm_log "[display] building helper: swiftc -O $(basename "$SOURCE") -> $HELPER"
	BUILD_OUT="$(swiftc -O "$SOURCE" -o "$HELPER" 2>&1)"
	BUILD_RC=$?
	if [ -n "$BUILD_OUT" ]; then
		printf '%s\n' "$BUILD_OUT" >>"$LOG"
	fi
	if [ "$BUILD_RC" -ne 0 ]; then
		dm_log "[display] REFUSED: helper build failed, swiftc exited $BUILD_RC (see $(basename "$LOG") for its output)"
		dm_finish 69
	fi
fi

# ---- run the helper -----------------------------------------------------------------------
case "$SUBCOMMAND" in
status) HELPER_ARGS=(status) ;;
1x) HELPER_ARGS=(set 1x) ;;
2x) HELPER_ARGS=(set 2x) ;;
esac

HELPER_OUT="$("$HELPER" "${HELPER_ARGS[@]}" 2>&1)"
HELPER_RC=$?
# gate r1 m4: a silent helper (empty stdout+stderr) must not put a bare blank line where "stdout
# carries only the [display] lines and the DONE line" promises one of those two shapes.
if [ -n "$HELPER_OUT" ]; then
	printf '%s\n' "$HELPER_OUT" >>"$LOG"
	printf '%s\n' "$HELPER_OUT"
fi
FINAL_RC=$HELPER_RC

# Attempts the opposite-of-$1 switch as a best-effort restore; echoes 1 if the helper reported OK,
# 0 otherwise. Logs the restore attempt's own raw output as a side effect. Only ever called when
# the caller has already established a switch actually happened (see B3 in the header) -- this
# function itself does not make that judgement, so it must never be called unconditionally.
dm_attempt_restore() { # <requested: 1x|2x>
	local opposite="2x" restore_out restore_rc
	if [ "$1" = "2x" ]; then opposite="1x"; fi
	restore_out="$("$HELPER" set "$opposite" 2>&1)"
	restore_rc=$?
	printf '%s\n' "$restore_out" >>"$LOG"
	if [ "$restore_rc" -eq 0 ] && printf '%s\n' "$restore_out" | grep -q '^\[display\] OK '; then
		echo 1
	else
		echo 0
	fi
}

# Scopes a `system_profiler SPDisplaysDataType` report to the ONE stanza whose own `Main Display:
# Yes` line is set (gate r1 B4): a new stanza starts at every bare `Name:` header line (a line that
# is nothing but a label and a colon, at ANY indentation -- display entries and their parent
# sections are demarcated the same way), and only a stanza that saw `Main Display: Yes` before the
# next header survives to be printed. Prints nothing when no stanza is marked main, which is the
# fail-closed signal the cross-check below already treats "nothing parseable" as. `awk` (not a
# fixed indentation count) because the exact indentation of SPDisplaysDataType's nesting is not a
# contract this tool can pin.
dm_main_display_block() {
	awk '
		function flush() { if (is_main) printf "%s", buf; buf = ""; is_main = 0 }
		/^[[:space:]]*[^[:space:]:][^:]*:[[:space:]]*$/ { flush(); next }
		{ buf = buf $0 "\n" }
		/Main Display:[[:space:]]*Yes/ { is_main = 1 }
		END { flush() }
	'
}

# ---- system_profiler cross-check -- only for 1x/2x, only when the helper itself claims rc=0 ---
if [ "$SUBCOMMAND" != "status" ] && [ "$HELPER_RC" -eq 0 ]; then
	CURRENT_LINE="$(printf '%s\n' "$HELPER_OUT" | grep -E '^\[display\] current: ' | tail -n 1)"
	CURRENT_LOOKS="$(printf '%s\n' "$CURRENT_LINE" | sed -n 's/.* looks=\([0-9][0-9]*\)x\([0-9][0-9]*\) .*/\1 \2/p')"
	AFTER_LINE="$(printf '%s\n' "$HELPER_OUT" | grep -E '^\[display\] after: ' | tail -n 1)"
	AFTER_LOOKS="$(printf '%s\n' "$AFTER_LINE" | sed -n 's/.* looks=\([0-9][0-9]*\)x\([0-9][0-9]*\) .*/\1 \2/p')"

	# gate r1 B3: a switch actually happened iff the helper's own current: and after: lines name
	# DIFFERENT looks sizes -- already-in-target reports the same size on both (display_mode.swift
	# never touches CoreGraphics in that branch), by construction, not by inference.
	SWITCHED=0
	if [ -n "$CURRENT_LOOKS" ] && [ -n "$AFTER_LOOKS" ] && [ "$CURRENT_LOOKS" != "$AFTER_LOOKS" ]; then
		SWITCHED=1
	fi

	# gate r1 m5: bounded, so a hung or merely slow system_profiler degrades to the SAME fail-closed
	# refusal as an absent line (below) rather than hanging this wrapper indefinitely. 5s is
	# generous for a local Info.framework query and short enough that an unattended batch notices.
	SP_OUT="$RUNTIME/display-mode-profiler.out"
	: >"$SP_OUT"
	system_profiler SPDisplaysDataType >"$SP_OUT" 2>/dev/null &
	SP_PID=$!
	SP_WAITED=0
	while kill -0 "$SP_PID" 2>/dev/null && [ "$SP_WAITED" -lt 5 ]; do
		sleep 1
		SP_WAITED=$((SP_WAITED + 1))
	done
	if kill -0 "$SP_PID" 2>/dev/null; then
		kill "$SP_PID" 2>/dev/null
		dm_log_only "[display] system_profiler did not finish within 5s -- treating as no parseable line"
	fi
	wait "$SP_PID" 2>/dev/null
	PROFILER_MAIN_BLOCK="$(dm_main_display_block <"$SP_OUT")"
	PROFILER_LOOKS="$(printf '%s\n' "$PROFILER_MAIN_BLOCK" | sed -n 's/.*UI Looks like: \([0-9][0-9]*\) x \([0-9][0-9]*\).*/\1 \2/p' | head -n 1)"

	# gate r1 B2: an absent second opinion (system_profiler gave no main-display UI Looks like:
	# line -- including "no stanza was marked main" from B4) or an unparseable after: line (a
	# helper-grammar drift, gate r1 I2) is NOT agreement. Fail closed: refuse loudly rather than
	# silently reporting the helper's own rc=0 unexamined.
	if [ -z "$AFTER_LOOKS" ] || [ -z "$PROFILER_LOOKS" ]; then
		RESTORED=0
		NOTE=""
		if [ "$SWITCHED" -eq 1 ]; then
			RESTORED="$(dm_attempt_restore "$SUBCOMMAND")"
		else
			NOTE=" (nothing to restore)"
		fi
		if [ -z "$PROFILER_LOOKS" ]; then
			REASON='system_profiler gave no "UI Looks like:" line for the main display'
		else
			REASON="could not parse the helper's own after: line"
		fi
		dm_log "[display] VERIFY-FAILED: $REASON restored=$RESTORED$NOTE"
		FINAL_RC=65
	elif [ "$AFTER_LOOKS" != "$PROFILER_LOOKS" ]; then
		RESTORED=0
		NOTE=""
		if [ "$SWITCHED" -eq 1 ]; then
			RESTORED="$(dm_attempt_restore "$SUBCOMMAND")"
		else
			NOTE=" (nothing to restore)"
		fi
		dm_log "[display] VERIFY-FAILED: system_profiler (${PROFILER_LOOKS% *}x${PROFILER_LOOKS#* }) disagrees with the helper's after: line (${AFTER_LOOKS% *}x${AFTER_LOOKS#* }) restored=$RESTORED$NOTE"
		FINAL_RC=65
	fi
fi

dm_finish "$FINAL_RC"
