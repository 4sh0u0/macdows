#!/usr/bin/env bash
# gen-notices.sh: reverse-derive the set of third-party components actually packaged
# into an app bundle (via `otool -L` on every embedded dylib + the FreeRDP build
# manifest's CMakeCache snapshot), then:
#   1. fail if THIRD_PARTY_NOTICES.md is missing an entry for any detected component
#      (adr/0006 §5 — this is the enforcement mechanism, not "please remember to update
#      the file")
#   2. fail if any linked dependency resolves to an absolute, non-system, non-bundle
#      path (a regression of adr/0006 §3 defect #1 — brew-absolute-path linking)
#   3. (re)generate sbom/macdows.cdx.json, a minimal CycloneDX 1.6 SBOM
#
# Usage: Scripts/gen-notices.sh <path-to-.app>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd otool
require_cmd jq
require_cmd shasum
require_cmd uuidgen
require_cmd strings

APP_PATH="${1:-}"
[ -n "$APP_PATH" ] || die "usage: $(basename "$0") <path-to-.app>"
[ -d "$APP_PATH" ] || die "not a directory: $APP_PATH"
APP_PATH="$(cd "$APP_PATH" && pwd)"

INFO_PLIST="$APP_PATH/Contents/Info"
EXEC_NAME="$(defaults read "$INFO_PLIST" CFBundleExecutable 2>/dev/null || true)"
[ -n "$EXEC_NAME" ] || die "could not read CFBundleExecutable from $INFO_PLIST.plist"
EXEC_PATH="$APP_PATH/Contents/MacOS/$EXEC_NAME"
[ -x "$EXEC_PATH" ] || die "executable not found: $EXEC_PATH"

# --- Collect every linked-library path referenced by the executable + embedded dylibs -
BINARIES=("$EXEC_PATH")
if [ -d "$APP_PATH/Contents/Frameworks" ]; then
	while IFS= read -r -d '' dylib; do BINARIES+=("$dylib"); done \
		< <(find "$APP_PATH/Contents/Frameworks" -name '*.dylib' -print0)
fi

ALL_DEPS=()
for bin in "${BINARIES[@]}"; do
	while IFS= read -r path; do
		ALL_DEPS+=("$path")
	done < <(otool -L "$bin" | tail -n +2 | awk '{print $1}')
done

# --- $HOME leakage guard: no bundle Mach-O may have a burned-in local path string ------
# (e.g. OpenSSL's --openssldir, or any other build-time absolute path baked in as a
# compiled-in string constant — a distributable binary must never contain the building
# developer's home directory).
for bin in "${BINARIES[@]}"; do
	if strings -a "$bin" | grep -qF "$HOME"; then
		die "found \$HOME ($HOME) burned into $bin as a string constant — a distributed binary must never embed the building machine's home directory (check --prefix/--openssldir-style build flags)"
	fi
done
log "No \$HOME string leakage in bundle binaries"

# --- Defect-#1 regression guard: nothing outside @rpath/@executable_path/system -------
UNEXPECTED="$(printf '%s\n' "${ALL_DEPS[@]}" \
	| grep -vE '^(@rpath/|@executable_path/|@loader_path/|/usr/lib/|/System/)' || true)"
if [ -n "$UNEXPECTED" ]; then
	log "Dependency path(s) outside @rpath/@executable_path/system (adr/0006 §3 defect #1 regression?):"
	printf '%s\n' "$UNEXPECTED" >&2
	die "gen-notices.sh: found non-relocatable dependency path(s) — see above"
fi

# --- Detect components ----------------------------------------------------------------
DETECTED=()
printf '%s\n' "${ALL_DEPS[@]}" | grep -q 'libfreerdp\|libwinpr' && DETECTED+=("FreeRDP")
printf '%s\n' "${ALL_DEPS[@]}" | grep -q '/usr/lib/libz\.' && DETECTED+=("zlib")

CURRENT_MANIFEST="$CRDP_BUILD_DIR/freerdp/current/build-manifest.json"
OPENSSL_STATIC="FALSE"
if [ -f "$CURRENT_MANIFEST" ]; then
	OPENSSL_STATIC="$(jq -r '.cmakeCache.OPENSSL_USE_STATIC_LIBS // "FALSE"' "$CURRENT_MANIFEST")"
fi
if [ "$OPENSSL_STATIC" = "TRUE" ]; then
	# Statically linked into libfreerdp3 — never appears as its own otool -L entry.
	DETECTED+=("OpenSSL")
fi

log "Detected packaged components: ${DETECTED[*]:-<none>}"

# --- Positive assertions: an empty or FreeRDP-less detection is always a scan bug, ----
# never a legitimate outcome — every real build embeds FreeRDP. A silent empty DETECTED
# would make every check below vacuously pass.
[ "${#DETECTED[@]}" -gt 0 ] || die "no components detected at all — otool -L parsing is almost certainly broken (empty ALL_DEPS, or every dependency went unmatched)"
printf '%s\n' "${DETECTED[@]}" | grep -qx "FreeRDP" \
	|| die "FreeRDP was not detected in the bundle — every real build embeds it; this points at a broken otool -L scan, not a legitimately FreeRDP-less app"

# --- Cross-check THIRD_PARTY_NOTICES.md ------------------------------------------------
NOTICES_FILE="$CRDP_REPO_ROOT/THIRD_PARTY_NOTICES.md"
[ -f "$NOTICES_FILE" ] || die "missing $NOTICES_FILE"

