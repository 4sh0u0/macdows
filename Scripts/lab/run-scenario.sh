#!/usr/bin/env bash
# Orchestration helper: run one lab step and wait for its DONE line.
#   run-scenario.sh relay <job-template>   -- stage the runtime share, copy jobs/<t>.env to
#                                             the runtime job.env, open relay.command
#   run-scenario.sh smoke <job> [batch]    -- copy jobs/smoke-<t>.env to the runtime
#                                             smoke-job.env (with BATCH optionally overridden),
#                                             open smoke-job.command (one window-smoke run)
#   run-scenario.sh etw <job-template>     -- copy jobs/etw-<t>.env to the runtime etw-job.env,
#                                             open wdp-etw.command (Device Portal ETW capture)
#   run-scenario.sh checkpoint <j> [batch] -- one whole checkpoint through checkpoint.sh: the
#                                             capture, the run, the snapshot and the gather
#
# TRACKED vs RUNTIME -- see the block at the top of run-matrix.sh for the whole story. In
# short: jobs/*.env and share/*.ps1 next to this file are tracked DEFINITIONS and are never
# written to; the instance a run uses lives under .build/lab-runtime/, which git ignores, and
# that runtime share is what the relay redirects to the host as \\tsclient\lab.
set -eu
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB/../.." && pwd)"
RUNTIME="$REPO_ROOT/.build/lab-runtime"
SHARE="$RUNTIME/share"
mkdir -p "$SHARE"

