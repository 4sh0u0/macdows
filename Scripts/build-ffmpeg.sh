#!/usr/bin/env bash
# build-ffmpeg.sh: download, verify, and build a pinned, minimal, **LGPL-only** shared
# FFmpeg for FreeRDP's H.264 decode path (adr/0007) to dynamically link against.
#
# Why this exists (Phase 2 W8, "H264 distribution compliance"):
#   1. Homebrew's ffmpeg formula is built `--enable-gpl --enable-version3`, which makes
#      the resulting libraries **GPL-3.0**. Redistributing them inside an Apache-2.0 app
#      bundle is a hard licence blocker, not a style preference. This build is
#      `--disable-gpl --disable-nonfree --disable-version3`, i.e. LGPL-2.1-or-later — the
#      one licence posture adr/0006 §3 / adr/0007 accept for a shipped binary.
#   2. Homebrew links by absolute path (/opt/homebrew/...), which is undistributable and
#      breaks on `brew upgrade ffmpeg` — the exact adr/0006 §3 defect #1 that
#      Scripts/build-openssl.sh already fixed for OpenSSL. `--install-name-dir=@rpath`
#      here gives the shipped dylibs (four since the 3.31.1 pin) @rpath install names, so the app bundle's existing
#      LD_RUNPATH_SEARCH_PATHS=@executable_path/../Frameworks resolves them with no
#      install_name_tool rewriting.
#   3. "Whatever brew resolved to today" is not an SBOM-able version. This is pinned by
#      version + sha256 in deps/freerdp.lock.
#
# Link mode is **shared, never static** (adr/0006 §3, adr/0007): LGPL-2.1 §6 requires
# users be able to replace the library with a modified version. See LGPL_RELINK.md for
# the corresponding user-facing relink instructions this build is shaped to satisfy.
#
# Idempotent: skips the download/build/install if the target version is already installed
# under .build/deps/ffmpeg-prefix. Delete the stamp file (printed on success) to force a
# rebuild, or pass --force.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd curl
require_cmd shasum
require_cmd tar
require_cmd make
require_cmd jq
require_cmd strings
require_cmd otool
require_cmd perl

FORCE=0
for arg in "$@"; do
	case "$arg" in
	--force) FORCE=1 ;;
	*) die "unknown argument: $arg (supported: --force)" ;;
	esac
done

# Pinned per deps/freerdp.lock .ffmpeg (kept in sync manually — same arrangement as
# Scripts/build-openssl.sh: this script is the one place allowed to know these values;
# deps/freerdp.lock documents the decision and Scripts/gen-notices.sh cross-checks the
# version against THIRD_PARTY_NOTICES.md so the three can't drift silently).
#
# 9.0.1 is deliberately the same upstream release line Homebrew was providing before this
# script existed (libavcodec major 63, libavutil major 61), so FreeRDP's
# libfreerdp/codec/h264_ffmpeg.c compiles unchanged across the switch — the swap is a
# licence/provenance change, not an API-version change.
FFMPEG_VERSION="9.0.1"
FFMPEG_TARBALL="ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_URL="https://ffmpeg.org/releases/${FFMPEG_TARBALL}"
FFMPEG_SHA256="cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"

LOCK_FILE="$CRDP_REPO_ROOT/deps/freerdp.lock"
[ -f "$LOCK_FILE" ] || die "missing $LOCK_FILE"
DEPLOYMENT_TARGET="$(jq -er '.deployment_target' "$LOCK_FILE")" \
	|| die "deps/freerdp.lock has no .deployment_target field"

# Fail loudly rather than silently building a differently-pinned ffmpeg than the lock
# records — the lock is what THIRD_PARTY_NOTICES.md and the SBOM are generated against.
LOCKED_VERSION="$(jq -er '.ffmpeg.version' "$LOCK_FILE")" \
	|| die "deps/freerdp.lock has no .ffmpeg.version field"
[ "$LOCKED_VERSION" = "$FFMPEG_VERSION" ] \
	|| die "version drift: this script builds ffmpeg $FFMPEG_VERSION but deps/freerdp.lock .ffmpeg.version says $LOCKED_VERSION — update both together"
LOCKED_SHA256="$(jq -er '.ffmpeg.sha256' "$LOCK_FILE")" \
	|| die "deps/freerdp.lock has no .ffmpeg.sha256 field"
