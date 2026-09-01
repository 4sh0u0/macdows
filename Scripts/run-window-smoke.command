#!/usr/bin/env bash
# Terminal-relay launcher for window-smoke (W4b's real-host pixel-path verification
# harness, Tools/window-smoke). Terminal.app has local-network TCC permission already
# granted on this machine, and this script's own subprocess (window-smoke, launched below)
# inherits it -- the same mechanism Tools/bridge-smoke has relied on since W4a.
#
# Reads RDP credentials from ~/.config/macdows/host.env (or WIN_HOST/WIN_USER/
# WIN_PASS env vars, which take priority) itself only via window-smoke's own main.swift --
# this script never touches them directly (red line: no credential-handling logic in
# scripts either, not just library code). The one exception is WIN_HOST, which the
# boundary gate below has to know: it is read back out of host.env with grep/sed rather
# than by sourcing the file, so WIN_USER/WIN_PASS never enter this shell at all.
#
# LIVE-HOST BOUNDARY GATE. Before anything is built and long before window-smoke opens a
# socket, crdp_assert_lab_boundary (Scripts/lib.sh) has to confirm the target host is
# inside the owner's own lab segments; the allowed segments live only in the untracked
# ~/.config/macdows/lab-boundary.env. The gate is fail-closed -- a missing boundary file,
# an unresolvable host or an address outside the segments all refuse -- and a refusal
# writes a non-zero DONE line to the log and leaves this Terminal window open, the same
# "failure keeps the scrollback" contract the run itself follows.
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

# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
# lib.sh turns on `set -e` for whoever sources it; this launcher deliberately runs without
# it, so that `"$BIN"`'s own non-zero exit is captured into the DONE line below instead of
# killing the script before it can be written. Restore the launcher's own mode.
set +e

# The log is opened before the gate (it used to be opened after the build) so a refusal
# has somewhere to record its verdict: the DONE line is the contract every caller of this
# launcher reads, and a gate refusal has to speak it too.
LOG="${WINDOW_SMOKE_LOG:-$REPO_ROOT/.build/evidence/window-smoke-run.log}"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

# WIN_HOST from the environment wins here, as it does in window-smoke. Otherwise pull just
# that one key out of host.env textually -- sourcing the file would drag WIN_USER/WIN_PASS
# into this shell for no reason (the head comment's red line).
#
# This extraction and window-smoke's own reader now agree on every line shape that matters.
# They did not always: the Swift side keyed each line on the whole text left of the first
# `=`, so `export WIN_HOST=x` was filed under the key "export WIN_HOST" and was invisible to
# the WIN_HOST lookup, while this script accepted the `export ` prefix and took the last
# match. On a file carrying both spellings the two disagreed, and fail-open in the worst
# direction: measured on a fixture with a bare out-of-boundary line followed by an
# in-boundary `export` line, the gate approved the in-boundary value while window-smoke
# would have connected to the out-of-boundary one. That divergence is closed at the parser
# level: MacdowsCore's EnvFile is the one parser now, and window-smoke's main.swift, the app,
# and Tools/bridge-smoke (through its GateShim) all read host.env through it instead of each
# carrying their own. Its rule is the
# Swift statement of the same intent as the grep/sed pair below -- optional `export ` prefix
# dropped, surrounding quotes stripped, a later occurrence of a key winning over an earlier
# one, which is this script's `tail -1`.
#
# Where the two still differ, the difference either fails CLOSED or is made irrelevant by the
# export below, never in a way that could point this script and window-smoke at different
# hosts. EnvFile trims a line before reading it
# and accepts any whitespace after `export`; the ERE below anchors the key at column 0 and
# wants exactly one space, so `  WIN_HOST=x`, `export<tab>WIN_HOST=x` and `export  WIN_HOST=x`
# yield nothing here -- and nothing means an empty SMOKE_HOST, which the gate refuses as an
# empty target. EnvFile strips only *matching* quotes where the sed pair strips a leading and
# a trailing one independently, so `WIN_HOST="x'` parses differently in the two; that one is
# neutralised by the export after the gate. None of them can make this script approve one
# host and window-smoke dial another.
SMOKE_HOST="${WIN_HOST:-}"
# ${HOME:-} rather than $HOME, matching crdp_assert_lab_boundary's own reasoning: this
# script runs under `set -u`, so with HOME unset the bare expansion would kill it outright,
# here of all places -- before the gate, and therefore before any DONE line reaches the log
# that every caller of this launcher polls on. Degrading to an absolute path that cannot
# exist keeps the failure inside the fail-closed path instead: no host.env is read,
# SMOKE_HOST stays empty, the gate refuses an empty target, and the run ends the way every
# other refusal does, with DONE exit=78.
HOST_ENV_FILE="${HOME:-}/.config/macdows/host.env"
if [ -z "$SMOKE_HOST" ] && [ -f "$HOST_ENV_FILE" ]; then
    SMOKE_HOST="$(grep -E '^(export )?WIN_HOST=' "$HOST_ENV_FILE" | tail -1 |
        sed -E -e "s/^(export )?WIN_HOST=//" -e "s/^[\"']//" -e "s/[\"']\$//")"
