#!/usr/bin/env bash
# test-cliprdr.sh: build Tools/cliprdr-check against a FreeRDP install prefix and run it -- an
# OFFLINE behaviour check (no socket, no host, no credentials) of the App's clipboard bridge
# (App/CRBridge/crclip_bridge.c, adr/0026 lane L3) attached to the prefix's built-in cliprdr
# channel, fed with server PDUs from FreeRDP's own server-side cliprdr encoder. It checks that
# every bridge callback returns success (a non-zero return ends the whole session), that the
# channel's thread sends only the two on-the-spot replies, that no data response is ever sent
# under a mode without Mac -> Windows (the channel asserts, and this build aborts on it), and
# what the bridge stores, posts, drops and counts on every path, with no clipboard content in any
# log line.
#
# Not Scripts/probe.sh and nothing like it: no host.env, no boundary gate, nothing dials. Tier 2
# runs it after Bootstrap (the "cliprdr bridge check" step in .github/workflows/tier2.yml).
#
# The byte limit the check passes to the bridge's store is read from the one place it lives,
# MacdowsCore's ClipboardLimits.defaultMaxBytes (Packages/MacdowsCore/Sources/MacdowsCore/
# Clipboard/ClipboardPolicy.swift): exactly one line of the form
#   public static let defaultMaxBytes: Int = <n> [* <n> ...]
# is required, or the run cannot judge.
#
# Usage: Scripts/test-cliprdr.sh
#   CRDP_FREERDP_PREFIX=<prefix>          check that prefix instead of .build/freerdp/current/prefix
#   CLIPRDR_CHECK_SANITIZER=thread|address build the whole binary with that sanitizer, in a build
#                                         directory of its own (key suffix -thread / -address)
# The binary is built under .build/cliprdr-check/<key>/ (untracked), keyed like
# Scripts/test-rail-handshake.sh: the prefix's config-hash directory name, or a digest of its
# physical path for a prefix outside .build/freerdp/<config-hash>/prefix. Configure and build
# output goes to stderr; stdout is the binary's case lines, ending in one verdict line
# "cliprdr-check: PASS|FAIL|ERROR ...".
# Exit: 0 PASS; 1 FAIL (the bridge does not behave as required); 2 ERROR (could not judge: no
# prefix, no toolchain, no limit, the build failed, the binary crashed or a self-check failed).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

cannot_judge() {
	log "ERROR: $*"
	echo "cliprdr-check: ERROR $* -- this run cannot judge the bridge"
	exit 2
}

for c in cmake pkg-config; do
	command -v "$c" >/dev/null 2>&1 || cannot_judge "required command not found: $c"
done

LIMIT_SOURCE="$CRDP_REPO_ROOT/Packages/MacdowsCore/Sources/MacdowsCore/Clipboard/ClipboardPolicy.swift"
[ -f "$LIMIT_SOURCE" ] || cannot_judge "no $LIMIT_SOURCE to read the clipboard byte limit from"
LIMIT_PATTERN='^    public static let defaultMaxBytes: Int = [0-9]+( \* [0-9]+)*$'
LIMIT_LINES="$(grep -cE "$LIMIT_PATTERN" "$LIMIT_SOURCE" || true)"
[ "$LIMIT_LINES" = "1" ] || cannot_judge "expected exactly one defaultMaxBytes line in $LIMIT_SOURCE, found $LIMIT_LINES"
LIMIT_EXPR="$(grep -E "$LIMIT_PATTERN" "$LIMIT_SOURCE" | sed -E 's/^.*= //')"
LIMIT=1
for factor in ${LIMIT_EXPR//\*/ }; do
	LIMIT=$((LIMIT * factor))
done
log "clipboard byte limit $LIMIT (ClipboardLimits.defaultMaxBytes = $LIMIT_EXPR)"

SANITIZER="${CLIPRDR_CHECK_SANITIZER:-}"
case "$SANITIZER" in
"" | thread | address) ;;
*) cannot_judge "CLIPRDR_CHECK_SANITIZER must be thread, address or unset" ;;
esac

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
	KEY="path-$(printf '%s' "$FREERDP_PREFIX" | shasum -a 256 | cut -c1-16)"
fi
if [ -n "$SANITIZER" ]; then
	KEY="$KEY-$SANITIZER"
fi
BUILD_DIR="$CRDP_BUILD_DIR/cliprdr-check/$KEY"
log "checking the clipboard bridge against the FreeRDP prefix $FREERDP_PREFIX (build dir $BUILD_DIR)"

cmake -S "$CRDP_REPO_ROOT/Tools/cliprdr-check" -B "$BUILD_DIR" \
	-DCMAKE_BUILD_TYPE=RelWithDebInfo -DFREERDP_PREFIX="$FREERDP_PREFIX" \
	-DCLIPRDR_CHECK_SANITIZER="$SANITIZER" >&2 \
	|| cannot_judge "configuring Tools/cliprdr-check against $FREERDP_PREFIX failed"
cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 2)" >&2 \
	|| cannot_judge "building Tools/cliprdr-check failed"
BIN="$BUILD_DIR/cliprdr-check"
[ -x "$BIN" ] || cannot_judge "the build succeeded but $BIN was not produced"

set +e
"$BIN" "$FREERDP_PREFIX" "$LIMIT"
rc=$?
set -e
case "$rc" in
0 | 1 | 2) exit "$rc" ;;
*) cannot_judge "cliprdr-check exited $rc (a crash is not a verdict)" ;;
esac
