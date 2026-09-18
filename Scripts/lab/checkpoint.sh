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
#   (e) SNAPSHOT=1: run-scenario.sh relay server-snapshot, wait for the relay's DONE (ceiling: the
#       job's own TIMEOUT plus a 90s margin, not a number this script carries -- see the
#       RELAY_TIMEOUT= line, near the bottom, for the derivation)
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
#   2  the checkpoint job, or one of the job files it names, is missing or malformed, or the
#      runtime directory cannot take this run's start stamp (see CP_START_STAMP)
#   3  refused: an ETW capture is still running (see the overlap guard)
#   4  the ETW capture never opened its output
#   5  the smoke run never reported a DONE line
#   6  the ETW capture never reported a DONE line
#   7  the snapshot relay never reported a DONE line within its ceiling (jobs/server-snapshot.env's
#      own TIMEOUT plus the same 90s margin ETW_DONE_TIMEOUT uses, or CHECKPOINT_TIMEOUT_RELAY when
#      that is set)
#   8  every step reported, and the evidence directory is still INCOMPLETE -- a REQUIRED artefact
#      was never produced. Distinct from 2-7 on purpose: those say a step failed and the scrollback
#      says which, while this one says every step SUCCEEDED and the evidence is short anyway, which
#      is the failure a reader has no other way to notice. 8 is only reached when no step failed;
#      a step's own code is more specific and wins.
# Every exit prints a manifest of this batch's artefacts -- including the refusals that stop the run
# before it starts, which exit through cp_die. That is done from an EXIT trap, so it is one property
# of the script rather than a promise each path has to keep. The exceptions are all exit 2, and they
# fall into two classes now rather than one:
#   SILENT -- a malformed job file (before the batch directory and the two TAGs are known: nothing to
#     list and nowhere to put it), and the runtime-directory refusals immediately after those checks
#     (the start stamp or its probe cannot be written, or this filesystem's `find` cannot order two
#     files written in sequence -- see CP_START_STAMP). The batch name is in hand for the second
#     class, but the trap is armed a few lines later, and nothing has been launched either way.
#   READ-ONLY MANIFEST -- the two refusals that fire after the arming point: the window-smoke log
#     that cannot be moved aside (see WS_ASIDE) and the snapshot report that cannot be cleared (step
#     (e)). They print the same listing-only manifest every cp_die prints. The snapshot one is the
#     single refusal that can fire after a step was LAUNCHED, and its manifest still gathers nothing:
#     this run's own files stay in .build/lab-runtime/ under their own names, where the next
#     checkpoint's pre-launch `rm` clears them, rather than being copied into a batch whose verdict
#     is a refusal.
#
# A cp_die REFUSAL'S MANIFEST IS READ-ONLY. Nothing was launched for this batch, so it lists whatever
# the batch directory ALREADY holds under each artefact's name and copies nothing into it -- in
# particular it never reads .build/lab-runtime/, which at refusal time can still carry a PREVIOUS,
# unrelated run's leftovers under the very names this batch would use. Copying those in would attribute
# them to a batch that never produced them, which is worse than an honest MISSING. A normal completion
# or a step failure that falls through to the bottom of the script is different: something WAS
# launched for this batch, and that path gathers from .build/lab-runtime/ into the batch directory --
# but only the files written AFTER this run's start stamp (CP_START_STAMP, below). A step that never
# launched leaves its source exactly as the previous run left it, and such a file is reported MISSING
# as a previous run's, copied nowhere and left in place, rather than attributed to this batch.
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

