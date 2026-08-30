#!/usr/bin/env bash
# Shared helpers sourced by the other Scripts/*.sh entry points.
# This file is not an entry point itself — it has no shebang-executable purpose beyond
# letting shellcheck and editors identify it as bash, and it inherits `set -euo pipefail`
# from whichever script sources it (all of them set it themselves too, so sourcing this
# alone from a non-strict caller would still leave the caller non-strict — don't rely on
# it for that).
set -euo pipefail

CRDP_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CRDP_REPO_ROOT

CRDP_BUILD_DIR="$CRDP_REPO_ROOT/.build"
CRDP_DEPS_PREFIX="$CRDP_BUILD_DIR/deps/prefix"
# ffmpeg gets its *own* prefix rather than sharing CRDP_DEPS_PREFIX with OpenSSL:
# Scripts/build-openssl.sh does an `rm -rf "$CRDP_DEPS_PREFIX"` before relocating its
# staged install, so anything else living there would be silently deleted by an unrelated
# OpenSSL rebuild. Sibling directories keep the two lifecycles independent while still
# sharing .build/deps/{download,src}.
CRDP_FFMPEG_PREFIX="$CRDP_BUILD_DIR/deps/ffmpeg-prefix"
export CRDP_BUILD_DIR CRDP_DEPS_PREFIX CRDP_FFMPEG_PREFIX

log() { printf '[%s] %s\n' "$(basename "${BASH_SOURCE[1]:-$0}")" "$*" >&2; }
die() {
	log "ERROR: $*"
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}
