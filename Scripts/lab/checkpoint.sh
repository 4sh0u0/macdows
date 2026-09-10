#!/usr/bin/env bash
# lab CHECKPOINT ORCHESTRATOR -- one checkpoint run, end to end, from the Mac side.
#   checkpoint.sh <job> [batch]        (or: run-scenario.sh checkpoint <job> [batch])
#
# WHAT IT DOES, in the order the 2026-09-09 W3 2x checkpoint established (that run's own
# orchestrator was an untracked .build/lab-runtime/c2p-orchestrate.sh; this is that sequence,
# tracked, with the signals it waits for stated instead of implied):
#   (a) overlap guard -- refuse if a Device Portal ETW capture is still running
#   (b) run-scenario.sh etw <ETW_JOB>, wait for the capture's socket, then settle
#   (c) run-scenario.sh smoke <SMOKE_JOB>, wait for the run's DONE
#   (d) wait for the capture's own DONE (it ends by itself, DURATION seconds after it started)
#   (e) SNAPSHOT=1: run-scenario.sh relay server-snapshot, wait for the relay's DONE
#   (f) gather everything into .build/evidence/<BATCH>/ and print a manifest
#
# WHY THE ORDER IS THE DESIGN, not a convenience. The capture must be OPEN before the run dials,
# or the session-establishment events (the gfx capability exchange, the monitor layout the whole
# 2x question turns on) fall outside the window -- hence (b) before (c), and the settle between
# them. The capture is waited for at (d) rather than abandoned, because its DONE line is what says
# the JSONL is complete. And the snapshot is LAST because it opens an RDP session of its own: run
# concurrently it would appear in the very connection digest it is being asked to read.
#
# WHAT IT NEVER DOES. It opens no socket and reads no credential: every step is a wrapper that
# runs its OWN live-host boundary gate (relay.command, wdp-etw.command, smoke-job.command), and
# this script only copies job files, watches log files and copies artefacts. It never kills a
# process -- a wait that times out reports which step and stops, because the thing it would be
# killing is somebody else's Terminal window (owner rule: a run in flight is evidence).
#
# THIS FILE IS TRACKED: no host address, no account name, no credential, no maintainer path. It
# prints repo-relative paths for that reason. Its own stdout carries only file names, counts and
# `DONE exit=<n>` lines -- no line of a run's log is echoed, so nothing needs masking here.
#
# jobs/checkpoint-<job>.env keys (single-line; the same line-shape whitelist and subshell read
# smoke-job.command uses -- the file is a table of values or it does not run):
#   ETW_JOB          names jobs/etw-<ETW_JOB>.env      (the capture)
#   SMOKE_JOB        names jobs/smoke-<SMOKE_JOB>.env  (the run being observed)
#   SNAPSHOT         0|1 -- run the server-snapshot relay after the run (default 1)
#   SETTLE_SECONDS   0-300, default 10 -- how long after the capture's socket opens before the
#                    run is launched
#   BATCH            evidence directory name; the optional second argument overrides it, which is
#                    how a dated run name is given WITHOUT editing a tracked job file
#
# Exit codes -- one per failed step, so a caller (or a human reading a scrollback) knows where:
#   0  every step reported AND every required artefact reached the evidence directory
#   2  the checkpoint job, or one of the job files it names, is missing or malformed
#   3  refused: an ETW capture is still running (see the overlap guard)
#   4  the ETW capture never opened its output
#   5  the smoke run never reported a DONE line
#   6  the ETW capture never reported a DONE line
#   7  the snapshot relay never reported a DONE line
#   8  every step reported, and the evidence directory is still INCOMPLETE -- a REQUIRED artefact
#      was never produced. Distinct from 2-7 on purpose: those say a step failed and the scrollback
#      says which, while this one says every step SUCCEEDED and the evidence is short anyway, which
#      is the failure a reader has no other way to notice. 8 is only reached when no step failed;
#      a step's own code is more specific and wins.
# Every exit prints a manifest of this batch's artefacts -- including the refusals that stop the run
# before it starts, which exit through cp_die. That is done from an EXIT trap, so it is one property
# of the script rather than a promise each path has to keep. (The one exception is 2: it fires before
# the batch directory and the two TAGs are known, i.e. before there is anything to list or anywhere
# to put it, and no run has happened.)
#
# A cp_die REFUSAL'S MANIFEST IS READ-ONLY. Nothing was launched for this batch, so it lists whatever
# the batch directory ALREADY holds under each artefact's name and copies nothing into it -- in
# particular it never reads .build/lab-runtime/, which at refusal time can still carry a PREVIOUS,
# unrelated run's leftovers under the very names this batch would use. Copying those in would attribute
# them to a batch that never produced them, which is worse than an honest MISSING. A normal completion
# or a step failure that falls through to the bottom of the script is different: something WAS
# launched for this batch, and that path still gathers from .build/lab-runtime/ into the batch
# directory as before.
#
# The codes in the `run:` / `capture:` / `snapshot relay:` lines below are the WRAPPERS' own and are
# never re-used as this script's. The two job-file wrappers now answer the same way as each other:
# 78 is a boundary refusal, 66 is a job file that is not readable, 65 is a job file that is not a
# table of values, and everything else is the run's own. smoke-job.command adds 75 for the two
# preflights that judge the ENVIRONMENT rather than the definition (this machine's display is not
# the geometry the run needs; this checkout does not carry the knob the job names), and passes the
# launcher's codes through unchanged -- so a `run: DONE exit=3` is the launcher's declared-desktop
# knob and nothing else. wdp-etw.command adds 64 (the CLIENT refused its own configuration), 69,
# 76 and 79 (the certificate pin).
#
# Environment: CHECKPOINT_TIMEOUT_ETW_OPEN / _SMOKE / _ETW_DONE / _RELAY override the four wait
# ceilings in seconds (see cp_timeout, near the bottom, for the defaults and why they are knobs).
set -u
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB/../.." && pwd)"
RUNTIME="$REPO_ROOT/.build/lab-runtime"