# THE START STAMP, and the one rule every reader of a run's files applies. Written into
# .build/lab-runtime/ the moment this batch's run begins (at GATHER_ARMED=1 below: after every
# job-file refusal, before anything is launched) and compared against by cp_fresh: a file is THIS
# run's only when it was modified after the stamp. The comparison is `find -newer`, which the BSD and
# GNU finds both make at the filesystem's own resolution (nanoseconds on APFS and ext4); bash 3.2's
# `-nt` rounds to whole seconds and would call a file written in the stamp's own second stale.
#
# WHY A RULE ABOUT FILES AND NOT ABOUT WHICH STEPS RAN. Every source gathered from
# .build/lab-runtime/ is cleared immediately before the launch that rewrites it (run-scenario.sh
# removes smoke-<TAG>.log and relay.log, this script removes the capture's two files and the
# snapshot report) -- but only when that launch happens. A checkpoint that fails at (b) never
# launches (c) or (e), never runs their `rm -f`s, and used to reach the gather with the PREVIOUS
# run's smoke log, the previous logoff relay's log and the previous checkpoint's snapshot report
# still under the names it was about to attribute to this batch: it copied all three in and read
# `run=[DONE exit=0] snapshot=[DONE exit=0]` out of them (the 2026-09-16 remapfix p3-none run,
# record gate r1 B1). Whether a step launched is one fact; whether a FILE is this run's is the one
# the manifest asserts, and the stamp answers it for every artefact the same way -- including the
# one source no `rm` ever clears (window-smoke-<TAG>.log's source is the batch directory itself,
# and a rerun under the same batch name finds the earlier run's copy exactly there).
#
# Fail-closed by construction FOR THE FILES THIS MAC WRITES, which is every gathered source but
# one: a real artefact can only be judged stale if its last write predates the stamp, which no launch
# this script performs can produce; a stale one can only pass if something rewrote it after the
# stamp, at which point it is this run's to explain.
#
# THE SNAPSHOT REPORT IS THE EXCEPTION, and is not judged by mtime at all. The HOST writes it,
# through the redirected drive, and the drive client sets the local file's times from the ones the
# server sends (ThirdParty/FreeRDP's drive channel implements FileBasicInformation by calling
# SetFileTime on the local file) -- so that mtime can be the host's clock, which this lab's host runs
# behind after a boot until it is corrected. A COMPLETE report would then be called a previous run's,
# counted REQUIRED, never copied, and deleted by the next checkpoint's pre-launch `rm`: evidence that
# cannot be reproduced without another live session, lost to a premise nobody measured (gate r1 B-2).
# Step (e) PROVES that one file's freshness instead of estimating it -- it removes the report, checks
# it is gone and sets SNAPSHOT_CLEARED, so "cleared by this run and present again afterwards" is the
# whole proof (see cp_this_runs). With (e) never launched the flag stays 0 and the report is a
# previous checkpoint's, which is the verdict the mtime rule gave for that shape anyway.
#
# PER INVOCATION, not per runtime directory. Nothing serialises checkpoints, and this file name used
# to be fixed: a second checkpoint, started by hand or by an orchestrator, wrote the SAME stamp with
# its own start time before it reached the overlap guard that exists to refuse it, and the run
# already in flight then compared its own artefacts against the intruder's stamp and reported its
# real log, its real capture and its real report as a previous run's -- rc 8, and the pair marked
# BROKEN downstream (gate r1 B-1). The pid in the name makes that impossible, and cp_on_exit removes
# the stamp (and the probe below) on every path, so a refused invocation leaves the runtime directory
# exactly as it found it.
CP_START_STAMP="$RUNTIME/checkpoint-start.$$.stamp"
# Written immediately after the stamp and compared against it: the production check that this
# filesystem and this `find` really do order two files written in sequence (see the write below).
CP_START_PROBE="$RUNTIME/checkpoint-start.$$.probe"

cp_fresh() { # <path> -- 0 iff the file exists and was modified after this run's start stamp
    [ -f "$1" ] || return 1
    [ -n "$(find "$1" -maxdepth 0 -newer "$CP_START_STAMP" 2>/dev/null)" ]
}

