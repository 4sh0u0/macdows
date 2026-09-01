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
require_cmd file

APP_PATH="${1:-}"
[ -n "$APP_PATH" ] || die "usage: $(basename "$0") <path-to-.app>"
[ -d "$APP_PATH" ] || die "not a directory: $APP_PATH"
APP_PATH="$(cd "$APP_PATH" && pwd)"

INFO_PLIST="$APP_PATH/Contents/Info"
EXEC_NAME="$(defaults read "$INFO_PLIST" CFBundleExecutable 2>/dev/null || true)"
[ -n "$EXEC_NAME" ] || die "could not read CFBundleExecutable from $INFO_PLIST.plist"
EXEC_PATH="$APP_PATH/Contents/MacOS/$EXEC_NAME"
[ -x "$EXEC_PATH" ] || die "executable not found: $EXEC_PATH"

# --- Collect every Mach-O in the bundle, and every linked-library path they reference ---
# Scanning by *content* (file(1) says Mach-O) across every directory a macOS app may put
# executable code in, rather than by `Contents/Frameworks/*.dylib` alone. The narrow version
# had two live blind spots:
#   - Contents/MacOS/ beyond the main executable. A Debug build puts most of the app's own
#     code in Macdows.debug.dylib there, so it went completely unscanned — which is one of
#     the two reasons the $HOME leak in CRSession.o survived undetected in Debug.
#   - Extension points this app does not use *yet*. XPCServices/PlugIns/Helpers/Library are
#     exactly where a future helper tool or XPC service would land, and a licence/leak gate
#     that silently stops covering new code the day it is added is worse than no gate.
# Extensionless binaries (framework binaries, helper tools) are covered too, which a
# `-name '*.dylib'` filter could never do.
SCAN_DIRS=(MacOS Frameworks XPCServices PlugIns Helpers Library)
BINARIES=()
for sub in "${SCAN_DIRS[@]}"; do
	[ -d "$APP_PATH/Contents/$sub" ] || continue
	while IFS= read -r -d '' candidate; do
		case "$(file -b "$candidate")" in
		Mach-O*) BINARIES+=("$candidate") ;;
		esac
	done < <(find "$APP_PATH/Contents/$sub" -type f -print0)
done

# The main executable must always be in the set; if the content scan somehow missed it, the
# whole scan is broken and every check below would pass vacuously.
printf '%s\n' "${BINARIES[@]:-}" | grep -cxF "$EXEC_PATH" >/dev/null \
	|| die "the Mach-O scan did not find the main executable $EXEC_PATH — the scan itself is broken, not the bundle"
log "Scanning ${#BINARIES[@]} Mach-O binaries in the bundle"

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
#
# `grep -cF ... >/dev/null`, deliberately not `grep -qF`: this script runs under
# `set -o pipefail`, and grep -q exits on the first match, which kills `strings` with
# SIGPIPE and makes the *pipeline* status 141 rather than grep's 0 — so the `if` would not
# fire on exactly the inputs it exists to catch. Whether it misfires depends on whether
# strings finished writing before grep exited, i.e. on binary size, so it is flaky rather
# than reliably broken. grep -c always drains its input and reports the real answer.
# (Verified: on a multi-hundred-KB dylib, `strings | grep -q X` -> 141 while `strings |
# grep -c X >/dev/null` -> 0, for an X that is present.)
for bin in "${BINARIES[@]}"; do
	if strings -a "$bin" | grep -cF "$HOME" >/dev/null; then
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
printf '%s\n' "${ALL_DEPS[@]}" | grep -c 'libfreerdp\|libwinpr' >/dev/null && DETECTED+=("FreeRDP")
printf '%s\n' "${ALL_DEPS[@]}" | grep -c '/usr/lib/libz\.' >/dev/null && DETECTED+=("zlib")

# FFmpeg (adr/0007 H264 decode; Phase 2 W8). Unlike OpenSSL this is dynamically linked and
# redistributed, so it is detectable straight from the load commands. All three components
# are checked because LGPL-2.1 §6 compliance is about what we *ship*: libavcodec carries
# its own LC_LOAD_DYLIB on libswresample, so an app missing any one of the three is both
# broken at load time and incompletely documented.
FFMPEG_COMPONENTS=(avcodec avutil swresample)
FFMPEG_LINKED=0
for comp in "${FFMPEG_COMPONENTS[@]}"; do
	if printf '%s\n' "${ALL_DEPS[@]}" | grep -c "lib${comp}\." >/dev/null; then
		FFMPEG_LINKED=$((FFMPEG_LINKED + 1))
	fi
