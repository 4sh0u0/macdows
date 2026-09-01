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
    source "$RUNTIME/job.env"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/Scripts/lib.sh"
    # lib.sh turns on -e/pipefail for its sourcer; this relay deliberately runs with
    # neither (it kills and reaps xfreerdp by hand, and those calls are allowed to fail).
    set +e +o pipefail
    if ! crdp_assert_lab_boundary "${WIN_HOST:-}"; then
        echo "[relay] BOUNDARY-REFUSED -- target is not a permitted lab host; no connection attempted"
        RELAY_RC=78
    else
        TIMEOUT="${TIMEOUT:-25}"
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
} >>"$LOG" 2>&1
echo "DONE exit=$RELAY_RC" >>"$LOG"
# self-close this Terminal window (same mechanism as Scripts/run-window-smoke.command)
if [ -n "${TERM_PROGRAM:-}" ] && [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
    TTY_NAME=$(tty)
    osascript -e 'tell application "Terminal" to close (every window whose tty is "'"$TTY_NAME"'")' >/dev/null 2>&1 &
fi
