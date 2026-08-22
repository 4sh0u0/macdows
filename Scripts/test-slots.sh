#!/usr/bin/env bash
# test-slots.sh: CRSurfaceSlots' own permanent regression suite (Tools/slots-test/main.mm),
# run plain and under AddressSanitizer -- mirrors test-queue.sh's shape for CRDPQueue, one
# level up the stack. adr/0005 §2's frame pathway (App/CRBridge/CRSurfaceSlots.h/.mm) had
# zero unit tests before the W4b review flagged it; this is where that coverage lives now,
# standalone (no FreeRDP connection, no CRSession -- exercises the C API directly), so it
# can run in CI or locally without a real RDP host.
#
# Needs a built FreeRDP prefix only for freerdp/codec/region.h's region16_* symbols (H1's
# own dependency, added specifically for the dirty-rect-union accumulation fix) -- IOSurface/
# CoreFoundation are system frameworks, no separate build step needed for those.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd clang++

log "Ensuring FreeRDP is built (region16_* symbols)"
"$SCRIPT_DIR/build-openssl.sh"
"$SCRIPT_DIR/build-freerdp.sh"

FREERDP_PREFIX="$CRDP_BUILD_DIR/freerdp/current/prefix"
CRBRIDGE_SRC="$CRDP_REPO_ROOT/App/CRBridge"
TEST_SRC="$CRDP_REPO_ROOT/Tools/slots-test/main.mm"
BUILD_DIR="$CRDP_BUILD_DIR/slots-test"
mkdir -p "$BUILD_DIR"

# shellcheck disable=SC2054 # the commas inside -Wl,-rpath,... are the linker's own
# argument syntax, not (mis-)used array-element separators.
COMMON_FLAGS=(
    -std=c++17 -Wall -Wextra -fobjc-arc
    -I "$CRBRIDGE_SRC"
    -I "$FREERDP_PREFIX/include/freerdp3"
    -I "$FREERDP_PREFIX/include/winpr3"
    -L "$FREERDP_PREFIX/lib"
    -Wl,-rpath,"$FREERDP_PREFIX/lib"
    -lfreerdp3 -lwinpr3
    -framework Foundation -framework CoreFoundation -framework IOSurface
)

log "Plain build"
clang++ "${COMMON_FLAGS[@]}" "$CRBRIDGE_SRC/CRSurfaceSlots.mm" "$TEST_SRC" -o "$BUILD_DIR/slots_test_plain"
"$BUILD_DIR/slots_test_plain"

log "AddressSanitizer build"
clang++ "${COMMON_FLAGS[@]}" -fsanitize=address -fno-omit-frame-pointer -g \
    "$CRBRIDGE_SRC/CRSurfaceSlots.mm" "$TEST_SRC" -o "$BUILD_DIR/slots_test_asan"
"$BUILD_DIR/slots_test_asan"

log "test-slots.sh: OK (plain + ASan both clean)"