# The same line grammar as smoke-job.command's and wdp-etw.command's, deliberately restated rather
# than shared: all three must run standalone (two of them are opened by Terminal.app, this one by a
# shell). The third consumer HAS now appeared, so the unification point named here is no longer
# hypothetical -- Scripts/lib.sh is where one copy belongs, and moving it there is registered as an
# open m rather than done inside this lane, because a shared grammar has to be sourced before the
# boundary gate runs in two of the three files and that ordering deserves its own change. When that
# move happens it should take the LOG MASK with it: smoke_mask_pipe/smoke_mask/smoke_re_escape and
# etw_mask_pipe/etw_mask/etw_re_escape are byte-for-byte identical once the prefix is removed, so
# the grammar is not the only copied family and a move that took only one of them would leave the
# next consumer copying the other. See smoke-job.command for why the VALUE half matters as much as
# the key half -- `BATCH=a b` is an assignment prefixed to the command `b`, so a grammar that only
# checked key names would still run programs.
CHECKPOINT_JOB_KEYS_RE='ETW_JOB|SMOKE_JOB|SNAPSHOT|SETTLE_SECONDS|BATCH'
CHECKPOINT_SQ="'"
CHECKPOINT_VALUE_BARE='[A-Za-z0-9._:,%@=+/-]*'
CHECKPOINT_VALUE_DQ='"[^"$`]*"'
CHECKPOINT_JOB_LINE_RE="^[[:space:]]*(#.*)?\$|^(export )?(${CHECKPOINT_JOB_KEYS_RE})=(${CHECKPOINT_VALUE_BARE}|${CHECKPOINT_SQ}[^${CHECKPOINT_SQ}]*${CHECKPOINT_SQ}|${CHECKPOINT_VALUE_DQ})\$"

cp_log() { # <text...>
    printf '[checkpoint] %s\n' "$*"
}

# Paths are printed repo-relative: this script's stdout is pasted into records, and an absolute
# path names the maintainer's home directory.
cp_rel() { # <absolute path>
    printf '%s' "${1#"$REPO_ROOT"/}"
}

cp_die() { # <exit code> <text...>
    local code="$1"
    shift
    # Every cp_die is an early refusal: nothing has been launched for this batch, so the EXIT trap's
    # manifest must not copy .build/lab-runtime/'s current contents into it (see LISTING_ONLY below).
    LISTING_ONLY=1
    cp_log "FAILED: $*"
    exit "$code"
}

# Reads ONE key out of a job file the same way its own wrapper does: in a subshell, so the file's
# variables, functions and `exit` die with it, and only the value comes back. Callers validate the
# shape -- an unvalidated value here would be handed straight to a file name.
# The etw and smoke job files this reads are validated by THEIR OWN wrappers before those wrappers
# act on them; what this needs from each is one naming key, early, so the waits below can be built.
# stdin is closed for the source for the reason smoke-job.command closes it: a job line that reached
# a program which reads stdin would block this orchestrator forever, and a checkpoint that never
# returns is worse than one that refuses.
cp_job_value() { # <job file> <key>
    (
        # shellcheck source=/dev/null
        . "$1" >/dev/null 2>&1 </dev/null
        eval "printf '%s' \"\${$2:-}\""
    ) | tr -d '\r'
}

