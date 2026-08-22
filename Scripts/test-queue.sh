#!/usr/bin/env bash
# test-queue.sh: runs Packages/MacdowsCore/Sources/CRDPQueue's test suite three ways —
# plain, under ThreadSanitizer, and under AddressSanitizer — and fails if any of the
# three finds anything.
#
# adr/0005 §1/§3's event-queue layer (crdpq_control/crdpq_frames/crdpq_outbound) is where
# this repo's shared-mutable-state-across-threads lives, on purpose (adr/0005 §5: this is
# exactly the C boundary Swift 6 strict concurrency doesn't manage). A data race or
# memory-safety bug here is the highest-value thing to catch before it ever reaches a real
# FreeRDP callback thread, so this gets its own dedicated verification entry point rather
# than folding into a plain `swift test`.
#
# `swift test --sanitize=thread`/`--sanitize=address` were verified (W3) to work cleanly
# for this mixed C+Swift-Testing target on this toolchain — no separate cmake/clang-only
# TSan harness turned out to be necessary, so this script is a thin, repeatable wrapper
# around SwiftPM's own sanitizer support rather than a standalone C stress program. If a
# future toolchain regresses that support, this is the one place to swap in a standalone
# harness without touching every other place that might want "run the queue's stress
# tests under a sanitizer".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd swift
require_cmd clang

PACKAGE_DIR="$CRDP_REPO_ROOT/Packages/MacdowsCore"

log "Plain test run"
swift test --package-path "$PACKAGE_DIR"

log "ThreadSanitizer run (--sanitize=thread)"
swift test --package-path "$PACKAGE_DIR" --sanitize=thread

log "AddressSanitizer run (--sanitize=address)"
swift test --package-path "$PACKAGE_DIR" --sanitize=address

# H1 (W3 review): the table-full coverage point that motivated H1's heap-out-of-bounds fix
# requires intercepting calloc at compile time (a `calloc` macro interposed before
# #include-ing crdpq_frames.c directly) — something no Swift Testing case can express.
# That one coverage point lives as a standalone C program instead (see
# Tools/crdpq-stress/frames_full.c's own header comment for the full rationale) and is
# compiled+run here, in all three of the same modes as the swift test runs above, since
# SwiftPM has no way to build a fault-injected variant of a target's own source file.
CRDPQ_SRC="$PACKAGE_DIR/Sources/CRDPQueue"
CRDPQ_INC="$CRDPQ_SRC/include"
STRESS_SRC="$CRDP_REPO_ROOT/Tools/crdpq-stress/frames_full.c"
STRESS_BUILD_DIR="$CRDP_BUILD_DIR/crdpq-stress"
mkdir -p "$STRESS_BUILD_DIR"

log "frames_full: plain build"
clang -std=c11 -Wall -Wextra -I "$CRDPQ_SRC" -I "$CRDPQ_INC" "$STRESS_SRC" -o "$STRESS_BUILD_DIR/frames_full_plain"
"$STRESS_BUILD_DIR/frames_full_plain"

log "frames_full: ThreadSanitizer build"
clang -std=c11 -Wall -Wextra -fsanitize=thread -g -I "$CRDPQ_SRC" -I "$CRDPQ_INC" "$STRESS_SRC" -o "$STRESS_BUILD_DIR/frames_full_tsan"
"$STRESS_BUILD_DIR/frames_full_tsan"

log "frames_full: AddressSanitizer build"
clang -std=c11 -Wall -Wextra -fsanitize=address -g -I "$CRDPQ_SRC" -I "$CRDPQ_INC" "$STRESS_SRC" -o "$STRESS_BUILD_DIR/frames_full_asan"
"$STRESS_BUILD_DIR/frames_full_asan"

log "test-queue.sh: OK (plain + TSan + ASan all clean, including frames_full)"
