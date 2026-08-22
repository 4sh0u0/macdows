#!/usr/bin/env bash
# bootstrap.sh: one-time / idempotent environment setup.
#   - checks brew dependencies (cmake, ninja, xcodegen, jq), installs any that are missing
#   - initializes the ThirdParty/FreeRDP submodule
#   - verifies the submodule's checked-out commit matches deps/freerdp.lock
#   - builds OpenSSL + FreeRDP, then runs `xcodegen generate`
#
# End to end, this is "clean checkout -> one command -> buildable Xcode project": after
# this script, `xcodebuild -project App/Macdows.xcodeproj -scheme Macdows build`
# just works, with no manual ordering of the individual Scripts/*.sh required first.
#
# Safe to re-run at any time; every step is a no-op if already satisfied.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

# ffmpeg + pkg-config: Phase 2 W0(2) AVC caps flip (adr/0007) -- Scripts/build-freerdp.sh
# defaults CRDP_WITH_FFMPEG=1, which needs both to configure FreeRDP's H264-decode
# ffmpeg backend (local-dev-only source; see deps/freerdp.lock's "ffmpeg" block).
REQUIRED_FORMULAS=(cmake ninja xcodegen jq ffmpeg pkg-config)

require_cmd git

if ! command -v brew >/dev/null 2>&1; then
	die "Homebrew not found. Install it from https://brew.sh, then re-run bootstrap.sh."
fi

log "Checking Homebrew dependencies: ${REQUIRED_FORMULAS[*]}"
for formula in "${REQUIRED_FORMULAS[@]}"; do
	if command -v "$formula" >/dev/null 2>&1; then
		log "  $formula: found ($(command -v "$formula"))"
		continue
	fi
	log "  $formula: missing, installing via brew"
	brew install "$formula"
done

log "Initializing git submodules"
git -C "$CRDP_REPO_ROOT" submodule update --init --recursive

LOCK_FILE="$CRDP_REPO_ROOT/deps/freerdp.lock"
[ -f "$LOCK_FILE" ] || die "missing $LOCK_FILE"

SUBMODULE_DIR="$CRDP_REPO_ROOT/ThirdParty/FreeRDP"
# A submodule's .git is a *file* (a gitdir pointer), not a directory — hence -e, not -d.
[ -e "$SUBMODULE_DIR/.git" ] || die "ThirdParty/FreeRDP has no .git after submodule update — check network access to github.com"

EXPECTED_SHA="$(jq -r '.commit' "$LOCK_FILE")"
# Explicit if, not `A && B || die` (shellcheck SC2015): with two conditions chained through
# && before the ||, a review-round CI tightening (shellcheck -S style) treats the pattern
# as an error, not just a style note, since it reads ambiguously as "if A then B else die"
# when it's actually "die unless both A and B hold" -- this form says exactly that.
if [ -z "$EXPECTED_SHA" ] || [ "$EXPECTED_SHA" = "null" ]; then
	die "deps/freerdp.lock has no .commit field"
fi

ACTUAL_SHA="$(git -C "$SUBMODULE_DIR" rev-parse HEAD)"

if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
	die "ThirdParty/FreeRDP is at $ACTUAL_SHA but deps/freerdp.lock pins $EXPECTED_SHA.
Fix with: git -C ThirdParty/FreeRDP checkout $EXPECTED_SHA"
fi
log "submodule SHA matches deps/freerdp.lock ($ACTUAL_SHA)"

log "Building OpenSSL (idempotent, no-op if already built)"
"$SCRIPT_DIR/build-openssl.sh"

log "Building FreeRDP (idempotent, no-op if already built)"
"$SCRIPT_DIR/build-freerdp.sh"

PROJECT_SPEC="$CRDP_REPO_ROOT/App/project.yml"
if [ -f "$PROJECT_SPEC" ]; then
	log "Generating the Xcode project (xcodegen generate --spec App/project.yml)"
	xcodegen generate --spec "$PROJECT_SPEC"
else
	log "No App/project.yml yet — skipping xcodegen generate"
fi

log "bootstrap.sh: OK"
