#!/usr/bin/env bash
# build-freerdp.sh: apply the patch queue, configure FreeRDP with "config A'" (adr/0004's
# config A, corrected per adr/0006 §3), build with Ninja, and install to
# .build/freerdp/<config-hash>/prefix. A `.build/freerdp/current` symlink always points
# at the most recently built config so downstream consumers (App/, Tools/rail-probe)
# don't need to know the hash.
#
# Idempotent: if a prefix already exists for the current config hash (submodule SHA +
# patch contents + this script's own contents + Xcode version, mirroring the CI cache
# key in adr/0006 §6), the build is skipped. Pass --force to rebuild anyway.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd cmake
require_cmd ninja
require_cmd jq
require_cmd shasum
require_cmd git

FORCE=0
for arg in "$@"; do
	case "$arg" in
	--force) FORCE=1 ;;
	*) die "unknown argument: $arg (supported: --force)" ;;
	esac
done

LOCK_FILE="$CRDP_REPO_ROOT/deps/freerdp.lock"
[ -f "$LOCK_FILE" ] || die "missing $LOCK_FILE"

FREERDP_SRC="$CRDP_REPO_ROOT/ThirdParty/FreeRDP"
# A submodule's .git is a *file* (a gitdir pointer), not a directory — hence -e, not -d.
[ -e "$FREERDP_SRC/.git" ] || die "ThirdParty/FreeRDP submodule not initialized — run Scripts/bootstrap.sh first"

[ -f "$CRDP_DEPS_PREFIX/lib/libssl.a" ] || die "static OpenSSL not found at $CRDP_DEPS_PREFIX — run Scripts/build-openssl.sh first"

SUBMODULE_SHA="$(git -C "$FREERDP_SRC" rev-parse HEAD)"
EXPECTED_SHA="$(jq -er '.commit' "$LOCK_FILE")" || die "deps/freerdp.lock has no .commit field"
[ "$SUBMODULE_SHA" = "$EXPECTED_SHA" ] || die "ThirdParty/FreeRDP HEAD ($SUBMODULE_SHA) != deps/freerdp.lock commit ($EXPECTED_SHA). Run Scripts/bootstrap.sh."

DEPLOYMENT_TARGET="$(jq -er '.deployment_target' "$LOCK_FILE")" || die "deps/freerdp.lock has no .deployment_target field"

if ! git -C "$FREERDP_SRC" diff --quiet -- . || ! git -C "$FREERDP_SRC" diff --cached --quiet -- .; then
	die "ThirdParty/FreeRDP has local modifications outside the patch queue.
This should never happen from a clean run of this script (it always reverts patches on
exit). Clean it manually and re-run: git -C ThirdParty/FreeRDP checkout -- ."
fi