fi
if ! crdp_assert_lab_boundary "$SMOKE_HOST"; then
    echo "[launcher] live-host boundary gate refused this target -- nothing was built, nothing was connected" >&2
    echo "DONE exit=78" >>"$LOG"
    exit 78
fi
# Hand window-smoke the exact string the gate just cleared, instead of letting it re-derive
# a host from the same file at all. Keep this even though EnvFile and the extraction above
# now line up: alignment is a property two separate implementations currently happen to
# share, and re-deriving would put the gate's verdict at the mercy of it holding forever.
# main.swift's EnvFile.value prefers the environment variable over the file, so this is
# instead a by-construction guarantee, independent of any parser: what was validated is what
# gets dialled, whatever host.env happens to contain and however it is read.
export WIN_HOST="$SMOKE_HOST"

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

# Every exit from here on writes a DONE line first: that line is the whole contract callers
# poll on, and a build failure that exits silently leaves them reading an empty log.
# Generate the project only when it is missing, but ALWAYS run xcodebuild: an
# existence-only check on $BIN ran an 8-day-stale binary against a freshly rebuilt
# libfreerdp3 on 2026-09-01 (the patch-queue metadata commit rotated the FreeRDP config
# hash, so the dylibs moved out from under the old binary's rpath) and dyld aborted
# before main(). Incremental xcodebuild is a few seconds when everything is fresh --
# that is the correct price for never again exec'ing a binary older than its sources
# or its runtime dylibs.
if [[ ! -d "$APP_DIR/Macdows.xcodeproj" ]]; then
    echo "[launcher] $APP_DIR/Macdows.xcodeproj not found -- generating project..." >&2
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "[launcher] xcodegen not found on PATH -- install it (e.g. 'brew install xcodegen') and retry" >&2
        echo "DONE exit=1" >>"$LOG"
        exit 1
    fi
    if ! (
        cd "$APP_DIR" || exit 1
        xcodegen generate
    ); then
        echo "DONE exit=1" >>"$LOG"
        exit 1
    fi
fi
if ! xcodebuild -project "$APP_DIR/Macdows.xcodeproj" -scheme window-smoke -configuration Debug \
    build -derivedDataPath "$APP_DIR/build"; then
    echo "DONE exit=1" >>"$LOG"
    exit 1
fi

"$BIN" >>"$LOG" 2>&1
echo "DONE exit=$?" >>"$LOG"

# Self-close this Terminal window on clean completion; keep it open on failure
# so the scrollback stays inspectable. tty-matched so only this window closes.
RC=$(tail -1 "$LOG" | sed -n 's/^DONE exit=\([0-9]*\)$/\1/p')
if [ "${RC:-1}" -eq 0 ] && [ -n "${TERM_PROGRAM:-}" ] && [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
    TTY_NAME=$(tty)
    osascript -e 'tell application "Terminal" to close (every window whose tty is "'"$TTY_NAME"'")' >/dev/null 2>&1 &
fi
