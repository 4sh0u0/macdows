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
# shellcheck source=/dev/null
source "$HOME/.config/macdows/host.env"
# shellcheck source=/dev/null
source "$REPO_ROOT/Scripts/lib.sh"
# lib.sh turns on -euo pipefail for its sourcer; this probe has always run with none of
# them (an unreachable host is an expected outcome here, not an abort).
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