# Fills the redirected drive from the tracked tree.
#
# This lives HERE, at the single choke point every relay job passes through, and not in
# run-matrix.sh: the matrix drives its four jobs through this script, and so does every
# hand-launched lane (`run-scenario.sh relay stage`, `... readback`, `... host-agent-tests`).
# Staging from run-matrix.sh alone would have left each of those running against whatever the
# last matrix run happened to leave in the share -- which, on a fresh clone, is nothing at all,
# and the failure would surface on the host as a job that starts, finds no script, and reports
# nothing. One place, every caller; two places would drift.
#
# *.Tests.ps1 are deliberately excluded: they run on the Mac under pwsh (and in Tier 1 CI),
# never on the host, so staging them would only widen the redirected drive.
stage_share() {
    local staged=0 f base agent

    # PRUNE FIRST. `cp -f` overwrites but never removes, so without this a host-side script
    # renamed or deleted in the tracked tree would sit on the redirected drive forever -- and a
    # jobs/*.env still naming the old file would keep "working" against code that no longer
    # exists in git. It also makes the "no *.Tests.ps1 on the drive" property hold for an
    # EXISTING runtime dir, not only a fresh one: a Tests.ps1 that reached $SHARE by any other
    # route (an older harness, a manual copy) is removed here rather than tolerated.
    #
    # Scoped to *.ps1 -- exactly the files this function owns. Host-written artefacts
    # (*-out.txt, *.done) and host-agent/ are deliberately left alone: run-matrix.sh already
    # removes the two report files it polls for, host-agent/ is cp -R-refreshed below, and a
    # blanket wipe of the share would be a bigger hammer than the problem.
    rm -f "$SHARE"/*.ps1

    for f in "$LAB"/share/*.ps1; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        case "$base" in
        *.Tests.ps1) continue ;;
        esac
        cp -f "$f" "$SHARE/$base"
        staged=$((staged + 1))
    done
    if [ "$staged" -eq 0 ]; then
        echo "[stage] FAILED: no host-side scripts under $LAB/share" >&2
        return 1
    fi
    # Tools/host-agent is the tracked source of truth and is never edited from here.
    mkdir -p "$SHARE/host-agent"
    cp -R "$REPO_ROOT/Tools/host-agent/." "$SHARE/host-agent/"
    agent="$(find "$SHARE/host-agent" -type f | wc -l | tr -d ' ')"
    echo "[stage] host-side scripts staged into the runtime share: $staged (host-agent: $agent file(s))"
}

MODE="$1"; shift
case "$MODE" in
relay)
    stage_share
    cp "$LAB/jobs/$1.env" "$RUNTIME/job.env"
    rm -f "$RUNTIME/relay.log"
    open -a Terminal "$LAB/relay.command"
    echo "relay $1 launched"
    ;;
etw)
    # No staging: the ETW capture opens no RDP session, so it never mounts the redirected drive,
    # and filling a share for it would only widen what the host can reach during a run that has
    # no business touching it. The previous log is removed for the same reason the relay's is --
    # a caller polling for the DONE line must not be able to read the last run's verdict.
    cp "$LAB/jobs/etw-$1.env" "$RUNTIME/etw-job.env"
    rm -f "$RUNTIME/etw.log"
    open -a Terminal "$LAB/wdp-etw.command"
    echo "etw $1 launched"
    ;;
smoke)
    # No staging: window-smoke opens an RDP session but mounts no redirected drive, so filling a
    # share for it would only widen what the host can reach during a run that has no business
    # touching it -- the same reasoning as the etw mode's.
    #
    # This mode used to GENERATE a runtime .command with the caller's KEY=VALUE pairs baked into
    # it. It now copies a TRACKED job definition instead, for the reason the block at the top of
    # run-matrix.sh gives: a run's parameters belong in a reviewed file, not in whatever the last
    # caller typed. jobs/smoke-*.env are those definitions; smoke-job.command is the one wrapper
    # that reads them, and it validates every line, key and value before anything is built or
    # connected. The generator was deleted with this lane -- it had no caller left, and the file it
    # produced was named .build/lab-runtime/smoke-job.command, one path component away from the
    # tracked wrapper of the same name.
    JOB="$1"
    TEMPLATE="$LAB/jobs/smoke-$JOB.env"
    # The optional batch override goes into the RUNTIME instance and never into the tracked
    # template: a later assignment wins when the file is read, so `checkpoint 2x-D
    # checkpoint-20260910` gives the run a dated evidence directory without anybody editing a file
    # that is under review. Its shape is checked here because this is the one place a caller's own
    # string reaches the job file at all.
    #
    # The instance is REBUILT rather than appended to, and the separating newline is written HERE
    # rather than assumed of the template. An append is correct only while every template ends in
    # one; a template that does not -- an editor without "insert final newline", a hand-assembled
    # file -- glues `BATCH=<override>` onto its last line, and what happens then depends entirely on
    # which key that line is. A key with a strict shape is refused, which is survivable. A FREE-TEXT
    # key (MOVE_TARGET, APP, APP_ARGS) swallows it silently: the value is corrupted, the override is
    # LOST, and the run goes to the template's own batch reporting DONE exit=0 while the checkpoint
    # that asked for a dated directory gathers from one nothing was ever written to. Fail-open, in
    # the one step whose whole job is to say where the evidence goes. The extra blank line the
    # unconditional newline can leave behind is admitted by the wrapper's grammar and costs nothing.
    if [ "$#" -ge 2 ] && [ -n "$2" ]; then
        if ! printf '%s\n' "$2" | grep -qE '^[A-Za-z0-9._-]{1,32}$'; then
            echo "[smoke] REFUSED: batch override must match ^[A-Za-z0-9._-]{1,32}\$ -- it names .build/evidence/<BATCH>/" >&2
            exit 2
        fi
        # `set -e` covers the read: a template that is not there fails `cat` and stops the mode,
        # rather than leaving an instance holding nothing but the override.
        {
            cat "$TEMPLATE"
            printf '\n'
            printf 'BATCH=%s\n' "$2"
        } > "$RUNTIME/smoke-job.env"
    else
        cp "$TEMPLATE" "$RUNTIME/smoke-job.env"
    fi
    # Both of the wrapper's logs go, for the reason the etw mode removes its own: a caller polling
    # for DONE must not be able to read the last run's verdict. The per-TAG name is derived
    # TEXTUALLY -- the same grep/sed idiom run-window-smoke.command uses for WIN_HOST, last
    # assignment winning -- and deliberately not by sourcing the job file: smoke-job.command
    # checks every line's shape BEFORE it executes one, and this script must not be the thing that
    # runs a job line ahead of that check.
    rm -f "$RUNTIME/smoke.log"
    TAG="$(tr -d '\r' < "$RUNTIME/smoke-job.env" | sed -n 's/^\(export \)\{0,1\}TAG=//p' | tail -n 1 | sed -e "s/^[\"']//" -e "s/[\"']\$//")"
    if printf '%s\n' "$TAG" | grep -qE '^[A-Za-z0-9._-]{1,32}$'; then
        rm -f "$RUNTIME/smoke-$TAG.log"
    fi
    open -a Terminal "$LAB/smoke-job.command"
    echo "smoke $JOB launched"
    ;;
checkpoint)
    # The orchestrator runs on THIS side (no Terminal hop): it launches the three modes above and
    # waits on their logs, so it must stay in a shell whose exit status the caller can read.
    "$LAB/checkpoint.sh" "$@"
    ;;
*)
    echo "run-scenario.sh: unknown mode '$MODE' -- expected relay, etw, smoke or checkpoint" >&2
    exit 2
    ;;
esac