done
if [ "$FFMPEG_LINKED" -gt 0 ]; then
	DETECTED+=("FFmpeg")
	[ "$FFMPEG_LINKED" -eq "${#FFMPEG_COMPONENTS[@]}" ] \
		|| die "only $FFMPEG_LINKED of ${#FFMPEG_COMPONENTS[@]} FFmpeg components (${FFMPEG_COMPONENTS[*]}) appear in the bundle's load commands — a partial FFmpeg embed cannot load at runtime and cannot satisfy the LGPL §6 obligation to ship replaceable libraries; check App/project.yml's Copy Files entries"
	# Load commands say what is *referenced*; this says what is actually *present*. An app
	# that resolved its @rpath entries against a build-tree dylib outside the bundle would
	# pass the former and fail the latter.
	for comp in "${FFMPEG_COMPONENTS[@]}"; do
		find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -name "lib${comp}.*.dylib" -print -quit 2>/dev/null | grep -c . >/dev/null \
			|| die "lib${comp} is referenced by the bundle but no lib${comp}.*.dylib is embedded in Contents/Frameworks — FFmpeg is dynamically linked and must be redistributed with the app (adr/0007, LGPL-2.1 §6)"
	done
fi

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
printf '%s\n' "${DETECTED[@]}" | grep -cx "FreeRDP" >/dev/null \
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

# --- Compliance payload: the obligations must travel with the ARTIFACT ------------------
# Documenting a licence in the source repository does nothing for someone who receives only
# Macdows.app. Apache-2.0 §4(d)/(a) (attribution and NOTICE), and above all LGPL-2.1 §1/§6
# (deliver the licence, and tell the recipient how to substitute their own build of the
# library), attach to the *distributed copy*. So the bundle itself must carry them, and this
# gate checks the bundle rather than the repo.
#
# Byte-identity against the tracked copies, not mere existence: a stale Contents/Resources
# left behind by an incremental build would otherwise sail through while shipping notices
# that no longer describe what is actually linked.
RESOURCES_DIR="$APP_PATH/Contents/Resources"
LICENSES_DIR="$RESOURCES_DIR/licenses"

assert_bundled_copy() {
	# $1 = path in the repo, $2 = path in the bundle, $3 = human description
	local repo_file="$1" bundle_file="$2" desc="$3" repo_sha bundle_sha
	[ -f "$repo_file" ] || die "$desc is missing from the repository at $repo_file — it cannot be shipped"
	[ -f "$bundle_file" ] \
		|| die "$desc is not present in the built bundle at ${bundle_file#"$APP_PATH"/} — the licence obligations have to ship with the artifact, not just live in the repo (check App/project.yml's Copy Files -> resources phase)"
	repo_sha="$(shasum -a 256 "$repo_file" | awk '{print $1}')"
	bundle_sha="$(shasum -a 256 "$bundle_file" | awk '{print $1}')"
	[ "$repo_sha" = "$bundle_sha" ] \
		|| die "$desc in the bundle (${bundle_file#"$APP_PATH"/}) does not match the tracked copy ($repo_file) — the shipped copy is stale; clean-build the app so the Copy Files phase refreshes it"
}

# The licence text every detected component needs shipped alongside it.
license_file_for() {
	case "$1" in
	FreeRDP) printf 'LICENSE-FreeRDP-Apache-2.0.txt' ;;
	OpenSSL) printf 'LICENSE-OpenSSL-Apache-2.0.txt' ;;
	FFmpeg) printf 'LICENSE-FFmpeg-LGPL-2.1.txt' ;;
	zlib) printf 'LICENSE-zlib.txt' ;;
	*) return 1 ;;
	esac
}

assert_bundled_copy "$NOTICES_FILE" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md" "THIRD_PARTY_NOTICES.md"

