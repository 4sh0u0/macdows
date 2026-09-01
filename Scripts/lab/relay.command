#!/usr/bin/env bash
# lab relay -- one-shot RemoteApp run against the owner's own test host (authorized e2e
# lab; same posture as W7's acceptance relay). Reads NO credentials itself beyond
# sourcing the owner's untracked host.env. Launched via Terminal.app (local-network TCC
# holder); `open -a Terminal` does not pass environment variables through, so ALL
# parameters come from job.env.
#
# THIS FILE IS TRACKED (Scripts/lab, since 2026-09-01) and therefore world-readable: it
# must never gain a host address, account name or credential. Everything host-specific is
# read at run time from the owner's untracked ~/.config/macdows/host.env, and everything
# this run produces -- job.env, relay.log and the redirected drive itself -- lives under
# .build/lab-runtime/, which git ignores. See run-matrix.sh's header for the full split.
#
# LIVE-HOST BOUNDARY GATE (owner rule 2026-08-31): before xfreerdp is invoked,
# crdp_assert_lab_boundary (Scripts/lib.sh) must confirm WIN_HOST is inside the owner's
# own lab segments. Fail-closed -- a refusal writes BOUNDARY-REFUSED plus a non-zero DONE
# line to relay.log and no connection is attempted. The window still self-closes; the
# verdict lives in the log, which is what callers poll.
#
# job.env keys:
#   PROGRAM   Windows path of the RemoteApp program to run
#   CMDARGS   command-line arguments (optional; must contain no commas -- xfreerdp's
#             /app sub-parser splits on commas, so put complex logic in a .ps1 under
#             share/ and pass "-NoProfile -ExecutionPolicy Bypass -File \\tsclient\lab\X.ps1".
#             \\tsclient\lab resolves to the RUNTIME share, into which run-scenario.sh
#             stages the tracked share/*.ps1 before every relay job -- not to the tracked
#             directory. Staging is in run-scenario.sh and NOT in run-matrix.sh on purpose:
#             the hand-launched lanes never go through run-matrix.sh. See stage_share.)
#   TIMEOUT   seconds before the connection is closed (default 25)
set -u
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
RUNTIME="$REPO_ROOT/.build/lab-runtime"
SHARE="$RUNTIME/share"
mkdir -p "$SHARE"
LOG="$RUNTIME/relay.log"
: > "$LOG"
RELAY_RC=0
{
    # shellcheck source=/dev/null
    source "$HOME/.config/macdows/host.env"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/Scripts/lib.sh"
    # lib.sh turns on -e/pipefail for its sourcer; this relay deliberately runs with
    # neither (it kills and reaps xfreerdp by hand, and those calls are allowed to fail).
    set +e +o pipefail
    # The boundary gate runs FIRST and judges host.env alone. job.env is a per-run file under
    # .build/ and is never sourced into THIS shell: it is executed once, in a subshell, and only
    # its three keys (PROGRAM, CMDARGS, TIMEOUT) come back out. That isolates what job.env can
    # WRITE (its variables, functions, traps and `exit` die with the subshell), not what it can
    # READ (the subshell inherits this environment) -- sourcing it here let it redefine
    # crdp_assert_lab_boundary (review relay-offline r2 B2) and, once that was closed by
    # ordering, overwrite WIN_HOST/WIN_USER/WIN_PASS/SHARE after the gate had passed -- the gate
    # approving one host and xfreerdp dialling another (r3 B1). test-relay-offline.sh pins
    # both (cases 10b/10c). Each key is then validated: a missing or PROGRAM-less job used to
    # trip `set -u` on "${PROGRAM}" and kill this shell BEFORE the DONE line, so the caller
    # (run-matrix.sh's run_relay_job) could only give up on its own WAIT_* timeout, and a
    # non-numeric TIMEOUT made the poll loop's `-lt` fail so the connection was torn down at
    # once yet reported DONE exit=0 (r4 I1). The contract is "every run writes DONE" -- the
    # job.env refusals keep it, each with a named reason and a sysexits code the caller can
    # tell apart (66 EX_NOINPUT / 65 EX_DATAERR; 78 EX_CONFIG stays the boundary's).
    if ! crdp_assert_lab_boundary "${WIN_HOST:-}"; then
        echo "[relay] BOUNDARY-REFUSED -- target is not a permitted lab host; no connection attempted"
        RELAY_RC=78
    elif [ ! -r "$RUNTIME/job.env" ]; then
        echo "[relay] JOB-ENV-MISSING -- $RUNTIME/job.env is not readable; no connection attempted"
        RELAY_RC=66
    else
        # One subshell, three lines out plus a sentinel (the keys are single-line by contract;
        # `read -r` keeps CMDARGS' backslashes). job.env therefore runs exactly once. A value
        # carrying a newline would shift the following lines, so the fourth read must land on
        # the sentinel or the job is refused as multi-line. job.env is normally copied from
        # jobs/*.env by run-scenario.sh (LF), but a hand-edited CRLF file leaves a trailing CR on
        # each value; it is stripped, not shipped to xfreerdp's argv or fed to the TIMEOUT check
        # (review relay-offline r5 minors, r6 I1).
        # shellcheck source=/dev/null
        JOB_KEYS="$( . "$RUNTIME/job.env" >/dev/null 2>&1; printf '%s\n%s\n%s\n%s\n' "${PROGRAM:-}" "${CMDARGS:-}" "${TIMEOUT:-}" 'END-OF-JOB-KEYS' )"
        PROGRAM=""; CMDARGS=""; TIMEOUT=""; JOB_KEYS_END=""
        { IFS= read -r PROGRAM; IFS= read -r CMDARGS; IFS= read -r TIMEOUT; IFS= read -r JOB_KEYS_END; } <<EOF_JOB_KEYS
$JOB_KEYS
EOF_JOB_KEYS
        CR=$(printf '\r')
        PROGRAM="${PROGRAM%"$CR"}"; CMDARGS="${CMDARGS%"$CR"}"; TIMEOUT="${TIMEOUT%"$CR"}"; JOB_KEYS_END="${JOB_KEYS_END%"$CR"}"
        TIMEOUT="${TIMEOUT:-25}"
        if [ "$JOB_KEYS_END" != "END-OF-JOB-KEYS" ]; then
            echo "[relay] JOB-ENV-INVALID -- a job.env value spans more than one line; no connection attempted"
            RELAY_RC=65
        elif [ -z "$PROGRAM" ]; then
            echo "[relay] JOB-ENV-INVALID -- job.env sets no PROGRAM; no connection attempted"
            RELAY_RC=65
        elif ! printf '%s' "$TIMEOUT" | grep -qE '^[1-9][0-9]*$'; then
            echo "[relay] JOB-ENV-INVALID -- job.env TIMEOUT is not a positive integer; no connection attempted"
            RELAY_RC=65
        else
            APP_SPEC="/app:program:${PROGRAM}"
            if [ -n "${CMDARGS:-}" ]; then
                APP_SPEC="${APP_SPEC},cmd:${CMDARGS}"
            fi
            echo "[relay] program=${PROGRAM} timeout=${TIMEOUT}s"
            xfreerdp "/v:${WIN_HOST}" "/u:${WIN_USER}" "/p:${WIN_PASS}" /cert:ignore \
                "$APP_SPEC" "/drive:lab,${SHARE}" /gfx:AVC420 &
            XPID=$!
            SECS=0
            while kill -0 "$XPID" 2>/dev/null && [ "$SECS" -lt "$TIMEOUT" ]; do
                sleep 1
                SECS=$((SECS + 1))
            done
            if kill -0 "$XPID" 2>/dev/null; then
                echo "[relay] timeout reached -- closing connection"
                kill "$XPID" 2>/dev/null
                wait "$XPID" 2>/dev/null
            fi
            echo "[relay] xfreerdp exited"
        fi
    fi
} >>"$LOG" 2>&1
echo "DONE exit=$RELAY_RC" >>"$LOG"
# self-close this Terminal window (same mechanism as Scripts/run-window-smoke.command)
if [ -n "${TERM_PROGRAM:-}" ] && [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
    TTY_NAME=$(tty)
    osascript -e 'tell application "Terminal" to close (every window whose tty is "'"$TTY_NAME"'")' >/dev/null 2>&1 &
fi
