#!/usr/bin/env bash
# probe.sh: build (if needed) and run Tools/rail-probe against a real Windows RDS host.
#
# Credentials are never hardcoded here or anywhere in the repo. They come from a file
# exporting WIN_HOST, WIN_USER, WIN_PASS — pointed to by $CRDP_HOST_ENV, or defaulting to
# ~/.config/macdows/host.env. That file must never be tracked by git (see the
# security red lines in AGENTS.md — this script refuses to run without it rather than
# falling back to a built-in address).
#
# LIVE-HOST BOUNDARY GATE. This script dials a real machine, so crdp_assert_lab_boundary
# (Scripts/lib.sh) has to confirm the target is inside the owner's own lab segments before
# anything else happens; the allowed segments live only in the untracked
# ~/.config/macdows/lab-boundary.env. The gate is fail-closed -- a missing boundary file, an
# unresolvable host or an address outside the segments all refuse -- and neither it nor the
# refusal below ever names a segment, so a scrollback or a CI transcript cannot become the
# place the owner's network shape leaks. Once the gate has passed, this script exports
# MACDOWS_BOUNDARY_GATED=1; rail-probe refuses to run without it, so the binary this script
# builds cannot be usefully run behind this script's back (see the handshake comment below).
#
# Usage: Scripts/probe.sh [rail-probe args, e.g. --app 'C:\Windows\System32\winver.exe' --duration 25 --out runs/s1.jsonl]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Nothing this script inherited may stand in for its own verdict. The handshake below is a
# statement about THIS run -- "the gate passed here" -- so any value the caller already had is
# cleared first, before the gate is even consulted. Without this the invariant the handshake
# comment states would be false in the one case that matters most: a maintainer using the
# documented `export MACDOWS_BOUNDARY_GATED=skip-gate-i-know` override in their shell would
# hand the handshake to the entire process tree of a run the boundary is about to REFUSE.
# Clearing it here also makes the refusal path's promise exact -- a refused run leaves no
# handshake behind, whatever the environment it started in.
unset MACDOWS_BOUNDARY_GATED

# ${HOME:-} rather than $HOME in both places below, matching crdp_assert_lab_boundary and
# Scripts/run-window-smoke.command: this script runs under `set -u`, where a bare $HOME with
# HOME unset kills it on the spot with "HOME: unbound variable". That is still fail-closed --
# nothing is built and nothing is dialled -- but it reports a shell diagnostic instead of the
# script's own "host credentials file not found" die, which is the message that actually
# tells the reader what to do.
HOST_ENV="${CRDP_HOST_ENV:-${HOME:-}/.config/macdows/host.env}"
if [ ! -f "$HOST_ENV" ]; then
	die "host credentials file not found: $HOST_ENV
Set \$CRDP_HOST_ENV to a file exporting WIN_HOST, WIN_USER, WIN_PASS, or create
${HOME:-}/.config/macdows/host.env with those three variables. No host address or
credential may ever be committed to this repository (see AGENTS.md security red lines)."
fi

# shellcheck disable=SC1090
source "$HOST_ENV"
: "${WIN_HOST:?WIN_HOST not set in $HOST_ENV}"
: "${WIN_USER:?WIN_USER not set in $HOST_ENV}"
: "${WIN_PASS:?WIN_PASS not set in $HOST_ENV}"

# The gate runs here: after WIN_HOST is known, and deliberately before require_cmd/the build
# below rather than next to the exec. Two reasons. A refusal must cost nothing and change
# nothing -- no toolchain requirement, no configure, no compile, no artifacts on disk -- so
# "the boundary said no" is the whole story of the run. And the refusal path stays testable
# on a machine that has no cmake at all, which is what lets Scripts/test-lab-boundary.sh pin
# this ordering in Tier 1 CI (ubuntu-latest, no FreeRDP prefix, no toolchain assumptions).
#
# The gate takes the host as an argument, so it needs nothing exported; the export therefore
# waits until after the verdict. "Costs nothing" has to include the credentials: the gate
# spawns a python3 child, and on a refused run there is no reason for WIN_PASS to have been
# in any child's environment (same-user-visible via `ps e` / /proc/<pid>/environ). This
# cannot help when host.env writes `export WIN_PASS=` itself -- sourcing it exports for us --
# but probe.sh should not be the thing that widens the exposure.
crdp_assert_lab_boundary "$WIN_HOST" || die "refusing to probe: target host is outside the owner lab boundary (or the boundary file is missing/unreadable); see AGENTS.md live-host testing boundary"

export WIN_HOST WIN_USER WIN_PASS

# Launcher handshake for Tools/rail-probe. The gate above is a shell function, so it only
# protects the shell entry points; the binary this script builds lands at
# Tools/rail-probe/build/rail-probe and can be run straight from a shell, where nothing
# checks anything. rail-probe's main() therefore refuses (exit 78) unless it is told that a
# launcher already cleared the boundary, and this is where it gets told.
#
# It is a handshake, not a second opinion: the boundary rule keeps exactly one
# implementation (crdp_assert_lab_boundary), and rail-probe only ever answers "was I
# started by something that ran it?". The threat model is an accidental ungated run -- a
# recalled shell-history line, a script that learned the binary's path -- not a local user
# who means to bypass it and owns this environment anyway. The C side documents the value
# vocabulary ("1" here, a deliberate "skip-gate-i-know" override for a developer who has
# gated by other means); the two files have to agree, and the boundary suite pins that.
#
# Placed AFTER the gate, for the same reason as the credential export above: a refused run
# must leave nothing behind that could let a later, ungated invocation slip through. If
# this sat before the refusal, the handshake would be exported into the environment of a
# run the boundary had just rejected. This line plus the `unset` near the top of the script
# are what make that an invariant rather than a habit: inside this process the handshake
# exists on the far side of the gate and nowhere else, no matter what the caller exported.
export MACDOWS_BOUNDARY_GATED=1

require_cmd cmake

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