# A DONE line counts only in a log this run wrote. The fixed-name logs (etw.log, smoke.log,
# relay.log) are exactly where a previous run's verdict survives until the next launch truncates
# them, so every wait and every verdict below reads them through this and nothing else.
cp_has_done() { # <log>
    cp_fresh "$1" && grep -q '^DONE exit=' "$1"
}

# Waits for <path> to exist AS THIS RUN'S FILE (see cp_fresh). Returns 0 when it does, 1 on timeout,
# 2 when <abort-log> reported a verdict first -- a capture that refused (a bad pin, a bad job file)
# writes DONE and exits, and waiting the full timeout for a file it will never create only delays
# the diagnosis.
cp_wait_file() { # <path> <timeout seconds> [abort-log]
    local i=0
    until cp_fresh "$1"; do
        if [ -n "${3:-}" ] && cp_has_done "$3"; then return 2; fi
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
            if cp_has_done "$log"; then return 0; fi
        done
        sleep 1
        i=$((i + 1))
        if [ "$i" -ge "$timeout" ]; then return 1; fi
    done
}

cp_done_line() { # <log>...
    local log
    for log in "$@"; do
        if cp_has_done "$log"; then
            grep '^DONE exit=' "$log" | tail -n 1
            return 0
        fi
    done
    printf '%s' '<no DONE line from this run>'
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
# this batch -- and that path gathers from .build/lab-runtime/ into the batch directory, admitting
# only what is NEWER THAN THE START STAMP: a step that was skipped after an earlier one failed left
# its source untouched since the previous run, and that file is a previous run's, not this one's
# (see CP_START_STAMP and cp_fresh above).
GATHER_ARMED=0
GATHER_DONE=0
MISSING=0
FAIL_CODE=0
FAIL_STEP=''
LISTING_ONLY=0
# Set by step (e) once it has removed the previous report and checked the removal landed: the
# snapshot report's whole freshness proof (see CP_START_STAMP and cp_this_runs).
SNAPSHOT_CLEARED=0
# The name an earlier run's window-smoke log was moved aside to, set only once the move has actually
# happened (see WS_LOG_SRC's move-aside block). Empty means there was nothing to move.
WS_ASIDE=''

# One artefact. `required` is what separates "this batch is short of something" from "this run did
# not ask for it": a missing REQUIRED artefact is counted and becomes the run's verdict, a missing
# optional one is only reported.
#
# When LISTING_ONLY is set (see cp_die and the comment above) this never reads <source> and never
# calls `cp` -- it reports only whether <destination name> is ALREADY in the batch directory, which
# is true only for window-smoke's own artefact (its source IS the batch directory; see WS_LOG_SRC)
# or for a directory a previous, completed run of the SAME batch name left behind.
#
# IS THIS FILE THIS RUN'S? Two proofs, because the artefacts have two authors. Everything this Mac
# writes is judged by mtime against this run's start stamp. The snapshot report is written by the
# HOST and its mtime can be the host's clock, so it is judged by the only thing this script watched
# happen: step (e) removed that file and checked it was gone, so a file present now was written
# after the removal. See CP_START_STAMP for why the difference is not a convenience.
# shellcheck disable=SC2329,SC2317  # reached only through the EXIT trap, via cp_gather -> gather
cp_this_runs() { # <path> <kind: ''|snapshot|window-smoke>
    case "$2" in
    snapshot) [ "$SNAPSHOT_CLEARED" -eq 1 ] ;;
    *) cp_fresh "$1" ;;
    esac
}

