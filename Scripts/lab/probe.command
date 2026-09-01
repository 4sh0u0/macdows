#!/usr/bin/env bash
# lab reachability probe (authorized e2e lab): is the test host's RDP port reachable
# from a Terminal.app-descended process? Writes one word to the runtime
# probe-result.txt (.build/lab-runtime/, ignored -- this file itself is tracked and must
# never carry a host address; the target comes from the owner's untracked host.env).
#
# LIVE-HOST BOUNDARY GATE (owner rule 2026-08-31): crdp_assert_lab_boundary
# (Scripts/lib.sh) must confirm WIN_HOST is inside the owner's own lab segments before
# any packet is sent. Fail-closed -- a refusal writes BOUNDARY-REFUSED and nc is never
# run, so the result word is always one of BOUNDARY-REFUSED / REACHABLE / UNREACHABLE.
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
RUNTIME="$REPO_ROOT/.build/lab-runtime"
mkdir -p "$RUNTIME"
# Truncate the result FIRST (relay.command does the same with its log): if anything below dies
# before the verdict is written -- a host.env that exits, a missing lib.sh -- the caller must find
# an empty file and time out, never last run's REACHABLE (test-probe-offline.sh pins this).
: > "$RUNTIME/probe-result.txt"
# shellcheck source=/dev/null
source "$HOME/.config/macdows/host.env"
# shellcheck source=/dev/null
source "$REPO_ROOT/Scripts/lib.sh"
# lib.sh turns on -euo pipefail for its sourcer; this probe has always run with none of them:
# -e because an unreachable host is an expected outcome here, not an abort; -u because every
# variable read below is either set above or deliberately defaulted (`${WIN_HOST:-}`), and a
# missing host.env must reach the gate's own empty-host refusal rather than die on expansion.
set +eu +o pipefail
if ! crdp_assert_lab_boundary "${WIN_HOST:-}"; then
    echo "BOUNDARY-REFUSED" > "$RUNTIME/probe-result.txt"
elif nc -z -G 5 "$WIN_HOST" 3389 2>/dev/null; then
    echo "REACHABLE" > "$RUNTIME/probe-result.txt"
else
    echo "UNREACHABLE" > "$RUNTIME/probe-result.txt"
fi
if [ -n "${TERM_PROGRAM:-}" ] && [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
    TTY_NAME=$(tty)
    osascript -e 'tell application "Terminal" to close (every window whose tty is "'"$TTY_NAME"'")' >/dev/null 2>&1 &
fi
