#!/usr/bin/env bash
# probe.sh: build (if needed) and run Tools/rail-probe against a real Windows RDS host.
#
# Credentials are never hardcoded here or anywhere in the repo. They come from a file
# exporting WIN_HOST, WIN_USER, WIN_PASS — pointed to by $CRDP_HOST_ENV, or defaulting to
# ~/.config/macdows/host.env. That file must never be tracked by git (see the
# security red lines in AGENTS.md — this script refuses to run without it rather than
# falling back to a built-in address).
#
# Usage: Scripts/probe.sh [rail-probe args, e.g. --app 'C:\Windows\System32\winver.exe' --duration 25 --out runs/s1.jsonl]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd cmake

HOST_ENV="${CRDP_HOST_ENV:-$HOME/.config/macdows/host.env}"
if [ ! -f "$HOST_ENV" ]; then
	die "host credentials file not found: $HOST_ENV
Set \$CRDP_HOST_ENV to a file exporting WIN_HOST, WIN_USER, WIN_PASS, or create
$HOME/.config/macdows/host.env with those three variables. No host address or
credential may ever be committed to this repository (see AGENTS.md security red lines)."
fi

# shellcheck disable=SC1090
source "$HOST_ENV"
: "${WIN_HOST:?WIN_HOST not set in $HOST_ENV}"
: "${WIN_USER:?WIN_USER not set in $HOST_ENV}"
: "${WIN_PASS:?WIN_PASS not set in $HOST_ENV}"
export WIN_HOST WIN_USER WIN_PASS

FREERDP_PREFIX="$CRDP_BUILD_DIR/freerdp/current/prefix"
[ -d "$FREERDP_PREFIX" ] || die "no FreeRDP build found at $FREERDP_PREFIX — run Scripts/build-freerdp.sh first"

PROBE_DIR="$CRDP_REPO_ROOT/Tools/rail-probe"
BUILD_DIR="$PROBE_DIR/build"

log "Configuring rail-probe against $FREERDP_PREFIX"
cmake -S "$PROBE_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=RelWithDebInfo -DFREERDP_PREFIX="$FREERDP_PREFIX"
cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"

BIN="$BUILD_DIR/rail-probe"
[ -x "$BIN" ] || die "build succeeded but $BIN was not produced"

log "Running rail-probe against host from \$WIN_HOST (value withheld from this script's own log output)"
exec "$BIN" "$@"