# Waits for <path> to exist. Returns 0 when it does, 1 on timeout, 2 when <abort-log> reported a
# verdict first -- a capture that refused (a bad pin, a bad job file) writes DONE and exits, and
# waiting the full timeout for a file it will never create only delays the diagnosis.
cp_wait_file() { # <path> <timeout seconds> [abort-log]
    local i=0
    until [ -f "$1" ]; do
        if [ -n "${3:-}" ] && [ -f "$3" ] && grep -q '^DONE exit=' "$3"; then return 2; fi
        sleep 1
        i=$((i + 1))
        if [ "$i" -ge "$2" ]; then return 1; fi
    done
    return 0
}

# Waits for a `DONE exit=` line in ANY of the given logs (the first argument is the timeout). Two
# logs because smoke-job.command writes its verdict to the fixed smoke.log and only THEN copies it
# to the per-TAG name: a job so malformed that its TAG was never trusted produces the first and not
# the second, and waiting only on the per-TAG name would sit out the full timeout for a refusal
# that already happened.
cp_wait_done() { # <timeout seconds> <log>...
    local timeout="$1" i=0 log
    shift
    while :; do
        for log in "$@"; do
            if [ -f "$log" ] && grep -q '^DONE exit=' "$log"; then return 0; fi
        done
        sleep 1
        i=$((i + 1))
        if [ "$i" -ge "$timeout" ]; then return 1; fi
    done
}

cp_done_line() { # <log>...
    local log
    for log in "$@"; do
        if [ -f "$log" ] && grep -q '^DONE exit=' "$log"; then
            grep '^DONE exit=' "$log" | tail -n 1
            return 0
        fi
    done
    printf '%s' '<no DONE line>'
}

# A fixed wait, spelled as a bounded poll rather than one long `sleep`: the whole script's waiting
# discipline is "1 second at a time, with a ceiling", and a lone `sleep 300` in the middle of it is
# the one place a Ctrl-C would land in an uninterruptible-looking gap.
cp_settle() { # <seconds>
    local i=0
    while [ "$i" -lt "$1" ]; do
        sleep 1
        i=$((i + 1))
    done
}

# (a) THE OVERLAP GUARD. Two realtime ETW subscriptions against the same Device Portal do not
# simply coexist: the second one's teardown disables the providers the FIRST one is still reading,
# so an overlapping checkpoint silently truncates the capture that was already running -- and the
# damage lands in the OTHER run's evidence, where nobody is looking.
#
# THE LIVENESS SIGNAL IS THE CAPTURE'S OWN PID LINE. wdp-etw.command writes `[etw] pid=<its own
# pid>` into etw.log after the capture's start line and before it dials, precisely so this guard has
# something better to read than a pattern: `kill -0` on that number answers about THIS checkout's
# capture, while `pgrep -f <path>` answers about anything on the machine whose command line happens
# to contain the path -- a neighbouring checkout's run, an editor with the file open, a `less`.
# So a capture counts as live when its log exists, carries no verdict yet, and its pid is still
# there. A pid that is GONE is not an overlap however loudly the process table matches: that is the
# whole point of preferring this signal, and the case that pins it is what a mutation proof breaks.
#
# The process table is the FALLBACK, used only when the log names no pid -- a capture that has not
# reached its dial yet, or a log written before this line existed. The fallback says so on stdout:
# a guard that quietly changed which signal it reads would otherwise look identical in a scrollback.
# Fail-closed if pgrep is unavailable too: unable to prove the previous capture ended is not the
# same as knowing it did.
#
# Two limits, both in the fail-CLOSED direction and both cheap to resolve by hand (`rm` the log, or
# close the window): a pid the kernel has since handed to something else reads as live, and a
# `kill -0` refused with EPERM -- a capture started by ANOTHER user, which is not a shape this lane
# has -- reads as gone.
cp_etw_capture_live() {
    local etw_pid
    [ -f "$RUNTIME/etw.log" ] || return 1
    if grep -q '^DONE exit=' "$RUNTIME/etw.log"; then return 1; fi
    # `tail -n 1`: the log is truncated per run, so there is one pid line, but if a hand-assembled
    # log ever carried two, the LAST is the capture that would still be running.
    etw_pid="$(sed -n 's/^\[etw\] pid=\([0-9][0-9]*\)$/\1/p' "$RUNTIME/etw.log" | tail -n 1)"
    if [ -n "$etw_pid" ]; then
        if kill -0 "$etw_pid" 2>/dev/null; then
            cp_log "$(cp_rel "$RUNTIME/etw.log") names pid $etw_pid and it is still alive"
            return 0
        fi
        return 1
    fi
    cp_log "$(cp_rel "$RUNTIME/etw.log") has no verdict and no [etw] pid= line -- the capture has not reached its dial, or the log predates the pid line; falling back to the process table"
    if ! command -v pgrep >/dev/null 2>&1; then
        cp_log "pgrep is unavailable, so a capture in flight cannot be ruled out"
        return 0
    fi
    pgrep -f "$LAB/wdp_etw.py" >/dev/null 2>&1 && return 0
    pgrep -f "$LAB/wdp-etw.command" >/dev/null 2>&1 && return 0
    return 1
}