for comp in "${DETECTED[@]:-}"; do
	[ -n "$comp" ] || continue
	comp_license="$(license_file_for "$comp")" \
		|| die "no vendored licence text is mapped for detected component '$comp' — add one under ThirdParty/licenses/ and register it in license_file_for() (a component may not ship undocumented)"
	assert_bundled_copy "$CRDP_REPO_ROOT/ThirdParty/licenses/$comp_license" \
		"$LICENSES_DIR/$comp_license" "$comp licence text ($comp_license)"
done
log "Bundle carries THIRD_PARTY_NOTICES.md + licence texts for: ${DETECTED[*]}"

# --- Version single-sourcing: deps/freerdp.lock is the only place these are pinned; ---
# cross-check THIRD_PARTY_NOTICES.md's hand-written version mentions instead of letting
# them drift silently out of sync on the next FreeRDP/OpenSSL bump.
LOCK_FILE_FOR_NOTICES="$CRDP_REPO_ROOT/deps/freerdp.lock"
FREERDP_TAG="$(jq -er '.tag' "$LOCK_FILE_FOR_NOTICES")" || die "deps/freerdp.lock has no .tag field"
LOCKED_OPENSSL_VERSION="$(jq -er '.openssl.version' "$LOCK_FILE_FOR_NOTICES")" || die "deps/freerdp.lock has no .openssl.version field"
LOCKED_FFMPEG_VERSION="$(jq -er '.ffmpeg.version' "$LOCK_FILE_FOR_NOTICES")" || die "deps/freerdp.lock has no .ffmpeg.version field"

grep -qF "$FREERDP_TAG" "$NOTICES_FILE" \
	|| die "THIRD_PARTY_NOTICES.md does not mention FreeRDP version $FREERDP_TAG (deps/freerdp.lock .tag) — the notices file is stale, update its FreeRDP section"
grep -qF "$LOCKED_OPENSSL_VERSION" "$NOTICES_FILE" \
	|| die "THIRD_PARTY_NOTICES.md does not mention OpenSSL version $LOCKED_OPENSSL_VERSION (deps/freerdp.lock .openssl.version) — the notices file is stale, update its OpenSSL section"
