#!/usr/bin/env bash
# check-patch-queue.sh: validate the FreeRDP patch queue (ThirdParty/patches/*.patch) against
# the rules in ThirdParty/patches/README.md, without building anything:
#
#   rule 5 -- the lock's inventory names exactly the queue: the set of deps/freerdp.lock
#             .patches[].file names equals the set of *.patch file names in the queue directory,
#             in both directions (both empty passes). The lock must carry a .patches array, every
#             entry a bare file name, no name twice. Checked FIRST, before the empty-queue exit:
#             a patch file deleted with its lock entry left behind used to pass as "No patches",
#             and a lock whose .patches was emptied with the file left in place passed too
#             (lane rail-clientstatus, 2026-11-10: writer M3, gate r1 m-6).
#   rule 1 -- every patch's header carries an upstream record (FreeRDP issue/PR link) or the
#             lab-only marker (default-OFF knob + Accepted ADR); the verdict is lib.sh's
#             crdp_patch_record_ok, the same function Scripts/build-freerdp.sh consults.
#   rule 2 -- every patch applies cleanly to the pinned ThirdParty/FreeRDP checkout
#             (`git apply --check`); a patch that no longer applies is a hard failure.
#
# Tier 1's "Patch queue validation" step runs this script; before 2026-09-07 the workflow and
# the build script each carried their own copy of the rule-1 grep, which is exactly how an
# exception lands in one and not the other. Scripts/test-patch-queue.sh pins this script.
# Rule 5 lives here only: Scripts/build-freerdp.sh never reads the lock's .patches (it globs the
# directory), and that script and lib.sh are config-hash inputs, so the rule stays out of both.
#
# Usage: Scripts/check-patch-queue.sh [--patch-dir DIR] [--freerdp-src DIR] [--lock FILE] [--no-apply] [--no-lock]
#   --patch-dir DIR     queue to validate (default: ThirdParty/patches)
#   --freerdp-src DIR   pinned checkout for rule 2 (default: ThirdParty/FreeRDP)
#   --lock FILE         lock whose .patches[] rule 5 compares with the queue (default: deps/freerdp.lock)
#   --no-apply          skip rule 2 (for fixtures with no checkout to apply against)
#   --no-lock           skip rule 5 (for rule-1/2 fixtures that have no lock of their own); a
#                       --patch-dir given without --lock is still compared with the default lock
# Exit 0 when every rule passes (an empty queue with an empty .patches passes), 1 on the first refusal.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

PATCH_DIR="$CRDP_REPO_ROOT/ThirdParty/patches"
FREERDP_SRC="$CRDP_REPO_ROOT/ThirdParty/FreeRDP"
LOCK_FILE="$CRDP_REPO_ROOT/deps/freerdp.lock"
APPLY=1
CHECK_LOCK=1
while [ $# -gt 0 ]; do
	case "$1" in
	--patch-dir) PATCH_DIR="${2:?--patch-dir needs a directory}"; shift 2 ;;
	--freerdp-src) FREERDP_SRC="${2:?--freerdp-src needs a directory}"; shift 2 ;;
	--lock) LOCK_FILE="${2:?--lock needs a file}"; shift 2 ;;
	--no-apply) APPLY=0; shift ;;
	--no-lock) CHECK_LOCK=0; shift ;;
	*) die "unknown argument: $1 (supported: --patch-dir DIR, --freerdp-src DIR, --lock FILE, --no-apply, --no-lock)" ;;
	esac
done