[ "$LOCKED_SHA256" = "$FFMPEG_SHA256" ] \
	|| die "sha256 drift: this script pins $FFMPEG_SHA256 but deps/freerdp.lock .ffmpeg.sha256 says $LOCKED_SHA256 — update both together"

DOWNLOAD_DIR="$CRDP_BUILD_DIR/deps/download"
SRC_DIR="$CRDP_BUILD_DIR/deps/src/ffmpeg-${FFMPEG_VERSION}"
STAMP_FILE="$CRDP_FFMPEG_PREFIX/.ffmpeg-${FFMPEG_VERSION}.stamp"

# Deliberately does NOT create $CRDP_FFMPEG_PREFIX: it is created by the promotion step at
# the very end, after every guard has passed. Pre-creating it would leave an empty prefix
# directory behind on a failed first build, which is a worse failure mode to debug than a
# simply-absent one (and the stamp check below is a plain -f test that does not need the
# directory to exist).
mkdir -p "$DOWNLOAD_DIR" "$CRDP_BUILD_DIR/deps/src"

if [ "$FORCE" -eq 0 ] && [ -f "$STAMP_FILE" ]; then
	log "FFmpeg $FFMPEG_VERSION already installed at $CRDP_FFMPEG_PREFIX (stamp: $STAMP_FILE); skipping. Pass --force to rebuild."
	exit 0
fi

TARBALL_PATH="$DOWNLOAD_DIR/$FFMPEG_TARBALL"
if [ -f "$TARBALL_PATH" ]; then
	log "Using cached tarball $TARBALL_PATH"
else
	log "Downloading $FFMPEG_URL"
	# --proto '=https' --proto-redir '=https': the sha256 below is the real integrity
	# control, but there is no reason to let a redirect (or a typo'd URL) silently downgrade
	# the transport to plain HTTP first. Constrains both the initial request and anything it
	# is redirected to.
	curl -fL --proto '=https' --proto-redir '=https' --retry 3 \
		-o "${TARBALL_PATH}.partial" "$FFMPEG_URL"
	mv "${TARBALL_PATH}.partial" "$TARBALL_PATH"
fi

log "Verifying sha256"
ACTUAL_SHA256="$(shasum -a 256 "$TARBALL_PATH" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$FFMPEG_SHA256" ]; then
	rm -f "$TARBALL_PATH"
	die "sha256 mismatch for $FFMPEG_TARBALL: expected $FFMPEG_SHA256, got $ACTUAL_SHA256 (corrupt/tampered download removed — re-run to retry)"
fi
log "sha256 OK: $ACTUAL_SHA256"

rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
log "Extracting to $SRC_DIR"
tar -xJf "$TARBALL_PATH" -C "$SRC_DIR" --strip-components=1

# --- Placeholder prefix + DESTDIR staging (same defect class as Scripts/build-openssl.sh)
# FFmpeg's configure bakes its *entire command line* into libavutil as the compiled-in
# string constant FFMPEG_CONFIGURATION (configure:8770, surfaced by avutil_configuration()
# and plainly visible with `strings`). That includes --prefix, so configuring straight
# against $CRDP_FFMPEG_PREFIX would burn "/Users/<name>/..." into a distributed dylib —
# which is both the adr/0006 §3 leak class and a hard failure of the $HOME guard in
# Scripts/gen-notices.sh. Configure against a path that will never exist on a real
# machine, then `make install DESTDIR=` into a staging root and relocate.
#
# Upside: that same baked-in string is *evidence* of the licence posture. On the built
# libavutil, `strings -a ... | grep -- --disable-gpl` shows this build is not GPL —
# THIRD_PARTY_NOTICES.md points at exactly that check.
FFMPEG_PREFIX_PLACEHOLDER="/private/var/macdows-ffmpeg-buildtime-prefix"
STAGING_ROOT="$CRDP_BUILD_DIR/deps/ffmpeg-stage"