MISSING=()
for comp in "${DETECTED[@]:-}"; do
	[ -n "$comp" ] || continue
	grep -qi "$comp" "$NOTICES_FILE" || MISSING+=("$comp")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
	die "THIRD_PARTY_NOTICES.md is missing an entry for: ${MISSING[*]} (linked but not documented — adr/0001 obligation 2)"
fi
log "THIRD_PARTY_NOTICES.md covers all detected components"

# --- Version single-sourcing: deps/freerdp.lock is the only place these are pinned; ---
# cross-check THIRD_PARTY_NOTICES.md's hand-written version mentions instead of letting
# them drift silently out of sync on the next FreeRDP/OpenSSL bump.
LOCK_FILE_FOR_NOTICES="$CRDP_REPO_ROOT/deps/freerdp.lock"
FREERDP_TAG="$(jq -er '.tag' "$LOCK_FILE_FOR_NOTICES")" || die "deps/freerdp.lock has no .tag field"
LOCKED_OPENSSL_VERSION="$(jq -er '.openssl.version' "$LOCK_FILE_FOR_NOTICES")" || die "deps/freerdp.lock has no .openssl.version field"

grep -qF "$FREERDP_TAG" "$NOTICES_FILE" \
	|| die "THIRD_PARTY_NOTICES.md does not mention FreeRDP version $FREERDP_TAG (deps/freerdp.lock .tag) — the notices file is stale, update its FreeRDP section"
grep -qF "$LOCKED_OPENSSL_VERSION" "$NOTICES_FILE" \
	|| die "THIRD_PARTY_NOTICES.md does not mention OpenSSL version $LOCKED_OPENSSL_VERSION (deps/freerdp.lock .openssl.version) — the notices file is stale, update its OpenSSL section"
log "THIRD_PARTY_NOTICES.md version mentions match deps/freerdp.lock ($FREERDP_TAG, $LOCKED_OPENSSL_VERSION)"

# --- Generate sbom/macdows.cdx.json (CycloneDX 1.6, minimal fields) -------------
FREERDP_DYLIB="$(find "$APP_PATH/Contents/Frameworks" -name 'libfreerdp3.*.dylib' 2>/dev/null | head -1 || true)"
FREERDP_SHA256=""
if [ -n "$FREERDP_DYLIB" ]; then
	FREERDP_SHA256="$(shasum -a 256 "$FREERDP_DYLIB" | awk '{print $1}')"
fi

FREERDP_COMMIT="$(jq -er '.commit' "$LOCK_FILE_FOR_NOTICES")" || die "deps/freerdp.lock has no .commit field"

PATCH_DIR="$CRDP_REPO_ROOT/ThirdParty/patches"
PATCHES_JSON="[]"
if [ -d "$PATCH_DIR" ] && find "$PATCH_DIR" -maxdepth 1 -name '*.patch' -print -quit | grep -q .; then
	PATCHES_JSON="$(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' -print0 | xargs -0 -n1 basename | sort | jq -R . | jq -s .)"
fi

mkdir -p "$CRDP_REPO_ROOT/sbom"
jq -n \
	--arg serial "urn:uuid:$(uuidgen | tr '[:upper:]' '[:lower:]')" \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg freerdpTag "$FREERDP_TAG" \
	--arg freerdpCommit "$FREERDP_COMMIT" \
	--arg freerdpSha "$FREERDP_SHA256" \
	--arg opensslVersion "$LOCKED_OPENSSL_VERSION" \
	--argjson patches "$PATCHES_JSON" \
	--arg opensslPresent "$([ "$OPENSSL_STATIC" = "TRUE" ] && echo true || echo false)" \
	--arg zlibPresent "$(printf '%s\n' "${DETECTED[@]:-}" | grep -qx zlib && echo true || echo false)" \
	'
	def freerdpHashes: (if $freerdpSha == "" then [] else [{alg: "SHA-256", content: $freerdpSha}] end);
	{
		bomFormat: "CycloneDX",
		specVersion: "1.6",
		serialNumber: $serial,
		version: 1,
		metadata: {
			timestamp: $ts,
			component: {type: "application", name: "Macdows", version: "0.0.0-dev"}
		},
		components: (
			[{
				type: "library",
				name: "FreeRDP",
				version: $freerdpTag,
				purl: ("pkg:generic/FreeRDP@" + $freerdpTag + "?vcs_url=git%2Bhttps%3A%2F%2Fgithub.com%2FFreeRDP%2FFreeRDP.git%40" + $freerdpCommit),
				licenses: [{license: {id: "Apache-2.0"}}],
				hashes: freerdpHashes,
				pedigree: {patches: $patches}
			}]
			+ (if $opensslPresent == "true" then [{
				type: "library",
				name: "OpenSSL",
				version: $opensslVersion,
				purl: ("pkg:generic/openssl@" + $opensslVersion),
				licenses: [{license: {id: "Apache-2.0"}}],
				description: "Statically linked into libfreerdp3; self-built, no shared dylib entry."
			}] else [] end)
			+ (if $zlibPresent == "true" then [{
				type: "library",
				name: "zlib",
				version: "system",
				purl: "pkg:generic/zlib",
				licenses: [{license: {id: "Zlib"}}],
				description: "System library (/usr/lib/libz.dylib), dynamically linked, not redistributed."
			}] else [] end)
		)
	}
	' >"$CRDP_REPO_ROOT/sbom/macdows.cdx.json"

log "Wrote sbom/macdows.cdx.json"
log "gen-notices.sh: OK"
