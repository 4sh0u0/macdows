#!/usr/bin/env bash
# test-build-freerdp-toggle.sh: offline pins for Scripts/build-freerdp.sh's lab toggle
# CRDP_LAB_SCALEDMAP_ADVERTISE (ADR-0016 D1) through the `--print-config-hash` seam, which
# computes the config hash and exits before anything under .build/ is touched.
#
# Pinned: the toggle is validated (only 0/1), it folds into the config hash (so the lab build
# can never land in the product prefix), and the seam itself is side-effect free. What this
# cannot pin (live wiring, no offline seam): that a lab build never moves `.build/freerdp/
# current` and that the -D flag reaches cmake -- both are guarded by inspection and by the
# manifest of the real lab build (crdpLabScaledmapAdvertise / cmakeCache.MACDOWS_LAB_SCALEDMAP_ADVERTISE).
#
# Needs the script's own prerequisites (cmake, ninja, jq, shasum, git, the pinned submodule at
# the lock commit); CRDP_WITH_FFMPEG=0 keeps it independent of a self-built ffmpeg prefix. Where a
# prerequisite is missing (Tier 1's ubuntu runner has no ninja) it says SKIP and exits 0 -- the
# pin is a macOS developer-machine check, run before pushing a build-script change.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_FREERDP="${BUILD_FREERDP:-$SCRIPT_DIR/build-freerdp.sh}"

for c in cmake ninja jq shasum git; do
    if ! command -v "$c" >/dev/null 2>&1; then echo "SKIP: $c not installed (build-freerdp.sh needs it before the hash seam)"; exit 0; fi
done
[ -e "$REPO_ROOT/ThirdParty/FreeRDP/.git" ] || { echo "SKIP: ThirdParty/FreeRDP submodule not checked out"; exit 0; }

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL $1"; }
snapshot() {
    # A fresh checkout (CI) has no .build/freerdp at all; that is "nothing there", not a failure.
    [ -d "$REPO_ROOT/.build/freerdp" ] || { echo "<no .build/freerdp>"; return 0; }
    find "$REPO_ROOT/.build/freerdp" -mindepth 1 -maxdepth 1 | sort | tr '\n' ' '
}

before="$(snapshot)"
set +e
h0="$(CRDP_WITH_FFMPEG=0 CRDP_LAB_SCALEDMAP_ADVERTISE=0 "$BUILD_FREERDP" --print-config-hash 2>/dev/null)"; r0=$?
h1="$(CRDP_WITH_FFMPEG=0 CRDP_LAB_SCALEDMAP_ADVERTISE=1 "$BUILD_FREERDP" --print-config-hash 2>/dev/null)"; r1=$?
hd="$(CRDP_WITH_FFMPEG=0 "$BUILD_FREERDP" --print-config-hash 2>/dev/null)"; rd=$?
e2="$(CRDP_WITH_FFMPEG=0 CRDP_LAB_SCALEDMAP_ADVERTISE=2 "$BUILD_FREERDP" --print-config-hash 2>&1)"; r2=$?
set -e
after="$(snapshot)"

if [ "$r0" -eq 0 ] && [[ "$h0" =~ ^[0-9a-f]{16}$ ]]; then ok "--print-config-hash prints a 16-hex config hash and exits 0"; else bad "--print-config-hash: rc=$r0 out=[$h0]"; fi
if [ "$rd" -eq 0 ] && [ "$hd" = "$h0" ]; then ok "the toggle defaults to 0 (unset == 0, same hash)"; else bad "default toggle: rc=$rd hash=[$hd] vs [$h0]"; fi
if [ "$r1" -eq 0 ] && [[ "$h1" =~ ^[0-9a-f]{16}$ ]] && [ "$h1" != "$h0" ]; then ok "CRDP_LAB_SCALEDMAP_ADVERTISE=1 folds into the hash (a different prefix dir)"; else bad "toggle=1: rc=$r1 hash=[$h1] vs [$h0]"; fi
if [ "$r2" -ne 0 ] && [[ "$e2" == *"CRDP_LAB_SCALEDMAP_ADVERTISE must be 0 or 1"* ]]; then ok "CRDP_LAB_SCALEDMAP_ADVERTISE=2 is refused by name"; else bad "toggle=2: rc=$r2 out=[$e2]"; fi
if [ "$before" = "$after" ]; then ok "the hash seam created nothing under .build/freerdp"; else bad "seam side effect: before=[$before] after=[$after]"; fi

# gate r1 I-5: "a lab build never publishes `current`" is a lib.sh predicate both link sites call.
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
set +e
crdp_freerdp_build_publishes_current 0; p0=$?
crdp_freerdp_build_publishes_current 1; p1=$?
set -e
if [ "$p0" -eq 0 ] && [ "$p1" -ne 0 ]; then ok "crdp_freerdp_build_publishes_current: product build publishes current, lab build (toggle 1) never does"; else bad "publishes_current predicate: toggle0=$p0 toggle1=$p1"; fi
if [ "$(grep -cE '^[[:space:]]*if[[:space:]]+!?[[:space:]]*crdp_freerdp_build_publishes_current[[:space:]]+"' "$BUILD_FREERDP")" -ge 2 ]; then ok "both current-link sites in build-freerdp.sh consult the predicate (call-shaped lines, not mentions)"; else bad "build-freerdp.sh does not consult the predicate at both current-link sites"; fi

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