# --- Configure flags: minimal LGPL H.264-decode-only shared build --------------------
# Verified against this exact version's `./configure --help` / --list-hwaccels. Deviations
# from the naive "turn everything off" list, and why:
#   * --disable-postproc is NOT passed: libpostproc no longer exists in ffmpeg 9.x (it is
#     absent from configure's LIBRARY_LIST entirely), so the option is unrecognised and
#     configure would abort on it.
#   * --disable-swresample is NOT passed even though FreeRDP never calls swr_*: libavcodec
#     itself carries an LC_LOAD_DYLIB on libswresample, so dropping it produces a
#     libavcodec that cannot load. It is a transitively required component, not an
#     optional one — hence a transitively required dylib in the shipped set (four with swscale, see below).
#   * --enable-parser=h264 IS passed (not in the original W8 sketch): --disable-everything
#     also drops parsers, and FreeRDP's h264_ffmpeg.c:1177 (3.31.1; :796 at 3.30.0) calls
#     av_parser_init(AV_CODEC_ID_H264) and treats NULL as a hard failure
#     ("Failed to initialize libav parser" -> goto EXCEPTION). Without this flag H.264
#     decode does not initialise at all.
#   * --arch=arm64 pins the architecture instead of letting configure autodetect it,
#     mirroring the CMAKE_OSX_ARCHITECTURES pin (adr/0006 §3 defect #3: an unpinned arch
#     is not reproducible).
#   * -mmacosx-version-min comes from deps/freerdp.lock .deployment_target, the same
#     single source Scripts/build-openssl.sh and Scripts/build-freerdp.sh read.
FFMPEG_CONFIGURE_FLAGS=(
	# Licence posture — the entire point of this script. Do not relax any of these three.
	--disable-gpl
	--disable-nonfree
	--disable-version3
	# Shared only: LGPL-2.1 §6 relink right (adr/0007 prohibits static ffmpeg).
	--enable-shared
	--disable-static
	--install-name-dir=@rpath
	# Nothing but what the RDP GFX H.264 decode path needs.
	--disable-everything
	--disable-programs
	--disable-doc
	--disable-avdevice
	--disable-avformat
	--disable-avfilter
	# --enable-swscale (was --disable-swscale up to the 3.30.0 pin): FreeRDP >= 3.31.0
	# libfreerdp/codec/h264_ffmpeg.c:28 includes libswscale/swscale.h unconditionally under
	# WITH_FFMPEG (upstream b1e878a, "support more hardware decoders"), so the file does not
	# compile against a swscale-less prefix; its sws_getContext / sws_scale_frame calls sit
	# under WITH_VAAPI || WITH_VIDEOTOOLBOX (:642; sws_freeContext :954 under the three-term
	# variant that adds WITH_VAAPI_H264_ENCODING), and this build has WITH_VIDEOTOOLBOX=ON,
	# so the symbols are linked too. libswscale is
	# LGPL-2.1-or-later like the rest of this build; the --disable-gpl strings check below
	# still governs.
	--enable-swscale
	--enable-decoder=h264
	--enable-parser=h264
	--enable-videotoolbox
	--enable-hwaccel=h264_videotoolbox
	# Hermetic: nothing that merely happens to be installed on the build machine may end up
	# in the link line. Found the hard way -- without this, configure autodetected Homebrew's
	# libX11 (via /opt/homebrew's x11.pc, for the vaapi_x11/xv paths we do not build) and
	# put "-L/opt/homebrew/Cellar/libx11/.../lib -lX11" into EXTRALIBS-avutil, giving all
	# three dylibs an absolute-Homebrew-path LC_LOAD_DYLIB: adr/0006 §3 defect #1, reproduced
	# inside the very build that exists to eliminate it.
	#
	# --enable-pthreads is NOT redundant next to it: configure's AUTODETECT_LIBS includes
	# $THREADS_LIST, so --disable-autodetect turns pthreads off too, and
	# videotoolbox_hwaccel_deps is "videotoolbox pthreads" -- without this the H264
	# VideoToolbox hwaccel would be silently dropped while the build still succeeded.
	--disable-autodetect
	--enable-pthreads
	# Belt and braces: these are all already covered by --disable-autodetect, but they are
	# the ones whose accidental reintroduction would be most consequential (extra
	# redistributable dependencies / network surface in a decode-only library), so they are
	# stated explicitly rather than left implicit.
	--disable-network
	--disable-openssl
	--disable-iconv
	--disable-zlib
	--disable-bzlib
	--disable-lzma
	# Reproducibility.
	--arch=arm64
	"--extra-cflags=-mmacosx-version-min=$DEPLOYMENT_TARGET"
	"--extra-ldflags=-mmacosx-version-min=$DEPLOYMENT_TARGET"
)