# ---- (f) THE MANIFEST, AND WHY IT IS AN EXIT TRAP ---------------------------------------------
# Gathering used to sit at the bottom of the script, which made the header's promise -- "a non-zero
# exit still gathers whatever artefacts exist and prints the manifest" -- true only for the codes
# that fall through to it. The refusals that stop a checkpoint EARLY exit through cp_die and skipped
# it entirely, and those are the runs where the list matters most: after an overlap refusal or a
# capture that never started, the question a human has is "which of these artefacts does this batch
# actually have", and answering it by hand means listing a directory whose name they have to work
# out first. As a trap it is one property of the script instead of a promise every path has to keep.
#
# INSTALLED here and ARMED later. The trap goes on before the first cp_die can fire, because a trap
# installed after one is not a trap at all; the arming flag is what decides whether it does anything,
# and it is set only once $EVIDENCE and both TAGs exist. Everything that exits before that point
# exits 2 -- a malformed job file, a job it names that is not there -- and for those there is nothing
# to list and no directory name to put it against.
#
# WHAT AN EARLY REFUSAL'S MANIFEST CONTAINS, and why it is READ-ONLY. cp_die sets LISTING_ONLY before
# it exits, because every cp_die is a refusal before anything was launched for this batch: there is
# nothing of THIS run's to copy. .build/lab-runtime/ at refusal time can still carry a PREVIOUS,
# unrelated run's leftovers under the very names this batch would use (an overlap refusal never
# launched anything to remove them), and gathering those in used to attribute them to a batch that
# never produced them -- false evidence with a clean-looking manifest on top of it. So a LISTING_ONLY
# gather never opens .build/lab-runtime/ and never calls `cp`: it only reports whether the batch
# directory ALREADY holds each artefact under its name, which leaves an empty or non-existent batch
# directory exactly as it found it. A normal completion, or a step failure that falls through to the
# bottom of the script instead of exiting through cp_die, is different -- something WAS launched for
# this batch -- and that path still gathers from .build/lab-runtime/ into the batch directory.
GATHER_ARMED=0
GATHER_DONE=0
MISSING=0
FAIL_CODE=0
FAIL_STEP=''
LISTING_ONLY=0

# One artefact. `required` is what separates "this batch is short of something" from "this run did
# not ask for it": a missing REQUIRED artefact is counted and becomes the run's verdict, a missing
# optional one is only reported.
#
# When LISTING_ONLY is set (see cp_die and the comment above) this never reads <source> and never
# calls `cp` -- it reports only whether <destination name> is ALREADY in the batch directory, which
# is true only for window-smoke's own artefact (its source IS the batch directory; see WS_LOG_SRC)
# or for a directory a previous, completed run of the SAME batch name left behind.
# shellcheck disable=SC2329  # reached only through the EXIT trap, via cp_gather
gather() { # <source> <destination name> <required 0|1>
    local src="$1" dst="$EVIDENCE/$2" required="$3" why=''
    if [ "$LISTING_ONLY" -eq 1 ]; then
        if [ -f "$dst" ]; then
            cp_log "      $2  $(wc -c < "$dst" | tr -d ' ') bytes"
            return 0
        fi
        why='MISSING -- listing only, nothing gathered'
    elif [ ! -f "$src" ]; then
        why="MISSING ($(cp_rel "$src"))"
    elif [ "$src" != "$dst" ] && ! cp -f "$src" "$dst"; then
        # A required artefact that could not be COPIED is just as absent from the evidence
        # directory as one that was never written, and is counted the same way.
        why='COPY-FAILED'
    fi
    if [ -z "$why" ]; then
        cp_log "      $2  $(wc -c < "$dst" | tr -d ' ') bytes"
        return 0
    fi
    if [ "$required" -eq 1 ]; then
        MISSING=$((MISSING + 1))
        cp_log "      $2  $why  -- REQUIRED"
    else
        cp_log "      $2  $why"
    fi
    return 1
}

