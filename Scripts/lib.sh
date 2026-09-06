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

# Patch-queue rule 1 (ThirdParty/patches/README.md): every .patch file's HEADER must carry an
# upstream record -- a FreeRDP issue/PR link -- or, since ADR-0016 (owner ruling 2026-09-07),
# the lab-only marker
#     # Lab-only: default OFF; ADR: docs/adr/NNNN-<slug>.md
# which is valid only for a default-OFF build knob backed by an Accepted ADR (the README's
# rule 1 exception). "Header" means the lines before the first diff line (`diff --git ` or
# `--- `): a link that merely appears inside a hunk's context or additions does not count.
#
# This is the ONE implementation of the rule. Scripts/build-freerdp.sh consults it before
# folding the queue into the config hash, and Scripts/check-patch-queue.sh (Tier 1's patch
# validation step) consults it too -- keep it here so the build and CI can never disagree
# about what the rule accepts. Scripts/test-patch-queue.sh pins the verdicts.
#
# Usage:  crdp_patch_record_ok "$patch_file"   (0 = record present, 1 = refuse)
crdp_patch_record_ok() {
	local file="${1:-}" header
	[ -f "$file" ] || return 1
	header="$(awk '/^(diff --git |--- )/ { exit } { print }' "$file")"
	printf '%s\n' "$header" | grep -qE 'github\.com/FreeRDP/FreeRDP/(issues|pull)/[0-9]+' && return 0
	printf '%s\n' "$header" | grep -qE '^# Lab-only: default OFF; ADR: docs/adr/[0-9]{4}-[A-Za-z0-9._-]+\.md' && return 0
	return 1
}

# Live-host testing boundary gate (owner rule, 2026-08-31): a real-host debugging step may
# only ever target the owner's own machine inside the owner's own lab network. Prose in a
# rules file cannot enforce that, so every script that is about to touch a live host calls
# this first and refuses on a non-zero return.
#
# Fail-closed by construction: *every* path that cannot positively prove the target is
# inside an allowed segment returns 1. Missing boundary file, empty segment list, absent
# python3, empty host, unresolvable name, a name that resolves to several addresses of
# which any one falls outside -- all refusals.
#
# The allowed segments are maintainer-local data and never appear in a tracked file. They
# are read at call time from $MACDOWS_LAB_BOUNDARY_FILE (default
# ~/.config/macdows/lab-boundary.env), whose only key is MACDOWS_LAB_ALLOWED_NETS: a
# space-separated CIDR list. Nothing here ever prints that list, or the address a name
# resolved to -- a refusal names the host argument and the reason and nothing else, so a
# terminal scrollback, a tee'd log or a CI transcript can never become the place the
# segments leak.
#
# Usage:  crdp_assert_lab_boundary "$host" || <caller's own refusal path>
crdp_assert_lab_boundary() {
	local host="${1:-}"
	# ${HOME:-} rather than $HOME: with HOME unset, a caller running under `set -u` would be
	# killed outright by the expansion. Degrading to an absolute path that cannot exist
	# keeps the failure inside the fail-closed path below.
	local boundary_file="${MACDOWS_LAB_BOUNDARY_FILE:-${HOME:-}/.config/macdows/lab-boundary.env}"
	local nets reason

	if [ -z "$host" ]; then
		printf '[lab-boundary] REFUSED: empty target host\n' >&2
		return 1
	fi
	if [ ! -f "$boundary_file" ] || [ ! -r "$boundary_file" ]; then
		printf '[lab-boundary] REFUSED: %s -- boundary file not readable: %s\n' "$host" "$boundary_file" >&2
		return 1
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		printf '[lab-boundary] REFUSED: %s -- python3 unavailable, cannot evaluate the boundary\n' "$host" >&2
		return 1
	fi

	# Sourced inside a command substitution on purpose: the segment list must not land in
	# the caller's environment (where a later `env`/crash dump would carry it), and a
	# caller running under `set -e` must not be killed outright by a malformed boundary
	# file -- a failed source yields an empty value, which the next test turns into an
	# ordinary refusal.
	nets=""
	# shellcheck source=/dev/null
	nets="$( . "$boundary_file" >/dev/null 2>&1; printf '%s' "${MACDOWS_LAB_ALLOWED_NETS:-}" )" || nets=""
	if [ -z "${nets//[[:space:]]/}" ]; then
		printf '[lab-boundary] REFUSED: %s -- boundary file defines no allowed segments\n' "$host" >&2
		return 1
	fi

	# Host and segments travel in the environment, not in argv: argv is world-readable
	# through `ps` on this platform, the environment of another user's process is not.
	# The heredoc body sits at column 0 because Python's indentation is significant and
	# an unindented terminator is the one form that cannot be corrupted by tab/space
	# reflowing of this file.
	reason=""
	if ! reason="$(
		MACDOWS_GATE_HOST="$host" MACDOWS_GATE_NETS="$nets" python3 - <<'CRDP_LAB_BOUNDARY_PY'
import ipaddress
import os
import socket

host = os.environ["MACDOWS_GATE_HOST"]

try:
    nets = [ipaddress.ip_network(n, strict=False) for n in os.environ["MACDOWS_GATE_NETS"].split()]
except ValueError:
    # The ValueError text would quote the offending segment; never let it out.
    print("boundary file lists an unparseable segment")
    raise SystemExit(1)
if not nets:
    print("boundary file defines no allowed segments")
    raise SystemExit(1)

try:
    addrs = [ipaddress.ip_address(host)]
except ValueError:
    try:
        infos = socket.getaddrinfo(host, None)
    except (OSError, UnicodeError):
        # UnicodeError, not OSError, is what the idna codec raises for a DNS label over 63
        # characters; without it the refusal arrives as a traceback.
        print("host does not resolve")
        raise SystemExit(1)
    addrs = []
    for info in infos:
        try:
            addrs.append(ipaddress.ip_address(info[4][0].split("%")[0]))
        except ValueError:
            print("host resolved to an unparseable address")
            raise SystemExit(1)
    if not addrs:
        print("host resolves to no address")
        raise SystemExit(1)

# Every resolved address must be inside; one stray answer is enough to refuse.
for addr in addrs:
    if not any(addr in net for net in nets):
        print("target is outside the allowed lab segments")
        raise SystemExit(1)

raise SystemExit(0)
CRDP_LAB_BOUNDARY_PY
	)"; then
		printf '[lab-boundary] REFUSED: %s -- %s\n' "$host" "${reason:-boundary evaluation failed}" >&2
		return 1
	fi

	printf '[lab-boundary] target inside allowed segments\n'
	return 0
}
