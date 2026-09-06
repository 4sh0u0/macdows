#!/usr/bin/env bash
# test-patch-queue.sh: offline pins for the patch-queue rules (ThirdParty/patches/README.md
# rules 1 and 2) as enforced by Scripts/check-patch-queue.sh and lib.sh's
# crdp_patch_record_ok -- the ONE implementation Scripts/build-freerdp.sh and Tier 1 both call.
#
# Why this exists (2026-09-07, ADR-0016 D1): the queue gained its first lab-only patch (a
# default-OFF CMake option with no upstream record) and rule 1 gained the owner-ruled
# exception for exactly that shape. Until now rule 1 lived as two copies of one grep (the
# build script and the workflow); an exception added to one copy and not the other would
# have let the build and CI disagree. The regex now lives in lib.sh, and this suite pins what
# it accepts and refuses on synthetic patch files -- no compiler, no network, no shared
# .build/ state. Case 7/8 need the pinned FreeRDP submodule checkout (`git apply --check`
# is rule 2 itself); Tier 1 checks out submodules for that reason.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/check-patch-queue.sh"
FREERDP_SRC="$REPO_ROOT/ThirdParty/FreeRDP"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/patch-queue-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() {
    # check <name> <expected-exit> <expected-output-substring> <check-patch-queue args...>
    local name="$1" want_rc="$2" want_out="$3"; shift 3
    local out rc
    set +e
    out="$("$CHECK" "$@" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq "$want_rc" ] && [[ "$out" == *"$want_out"* ]]; then
        pass=$((pass + 1)); echo "  ok   $name"
    else
        fail=$((fail + 1)); echo "  FAIL $name :: rc=$rc (want $want_rc); output: $out" | head -c 800; echo
    fi
}

LINK='# Upstream: https://github.com/FreeRDP/FreeRDP/issues/12345'
MARKER='# Lab-only: default OFF; ADR: docs/adr/0016-scaledmap-disable-configurable-d1.md'
# A hunk that cannot apply to any file in the pinned tree: rule 2 must refuse it.
BOGUS_HUNK='diff --git a/CMakeLists.txt b/CMakeLists.txt
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -1,1 +1,1 @@
-this line does not exist in the pinned CMakeLists.txt
+nor does this one'

mk() { # mk <dir> <name> <header-lines...>
    local dir="$1" name="$2"; shift 2
    mkdir -p "$dir"
    { for h in "$@"; do printf '%s\n' "$h"; done; printf '%s\n' "$BOGUS_HUNK"; } > "$dir/$name"
}

echo "== rule 1: upstream record OR the lab-only marker, in the header"
mk "$TMP/empty" .keep   # no *.patch files at all
rm -f "$TMP/empty/.keep"
check 'empty queue passes and says so'                       0 'No patches'          --patch-dir "$TMP/empty" --no-apply
mk "$TMP/link"   0001-link.patch   "$LINK"
check 'a GitHub issue/PR link in the header passes'          0 '1 patch(es) validated' --patch-dir "$TMP/link" --no-apply
mk "$TMP/marker" 0001-lab.patch    "$MARKER"
check 'the lab-only marker (default OFF + ADR) passes'        0 '1 patch(es) validated' --patch-dir "$TMP/marker" --no-apply
mk "$TMP/none"   0001-none.patch   '# a patch with no record at all'
check 'neither record refuses, naming rule 1 and the file'   1 'rule 1'              --patch-dir "$TMP/none" --no-apply
check 'the refusal names the offending file'                 1 '0001-none.patch'     --patch-dir "$TMP/none" --no-apply
mk "$TMP/on"     0001-on.patch     '# Lab-only: default ON; ADR: docs/adr/0016-scaledmap-disable-configurable-d1.md'
check 'a lab-only marker that is not default OFF refuses'     1 'rule 1'              --patch-dir "$TMP/on" --no-apply
mk "$TMP/noadr"  0001-noadr.patch  '# Lab-only: default OFF'
check 'a lab-only marker without an ADR refuses'              1 'rule 1'              --patch-dir "$TMP/noadr" --no-apply
mkdir -p "$TMP/buried"
{ printf '%s\n' '# no record up here'; printf '%s\n' "$BOGUS_HUNK"; printf '%s\n' "+// see $LINK"; } > "$TMP/buried/0001-buried.patch"
check 'a link only inside a hunk (not the header) refuses'   1 'rule 1'              --patch-dir "$TMP/buried" --no-apply
mk "$TMP/mixed"  0001-link.patch   "$LINK"
mk "$TMP/mixed"  0002-none.patch   '# nothing'
check 'one bad patch fails the whole queue'                  1 '0002-none.patch'     --patch-dir "$TMP/mixed" --no-apply

echo "== rule 2: git apply --check against the pinned checkout"
if [ -e "$FREERDP_SRC/.git" ]; then
    check 'a header-valid patch that does not apply refuses (rule 2)' 1 'apply --check' --patch-dir "$TMP/marker" --freerdp-src "$FREERDP_SRC"
    check 'the real queue passes rule 1 and rule 2 against the pinned checkout' 0 '' --freerdp-src "$FREERDP_SRC"
else
    echo "  FAIL rule 2 cases need the ThirdParty/FreeRDP submodule checkout (git submodule update --init)"; fail=$((fail + 2))
fi

echo "== lib.sh: crdp_patch_record_ok is the same verdict"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
set +e
crdp_patch_record_ok "$TMP/link/0001-link.patch";     r1=$?
crdp_patch_record_ok "$TMP/marker/0001-lab.patch";    r2=$?
crdp_patch_record_ok "$TMP/none/0001-none.patch";     r3=$?
crdp_patch_record_ok "$TMP/buried/0001-buried.patch"; r4=$?
set -e
if [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && [ "$r3" -ne 0 ] && [ "$r4" -ne 0 ]; then
    pass=$((pass + 1)); echo "  ok   lib function: link ok, marker ok, none refused, buried refused"
else
    fail=$((fail + 1)); echo "  FAIL lib function verdicts: link=$r1 marker=$r2 none=$r3 buried=$r4"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
