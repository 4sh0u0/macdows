#!/usr/bin/env bash
# Terminal-relay launcher for window-smoke (W4b's real-host pixel-path verification
# harness, Tools/window-smoke). Terminal.app has local-network TCC permission already
# granted on this machine, and this script's own subprocess (window-smoke, launched below)
# inherits it -- the same mechanism Tools/bridge-smoke has relied on since W4a.
#
# Reads RDP credentials from ~/.config/macdows/host.env (or WIN_HOST/WIN_USER/
# WIN_PASS env vars, which take priority) itself only via window-smoke's own main.swift --
# this script never touches them directly (red line: no credential-handling logic in
# scripts either, not just library code).
#
# Screenshot capture is explicitly NOT this script's job (H2/H3, W4b review). Confirmed
# empirically: Screen Recording TCC is evaluated against the *directly calling* process's
# own code identity, and does not propagate through this Terminal-relay launch chain the
# way local-network access does -- neither window-smoke's own internal screencapture
# attempt, nor an attempt made from *this script itself* (a child of a freshly relaunched
# Terminal.app window), succeeds; both reliably fail with "could not create image from
# display". The only identity confirmed to hold the permission in practice is whatever
# already-running, already-permitted shell invokes this script -- so the actual screenshot
# capture is that caller's own responsibility, timed via `sleep` against this script's
# known ~15s-after-launch mark. window-smoke's own `finish()` assertion verifies the
# resulting file was genuinely produced by *this* run (mtime after launch, correct PNG
# signature, minimum size) rather than trusting that any particular capture attempt
# actually succeeded, so a stale file from an earlier run can never silently pass.
#
# Usage: run from anywhere -- always resolves paths relative to the repo root, and builds
# window-smoke first if it isn't already built (clean-checkout reproducible).
#   WINDOW_SMOKE_SCREENSHOT_PATH=/abs/path.png  overrides the evidence file path
#     (default: <repo>/.build/evidence/w4b-first-window.png, git-ignored)
#   WINDOW_SMOKE_LOG=/abs/path.log  overrides where this script tees window-smoke's own
#     stdout/stderr (default: <repo>/.build/evidence/window-smoke-run.log)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

APP_DIR="$REPO_ROOT/App"
# W4c review H2: -derivedDataPath, not the legacy SYMROOT= override this used until this
# fix. SYMROOT only redirects *this* project's own targets; the MacdowsCore SwiftPM
# package XcodeGen wires in via `packages:` is integrated as a logically separate nested
# project with its own independent build-output settings that do NOT follow a SYMROOT
# override on the outer project -- confirmed empirically: `xcodebuild -scheme window-smoke
# ... SYMROOT=build` from a truly clean checkout (no prior App/build) reproducibly failed
# with "Unable to resolve module dependency: MacdowsCore", because MacdowsCore.
# swiftmodule was landing in Packages/MacdowsCore/build/Debug/ (its own default, SYMROOT-
# independent location) while window-smoke's own search paths only looked in
# App/build/Debug/. -derivedDataPath redirects the *entire* derived-data root uniformly,
# including nested/embedded package projects, and was verified to build cleanly from an
# identical from-scratch checkout. The predictable binary path this script depends on
# moves accordingly, from build/Debug/window-smoke to derived data's own
# Build/Products/Debug/window-smoke layout under the same redirected root.
BIN="$APP_DIR/build/Build/Products/Debug/window-smoke"

if [[ ! -x "$BIN" ]]; then
    echo "[launcher] $BIN not found -- generating project and building window-smoke..." >&2
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "[launcher] xcodegen not found on PATH -- install it (e.g. 'brew install xcodegen') and retry" >&2
        exit 1
    fi
    (
        cd "$APP_DIR" || exit 1
        xcodegen generate
    ) || exit 1
    xcodebuild -project "$APP_DIR/Macdows.xcodeproj" -scheme window-smoke -configuration Debug \
        build -derivedDataPath "$APP_DIR/build" || exit 1
fi

LOG="${WINDOW_SMOKE_LOG:-$REPO_ROOT/.build/evidence/window-smoke-run.log}"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

"$BIN" >>"$LOG" 2>&1
echo "DONE exit=$?" >>"$LOG"

# Self-close this Terminal window on clean completion; keep it open on failure
# so the scrollback stays inspectable. tty-matched so only this window closes.
RC=$(tail -1 "$LOG" | sed -n 's/^DONE exit=\([0-9]*\)$/\1/p')
if [ "${RC:-1}" -eq 0 ] && [ -n "${TERM_PROGRAM:-}" ] && [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
    TTY_NAME=$(tty)
    osascript -e 'tell application "Terminal" to close (every window whose tty is "'"$TTY_NAME"'")' >/dev/null 2>&1 &
fi