# --- Flag-list drift guard (same treatment .ffmpeg.version and .ffmpeg.sha256 already get)
# The array above is the executable source of truth, but deps/freerdp.lock's copy is what
# reviewers read, what THIRD_PARTY_NOTICES.md records as evidence of the non-GPL build, and
# what LGPL_RELINK.md tells users to reproduce for their §6 replacement. If the two drift,
# the §6 instructions silently stop producing a drop-in-compatible library and the licence
# evidence in the notices becomes a false claim — neither of which fails loudly on its own.
# So: compare the full list, element by element, and refuse to build on any difference.
#
# The lock stores the deployment-target flags with a '<computed: .deployment_target>'
# placeholder (it cannot hard-code a value that .deployment_target owns), so substitute that
# the same way Scripts/build-freerdp.sh substitutes its own '<computed: ...>' flags before
# comparing.
LOCK_FLAGS=()
while IFS= read -r lockflag; do
	LOCK_FLAGS+=("${lockflag//<computed: .deployment_target>/$DEPLOYMENT_TARGET}")
done < <(jq -er '.ffmpeg.configure_flags[]' "$LOCK_FILE" \
	|| die "deps/freerdp.lock has no .ffmpeg.configure_flags[] array")

if [ "${#LOCK_FLAGS[@]}" -ne "${#FFMPEG_CONFIGURE_FLAGS[@]}" ]; then
	die "configure-flag drift: this script passes ${#FFMPEG_CONFIGURE_FLAGS[@]} flags but deps/freerdp.lock .ffmpeg.configure_flags has ${#LOCK_FLAGS[@]} — update both together (the lock is what THIRD_PARTY_NOTICES.md and LGPL_RELINK.md are written against)"
fi
for i in "${!FFMPEG_CONFIGURE_FLAGS[@]}"; do
	[ "${FFMPEG_CONFIGURE_FLAGS[$i]}" = "${LOCK_FLAGS[$i]}" ] \
		|| die "configure-flag drift at index $i: this script passes '${FFMPEG_CONFIGURE_FLAGS[$i]}' but deps/freerdp.lock .ffmpeg.configure_flags[$i] says '${LOCK_FLAGS[$i]}' — update both together"
done
log "Configure flags match deps/freerdp.lock .ffmpeg.configure_flags (${#LOCK_FLAGS[@]} flags)"

log "Configuring FFmpeg $FFMPEG_VERSION (LGPL, H.264 decode only) --prefix=$FFMPEG_PREFIX_PLACEHOLDER (staged, not the real install location)"
log "  flags: ${FFMPEG_CONFIGURE_FLAGS[*]}"
(
	cd "$SRC_DIR"
	./configure --prefix="$FFMPEG_PREFIX_PLACEHOLDER" "${FFMPEG_CONFIGURE_FLAGS[@]}"

	NPROC="$(sysctl -n hw.ncpu)"
	log "Building (make -j$NPROC)"
	make -j"$NPROC"

	log "Installing to staging root"
	rm -rf "$STAGING_ROOT"
	make DESTDIR="$STAGING_ROOT" install
)

# --- Guards run against the STAGING tree, before anything is promoted ------------------
# Order matters and is the point: a build that fails any of these must never become
# reachable. Running them after `mv`-ing into $CRDP_FFMPEG_PREFIX would leave the rejected
# tree sitting exactly where Scripts/build-freerdp.sh looks for it — so the very next
# invocation would happily link the library this script just refused to ship (only the
# stamp would be missing, and the prefix check did not look at the stamp). Guarding the
# staging tree instead makes rejection total: on failure the script dies with
# $CRDP_FFMPEG_PREFIX untouched, so either the previous known-good install is still there,
# or (on a first build) nothing is, and build-freerdp.sh dies with its "run
# Scripts/build-ffmpeg.sh first" message.
#
# These are cheap, and they turn "the build finished" into "the build produced the thing we
# actually promised in THIRD_PARTY_NOTICES.md".
STAGED_PREFIX="$STAGING_ROOT$FFMPEG_PREFIX_PLACEHOLDER"
[ -d "$STAGED_PREFIX/lib" ] || die "staged install is missing $STAGED_PREFIX/lib — 'make install' did not produce the expected layout"