VERSIONS_CHECKED="$FREERDP_TAG, $LOCKED_OPENSSL_VERSION"
# Gated on FFmpeg actually being detected in this bundle, so the checks describe the
# artifact in hand rather than the repo's intent.
#
# Note on CRDP_WITH_FFMPEG=0: that toggle changes how *FreeRDP* is configured (no H264
# decode, no ffmpeg link), but App/project.yml's Copy Files entries are unconditional
# `optional: true` paths, so if an ffmpeg prefix happens to exist on the machine its dylibs
# are still embedded and this branch still runs. That is deliberate — a dylib physically
# present in a shipped bundle carries its licence obligations whether or not anything links
# it, so the gate follows what is in the bundle, not what the build flag intended.
if printf '%s\n' "${DETECTED[@]}" | grep -cx "FFmpeg" >/dev/null; then
	grep -qF "$LOCKED_FFMPEG_VERSION" "$NOTICES_FILE" \
		|| die "THIRD_PARTY_NOTICES.md does not mention FFmpeg version $LOCKED_FFMPEG_VERSION (deps/freerdp.lock .ffmpeg.version) — the notices file is stale, update its FFmpeg section"
	# LGPL-2.1 §6 is only satisfiable if the user is actually told how to exercise it, so
	# the relink document is part of the release gate, not an optional extra — and it has to
	# be *in the bundle*, since that is what the recipient receives.
	RELINK_DOC="$CRDP_REPO_ROOT/LGPL_RELINK.md"
	[ -f "$RELINK_DOC" ] \
		|| die "FFmpeg is packaged but $RELINK_DOC is missing — LGPL-2.1 §6 requires shipping instructions for replacing the library with a user-modified build"
	grep -qF "$LOCKED_FFMPEG_VERSION" "$RELINK_DOC" \
		|| die "LGPL_RELINK.md does not mention FFmpeg version $LOCKED_FFMPEG_VERSION — §6 instructions must point at the *corresponding* source, so a stale version there makes them unusable"
	assert_bundled_copy "$RELINK_DOC" "$RESOURCES_DIR/LGPL_RELINK.md" "LGPL_RELINK.md (the LGPL-2.1 §6 offer)"
	VERSIONS_CHECKED="$VERSIONS_CHECKED, $LOCKED_FFMPEG_VERSION"

	# --- The §6 instructions must still reproduce what we actually shipped --------------
	# deps/freerdp.lock is the single source of truth for the configure flags (and
	# Scripts/build-ffmpeg.sh refuses to build if its own array drifts from it). Both
	# user-facing documents quote that flag list — THIRD_PARTY_NOTICES.md as the evidence
	# that the shipped build is not GPL, LGPL_RELINK.md as the recipe a user runs to build a
	# replacement.
	#
	# This is a SET-EQUALITY assertion between the locked flag list and the flag block of
	# each document — both directions, both evaluated against the same extracted token set:
	#   forward  (locked -> block): a flag silently disappears from a document. The licence
	#            evidence becomes incomplete, or the user's replacement library is not
	#            drop-in compatible with what we shipped.
	#   reverse  (block -> locked): a flag is silently *added* to a document. A notices file
	#            that reads "--enable-gpl" is an affirmatively false licence claim about a
	#            binary we redistribute, and a relink recipe with an extra flag produces a
	#            library that behaves differently from the one it is supposed to replace.
	#
	# Both directions run against extract_flag_tokens output, never against the raw file.
	# That is load-bearing, not tidiness: an earlier version did the forward direction with
	# `grep -qF -- "$lockflag" "$doc"` over the whole file, and the prose outside the block
	# silently rescued flags that had been deleted from the block itself. Measured exposure
	# of that bug: 10 of the 28 locked flags were "documented" somewhere in LGPL_RELINK.md's
	# prose — including --enable-parser=h264, whose absence from the recipe breaks H.264
	# decode initialisation outright, i.e. exactly the §6 drop-in-compatibility failure this
	# check exists to prevent — and 1 of 28 in THIRD_PARTY_NOTICES.md (--disable-gpl, the
	# single most important one). The gate passed and logged "reproduce all 28 locked flags".
	FFMPEG_FLAG_DEPLOY="$(jq -er '.deployment_target' "$LOCK_FILE_FOR_NOTICES")" \
		|| die "deps/freerdp.lock has no .deployment_target field"

	# --- Token extraction ----------------------------------------------------------------
	# Scoped to an explicitly delimited region of each document rather than the whole file.
	# The delimiters are HTML comments (invisible when the Markdown is rendered) placed
	# immediately around the flag block:
	#     <!-- BEGIN ffmpeg-configure-flags --> ... <!-- END ffmpeg-configure-flags -->
	# Scoping is not optional. Both documents legitimately name configure flags in prose
	# outside the block — THIRD_PARTY_NOTICES.md explains that FFmpeg is LGPL "only when
	# built without --enable-gpl / --enable-nonfree / --enable-version3" and shows a
	# `grep -- --disable-gpl` command — so a whole-file scan reports the very flags this
	# check exists to forbid, and (per the note above) also lets deleted flags pass.
	# Explicit markers were chosen over heuristics like "the first fenced code block after a
	# heading" because they cannot be broken by ordinary editing of the surrounding prose,
	# and a missing marker is a hard failure rather than a silently empty scan.
	FFMPEG_FLAGS_BEGIN_MARK='<!-- BEGIN ffmpeg-configure-flags -->'
	FFMPEG_FLAGS_END_MARK='<!-- END ffmpeg-configure-flags -->'

	extract_flag_tokens() {
		# Prints one flag token per line (deduplicated) from the delimited region of $1.
		# The character class covers every shape the locked flags actually take:
		# '=' (--arch=arm64), '@' (--install-name-dir=@rpath), '_'
		# (--enable-hwaccel=h264_videotoolbox), '.' and embedded '-'
		# (--extra-cflags=-mmacosx-version-min=14.0).
		# If a future locked flag ever contains '/', ',', ':' or a space (e.g. a path-valued
		# or list-valued option), the token will be truncated or split here rather than
		# matched — which fails CLOSED, as a forward-direction "document is missing <flag>"
		# error. That message blames the document, so: if a newly added flag reports missing
		# while plainly present in the block, widen this class rather than editing the doc.
		awk -v b="$FFMPEG_FLAGS_BEGIN_MARK" -v e="$FFMPEG_FLAGS_END_MARK" '
			index($0, b) { inblk = 1; next }
			index($0, e) { inblk = 0; next }
			inblk { print }
		' "$1" | grep -oE -- '--[A-Za-z0-9][A-Za-z0-9._@=+_-]*' | sort -u
	}

	# Extract once per document; both directions then reason about exactly the same data.
	NOTICES_FLAG_TOKENS="$(extract_flag_tokens "$NOTICES_FILE" || true)"
	RELINK_FLAG_TOKENS="$(extract_flag_tokens "$RELINK_DOC" || true)"
	[ -n "$NOTICES_FLAG_TOKENS" ] \
		|| die "THIRD_PARTY_NOTICES.md: found no configure-flag tokens between $FFMPEG_FLAGS_BEGIN_MARK and $FFMPEG_FLAGS_END_MARK — the delimiters are missing, mismatched, or the block is empty, which would make this check silently pass"
	[ -n "$RELINK_FLAG_TOKENS" ] \
		|| die "LGPL_RELINK.md: found no configure-flag tokens between $FFMPEG_FLAGS_BEGIN_MARK and $FFMPEG_FLAGS_END_MARK — the delimiters are missing, mismatched, or the block is empty, which would make this check silently pass"

	# grep -c >/dev/null, never -q, in both helpers: -q early-exits and SIGPIPEs the
	# producer, which under `set -o pipefail` makes the pipeline report 141 instead of the
	# match result. Same rule as the $HOME guard above.
	assert_flag_documented() {
		# $1 = locked flag, $2 = that document's token set, $3 = label, $4 = consequence
		local flag="$1" tokens="$2" label="$3" consequence="$4"
		printf '%s\n' "$tokens" | grep -cxF -e "$flag" >/dev/null \
			|| die "$label's FFmpeg configure-flag block does not contain '$flag' (deps/freerdp.lock .ffmpeg.configure_flags).
$consequence
Note this checks the block delimited by $FFMPEG_FLAGS_BEGIN_MARK / $FFMPEG_FLAGS_END_MARK,
not the whole file — a mention in the surrounding prose does not satisfy it, by design."
	}

	# --- Forward direction: every locked flag must appear in each document's block --------
	LOCKED_FLAGS_RESOLVED=""
	FLAGS_CHECKED=0
	while IFS= read -r lockflag; do
		# Same '<computed: ...>' substitution Scripts/build-ffmpeg.sh applies before it
		# compares; the docs quote the resolved value.
		lockflag="${lockflag//<computed: .deployment_target>/$FFMPEG_FLAG_DEPLOY}"
		LOCKED_FLAGS_RESOLVED="$LOCKED_FLAGS_RESOLVED$lockflag