# --- Patch queue --------------------------------------------------------------------
PATCH_DIR="$CRDP_REPO_ROOT/ThirdParty/patches"
PATCHES=()
if [ -d "$PATCH_DIR" ]; then
	while IFS= read -r -d '' p; do PATCHES+=("$p"); done \
		< <(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' -print0 | sort -z)
fi
log "Patch queue: ${#PATCHES[@]} patch(es)"

for patch in "${PATCHES[@]:-}"; do
	[ -n "$patch" ] || continue
	grep -qE 'github\.com/FreeRDP/FreeRDP/(issues|pull)' "$patch" \
		|| die "patch $patch has no upstream issue/PR link in its header (ThirdParty/patches/README.md rule 1)"
done

# --- Config hash (mirrors the CI cache key formula in adr/0006 §6) ------------------
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' || echo 'no-xcode')"

compute_config_hash() {
	{
		printf 'submodule_sha=%s\n' "$SUBMODULE_SHA"
		printf 'xcode_version=%s\n' "$XCODE_VERSION"
		printf -- '--- build-freerdp.sh ---\n'
		cat "$SCRIPT_DIR/build-freerdp.sh"
		printf -- '--- lib.sh ---\n'
		cat "$SCRIPT_DIR/lib.sh"
		printf -- '--- lock cmake_config ---\n'
		jq -c '.cmake_config' "$LOCK_FILE"
		printf -- '--- lock openssl ---\n'
		jq -c '.openssl' "$LOCK_FILE"
		printf -- '--- patches ---\n'
		for patch in "${PATCHES[@]:-}"; do
			[ -n "$patch" ] || continue
			printf -- '-- %s --\n' "$(basename "$patch")"
			cat "$patch"
		done
	} | shasum -a 256 | awk '{print $1}' | cut -c1-16
}
CONFIG_HASH="$(compute_config_hash)"
log "Config hash: $CONFIG_HASH"

CONFIG_ROOT="$CRDP_BUILD_DIR/freerdp/$CONFIG_HASH"
BUILD_DIR="$CONFIG_ROOT/build"
INSTALL_PREFIX="$CONFIG_ROOT/prefix"
MANIFEST="$CONFIG_ROOT/build-manifest.json"
CURRENT_LINK="$CRDP_BUILD_DIR/freerdp/current"

if [ "$FORCE" -eq 0 ] && [ -f "$MANIFEST" ] && [ -f "$INSTALL_PREFIX/lib/libfreerdp3.dylib" ]; then
	log "Config $CONFIG_HASH already built at $INSTALL_PREFIX; skipping. Pass --force to rebuild."
	ln -sfn "$CONFIG_HASH" "$CURRENT_LINK"
	exit 0
fi

# --- Apply patches, always revert on exit (submodule stays pristine at rest) --------
cleanup_patches() {
	local status=$?
	if [ "${#PATCHES[@]}" -gt 0 ]; then
		log "Reverting applied patches (submodule checkout must stay pristine at rest)"
		local i
		for ((i = ${#PATCHES[@]} - 1; i >= 0; i--)); do
			git -C "$FREERDP_SRC" apply -R "${PATCHES[$i]}" \
				|| log "WARNING: failed to revert ${PATCHES[$i]} — check ThirdParty/FreeRDP with 'git status'"
		done
	fi
	exit "$status"
}
trap cleanup_patches EXIT

for patch in "${PATCHES[@]:-}"; do
	[ -n "$patch" ] || continue
	log "  checking $patch"
	git -C "$FREERDP_SRC" apply --check "$patch" \
		|| die "patch $patch fails to apply cleanly against $SUBMODULE_SHA"
done
for patch in "${PATCHES[@]:-}"; do
	[ -n "$patch" ] || continue
	log "  applying $patch"
	git -C "$FREERDP_SRC" apply "$patch"
done

# --- Configure -----------------------------------------------------------------------
mkdir -p "$CONFIG_ROOT"

# CMAKE_INSTALL_PREFIX is baked into compiled code at *configure* time (FreeRDP
# generates buildflags.h with FREERDP_INSTALL_PREFIX/FREERDP_PLUGIN_PATH/
# FREERDP_ADDIN_PATH/FREERDP_EXTENSION_PATH etc. derived from it, for runtime addin
# dlopen()-ing) — same defect class as OpenSSL's ENGINESDIR/MODULESDIR
# (Scripts/build-openssl.sh), found the same way: `strings` on the built dylib turned up
# $HOME even after OPENSSL_ROOT_DIR was fixed. Configure against a placeholder that will
# never exist on any real machine, then override the destination at install time with
# `cmake --install --prefix` (a pure copy-destination override — it does not touch what
# configure already baked into the compiled headers). Nothing in Phase 1's config
# (WITH_SERVER=OFF, no proxy, minimal channels) dynamically dlopen()s a plugin — the
# static-registration table is checked first (adr/0006 §3) — so the placeholder paths
# are dead configuration, never actually read at runtime.
FREERDP_PREFIX_PLACEHOLDER="/private/var/macdows-freerdp-buildtime-prefix"

# Read into a variable first (not `done < <(jq ...)`): a process substitution's exit
# status isn't checked by a trailing `||` on the while loop, so a truncated/failed jq
# there would silently pass. Command substitution's exit status *does* propagate.
FLAGS_RAW="$(jq -er '.cmake_config.flags[]' "$LOCK_FILE")" || die "failed to read .cmake_config.flags[] from $LOCK_FILE"
FLAGS=()
while IFS= read -r flag; do
	case "$flag" in
	-DCMAKE_INSTALL_PREFIX=*) flag="-DCMAKE_INSTALL_PREFIX=$FREERDP_PREFIX_PLACEHOLDER" ;;
	-DOPENSSL_ROOT_DIR=*) flag="-DOPENSSL_ROOT_DIR=$CRDP_DEPS_PREFIX" ;;
	-DCMAKE_OSX_DEPLOYMENT_TARGET=*) flag="-DCMAKE_OSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET" ;;
	esac
	FLAGS+=("$flag")
done <<<"$FLAGS_RAW"
GENERATOR="$(jq -er '.cmake_config.generator' "$LOCK_FILE")" || die "deps/freerdp.lock has no .cmake_config.generator field"

# Guardrail against a truncated/corrupted flags read silently configuring FreeRDP with
# almost nothing set (e.g. jq returning early, a bad substitution loop) — the real flag
# list is ~30 entries; anything drastically short is a bug, not a legitimate config.
[ "${#FLAGS[@]}" -ge 20 ] || die "only read ${#FLAGS[@]} CMake flags from $LOCK_FILE (expected >= 20) — refusing to configure with a suspiciously short flag list"

log "Configuring FreeRDP $SUBMODULE_SHA -> $INSTALL_PREFIX"
cmake -S "$FREERDP_SRC" -B "$BUILD_DIR" -G "$GENERATOR" "${FLAGS[@]}"

NPROC="$(sysctl -n hw.ncpu)"
log "Building (cmake --build -j$NPROC)"
cmake --build "$BUILD_DIR" -j"$NPROC"

log "Installing (real destination $INSTALL_PREFIX overrides the configured placeholder — a pure copy-destination override, doesn't touch what's already baked into compiled code)"
rm -rf "$INSTALL_PREFIX"
cmake --install "$BUILD_DIR" --prefix "$INSTALL_PREFIX"

# --- Manifest --------------------------------------------------------------------------
CACHE_FILE="$BUILD_DIR/CMakeCache.txt"
# WITH_GFX_H264 is deliberately NOT here: it's a plain CMake `set()`, not a cache
# variable (FreeRDP's top-level CMakeLists.txt derives it from WITH_OPENH264 et al.
# without CACHE), so it never appears in CMakeCache.txt — grepping for it always came
# back empty, which is a silent no-op, not a real reading of the build's H264 posture.
# WITH_OPENH264 (an actual `option()`) is the real, grep-able signal for the "no H264 —
# UI payload only" invariant adr/0004 depends on.
CACHE_KEYS=(
	CMAKE_BUILD_TYPE CMAKE_OSX_ARCHITECTURES CMAKE_OSX_DEPLOYMENT_TARGET
	CHANNEL_URBDRC WITH_VIDEOTOOLBOX WITH_FFMPEG WITH_SWSCALE WITH_DSP_FFMPEG
	WITH_OPENH264 WITH_URIPARSER WITH_JSON_DISABLED
	OPENSSL_ROOT_DIR OPENSSL_USE_STATIC_LIBS
)
CACHE_JSON="{}"
for key in "${CACHE_KEYS[@]}"; do
	value="$(grep -E "^${key}(:[A-Za-z]+)?=" "$CACHE_FILE" | head -1 | cut -d= -f2-)" \
		|| die "expected CMakeCache key '$key' not found in $CACHE_FILE — either a real config regression or this key needs removing from CACHE_KEYS (e.g. it isn't a real cache variable)"
	CACHE_JSON="$(jq --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$CACHE_JSON")"