EXPECTED_COMPONENTS=(avcodec avutil swresample swscale)
for comp in "${EXPECTED_COMPONENTS[@]}"; do
	find "$STAGED_PREFIX/lib" -maxdepth 1 -name "lib${comp}.*.dylib" -print -quit | grep -c . >/dev/null \
		|| die "expected lib${comp} dylib not found under $STAGED_PREFIX/lib"
done

# Nothing beyond those four may be produced: an extra libavformat/libavfilter/libavdevice
# here means a --disable-* stopped taking effect, and FindFFmpeg.cmake links every
# component it finds, so it would silently re-widen the link line.
UNEXPECTED_LIBS="$(find "$STAGED_PREFIX/lib" -maxdepth 1 -name '*.dylib' -type f -exec basename {} \; \
	| sed -E 's/\.[0-9].*$//' | sort -u \
	| grep -vE '^lib(avcodec|avutil|swresample|swscale)$' || true)"
if [ -n "$UNEXPECTED_LIBS" ]; then
	log "Unexpected libraries in the staged install:"
	printf '%s\n' "$UNEXPECTED_LIBS" >&2
	die "build produced ffmpeg components beyond avcodec/avutil/swresample/swscale — a --disable-* flag is not taking effect (nothing was promoted to $CRDP_FFMPEG_PREFIX)"
fi

# Relocatability guard, same rule Scripts/gen-notices.sh enforces on the finished bundle,
# applied here so the failure is attributed to this build instead of surfacing three steps
# later as a mysterious release-gate death. This is what caught the autodetected Homebrew
# libX11 that --disable-autodetect above now prevents.
while IFS= read -r -d '' dylib; do
	BAD_DEPS="$(otool -L "$dylib" | tail -n +2 | awk '{print $1}' \
		| grep -vE '^(@rpath/|@executable_path/|@loader_path/|/usr/lib/|/System/)' || true)"
	if [ -n "$BAD_DEPS" ]; then
		log "Non-relocatable dependency path(s) in $dylib:"
		printf '%s\n' "$BAD_DEPS" >&2
		die "built ffmpeg links a non-@rpath, non-system absolute path (adr/0006 §3 defect #1) — an external library was autodetected off this build machine; it must be disabled in FFMPEG_CONFIGURE_FLAGS, not shipped (nothing was promoted to $CRDP_FFMPEG_PREFIX)"
	fi
done < <(find "$STAGED_PREFIX/lib" -maxdepth 1 -name '*.dylib' -type f -print0)
log "Relocatability guard OK: all produced dylibs load only @rpath/system paths"

# GPL guard: the licence posture is the reason this script exists, so verify it from the
# built artifact rather than trusting that the flags above were passed.
AVUTIL_DYLIB="$(find "$STAGED_PREFIX/lib" -maxdepth 1 -name 'libavutil.*.dylib' -type f | head -1)"
[ -n "$AVUTIL_DYLIB" ] || die "could not locate the built libavutil dylib for the licence check"
# `grep -c >/dev/null`, deliberately not `grep -q`: under `set -o pipefail`, grep -q exits
# on the first match, `strings` then dies of SIGPIPE, and the *pipeline* status becomes 141
# — so `if ! strings | grep -q X` reads as "X absent" precisely when X is present, and
# `if strings | grep -q X` never fires. Both directions are silently wrong, and which way
# it lands depends on whether strings finished writing before grep exited (i.e. on binary
# size — it is flaky, not consistently wrong). grep -c always drains its input, so the
# pipeline status is grep's real match/no-match answer. Verified empirically against this
# exact dylib: -q -> 141, -c -> 0.
if ! strings -a "$AVUTIL_DYLIB" | grep -c -- '--disable-gpl' >/dev/null; then
	die "built libavutil does not record --disable-gpl in its baked-in FFMPEG_CONFIGURATION string — refusing to ship a possibly-GPL ffmpeg (this is the W8 licence invariant; nothing was promoted to $CRDP_FFMPEG_PREFIX)"