# Absolute paths before anything is handed to `git -C "$FREERDP_SRC"`, which resolves a
# relative patch path INSIDE the submodule (the pitfall tier1.yml's old step documented).
[ -d "$PATCH_DIR" ] && PATCH_DIR="$(cd "$PATCH_DIR" && pwd)"
[ -d "$FREERDP_SRC" ] && FREERDP_SRC="$(cd "$FREERDP_SRC" && pwd)"
PATCHES=()
if [ -d "$PATCH_DIR" ]; then
	while IFS= read -r -d '' p; do PATCHES+=("$p"); done \
		< <(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' -print0 | sort -z)
fi

# in_names <needle> [names...]: 0 when <needle> equals one of the names. A linear scan, not an
# associative array: the queue holds a handful of files and bash 3.2 (macOS /bin/bash) has none.
in_names() {
	local needle="$1" n
	shift
	for n in "$@"; do
		[ "$n" = "$needle" ] && return 0
	done
	return 1
}

if [ "$CHECK_LOCK" -eq 1 ]; then
	require_cmd jq
	[ -f "$LOCK_FILE" ] || die "no lock file at $LOCK_FILE (ThirdParty/patches/README.md rule 5), or pass --no-lock"
	# Read into a variable first, not `done < <(jq ...)`: a process substitution's exit status is
	# lost, and a lock jq cannot read must refuse rather than look like an empty inventory. A
	# missing .patches (or a non-array) refuses for the same reason: "the lock lists nothing" has
	# to be written down as [], not implied by an absent key.
	lock_raw="$(jq -r '
		if (.patches | type) != "array" then error("no .patches array")
		else .patches[] | .file
			| if type == "string" and length > 0 and (contains("/") | not) and (contains("\n") | not)
			  then . else error("a .patches entry has no bare file name in .file") end
		end' "$LOCK_FILE")" \
		|| die "cannot read a .patches array of bare .file names from $LOCK_FILE (ThirdParty/patches/README.md rule 5)"
	LOCK_NAMES=()
	if [ -n "$lock_raw" ]; then
		while IFS= read -r n; do
			if [ "${#LOCK_NAMES[@]}" -gt 0 ] && in_names "$n" "${LOCK_NAMES[@]}"; then
				die "$LOCK_FILE .patches lists $n twice (ThirdParty/patches/README.md rule 5)"
			fi
			LOCK_NAMES+=("$n")
		done <<<"$lock_raw"
	fi
	DIR_NAMES=()
	if [ "${#PATCHES[@]}" -gt 0 ]; then
		for p in "${PATCHES[@]}"; do DIR_NAMES+=("$(basename "$p")"); done
	fi
	missing_files=""  # listed in the lock, no such file in the queue directory
	unlisted_files="" # a file in the queue directory the lock does not list
	for n in ${LOCK_NAMES[@]+"${LOCK_NAMES[@]}"}; do
		in_names "$n" ${DIR_NAMES[@]+"${DIR_NAMES[@]}"} || missing_files="$missing_files $n"
	done
	for n in ${DIR_NAMES[@]+"${DIR_NAMES[@]}"}; do
		in_names "$n" ${LOCK_NAMES[@]+"${LOCK_NAMES[@]}"} || unlisted_files="$unlisted_files $n"
	done
	if [ -n "$missing_files$unlisted_files" ]; then
		die "$LOCK_FILE .patches and $PATCH_DIR disagree (ThirdParty/patches/README.md rule 5) -- listed in the lock with no file in the queue directory:${missing_files:- (none)}; in the queue directory but not listed in the lock:${unlisted_files:- (none)}. Adding a patch adds its file and its .patches entry in one commit; retiring one deletes the file and moves its entry to .retired_patches in one commit."
	fi
	echo "Lock inventory matches the queue: ${#LOCK_NAMES[@]} patch(es) in $LOCK_FILE .patches, the same names as the *.patch files in $PATCH_DIR (rule 5)."
else
	echo "Rule 5 (lock inventory) skipped: --no-lock."
fi

if [ "${#PATCHES[@]}" -eq 0 ]; then
	echo "No patches in $PATCH_DIR -- nothing to validate."
	exit 0
fi

require_cmd git
for patch in "${PATCHES[@]}"; do
	name="$(basename "$patch")"
	echo "Checking $name"
	crdp_patch_record_ok "$patch" \
		|| die "patch $name has no upstream issue/PR link and no lab-only marker in its header (ThirdParty/patches/README.md rule 1)"
	if [ "$APPLY" -eq 1 ]; then
		[ -e "$FREERDP_SRC/.git" ] || die "no pinned FreeRDP checkout at $FREERDP_SRC (run: git submodule update --init ThirdParty/FreeRDP), or pass --no-apply"
		git -C "$FREERDP_SRC" apply --check "$patch" \
			|| die "patch $name fails 'git apply --check' against the pinned FreeRDP checkout (ThirdParty/patches/README.md rule 2)"
	fi
done
echo "All ${#PATCHES[@]} patch(es) validated."