done

PATCHES_JSON="[]"
if [ "${#PATCHES[@]}" -gt 0 ]; then
	PATCHES_JSON="$(printf '%s\n' "${PATCHES[@]}" | xargs -n1 basename | jq -R . | jq -s .)"
fi

jq -n \
	--arg configHash "$CONFIG_HASH" \
	--arg submoduleSha "$SUBMODULE_SHA" \
	--arg builtAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg installPrefix "$INSTALL_PREFIX" \
	--arg xcodeVersion "$XCODE_VERSION" \
	--argjson patches "$PATCHES_JSON" \
	--argjson cmakeCache "$CACHE_JSON" \
	'{configHash: $configHash, submoduleSha: $submoduleSha, builtAt: $builtAt, installPrefix: $installPrefix, xcodeVersion: $xcodeVersion, patches: $patches, cmakeCache: $cmakeCache}' \
	>"$MANIFEST"

ln -sfn "$CONFIG_HASH" "$CURRENT_LINK"
log "FreeRDP installed to $INSTALL_PREFIX"
log "Manifest: $MANIFEST"
log "Stable path: $CURRENT_LINK -> $CONFIG_HASH"

# --- Retention: keep only the 2 most recently built config-hash dirs -----------------
# Each full FreeRDP build is ~100s of MB; old config-hash dirs from superseded lock/patch
# states otherwise accumulate forever. Keep the current one plus one prior (covers "just
# rolled back a bad change") and drop the rest, sorted by mtime.
mapfile -t OLD_CONFIGS < <(
	find "$CRDP_BUILD_DIR/freerdp" -mindepth 1 -maxdepth 1 -type d ! -name "$CONFIG_HASH" -print0 \
		| xargs -0 -I{} stat -f '%m%t%N' {} 2>/dev/null \
		| sort -rn -t"$(printf '\t')" -k1,1 \
		| cut -f2- \
		| tail -n +2
)
for old in "${OLD_CONFIGS[@]:-}"; do
	[ -n "$old" ] || continue
	log "Pruning older build: $old"
	rm -rf "$old"
done