"
		assert_flag_documented "$lockflag" "$NOTICES_FLAG_TOKENS" "THIRD_PARTY_NOTICES.md" \
			"The notices file's recorded licence evidence no longer matches how the shipped library was actually built."
		assert_flag_documented "$lockflag" "$RELINK_FLAG_TOKENS" "LGPL_RELINK.md" \
			"A user following that recipe would not reproduce the shipped library, which defeats the LGPL-2.1 §6 offer."
		FLAGS_CHECKED=$((FLAGS_CHECKED + 1))
	done < <(jq -er '.ffmpeg.configure_flags[]' "$LOCK_FILE_FOR_NOTICES" \
		|| die "deps/freerdp.lock has no .ffmpeg.configure_flags[] array")
	[ "$FLAGS_CHECKED" -ge 20 ] \
		|| die "only $FLAGS_CHECKED FFmpeg configure flags read from deps/freerdp.lock (expected >= 20) — refusing to treat a suspiciously short list as a passing check"

	# --- Reverse direction: each document's block may contain nothing else ----------------
	assert_no_extra_flags() {
		# $1 = that document's token set, $2 = label, $3 = newline-delimited allowed extra
		# flag NAMES (the part before '='), $4 = why those extras are legitimate.
		local tokens="$1" label="$2" allowed="$3" why="$4"
		local token name extra_count=0 token_count=0
		while IFS= read -r token; do
			[ -n "$token" ] || continue
			token_count=$((token_count + 1))
			if printf '%s\n' "$LOCKED_FLAGS_RESOLVED" | grep -cxF -e "$token" >/dev/null; then
				continue
			fi
			name="${token%%=*}"
			if [ -n "$allowed" ] && printf '%s\n' "$allowed" | grep -cxF -e "$name" >/dev/null; then
				extra_count=$((extra_count + 1))
				continue
			fi
			die "$label documents FFmpeg configure flag '$token', which is NOT in deps/freerdp.lock .ffmpeg.configure_flags.
A document may not claim the shipped library was built with a flag it was not built with:
in THIRD_PARTY_NOTICES.md that is a false licence statement about a binary we redistribute
(e.g. '--enable-gpl'), and in LGPL_RELINK.md it yields a replacement library that differs
from the one it is meant to replace. Either add the flag to the lock (and to
Scripts/build-ffmpeg.sh, which cross-checks it) or remove it from the document."
		done <<<"$tokens"
		# `${extra_count:+...}` would fire on the string "0" (it tests for non-empty, not
		# non-zero), so branch on the value explicitly.
		if [ "$extra_count" -gt 0 ]; then
			log "  $label block: $token_count token(s) = $FLAGS_CHECKED locked + $extra_count allowed extra ($why)"
		else
			log "  $label block: $token_count token(s) = $FLAGS_CHECKED locked, no extras"
		fi
	}

	# Allowed extras, enumerated explicitly rather than pattern-matched. Only LGPL_RELINK.md
	# has any: its block is a runnable `./configure` invocation, so it must also pass a
	# --prefix, which deps/freerdp.lock deliberately does not record (Scripts/build-ffmpeg.sh
	# supplies a throwaway placeholder prefix that is relocated after install, and the user's
	# own prefix is theirs to choose). The deployment-target flags are NOT extras — they are
	# locked, just with a '<computed: ...>' placeholder resolved above.
	assert_no_extra_flags "$NOTICES_FLAG_TOKENS" "THIRD_PARTY_NOTICES.md" "" ""
	assert_no_extra_flags "$RELINK_FLAG_TOKENS" "LGPL_RELINK.md" "--prefix" "--prefix, chosen by the user running the §6 procedure"
	log "FFmpeg configure flags: both documents' delimited blocks are set-equal to the $FLAGS_CHECKED flags in deps/freerdp.lock (prose outside the blocks is not consulted in either direction; LGPL_RELINK.md additionally documents the allowed extra --prefix)"

	# --- Licence posture re-verified on the SHIPPED dylib -------------------------------
	# Scripts/build-ffmpeg.sh already asserts this on what it builds, but that is a
	# different artifact from what ends up in the bundle: the Copy Files phase could have
	# picked up a stale prefix, a hand-placed dylib, or a rebuild done with different flags.
	# The whole reason W8 exists is that a GPL-3.0 FFmpeg must never be redistributed, so
	# the last gate before shipping re-reads the posture out of the file that will actually
	# ship. FFmpeg bakes its full configure command line into libavutil as the compiled-in
	# FFMPEG_CONFIGURATION string, which makes this directly checkable.
	SHIPPED_AVUTIL="$(find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -name 'libavutil.*.dylib' -type f | head -1)"
	[ -n "$SHIPPED_AVUTIL" ] || die "could not locate the embedded libavutil dylib for the licence re-check"
	# grep -c >/dev/null, not grep -q: see the $HOME guard's comment above for why -q is
	# unsafe in a pipeline under `set -o pipefail`.
	if ! strings -a "$SHIPPED_AVUTIL" | grep -c -- '--disable-gpl' >/dev/null; then
		die "the libavutil embedded in this bundle does not record --disable-gpl in its FFMPEG_CONFIGURATION string — it may be a GPL build (e.g. Homebrew's, which is --enable-gpl --enable-version3) and must not be redistributed inside this Apache-2.0 app"
	fi
	if strings -a "$SHIPPED_AVUTIL" | grep -cE -- '--enable-(gpl|nonfree|version3)' >/dev/null; then
		die "the libavutil embedded in this bundle records --enable-gpl/nonfree/version3 — this is not an LGPL-2.1-or-later build and must not be redistributed"
	fi
	log "Shipped libavutil licence posture re-verified: --disable-gpl present, no --enable-gpl/nonfree/version3"
