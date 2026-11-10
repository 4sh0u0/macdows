#!/usr/bin/env bash
# test-rail-handshake.sh: build Tools/rail-handshake-check against a FreeRDP install prefix and run
# it -- an OFFLINE behaviour check (no socket, no host, no credentials) that the prefix's built-in
# RAIL channel answers the server handshake with HANDSHAKE, then CLIENTSTATUS, and no EXEC, for
# both the Handshake and the HandshakeEx server PDU. That is FreeRDP PR #13696, carried as
# ThirdParty/patches/0003-rail-client-status-on-default-handshake.patch until a pin >= 3.33.0.
#
# Why (lane patch-pins, 2026-11-10; lane rail-clientstatus gate r1 m-6): without that behaviour
# the current Windows host never sends a window order, and nothing offline noticed -- a deleted
# patch file left Tier 1 and Tier 2 green. Scripts/check-patch-queue.sh rule 5 ties the lock to the
# queue directory; this ties the BUILT prefix to the behaviour, and keeps holding after the patch
# retires (it pins the behaviour, not the file).
#
# Not Scripts/probe.sh and nothing like it: no host.env, no boundary gate, nothing dials. Tier 2
# runs it after Bootstrap (the "RAIL handshake check" step in .github/workflows/tier2.yml).
#
# Usage: Scripts/test-rail-handshake.sh
#   CRDP_FREERDP_PREFIX=<prefix>  check that prefix instead of .build/freerdp/current/prefix
#                                 (an older config-hash dir, say, as a negative control)
# The binary is built under .build/rail-handshake-check/<key>/ (untracked), one build directory --
# so one CMake cache -- per key. The key is the prefix's config-hash directory name, or a digest
# of its physical path for a prefix outside .build/freerdp/<config-hash>/prefix. A reused cache
# keeps the include and -L paths pkg-config found at its FIRST configure (only the rpath follows a
# new FREERDP_PREFIX), so two different prefixes must never share a key: two physical paths with
# the same config hash would share one, which is harmless because the same hash means the same
# inputs. The physical path is passed to CMake on purpose; Tools/rail-handshake-check/
# CMakeLists.txt says why it departs from rail-probe's lexical spelling. Configure and build
# output goes to stderr; stdout is the binary's case lines, ending in one verdict line
# "rail-handshake-check: PASS|FAIL|ERROR ...".
# Exit: 0 PASS; 1 FAIL (the behaviour is missing from the prefix); 2 ERROR (could not judge: no
# prefix, no toolchain, the build failed, the binary crashed or its own self-check failed).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

cannot_judge() {
	log "ERROR: $*"
	echo "rail-handshake-check: ERROR $* -- this run cannot judge the prefix"
	exit 2
}

for c in cmake pkg-config; do
	command -v "$c" >/dev/null 2>&1 || cannot_judge "required command not found: $c"
done

PREFIX_IN="${CRDP_FREERDP_PREFIX:-$CRDP_BUILD_DIR/freerdp/current/prefix}"
[ -d "$PREFIX_IN" ] || cannot_judge "no FreeRDP prefix at $PREFIX_IN -- run Scripts/build-freerdp.sh first, or set CRDP_FREERDP_PREFIX"
# Physical path: `current` is a moving link, and the binary's rpath and its build dir must both
# name the config-hash directory being judged (the binary refuses a library loaded from anywhere
# else, too).
FREERDP_PREFIX="$(cd "$PREFIX_IN" && pwd -P)"
CONFIG_DIR="$(basename "$(dirname "$FREERDP_PREFIX")")"
if [[ "$CONFIG_DIR" =~ ^[0-9a-f]{16}$ ]]; then
	KEY="$CONFIG_DIR"
else
	# A prefix outside .build/freerdp/<config-hash>/prefix: key the build dir by its path instead.
	KEY="path-$(printf '%s' "$FREERDP_PREFIX" | shasum -a 256 | cut -c1-16)"
fi
BUILD_DIR="$CRDP_BUILD_DIR/rail-handshake-check/$KEY"
log "checking the FreeRDP prefix $FREERDP_PREFIX (build dir $BUILD_DIR)"
if [ -f "$FREERDP_PREFIX/../build-manifest.json" ] && command -v jq >/dev/null 2>&1; then
	log "FreeRDP prefix manifest: $(jq -c '{configHash, patches}' "$FREERDP_PREFIX/../build-manifest.json")"
fi

cmake -S "$CRDP_REPO_ROOT/Tools/rail-handshake-check" -B "$BUILD_DIR" \
	-DCMAKE_BUILD_TYPE=RelWithDebInfo -DFREERDP_PREFIX="$FREERDP_PREFIX" >&2 \
	|| cannot_judge "configuring Tools/rail-handshake-check against $FREERDP_PREFIX failed"
cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 2)" >&2 \
	|| cannot_judge "building Tools/rail-handshake-check failed"
BIN="$BUILD_DIR/rail-handshake-check"
[ -x "$BIN" ] || cannot_judge "the build succeeded but $BIN was not produced"

set +e
"$BIN" "$FREERDP_PREFIX"
rc=$?
set -e
case "$rc" in
0 | 1 | 2) exit "$rc" ;;
*) cannot_judge "rail-handshake-check exited $rc (a crash is not a verdict)" ;;
esac