# <kind> is '' for the artefacts that need no special handling, and names the two that do:
#   snapshot      server-snapshot-<TAG>.txt -- judged by cp_this_runs' second proof, and annotated
#                 with whether the report itself is complete (see cp_snapshot_suffix just below).
#                 Its relay DONE line only says the RDP SESSION ended -- not that the host finished
#                 writing the report -- which is exactly the gap the 2026-09-15 offset-20260915 batch
#                 fell into: a relay that outlived RELAY_TIMEOUT still leaves a COMPLETE report on
#                 disk, and gather() had no way to say so.
#   window-smoke  window-smoke-<TAG>.log -- the one source no pre-launch `rm` clears and the one the
#                 launcher APPENDS to, so a rerun under the same batch name has an earlier run's copy
#                 moved aside before anything is launched (see WS_ASIDE). Both the byte line and the
#                 MISSING line say so: the batch directory then holds two files of nearly the same
#                 name, and the record has to say which is which.
# shellcheck disable=SC2329,SC2317  # reached only through the EXIT trap, via cp_gather (SC2317: shellcheck 0.9 on Tier 1 follows the trap chain and reads this body as unreachable; 0.11 does not)
gather() { # <source> <destination name> <required 0|1> [kind '' | snapshot | window-smoke]
    local src="$1" dst="$EVIDENCE/$2" required="$3" kind="${4:-}" why='' suffix='' aside=''
    if [ "$kind" = 'window-smoke' ] && [ -n "$WS_ASIDE" ]; then
        aside=" -- an earlier run's log of this name was moved aside to $WS_ASIDE"
    fi
    if [ "$LISTING_ONLY" -eq 1 ]; then
        if [ -f "$dst" ]; then
            if [ "$kind" = 'snapshot' ]; then suffix="$(cp_snapshot_suffix "$dst")"; fi
            cp_log "      $2  $(wc -c < "$dst" | tr -d ' ') bytes$suffix$aside"
            return 0
        fi
        why='MISSING -- listing only, nothing gathered'
    elif [ ! -f "$src" ]; then
        why="MISSING ($(cp_rel "$src"))"
    elif ! cp_this_runs "$src" "$kind"; then
        # Present, and not this run's by whichever proof applies to it (see cp_this_runs). Not read,
        # not copied, not removed -- reported for what it is, and counted exactly like a file that
        # was never written.
        if [ "$kind" = 'snapshot' ]; then
            why="MISSING ($(cp_rel "$src") -- step (e) never launched, so this report is a previous checkpoint's, left in place, nothing copied)"
        else
            why="MISSING ($(cp_rel "$src") predates this checkpoint -- a previous run's, left in place, nothing copied)"
        fi
    elif [ "$src" != "$dst" ] && ! cp -f "$src" "$dst" 2>/dev/null; then
        # A required artefact that could not be COPIED is just as absent from the evidence
        # directory as one that was never written, and is counted the same way. `2>/dev/null` for
        # the reason the stamp write has it: cp's own diagnostic names an absolute path.
        why='COPY-FAILED'
    fi
    # Nothing was copied under this name by this run, yet the name is already there. Which run's it
    # is depends on how this branch was reached, and the line may only claim what that branch knows.
    if [ -n "$why" ] && [ "$src" != "$dst" ] && [ -f "$dst" ]; then
        if [ "$why" = 'COPY-FAILED' ]; then
            why="$why; a file of this name is present in the batch directory, provenance unknown -- the copy that failed may have written part of it"
        else
            why="$why; the $2 already in the batch directory is an earlier run's, not this one's"
        fi
    fi
    if [ -z "$why" ]; then
        if [ "$kind" = 'snapshot' ]; then suffix="$(cp_snapshot_suffix "$dst")"; fi
        cp_log "      $2  $(wc -c < "$dst" | tr -d ' ') bytes$suffix$aside"
        return 0
    fi
    if [ "$required" -eq 1 ]; then
        MISSING=$((MISSING + 1))
        cp_log "      $2  $why$aside  -- REQUIRED"
    else
        cp_log "      $2  $why$aside"
    fi
    return 1
}