fi
log "THIRD_PARTY_NOTICES.md version mentions match deps/freerdp.lock ($VERSIONS_CHECKED)"

# --- Generate sbom/macdows.cdx.json (CycloneDX 1.6, minimal fields) -------------
FREERDP_DYLIB="$(find "$APP_PATH/Contents/Frameworks" -name 'libfreerdp3.*.dylib' 2>/dev/null | head -1 || true)"
FREERDP_SHA256=""
if [ -n "$FREERDP_DYLIB" ]; then
	FREERDP_SHA256="$(shasum -a 256 "$FREERDP_DYLIB" | awk '{print $1}')"
fi

FREERDP_COMMIT="$(jq -er '.commit' "$LOCK_FILE_FOR_NOTICES")" || die "deps/freerdp.lock has no .commit field"

# Hash the *shipped* libavcodec, not the build-tree one: the SBOM has to describe the
# artifact that leaves the machine.
FFMPEG_PRESENT="$(printf '%s\n' "${DETECTED[@]:-}" | grep -cx FFmpeg >/dev/null && echo true || echo false)"
FFMPEG_SHA256=""
FFMPEG_URL=""
if [ "$FFMPEG_PRESENT" = "true" ]; then
	FFMPEG_AVCODEC="$(find "$APP_PATH/Contents/Frameworks" -name 'libavcodec.*.dylib' 2>/dev/null | head -1 || true)"
	if [ -n "$FFMPEG_AVCODEC" ]; then
		FFMPEG_SHA256="$(shasum -a 256 "$FFMPEG_AVCODEC" | awk '{print $1}')"
	fi
	FFMPEG_URL="$(jq -er '.ffmpeg.source_url' "$LOCK_FILE_FOR_NOTICES")" || die "deps/freerdp.lock has no .ffmpeg.source_url field"
