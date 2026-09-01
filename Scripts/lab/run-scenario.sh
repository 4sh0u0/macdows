#!/usr/bin/env bash
# Orchestration helper: run one lab step and wait for its DONE line.
#   run-scenario.sh relay <job-template>   -- stage the runtime share, copy jobs/<t>.env to
#                                             the runtime job.env, open relay.command
#   run-scenario.sh smoke <log> KEY=V ...  -- bake env into the runtime smoke-job.command,
#                                             open it
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
smoke)
    LOG="$1"; shift
    rm -f "$LOG"
    "$LAB/mk-smoke-job.sh" "WINDOW_SMOKE_LOG=$LOG" "$@" > /dev/null
    open -a Terminal "$RUNTIME/smoke-job.command"
    echo "smoke launched log=$LOG"
    ;;
esac