fi
if strings -a "$AVUTIL_DYLIB" | grep -cE -- '--enable-(gpl|nonfree|version3)' >/dev/null; then
	die "built libavutil records --enable-gpl/nonfree/version3 — this build is not LGPL-2.1-or-later and must not be redistributed (nothing was promoted to $CRDP_FFMPEG_PREFIX)"
fi
log "Licence guard OK: built libavutil records --disable-gpl and no --enable-gpl/nonfree/version3"

# --- Promotion: every guard above has passed, so this tree is allowed to be reachable ---
# Known, accepted race (same shape as Scripts/build-openssl.sh's identical rm -rf + mv):
# the window between the rm and the mv is not atomic, so an interrupt (or a second
# concurrent run of this script) can leave $CRDP_FFMPEG_PREFIX absent or half-populated.
# It is not made safe here because the recovery is already correct and cheap: the stamp
# file is written *last*, so any interrupted promotion leaves an unstamped prefix, the next
# run rebuilds from scratch rather than trusting it, and Scripts/build-freerdp.sh
# independently refuses to configure against a prefix whose version stamp is missing. These
# scripts are not designed for concurrent invocation.
log "Promoting staged install to $CRDP_FFMPEG_PREFIX"
rm -rf "$CRDP_FFMPEG_PREFIX"
mv "$STAGED_PREFIX" "$CRDP_FFMPEG_PREFIX"
rm -rf "$STAGING_ROOT"

# The generated .pc files still say prefix=<placeholder>; pkg-config derives -L/-I from
# that, so FreeRDP's find_package(FFmpeg) (which shells out to pkg-config, see
# ThirdParty/FreeRDP/cmake/FindFFmpeg.cmake) would hand CMake paths that do not exist.
# Rewrite the placeholder to the real location. These are plain text build-time metadata,
# never shipped, so unlike the compiled-in constants they are safe to point at a local
# path. (Done after promotion because the value written is the promoted location.)
log "Rewriting pkg-config prefix in $CRDP_FFMPEG_PREFIX/lib/pkgconfig/*.pc"
PC_COUNT=0
while IFS= read -r -d '' pc; do
	# perl with \Q...\E and both values passed through the environment, not `sed s|a|b|`:
	# neither path is a literal in a regex, and both land in a *substitution* where `&`,
	# `\1` and the delimiter itself are all metacharacters. A developer whose checkout path
	# contains an `&` (legal on macOS) would silently get a corrupted .pc file — pkg-config
	# would then hand CMake a bad -L and the build would fail somewhere far away from the
	# cause. \Q...\E quotes the pattern; $ENV{} in the replacement is a plain string
	# interpolation with no metacharacter meaning.
	FFMPEG_PC_FROM="$FFMPEG_PREFIX_PLACEHOLDER" FFMPEG_PC_TO="$CRDP_FFMPEG_PREFIX" \
		perl -i -pe 's/\Q$ENV{FFMPEG_PC_FROM}\E/$ENV{FFMPEG_PC_TO}/g' "$pc"
	PC_COUNT=$((PC_COUNT + 1))
done < <(find "$CRDP_FFMPEG_PREFIX/lib/pkgconfig" -name '*.pc' -print0)
[ "$PC_COUNT" -gt 0 ] || die "no .pc files found under $CRDP_FFMPEG_PREFIX/lib/pkgconfig — FreeRDP's find_package(FFmpeg) resolves through pkg-config and would silently fall back to a system/Homebrew ffmpeg"
# Cheap proof the rewrite actually happened; a silently unmatched substitution would leave
# the placeholder in place and send CMake at a path that does not exist.
if grep -rlF "$FFMPEG_PREFIX_PLACEHOLDER" "$CRDP_FFMPEG_PREFIX/lib/pkgconfig" >/dev/null 2>&1; then
	die "pkg-config files still reference $FFMPEG_PREFIX_PLACEHOLDER after the rewrite — the substitution did not take effect"
fi

date -u +%Y-%m-%dT%H:%M:%SZ >"$STAMP_FILE"
log "FFmpeg $FFMPEG_VERSION installed to $CRDP_FFMPEG_PREFIX"
log "Components: ${EXPECTED_COMPONENTS[*]} (shared, @rpath install names, LGPL-2.1-or-later)"