fi

# purl `checksum` qualifier = the pinned *source tarball* hash; the component's `hashes`
# array = the *built binary* we ship. They answer different questions ("was this built from
# the source everyone else has?" vs "is this the exact file in this bundle?"), so both are
# recorded rather than one standing in for the other.
FFMPEG_SRC_SHA256="$(jq -er '.ffmpeg.sha256' "$LOCK_FILE_FOR_NOTICES")" || die "deps/freerdp.lock has no .ffmpeg.sha256 field"
OPENSSL_SRC_SHA256="$(jq -er '.openssl.sha256' "$LOCK_FILE_FOR_NOTICES")" || die "deps/freerdp.lock has no .openssl.sha256 field"

PATCH_DIR="$CRDP_REPO_ROOT/ThirdParty/patches"
# Where a reader can fetch a patch by name. The queue is tracked in the public repository, so
# the blob URL is stable while the patch exists; once it retires, the SBOM that referenced it
# stays pinned to the release it was generated for, which is the point of recording it at all.
PATCH_BLOB_BASE="https://github.com/4sh0u0/macdows/blob/main/ThirdParty/patches"

# CycloneDX 1.6 `pedigree.patches[]` takes patch OBJECTS, not filenames: required `type` from
# the enum unofficial|monkey|backport|cherry-pick, optional `diff` ({text}|{url}) and
# `resolves[]` issue objects (themselves requiring `type` from defect|enhancement|security),
# every one of them additionalProperties:false. This block used to emit bare basename strings,
# which validated only for as long as the queue was empty ([] satisfies any items schema) and
# would have produced a BOM rejected by `cyclonedx validate` / Dependency-Track the first time
# a patch landed. Schema: https://cyclonedx.org/docs/1.6/json/#components_items_pedigree_patches
#
# `type: "unofficial"` ("a patch not developed by the creators or maintainers of the software
# being patched") is the honest classification for this queue as a whole: a single file here may
# carry both an upstream backport and a fix upstream has not taken yet, and "unofficial" is true
# of the file either way, where "backport" would only be true of part of it.
#
# `resolves[].references` is not a second source of truth: the URLs are grepped out of the patch
# header, i.e. the same "# Upstream: …" link that ThirdParty/patches/README.md rule 1 mandates and
# that both Scripts/build-freerdp.sh and tier1.yml's patch-queue validation already enforce.
PATCH_FILES=()
while IFS= read -r -d '' patch_path; do PATCH_FILES+=("$patch_path"); done \
	< <(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' -print0 2>/dev/null | sort -z)

PATCHES_JSON="[]"
if [ "${#PATCH_FILES[@]}" -gt 0 ]; then
	PATCH_OBJECTS=()
	for patch_path in "${PATCH_FILES[@]}"; do
		patch_name="$(basename "$patch_path")"
		# Same PCRE-free pattern the other two enforcement points use. Fails closed: an SBOM that
		# declares a modification with no upstream record is exactly the privately-maintained-fork
		# shape README rule 1 exists to prevent, so refuse to emit one rather than drop `resolves`.
		patch_refs="$(grep -oE 'https://github\.com/FreeRDP/FreeRDP/(issues|pull)/[0-9]+' "$patch_path" | sort -u | jq -R . | jq -s .)" \
			|| patch_refs="[]"
		[ "$patch_refs" != "[]" ] \
			|| die "patch $patch_name has no upstream issue/PR link in its header (ThirdParty/patches/README.md rule 1) — refusing to emit an SBOM that records a modification with no upstream record"
		PATCH_OBJECTS+=("$(jq -n --arg url "$PATCH_BLOB_BASE/$patch_name" --argjson refs "$patch_refs" '
			{
				type: "unofficial",
				diff: {url: $url},
				resolves: [$refs[] | {
					type: "defect",
					id: (split("/") | last),
					source: {name: "FreeRDP", url: "https://github.com/FreeRDP/FreeRDP"},
					references: [.]
				}]
			}')")
	done
	PATCHES_JSON="$(printf '%s\n' "${PATCH_OBJECTS[@]}" | jq -s .)"
fi

mkdir -p "$CRDP_REPO_ROOT/sbom"
jq -n \
	--arg serial "urn:uuid:$(uuidgen | tr '[:upper:]' '[:lower:]')" \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg freerdpTag "$FREERDP_TAG" \
	--arg freerdpCommit "$FREERDP_COMMIT" \
	--arg freerdpSha "$FREERDP_SHA256" \
	--arg opensslVersion "$LOCKED_OPENSSL_VERSION" \
	--arg ffmpegVersion "$LOCKED_FFMPEG_VERSION" \
	--arg ffmpegSha "$FFMPEG_SHA256" \
	--arg ffmpegUrl "$FFMPEG_URL" \
	--arg ffmpegSrcSha "$FFMPEG_SRC_SHA256" \
	--arg opensslSrcSha "$OPENSSL_SRC_SHA256" \
	--arg ffmpegPresent "$FFMPEG_PRESENT" \
	--argjson patches "$PATCHES_JSON" \
	--arg opensslPresent "$([ "$OPENSSL_STATIC" = "TRUE" ] && echo true || echo false)" \
	--arg zlibPresent "$(printf '%s\n' "${DETECTED[@]:-}" | grep -cx zlib >/dev/null && echo true || echo false)" \
	'
	def freerdpHashes: (if $freerdpSha == "" then [] else [{alg: "SHA-256", content: $freerdpSha}] end);
	def ffmpegHashes: (if $ffmpegSha == "" then [] else [{alg: "SHA-256", content: $ffmpegSha}] end);
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
				purl: ("pkg:generic/openssl@" + $opensslVersion + "?checksum=sha256:" + $opensslSrcSha),
				licenses: [{license: {id: "Apache-2.0"}}],
				description: "Statically linked into libfreerdp3; self-built, no shared dylib entry."
			}] else [] end)
			+ (if $ffmpegPresent == "true" then [{
				type: "library",
				name: "FFmpeg",
				version: $ffmpegVersion,
				purl: ("pkg:generic/ffmpeg@" + $ffmpegVersion + "?checksum=sha256:" + $ffmpegSrcSha + "&download_url=" + ($ffmpegUrl | @uri)),
				licenses: [{license: {id: "LGPL-2.1-or-later"}}],
				hashes: ffmpegHashes,
				description: "Self-built from the pinned upstream tarball with --disable-gpl --disable-nonfree --disable-version3 (LGPL, not GPL) and a decode-only component set. Dynamically linked and redistributed as three embedded dylibs (libavcodec, libavutil, libswresample) so the library can be replaced per LGPL-2.1 §6 -- see LGPL_RELINK.md. The recorded hash is of the shipped libavcodec.",
				externalReferences: [
					{type: "distribution", url: $ffmpegUrl},
					{type: "website", url: "https://ffmpeg.org"}
				]
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
