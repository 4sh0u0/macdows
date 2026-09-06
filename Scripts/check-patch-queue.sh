#!/usr/bin/env bash
# check-patch-queue.sh: validate the FreeRDP patch queue (ThirdParty/patches/*.patch) against
# the rules in ThirdParty/patches/README.md, without building anything:
#
#   rule 1 -- every patch's header carries an upstream record (FreeRDP issue/PR link) or the
#             lab-only marker (default-OFF knob + Accepted ADR); the verdict is lib.sh's
#             crdp_patch_record_ok, the same function Scripts/build-freerdp.sh consults.
#   rule 2 -- every patch applies cleanly to the pinned ThirdParty/FreeRDP checkout
#             (`git apply --check`); a patch that no longer applies is a hard failure.
#
# Tier 1's "Patch queue validation" step runs this script; before 2026-09-07 the workflow and
# the build script each carried their own copy of the rule-1 grep, which is exactly how an
# exception lands in one and not the other. Scripts/test-patch-queue.sh pins this script.
#
# Usage: Scripts/check-patch-queue.sh [--patch-dir DIR] [--freerdp-src DIR] [--no-apply]
#   --patch-dir DIR     queue to validate (default: ThirdParty/patches)
#   --freerdp-src DIR   pinned checkout for rule 2 (default: ThirdParty/FreeRDP)
#   --no-apply          rule 1 only (for fixtures with no checkout to apply against)
# Exit 0 when every patch passes (or the queue is empty), 1 on the first refusal.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

PATCH_DIR="$CRDP_REPO_ROOT/ThirdParty/patches"
FREERDP_SRC="$CRDP_REPO_ROOT/ThirdParty/FreeRDP"
APPLY=1
while [ $# -gt 0 ]; do
	case "$1" in
	--patch-dir) PATCH_DIR="${2:?--patch-dir needs a directory}"; shift 2 ;;
	--freerdp-src) FREERDP_SRC="${2:?--freerdp-src needs a directory}"; shift 2 ;;
	--no-apply) APPLY=0; shift ;;
	*) die "unknown argument: $1 (supported: --patch-dir DIR, --freerdp-src DIR, --no-apply)" ;;
	esac
done

PATCHES=()
if [ -d "$PATCH_DIR" ]; then
	while IFS= read -r -d '' p; do PATCHES+=("$p"); done \
		< <(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' -print0 | sort -z)
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
