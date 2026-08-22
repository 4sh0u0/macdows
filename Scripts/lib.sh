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
export CRDP_BUILD_DIR CRDP_DEPS_PREFIX

log() { printf '[%s] %s\n' "$(basename "${BASH_SOURCE[1]:-$0}")" "$*" >&2; }
die() {
	log "ERROR: $*"
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}
