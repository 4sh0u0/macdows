#!/usr/bin/env bash
# build-openssl.sh: download, verify, and build a pinned static OpenSSL for FreeRDP to
# link against. Replaces the lab prototype's dependency on Homebrew's openssl@3, which
# links by absolute path (`brew upgrade openssl` breaks every already-built binary) and
# isn't a pinned, SBOM-able version (adr/0006 §3 defect #1).
#
# Idempotent: skips the download/build/install if the target version is already
# installed under .build/deps/prefix. Delete the stamp file (printed on success) to
# force a rebuild, or pass --force.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd curl
require_cmd shasum
require_cmd tar
require_cmd perl
require_cmd make
require_cmd jq

FORCE=0
for arg in "$@"; do
	case "$arg" in
	--force) FORCE=1 ;;
	*) die "unknown argument: $arg (supported: --force)" ;;
	esac
done

# Pinned per deps/freerdp.lock .openssl (kept in sync manually — this is the one script
# that's allowed to know these values; deps/freerdp.lock documents the decision).
OPENSSL_VERSION="3.5.7"
OPENSSL_TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${OPENSSL_TARBALL}"
OPENSSL_SHA256="a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8"

LOCK_FILE="$CRDP_REPO_ROOT/deps/freerdp.lock"
[ -f "$LOCK_FILE" ] || die "missing $LOCK_FILE"
DEPLOYMENT_TARGET="$(jq -er '.deployment_target' "$LOCK_FILE")" \
	|| die "deps/freerdp.lock has no .deployment_target field"

DOWNLOAD_DIR="$CRDP_BUILD_DIR/deps/download"
SRC_DIR="$CRDP_BUILD_DIR/deps/src/openssl-${OPENSSL_VERSION}"
STAMP_FILE="$CRDP_DEPS_PREFIX/.openssl-${OPENSSL_VERSION}.stamp"

mkdir -p "$DOWNLOAD_DIR" "$CRDP_BUILD_DIR/deps/src" "$CRDP_DEPS_PREFIX"

if [ "$FORCE" -eq 0 ] && [ -f "$STAMP_FILE" ]; then
	log "OpenSSL $OPENSSL_VERSION already installed at $CRDP_DEPS_PREFIX (stamp: $STAMP_FILE); skipping. Pass --force to rebuild."
	exit 0
fi

TARBALL_PATH="$DOWNLOAD_DIR/$OPENSSL_TARBALL"
if [ -f "$TARBALL_PATH" ]; then
	log "Using cached tarball $TARBALL_PATH"
else
	log "Downloading $OPENSSL_URL"
	# --proto '=https' --proto-redir '=https': the sha256 below is the real integrity
	# control, but there is no reason to let a redirect (or a typo'd URL) silently downgrade
	# the transport to plain HTTP first. Constrains both the initial request and anything it
	# is redirected to. (github.com release URLs redirect to objects.githubusercontent.com,
	# so --proto-redir specifically matters here.)
	curl -fL --proto '=https' --proto-redir '=https' --retry 3 \
		-o "${TARBALL_PATH}.partial" "$OPENSSL_URL"
	mv "${TARBALL_PATH}.partial" "$TARBALL_PATH"
fi

log "Verifying sha256"
ACTUAL_SHA256="$(shasum -a 256 "$TARBALL_PATH" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$OPENSSL_SHA256" ]; then
	rm -f "$TARBALL_PATH"
	die "sha256 mismatch for $OPENSSL_TARBALL: expected $OPENSSL_SHA256, got $ACTUAL_SHA256 (corrupt/tampered download removed — re-run to retry)"
fi
log "sha256 OK: $ACTUAL_SHA256"

rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
log "Extracting to $SRC_DIR"
tar -xzf "$TARBALL_PATH" -C "$SRC_DIR" --strip-components=1