# WHICH FOUR ARE REQUIRED, and why the capture's two are not. Every way the capture can fail
# already has a code of its own (4 -- it never opened its output; 6 -- it never reported a verdict)
# and a `capture:` line saying so, so its absence is loud before the manifest is reached. The run's
# two logs and the snapshot's two are the ones whose absence is otherwise SILENT: the smoke wrapper
# can report DONE exit=0 and still have written its evidence log somewhere this manifest does not
# read (which is exactly the defect that made this a required-artefact question at all), and the
# relay can report a verdict without the host having written its report into the share.
# shellcheck disable=SC2329,SC2317  # reached only through the EXIT trap, via cp_on_exit (SC2317: shellcheck 0.9 on Tier 1 reads a trap-only function body as unreachable; 0.11 does not)
cp_gather() {
    if [ "$LISTING_ONLY" -eq 1 ]; then
        # No mkdir here -- a directory this refusal did not find must not exist because it asked.
        cp_log "(f) evidence -> $(cp_rel "$EVIDENCE")/  -- listing only, nothing gathered: this exit refused before anything was launched for this batch, so .build/lab-runtime/ is never opened here"
    else
        mkdir -p "$EVIDENCE"
        cp_log "(f) evidence -> $(cp_rel "$EVIDENCE")/"
    fi
    gather "$ETW_JSONL" "etw-$ETW_TAG.jsonl" 0
    gather "$ETW_TAG_LOG" "etw-$ETW_TAG.log" 0
    gather "$SMOKE_TAG_LOG" "smoke-$SMOKE_TAG.log" 1
    gather "$WS_LOG_SRC" "window-smoke-$SMOKE_TAG.log" 1
    if [ "$SNAPSHOT" = '1' ]; then
        gather "$RELAY_LOG" "relay-$SMOKE_TAG.log" 1
        gather "$SNAPSHOT_OUT" "server-snapshot-$SMOKE_TAG.txt" 1
    fi
    cp_log "verdicts: capture=[$(cp_done_line "$ETW_LOG")] run=[$(cp_done_line "$SMOKE_TAG_LOG" "$SMOKE_LOG")] snapshot=[$(cp_done_line "$RELAY_LOG")]"
    # The capture's JSONL carries server and channel names and is NEVER quotable as-is; the
    # summariser is the only reader that is safe by construction. Said here because this is the line
    # a human reads right before they go looking at the evidence directory.
    cp_log "read the capture through the summariser only: python3 -B $(cp_rel "$LAB")/etw_summarize.py $(cp_rel "$EVIDENCE")/etw-$ETW_TAG.jsonl"
}

# The whole verdict, in one place, for every way out of this script. The incoming status is read
# FIRST (it is $? at function entry and nothing else may run before it) and is only ever raised from
# 0 to 8: a step that failed already has a more specific code than "the evidence is short", and
# overwriting it would lose the step.
# shellcheck disable=SC2329,SC2317  # invoked by the EXIT trap installed below
cp_on_exit() {
    local rc=$?
    if [ "$GATHER_ARMED" -eq 1 ] && [ "$GATHER_DONE" -eq 0 ]; then
        GATHER_DONE=1
        cp_gather
        if [ "$FAIL_CODE" -ne 0 ] && [ -n "$FAIL_STEP" ]; then
            cp_log "FAILED at $FAIL_STEP -- nothing was killed; the evidence above is whatever the run produced"
        fi
        if [ "$MISSING" -gt 0 ]; then
            cp_log "INCOMPLETE: $MISSING artefact(s) missing"
            if [ "$rc" -eq 0 ]; then rc=8; fi
        fi
        if [ "$rc" -eq 0 ]; then
            cp_log "checkpoint $JOB_NAME complete"
        fi
    fi
    exit "$rc"
}
trap cp_on_exit EXIT

JOB_NAME="${1:-}"
BATCH_OVERRIDE="${2:-}"
if [ -z "$JOB_NAME" ]; then
    cp_die 2 "usage: checkpoint.sh <job> [batch]  (reads jobs/checkpoint-<job>.env)"
