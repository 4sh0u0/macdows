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
# rule 1 exception). "Header" means the lines before the first real diff line (`diff --git `,
# `--- a/` or `--- /dev/null`; a prose line that merely starts with "--- " does not end it,
# gate r1 m-3): a link that merely appears inside a hunk's context or additions does not count.
#
# The marker is a claim, so a marker-admitted patch must have the lab-only SHAPE, checked
# mechanically over its whole diff body (gate d1-lane r1 I-3, r2 I-7, r3 B-4, r4 B-6, r5 B-7/B-8).
# The rules are a GRAMMAR of what a guarded default-OFF knob looks like, not a token test:
#   1. exactly ONE new CMake `option(MACDOWS_LAB_<X> "..." OFF)` line, added in a hunk of a
#      *.cmake / CMakeLists.txt file (the knob);
#   2. every other ADDED line is one of: a one-line C comment that is nothing else (`/* ... */`
#      alone on the line, or `//`); or exactly `#cmakedefine MACDOWS_LAB_<X>` in a `*.in` template.
#      No code line is admitted, whether or not it names the knob, and NO added line at all is
#      admitted in a CMake file besides the knob itself: a `#` line there is a comment only outside
#      a multi-line quoted or bracket argument, which a hunk cannot prove (gate r6 B-9 -- the pinned
#      tree embeds C++ test sources in CMake strings). No added line may contain a backslash or
#      the sequence `??`: a comment ending in `\` (or in the `??/` trigraph under ISO modes) is
#      spliced with the NEXT physical line before comments are even recognised (C translation
#      phase 2 precedes phase 3), so it would swallow real code (gate r7 B-10, demonstrated
#      against rdpgfx_main.c). Residual, stated: a C comment line added inside a C++ raw string
#      literal (R"(...)") would be string content; the pinned tree's channels/ and libfreerdp/
#      contain no raw string literal, and the reviewer of a lab patch checks its sites;
#   3. every REMOVED line is a `#if` / `#elif` line re-added in the same hunk as exactly the removed
#      text followed by ` && !defined(MACDOWS_LAB_<X>)` -- a guard appended, nothing else;
#   4. text hunks of existing files only: every `diff --git` block carries a `--- a/` / `+++ b/`
#      pair naming the SAME file the block names (what `git apply` reads), so a bare hunk, a
#      mode-only block, a binary block, a new/deleted file, a rename or a copy is refused.
#   CR is stripped first so a CRLF patch is judged on its content. A bug fix, a behaviour change,
#   an extra hunk riding along, a `set(KNOB ...)` override, a runtime `if (KNOB)`, or a knob named
#   outside MACDOWS_LAB_* all fail one of the four. What the shape does NOT judge: the option's
#   description string and comment text (inert), and whether the guarded `#if` sites are the right
#   ones -- that is the ADR's and the reviewer's job.
#
# This is the ONE implementation of the rule. Scripts/build-freerdp.sh consults it before
# folding the queue into the config hash, Scripts/check-patch-queue.sh (Tier 1's patch
# validation step) and Scripts/gen-notices.sh (the release SBOM) consult it too -- keep it here
# so the build, CI and the release can never disagree. Scripts/test-patch-queue.sh pins the verdicts.
#
# Usage:  crdp_patch_record_ok "$patch_file"   (0 = record present, 1 = refuse)
crdp_patch_record_ok() {
	local file="${1:-}" header
	[ -f "$file" ] || return 1
	header="$(awk '/^(diff --git |--- (a\/|\/dev\/null))/ { exit } { print }' "$file")"
	printf '%s\n' "$header" | grep -qE 'github\.com/FreeRDP/FreeRDP/(issues|pull)/[0-9]+' && return 0
	if printf '%s\n' "$header" | grep -qE '^# Lab-only: default OFF; ADR: docs/adr/[0-9]{4}-[A-Za-z0-9._-]+\.md'; then
		awk '
			{ sub(/\r$/, "") }
			/^diff --git / { inbody = 1; ndg++; hdr = $NF; sub(/^b\//, "", hdr); file = ""; cmake = 0; next }
			/^--- (a\/|\/dev\/null)/ { inbody = 1; if (hdr == "") { bad = 1 }; next }
			!inbody { next }
			/^(rename (from|to)|copy (from|to)|new file mode|deleted file mode|similarity index|old mode|new mode|GIT binary patch|Binary files )/ { bad = 1; next }
			/^\+\+\+ / { file = $2; npp++
			             if (file == "/dev/null") { bad = 1; next }
			             sub(/^b\//, "", file)
			             if (hdr == "" || file != hdr) { bad = 1 }
			             hdr = ""; cmake = (file ~ /(\.cmake|CMakeLists\.txt)$/); next }
			/^@@ / { h++; next }
			/^\+[[:space:]]*option\([[:space:]]*MACDOWS_LAB_[A-Za-z0-9_]+[[:space:]]+"[^"]*"[[:space:]]+OFF[[:space:]]*\)[[:space:]]*$/ && cmake {
				name = $0; sub(/^\+[[:space:]]*option\([[:space:]]*/, "", name); sub(/[[:space:]].*/, "", name)
				nopt++; knob = name; next }
			/^\+/ { np[h]++; plus[h, np[h]] = substr($0, 2); pcm[h, np[h]] = cmake; pin[h, np[h]] = (file ~ /\.in$/); next }
			/^-/  { nm[h]++; minus[h, nm[h]] = substr($0, 2); next }
			END {
				if (bad || nopt != 1 || ndg != npp || hdr != "") exit 1
				guardtail = "^[[:space:]]*&&[[:space:]]*!defined\\(" knob "\\)[[:space:]]*$"
				guardline = "^[[:space:]]*#[[:space:]]*(if|elif)[[:space:]].*&&[[:space:]]*!defined\\(" knob "\\)[[:space:]]*$"
				for (k = 1; k <= h; k++) {
					# rule 2: every added line is a comment, the cmakedefine, or a guard re-add (which
					# rule 3 then pairs with a removed line -- a guard line with no removed twin is refused)
					ng = 0
					for (i = 1; i <= np[k]; i++) {
						l = plus[k, i]
						if (l ~ /\\|\?\?/) exit 1
						if (l ~ /^[[:space:]]*\/\*([^*]|\*+[^*\/])*\*+\/[[:space:]]*$/) continue
						if (l ~ /^[[:space:]]*\/\//) continue
						if (pcm[k, i]) exit 1
						if (pin[k, i] && l ~ ("^[[:space:]]*#cmakedefine[[:space:]]+" knob "[[:space:]]*$")) continue
						if (l ~ guardline) { ng++; continue }
						exit 1
					}
					# rule 3: every removed line is a #if/#elif re-added as itself + the guard tail;
					# the number of guard re-adds must equal the number of removed lines (bijection)
					matched = 0
					for (i = 1; i <= nm[k]; i++) {
						r = minus[k, i]; found = 0
						if (r !~ /^[[:space:]]*#[[:space:]]*(if|elif)[[:space:]]/) exit 1
						for (j = 1; j <= np[k]; j++) {
							l = plus[k, j]
							if (substr(l, 1, length(r)) == r && substr(l, length(r) + 1) ~ guardtail) { found = 1; break }
						}
						if (!found) exit 1
						matched++
					}
					if (ng != matched) exit 1
				}
				exit 0
			}
		' "$file" && return 0
	fi
	return 1
}

# Does a Scripts/build-freerdp.sh run get to publish its prefix as .build/freerdp/current?
# Only the product build (CRDP_LAB_SCALEDMAP_ADVERTISE=0) does; a lab build (1) never does, so
# App/ and every default consumer keep the product build (ADR-0016 section 1.2). Both places the
# build script links `current` consult this, and Scripts/test-build-freerdp-toggle.sh pins it
# (gate d1-lane r1 I-5).
#
# Usage:  crdp_freerdp_build_publishes_current "$CRDP_LAB_SCALEDMAP_ADVERTISE"   (0 = publish)
crdp_freerdp_build_publishes_current() {
	[ "${1:-0}" = "0" ]
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