# The report's own last line is the host's declaration, not this script's: server-snapshot.ps1
# (see Scripts/lab/share/server-snapshot.ps1) writes RESULT: DONE only once, as its final line,
# whether or not the relay session around it is later judged a timeout. It writes that line with
# [IO.File]::WriteAllLines, i.e. Environment.NewLine -- CRLF on Windows -- so the trailing CR is
# stripped before the comparison the same way cp_job_value already strips CR from every other
# host-written value this script reads (gate r1 B1: a bare `=` comparison here called every real,
# complete report INCOMPLETE, because it never matched the CRLF the host actually writes).
# shellcheck disable=SC2329,SC2317  # reached only through the EXIT trap, via cp_gather -> gather
cp_snapshot_suffix() { # <gathered path>
    if [ "$(tail -n 1 "$1" 2>/dev/null | tr -d '\r')" = 'RESULT: DONE' ]; then
        printf ' (complete)'
    else
        printf ' (INCOMPLETE -- last line is not RESULT: DONE)'
    fi
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
    gather "$WS_LOG_SRC" "window-smoke-$SMOKE_TAG.log" 1 window-smoke
    if [ "$SNAPSHOT" = '1' ]; then
        gather "$RELAY_LOG" "relay-$SMOKE_TAG.log" 1
        gather "$SNAPSHOT_OUT" "server-snapshot-$SMOKE_TAG.txt" 1 snapshot
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
    # THIS INVOCATION'S stamp and probe, on every path (see CP_START_STAMP): they are private to the
    # run that wrote them, and a stamp left behind is one more file the next reader of the runtime
    # directory has to date. `2>/dev/null` for the reason the writes have it -- a refused `rm` is
    # diagnosed by rm itself, with an absolute path in it. The verdict is already in $rc and this
    # cannot change it.
    rm -f "$CP_START_STAMP" "$CP_START_PROBE" 2>/dev/null
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

# THE SNAPSHOT'S OWN CEILING, read only when the snapshot step will run: SNAPSHOT=0 has no
# business refusing over a file it will never open. jobs/server-snapshot.env's TIMEOUT is the
# session length relay.command itself honours (see relay.command's own JOB-ENV-INVALID check), so
# it is read here the same way ETW_JOB_FILE's DURATION already is -- readable check, then
# cp_job_value, before anything is launched -- and a missing or malformed value refuses now rather
# than after the capture and the run have already spent minutes on a checkpoint that was always
# going to fail at (e). SNAPSHOT_TIMEOUT stays 0 (unused, valid for arithmetic) when SNAPSHOT=0.
#
# THE REFUSAL MESSAGE CLAIMS ONLY WHAT IS TRUE OF relay.command, not what would be convenient: a
# MISSING TIMEOUT is not one of relay.command's own refusals -- it defaults a missing value to 25s
# (relay.command:107) -- and its own regex (`^[1-9][0-9]*$`) accepts more digits than this script's
# `^[1-9][0-9]{0,4}$` does. What relay.command WOULD refuse is a non-numeric value; what THIS
# script additionally requires, for its own reason, is a positive integer of 1-5 digits to derive
# a wait ceiling from -- it will not guess one for a job it cannot even read.
SNAPSHOT_TIMEOUT=0
if [ "$SNAPSHOT" = '1' ]; then
    SNAPSHOT_JOB_FILE="$LAB/jobs/server-snapshot.env"
    [ -r "$SNAPSHOT_JOB_FILE" ] || cp_die 2 "$(cp_rel "$SNAPSHOT_JOB_FILE") is not readable"
    SNAPSHOT_TIMEOUT="$(cp_job_value "$SNAPSHOT_JOB_FILE" TIMEOUT)"
    printf '%s\n' "$SNAPSHOT_TIMEOUT" | grep -qE '^[1-9][0-9]{0,4}$' \
        || cp_die 2 "$(cp_rel "$SNAPSHOT_JOB_FILE") has no TIMEOUT that is a positive integer of 1-5 digits (relay.command itself would only refuse a non-numeric value, defaulting a missing one to 25s -- this script needs an actual number to derive the snapshot wait ceiling from)"
fi

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
# THE START STAMP (see CP_START_STAMP above): written now, after the last job-file refusal and
# before anything is launched, so every file a launch below produces is newer than it and every
# leftover of a previous run is not. A data write rather than a bare `touch`, so the mtime moves
# even when the previous checkpoint left a stamp of the same size; the content is for a human
# reading the runtime directory and is never parsed.
#
# WHY THE `2>/dev/null` IS WHERE IT IS. A failing `mkdir`, and a failing `> path`, are diagnosed by
# mkdir and by THE SHELL -- not by this script -- and those diagnostics carry the absolute path,
# i.e. the maintainer's home directory, into a stdout that is teed into the evidence directory and
# pasted into records (the masking on the way there rewrites addresses and nothing else). cp_die's
# own message is repo-relative and says as much as a reader needs. `> path 2>/dev/null` does NOT
# suppress the shell's diagnostic -- the redirections are applied left to right and the failing one
# is the first -- so the write is wrapped in a group with the suppression on the group.
mkdir -p "$RUNTIME" 2>/dev/null || cp_die 2 "cannot create $(cp_rel "$RUNTIME")"
{ printf 'batch=%s start=%s\n' "$BATCH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CP_START_STAMP"; } 2>/dev/null \
    || cp_die 2 "cannot write $(cp_rel "$CP_START_STAMP") -- nothing below could write to the runtime directory either"
# THE ORDERING CHECK, ON THE FILESYSTEM THAT ACTUALLY MATTERS. Every artefact below is judged by
# `find -newer "$CP_START_STAMP"`, and an EQUAL timestamp is not newer -- so on a volume whose
# timestamps cannot separate two files written in sequence (or under a `find` on PATH that answers
# differently, which is a live shape in this project's tooling), a file this run really wrote reads
# as a previous run's and a complete batch reports itself INCOMPLETE. The offline suite asserts this
# for its own sandbox; here it is asserted for .build/lab-runtime, with one probe file written
# immediately after the stamp, before anything is launched.
{ printf 'probe written immediately after the start stamp; see CP_START_PROBE\n' > "$CP_START_PROBE"; } 2>/dev/null \
    || cp_die 2 "cannot write $(cp_rel "$CP_START_PROBE") -- nothing below could write to the runtime directory either"
[ -n "$(find "$CP_START_PROBE" -maxdepth 0 -newer "$CP_START_STAMP" 2>/dev/null)" ] \
    || cp_die 2 "runtime filesystem or find cannot order files written in sequence -- $(cp_rel "$CP_START_PROBE") was written after $(cp_rel "$CP_START_STAMP") and does not come out newer than it, so a file this run writes could be reported as a previous run's"
# From here on, every exit gathers and prints the manifest -- including the overlap refusal below.
GATHER_ARMED=1
cp_log "start stamp: $(cp_rel "$CP_START_STAMP") -- only files modified after it are gathered as this batch's"

# Wait ceilings, each a statement about the step rather than a round number:
#   ETW socket   60 s   -- the portal answers in seconds; a minute is a hung TLS handshake
#   smoke run   900 s   -- an incremental xcodebuild plus a multi-minute live battery
#   ETW DONE    DURATION + 90 s -- the capture ends by itself; the margin is teardown and the
#                                  summary line
#   relay       jobs/server-snapshot.env's own TIMEOUT + 90 s -- the same margin ETW_DONE_TIMEOUT
#                                  uses, read from the job rather than carried as a number here,
#                                  because a fixed ceiling can drift out of step with the job it is
#                                  timing: a fixed 180s against TIMEOUT=240 read a complete snapshot
#                                  (last line RESULT: DONE, relay DONE exit=0 65-85s later) as a
#                                  timeout three times in the 2026-09-15 offset-20260915 batch.
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
RELAY_TIMEOUT="$(cp_timeout "${CHECKPOINT_TIMEOUT_RELAY:-}" $((SNAPSHOT_TIMEOUT + 90)))"

# Stated in the header, not just held in a variable: a scrollback reader watching (e) run long has
# no other way to tell whether it is still inside its ceiling. SNAPSHOT=0 never printed a ceiling
# because it never has one -- (e) does not run -- so this stays silent there rather than printing a
# number nothing waits on.
if [ "$SNAPSHOT" = '1' ]; then
    SNAPSHOT_STATUS="snapshot=$SNAPSHOT snapshot-wait=${RELAY_TIMEOUT}s"
else
    SNAPSHOT_STATUS="snapshot=$SNAPSHOT"
fi
cp_log "checkpoint $JOB_NAME: etw=$ETW_JOB (TAG=$ETW_TAG, ${ETW_DURATION}s) smoke=$SMOKE_JOB (TAG=$SMOKE_TAG) $SNAPSHOT_STATUS batch=$BATCH"
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

# ---- an earlier run's window-smoke log, moved aside ------------------------------------------
# WS_LOG_SRC's source IS the batch directory (see above), nothing removes it before the run, and the
# launcher only ever APPENDS to it (every write in Scripts/run-window-smoke.command is `>>`). A
# rerun under the same batch name would therefore leave ONE file holding both runs' rows, both
# `[launcher]` start lines and both `DONE exit=` lines -- with its mtime moved by this run's appends,
# so the freshness rule calls all of it this run's. That is the false-evidence class this lane
# exists to close (gate r1 I-1), and the fix is to start from nothing: the earlier run's copy is
# moved aside under a name that says what it is, and is NEVER overwritten -- if that name is taken
# this refuses rather than choosing which run's evidence to destroy. Placed after the overlap guard
# and before the first `rm -f` of step (b), so a refusal here is still a refusal before any launch.
if [ -e "$WS_LOG_SRC" ]; then
    # Aside means BESIDE THE FILE ITSELF -- the aside path is derived from WS_LOG_SRC and never from
    # $EVIDENCE, so the move cannot depend on a directory that does not exist yet and the earlier
    # run's bytes stay in the directory a reader already has open.
    WS_ASIDE_NAME="$(basename "$WS_LOG_SRC").before-$(date -u +%Y%m%dT%H%M%SZ)"
    WS_ASIDE_PATH="$(dirname "$WS_LOG_SRC")/$WS_ASIDE_NAME"
    if [ -e "$WS_ASIDE_PATH" ]; then
        cp_die 2 "$(cp_rel "$WS_LOG_SRC") is an earlier run's and the name it would be moved aside to ($WS_ASIDE_NAME) is taken -- nothing has been launched; move or remove one of them and run this again"
    fi
    mv "$WS_LOG_SRC" "$WS_ASIDE_PATH" 2>/dev/null \
        || cp_die 2 "cannot move $(cp_rel "$WS_LOG_SRC") aside to $WS_ASIDE_NAME -- nothing has been launched"
    # Only now: the manifest line for that artefact reads this, and it must not say a move happened
    # unless one did.
    WS_ASIDE="$WS_ASIDE_NAME"
    cp_log "an earlier run's $(cp_rel "$WS_LOG_SRC") was already there; moved aside to $WS_ASIDE so this run's log carries this run's rows only"
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
    # manifest gathers -- and this removal is also the whole FRESHNESS PROOF for that one artefact
    # (see CP_START_STAMP): its mtime can be the host's clock, so "this run cleared it and it is
    # here again" is the only thing this script can state from its own observation. The check is
    # what makes it a proof: an `rm -f` that silently failed would otherwise set the flag over a
    # previous checkpoint's report. This is the one cp_die that can fire after a step was LAUNCHED,
    # and its manifest is read-only like every other refusal's (see the header).
    rm -f "$SNAPSHOT_OUT" 2>/dev/null
    if [ -e "$SNAPSHOT_OUT" ]; then
        cp_die 2 "cannot clear $(cp_rel "$SNAPSHOT_OUT") before the snapshot runs -- without that removal this run's report cannot be told from a previous checkpoint's"
    fi
    SNAPSHOT_CLEARED=1
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