# --prefix and --openssldir are both fixed, non-user-specific paths, NOT $CRDP_DEPS_PREFIX
# (which lives under the developer's home directory): OpenSSL's Configure bakes both in
# as compiled-in string constants in libcrypto (--openssldir directly; --prefix
# indirectly, via derived ENGINESDIR/MODULESDIR constants — verified by `strings` on a
# first attempt that only fixed --openssldir and still leaked $HOME through --prefix's
# derived paths). Using the real build prefix here would burn "/Users/<name>/..." into
# every distributed binary, the exact "absolute local path leaked into shipped
# artifacts" defect class as the Homebrew linking issues elsewhere in this ADR. Neither
# ENGINESDIR/MODULESDIR nor --openssldir's contents are ever populated or read at
# runtime by our statically-linked, engine-free usage — they're dead configuration data,
# just not allowed to be *ours* while dead.
#
# Since --prefix must still be *some* value for `./Configure` and `make install` to work
# with, and that value is what ends up baked into the binary, we configure against a
# placeholder prefix that will never exist on any real machine, then use OpenSSL's
# `make install DESTDIR=` staging support to physically install into $CRDP_DEPS_PREFIX
# anyway — the compiled-in constants keep referencing the placeholder; the actual files
# our build (and everyone else's `OPENSSL_ROOT_DIR`) find are at the real location.
OPENSSL_PREFIX_PLACEHOLDER="/private/var/macdows-openssl-buildtime-prefix"
STAGING_ROOT="$CRDP_BUILD_DIR/deps/openssl-stage"

# no-module: the legacy provider (needed for MD4 -- classic NTLM's NT-hash step, which
# NTLMv2 responses still depend on) would otherwise build as a separately loadable
# providers/legacy.dylib, discovered at runtime via a MODULESDIR baked into libcrypto at
# compile time from --prefix. Since --prefix here is a placeholder path that gets
# relocated after the build (see the comment on OPENSSL_PREFIX_PLACEHOLDER below), that
# baked-in MODULESDIR never matches where the module file actually ends up, and
# OSSL_PROVIDER_load(NULL, "legacy") silently fails to find it at runtime -- this broke
# real-host NLA/CredSSP authentication with SEC_E_NO_CREDENTIALS end to end (root-caused
# during W4a; see providers/build.info's own comment on STATIC_LEGACY for the mechanism).
# `no-module` (with `legacy` left at its own default-enabled state) makes OpenSSL's build
# system compile the legacy provider's object files directly into libcrypto instead of a
# separate module -- OSSL_PROVIDER_load resolves a built-in provider from an in-process
# table, never touching the filesystem, so the placeholder-prefix relocation can no longer
# break it.
log "Configuring OpenSSL $OPENSSL_VERSION: no-shared no-module darwin64-arm64-cc -mmacosx-version-min=$DEPLOYMENT_TARGET --prefix=$OPENSSL_PREFIX_PLACEHOLDER (staged, not the real install location)"
(
	cd "$SRC_DIR"
	./Configure darwin64-arm64-cc no-shared no-module \
		"-mmacosx-version-min=$DEPLOYMENT_TARGET" \
		--prefix="$OPENSSL_PREFIX_PLACEHOLDER" \
		--openssldir="/private/etc/ssl"

	NPROC="$(sysctl -n hw.ncpu)"
	log "Building (make -j$NPROC)"
	make -j"$NPROC"

	log "Installing (install_sw + install_ssldirs; skipping docs/manpages) to staging root"
	rm -rf "$STAGING_ROOT"
	make DESTDIR="$STAGING_ROOT" install_sw install_ssldirs
)

log "Relocating staged install to $CRDP_DEPS_PREFIX"
rm -rf "$CRDP_DEPS_PREFIX"
mv "$STAGING_ROOT$OPENSSL_PREFIX_PLACEHOLDER" "$CRDP_DEPS_PREFIX"
rm -rf "$STAGING_ROOT"

date -u +%Y-%m-%dT%H:%M:%SZ >"$STAMP_FILE"
log "OpenSSL $OPENSSL_VERSION installed to $CRDP_DEPS_PREFIX"