fi
case "$JOB_NAME" in
*/* | '') cp_die 2 "the job name must not contain '/' -- it names jobs/checkpoint-<job>.env" ;;
esac
JOB_FILE="$LAB/jobs/checkpoint-$JOB_NAME.env"
[ -r "$JOB_FILE" ] || cp_die 2 "$(cp_rel "$JOB_FILE") is not readable"

BAD_LINE="$(tr -d '\r' < "$JOB_FILE" | grep -nvE "$CHECKPOINT_JOB_LINE_RE" | head -n 1 | cut -d: -f1)"
if [ -n "$BAD_LINE" ]; then
    cp_die 2 "line $BAD_LINE of $(cp_rel "$JOB_FILE") is neither blank, a comment, nor an assignment of a SINGLE WORD to one of ETW_JOB SMOKE_JOB SNAPSHOT SETTLE_SECONDS BATCH"
fi

ETW_JOB="$(cp_job_value "$JOB_FILE" ETW_JOB)"
SMOKE_JOB="$(cp_job_value "$JOB_FILE" SMOKE_JOB)"
SNAPSHOT="$(cp_job_value "$JOB_FILE" SNAPSHOT)"
SETTLE_SECONDS="$(cp_job_value "$JOB_FILE" SETTLE_SECONDS)"
BATCH="$(cp_job_value "$JOB_FILE" BATCH)"
SNAPSHOT="${SNAPSHOT:-1}"
SETTLE_SECONDS="${SETTLE_SECONDS:-10}"
if [ -n "$BATCH_OVERRIDE" ]; then BATCH="$BATCH_OVERRIDE"; fi

# Every value's shape, before anything is launched. A job name reaches a file path and BATCH names
# a directory, so both are held to the same character class the wrappers hold their TAGs to -- no
# separator, nothing that could climb out of jobs/ or out of .build/evidence/.
printf '%s\n' "$ETW_JOB" | grep -qE '^[A-Za-z0-9._-]{1,32}$' \
    || cp_die 2 "ETW_JOB must match ^[A-Za-z0-9._-]{1,32}\$ (it names jobs/etw-<ETW_JOB>.env)"
printf '%s\n' "$SMOKE_JOB" | grep -qE '^[A-Za-z0-9._-]{1,32}$' \
    || cp_die 2 "SMOKE_JOB must match ^[A-Za-z0-9._-]{1,32}\$ (it names jobs/smoke-<SMOKE_JOB>.env)"
# `.` and `..` pass the character class and are still not directory names -- see smoke-job.command.
printf '%s\n' "$BATCH" | grep -qE '^[A-Za-z0-9._-]{1,32}$' \
    || cp_die 2 "BATCH must match ^[A-Za-z0-9._-]{1,32}\$ (it names .build/evidence/<BATCH>/)"
case "$BATCH" in
. | ..) cp_die 2 "BATCH must be a real directory name, not . or .." ;;
esac
printf '%s\n' "$SNAPSHOT" | grep -qE '^[01]$' || cp_die 2 "SNAPSHOT must be 0 or 1"
printf '%s\n' "$SETTLE_SECONDS" | grep -qE '^[0-9]{1,3}$' \
    || cp_die 2 "SETTLE_SECONDS must be 0-300 seconds"
[ "$SETTLE_SECONDS" -le 300 ] || cp_die 2 "SETTLE_SECONDS must be 0-300 seconds"

ETW_JOB_FILE="$LAB/jobs/etw-$ETW_JOB.env"
SMOKE_JOB_FILE="$LAB/jobs/smoke-$SMOKE_JOB.env"
[ -r "$ETW_JOB_FILE" ] || cp_die 2 "$(cp_rel "$ETW_JOB_FILE") is not readable"
[ -r "$SMOKE_JOB_FILE" ] || cp_die 2 "$(cp_rel "$SMOKE_JOB_FILE") is not readable"

# The two TAGs name every artefact this checkpoint gathers, and the capture's DURATION sets the
# ceiling on step (d)'s wait. Read here, from the SAME files the wrappers will read, so a mismatch
# between what this script waits for and what a wrapper produces is impossible by construction.
ETW_TAG="$(cp_job_value "$ETW_JOB_FILE" TAG)"
ETW_DURATION="$(cp_job_value "$ETW_JOB_FILE" DURATION)"
SMOKE_TAG="$(cp_job_value "$SMOKE_JOB_FILE" TAG)"
SMOKE_BATCH="$(cp_job_value "$SMOKE_JOB_FILE" BATCH)"
ETW_DURATION="${ETW_DURATION:-60}"
printf '%s\n' "$ETW_TAG" | grep -qE '^[A-Za-z0-9_-]{1,32}$' \
    || cp_die 2 "$(cp_rel "$ETW_JOB_FILE") has no usable TAG (wdp-etw.command would refuse it too)"
printf '%s\n' "$SMOKE_TAG" | grep -qE '^[A-Za-z0-9._-]{1,32}$' \
    || cp_die 2 "$(cp_rel "$SMOKE_JOB_FILE") has no usable TAG (smoke-job.command would refuse it too)"
printf '%s\n' "$ETW_DURATION" | grep -qE '^[1-9][0-9]{0,4}$' \
    || cp_die 2 "$(cp_rel "$ETW_JOB_FILE") has a DURATION that is not a positive integer"

ETW_JSONL="$RUNTIME/wdp/etw-$ETW_TAG.jsonl"
ETW_LOG="$RUNTIME/etw.log"
ETW_TAG_LOG="$RUNTIME/wdp/etw-$ETW_TAG.log"
SMOKE_LOG="$RUNTIME/smoke.log"
SMOKE_TAG_LOG="$RUNTIME/smoke-$SMOKE_TAG.log"
RELAY_LOG="$RUNTIME/relay.log"
SNAPSHOT_OUT="$RUNTIME/share/server-snapshot-out.txt"
EVIDENCE="$REPO_ROOT/.build/evidence/$BATCH"
# THE RUN'S EVIDENCE LOG IS UNDER $BATCH AND NOWHERE ELSE. Step (c) calls
# `run-scenario.sh smoke <job> "$BATCH"`, and BATCH is non-empty by the time it gets there (it is
# validated above), so the smoke mode ALWAYS writes that value into the runtime job instance and
# the wrapper always reads it as its own. The template's BATCH is therefore never what the run
# used: it is what the run would have used had this script not overridden it.
#
# Reading the template's value here was wrong in two ways at once, and neither was visible while
# every shipped pair of job files happened to agree. With a dated batch name the run's real log was
# reported MISSING; and when the template's directory still held the PREVIOUS run's log of the same
# name -- which is exactly what running the same job twice leaves there -- gather() copied that
# stale file OVER the real one under the new batch name. Not absent evidence but FALSE evidence,
# with a clean manifest, a clean verdicts line and exit 0 over the top of it. The source is now the
# same directory as the destination, so gather() reports the size and copies nothing.
WS_LOG_SRC="$EVIDENCE/window-smoke-$SMOKE_TAG.log"
# From here on, every exit gathers and prints the manifest -- including the overlap refusal below.
GATHER_ARMED=1

# Wait ceilings, each a statement about the step rather than a round number:
#   ETW socket   60 s   -- the portal answers in seconds; a minute is a hung TLS handshake
#   smoke run   900 s   -- an incremental xcodebuild plus a multi-minute live battery
#   ETW DONE    DURATION + 90 s -- the capture ends by itself; the margin is teardown and the
#                                  summary line
#   relay       180 s   -- one RDP session that runs a read-only PowerShell report
#
# Each is overridable by an environment variable of the same name, because these are statements
# about PATIENCE, not about safety: nothing this script does depends on a ceiling being large, and
# a lane with a longer battery (or an offline suite that cannot wait fifteen minutes to watch a
# timeout happen) needs to say so without editing this file. A malformed override falls back to the
# default rather than to zero -- the fail-safe direction for a ceiling is "wait the normal amount".
cp_timeout() { # <override value> <default>
    if printf '%s\n' "$1" | grep -qE '^[1-9][0-9]{0,5}$'; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}
ETW_OPEN_TIMEOUT="$(cp_timeout "${CHECKPOINT_TIMEOUT_ETW_OPEN:-}" 60)"
SMOKE_TIMEOUT="$(cp_timeout "${CHECKPOINT_TIMEOUT_SMOKE:-}" 900)"
ETW_DONE_TIMEOUT="$(cp_timeout "${CHECKPOINT_TIMEOUT_ETW_DONE:-}" $((ETW_DURATION + 90)))"
RELAY_TIMEOUT="$(cp_timeout "${CHECKPOINT_TIMEOUT_RELAY:-}" 180)"

cp_log "checkpoint $JOB_NAME: etw=$ETW_JOB (TAG=$ETW_TAG, ${ETW_DURATION}s) smoke=$SMOKE_JOB (TAG=$SMOKE_TAG) snapshot=$SNAPSHOT batch=$BATCH"
# The template's own BATCH is read for exactly one purpose: saying out loud that it is not the one
# in force. It is never a path here -- see WS_LOG_SRC above for what happens when it is -- but a
# reader comparing this scrollback against a job file under review deserves to be told that the
# name in the file is not the name on the directory.
if [ -n "$SMOKE_BATCH" ] && [ "$SMOKE_BATCH" != "$BATCH" ]; then
    cp_log "$(cp_rel "$SMOKE_JOB_FILE") declares BATCH=$SMOKE_BATCH; this run overrides it with $BATCH, which is where the wrapper writes and where the manifest reads"
fi

# ---- (a) overlap guard ---------------------------------------------------------------------
if cp_etw_capture_live; then
    cp_die 3 "an ETW capture is still in flight ($(cp_rel "$ETW_LOG") has no DONE line and the capture's process is alive). Two captures overlapping disable each other's providers -- wait for it, or close its window, and run this again"
fi

# ---- (b) the capture -------------------------------------------------------------------------
# The previous capture's JSONL is removed BEFORE the launch, not after: the wait below treats the
# file's appearance as "the socket is open", and last run's file would satisfy it instantly.
# run-scenario.sh removes etw.log itself, for the same reason.
rm -f "$ETW_JSONL" "$ETW_TAG_LOG"
cp_log "(b) starting the capture"
"$LAB/run-scenario.sh" etw "$ETW_JOB" || cp_die 4 "run-scenario.sh etw $ETW_JOB did not start"
cp_wait_file "$ETW_JSONL" "$ETW_OPEN_TIMEOUT" "$ETW_LOG"
case $? in
0)
    cp_log "(b) capture open ($(cp_rel "$ETW_JSONL") exists); settling ${SETTLE_SECONDS}s before the run"
    cp_settle "$SETTLE_SECONDS"
    ;;
2)
    FAIL_CODE=4
    FAIL_STEP="(b) the capture reported [$(cp_done_line "$ETW_LOG")] without ever opening its output"
    ;;
*)
    FAIL_CODE=4
    FAIL_STEP="(b) the capture did not open its output within ${ETW_OPEN_TIMEOUT}s"
    ;;
esac

# ---- (c) the run ------------------------------------------------------------------------------
if [ "$FAIL_CODE" -eq 0 ]; then
    cp_log "(c) starting the run"
    if "$LAB/run-scenario.sh" smoke "$SMOKE_JOB" "$BATCH"; then
        if cp_wait_done "$SMOKE_TIMEOUT" "$SMOKE_TAG_LOG" "$SMOKE_LOG"; then
            cp_log "(c) run: $(cp_done_line "$SMOKE_TAG_LOG" "$SMOKE_LOG")"
        else
            FAIL_CODE=5
            FAIL_STEP="(c) the run did not report a DONE line within ${SMOKE_TIMEOUT}s"
        fi
    else
        FAIL_CODE=5
        FAIL_STEP="(c) run-scenario.sh smoke $SMOKE_JOB did not start"
    fi
fi

# ---- (d) the capture's own verdict ------------------------------------------------------------
# Waited for even when (c) failed: the capture is already running, it ends by itself, and its DONE
# line is what says the JSONL on disk is complete rather than half-written.
if [ "$FAIL_CODE" -eq 0 ] || [ "$FAIL_CODE" -eq 5 ]; then
    if cp_wait_done "$ETW_DONE_TIMEOUT" "$ETW_LOG"; then
        cp_log "(d) capture: $(cp_done_line "$ETW_LOG")"
    elif [ "$FAIL_CODE" -eq 0 ]; then
        FAIL_CODE=6
        FAIL_STEP="(d) the capture did not report a DONE line within ${ETW_DONE_TIMEOUT}s"
    fi
fi

# ---- (e) the snapshot -------------------------------------------------------------------------
if [ "$FAIL_CODE" -eq 0 ] && [ "$SNAPSHOT" = '1' ]; then
    # The host writes its report into the redirected share; last run's copy must not be what the
    # manifest gathers.
    rm -f "$SNAPSHOT_OUT"
    cp_log "(e) starting the server snapshot"
    if "$LAB/run-scenario.sh" relay server-snapshot; then
        if cp_wait_done "$RELAY_TIMEOUT" "$RELAY_LOG"; then
            cp_log "(e) snapshot relay: $(cp_done_line "$RELAY_LOG")"
        else
            FAIL_CODE=7
            FAIL_STEP="(e) the snapshot relay did not report a DONE line within ${RELAY_TIMEOUT}s"
        fi
    else
        FAIL_CODE=7
        FAIL_STEP="(e) run-scenario.sh relay server-snapshot did not start"
    fi
elif [ "$SNAPSHOT" != '1' ]; then
    cp_log "(e) skipped -- SNAPSHOT=0"
fi

# ---- (f) gather -------------------------------------------------------------------------------
# The verdict itself is the EXIT TRAP's (installed above, armed the moment the batch directory and
# both TAGs were known): it gathers, prints the manifest and then says FAILED / INCOMPLETE /
# complete. Getting here means every step reported.
exit "$FAIL_CODE"
