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
# A lab-only patch must ADD a default-OFF option (rule 1 exception, gate r1 I-3); this hunk is that line.
OPTION_HUNK='diff --git a/cmake/ConfigOptions.cmake b/cmake/ConfigOptions.cmake
--- a/cmake/ConfigOptions.cmake
+++ b/cmake/ConfigOptions.cmake
@@ -1,1 +1,2 @@
 option(WITH_SWSCALE "Use SWScale image library for screen resizing" ON)
+option(MACDOWS_LAB_FIXTURE "Lab-only fixture knob" OFF)'
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
mkdir -p "$TMP/marker"
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$BOGUS_HUNK"; } > "$TMP/marker/0001-lab.patch"
check 'the lab-only marker (default OFF + ADR) with an added default-OFF option passes' 0 '1 patch(es) validated' --patch-dir "$TMP/marker" --no-apply
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

echo "== rule 1, lab-only exception: the marker alone is a sentence; the patch must ADD a default-OFF option (gate r1 I-3)"
# The fixtures above carry only a bogus hunk. A real lab-only patch adds `option(<NAME> "..." OFF)`
# to a CMake file; a bug fix wearing the marker adds no such line and must be refused.
mkdir -p "$TMP/labopt" "$TMP/labon" "$TMP/labfix"
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; } > "$TMP/labopt/0001-lab.patch"
check 'marker + an added default-OFF option passes'          0 '1 patch(es) validated' --patch-dir "$TMP/labopt" --no-apply
{ printf '%s\n' "$MARKER"; printf '%s\n' "${OPTION_HUNK/OFF)/ON)}"; } > "$TMP/labon/0001-lab.patch"
check 'marker + an added option defaulting ON refuses'       1 'rule 1'              --patch-dir "$TMP/labon" --no-apply
{ printf '%s\n' "$MARKER"; printf '%s\n' "$BOGUS_HUNK"; } > "$TMP/labfix/0001-bugfix.patch"
check 'marker on a patch that adds no option (a bug fix in disguise) refuses' 1 'rule 1' --patch-dir "$TMP/labfix" --no-apply

echo "== the added option must be a NEW option in a CMake file's hunk (gate r2 I-7)"
mkdir -p "$TMP/opthdr" "$TMP/optmd" "$TMP/optflip"
# (a) the option line sits in the HEADER (before any diff line), not in a hunk
{ printf '%s\n' "$MARKER"; printf '%s\n' '+option(MACDOWS_LAB_FIXTURE "smuggled into the header" OFF)'; printf '%s\n' "$BOGUS_HUNK"; } > "$TMP/opthdr/0001-lab.patch"
check 'an option line in the header (not a hunk) does not count'   1 'rule 1' --patch-dir "$TMP/opthdr" --no-apply
# (b) the option line is added to a non-CMake file
MD_HUNK='diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1,1 +1,2 @@
 # FreeRDP
+option(MACDOWS_LAB_FIXTURE "not a CMake file" OFF)'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$MD_HUNK"; } > "$TMP/optmd/0001-lab.patch"
check 'an option line added to a non-CMake file does not count'     1 'rule 1' --patch-dir "$TMP/optmd" --no-apply
# (c) an existing upstream option flipped ON -> OFF is a behaviour change, not a new knob
FLIP_HUNK='diff --git a/cmake/ConfigOptions.cmake b/cmake/ConfigOptions.cmake
--- a/cmake/ConfigOptions.cmake
+++ b/cmake/ConfigOptions.cmake
@@ -1,1 +1,1 @@
-option(WITH_SWSCALE "Use SWScale image library for screen resizing" ON)
+option(WITH_SWSCALE "Use SWScale image library for screen resizing" OFF)'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$FLIP_HUNK"; } > "$TMP/optflip/0001-lab.patch"
check 'flipping an existing option ON->OFF is not an added knob'   1 'rule 1' --patch-dir "$TMP/optflip" --no-apply

echo "== the file a hunk targets is what git apply reads (--- / +++), not what diff --git claims (gate r3 B-4)"
mkdir -p "$TMP/lie" "$TMP/crlf" "$TMP/spaced" "$TMP/xfile"
# (a) diff --git names a .cmake file but --- / +++ target a C file: git apply patches the C file.
LIE_HUNK='diff --git a/cmake/ConfigOptions.cmake b/cmake/ConfigOptions.cmake
--- a/libfreerdp/core/rdp.c
+++ b/libfreerdp/core/rdp.c
@@ -1,1 +1,2 @@
 #include <freerdp/config.h>
+option(MACDOWS_LAB_FIXTURE "the header lies about the file" OFF)'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$LIE_HUNK"; } > "$TMP/lie/0001-lab.patch"
check 'a diff --git line that disagrees with --- / +++ refuses'      1 'rule 1' --patch-dir "$TMP/lie" --no-apply
# (b) CRLF line endings must not turn a valid lab patch into a refusal (r3 N-2)
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; } | sed 's/$/\r/' > "$TMP/crlf/0001-lab.patch"
check 'a CRLF-terminated lab patch with an added default-OFF option passes' 0 '1 patch(es) validated' --patch-dir "$TMP/crlf" --no-apply
# (c) CMake allows whitespace after the opening parenthesis (r3 N-3)
{ printf '%s\n' "$MARKER"; printf '%s\n' "${OPTION_HUNK/option(MACDOWS_LAB_FIXTURE/option( MACDOWS_LAB_FIXTURE}"; } > "$TMP/spaced/0001-lab.patch"
check '"option( NAME ..." with a space after the parenthesis passes'  0 '1 patch(es) validated' --patch-dir "$TMP/spaced" --no-apply
# (d) a removed option line in a DIFFERENT file is not a modification of the new knob (r3 N-4)
OTHER_REMOVE='diff --git a/client/CMakeLists.txt b/client/CMakeLists.txt
--- a/client/CMakeLists.txt
+++ b/client/CMakeLists.txt
@@ -1,2 +1,1 @@
 project(client)
-option(MACDOWS_LAB_FIXTURE "an unrelated line in another file" ON)'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$OTHER_REMOVE"; } > "$TMP/xfile/0001-lab.patch"
check 'a same-named removal in another file does not make the new option a flip' 0 '1 patch(es) validated' --patch-dir "$TMP/xfile" --no-apply

echo "== header boundary: only a real diff line ends the header (gate r1 m-3)"
mkdir -p "$TMP/dashes"
{ printf '%s\n' '# a header comment'; printf '%s\n' '--- notes: this line starts with three dashes but is prose'; printf '%s\n' "$LINK"; printf '%s\n' "$BOGUS_HUNK"; } > "$TMP/dashes/0001-dashes.patch"
check 'a header line starting with "--- " (prose) does not cut the header' 0 '1 patch(es) validated' --patch-dir "$TMP/dashes" --no-apply

echo "== rule 2: git apply --check against the pinned checkout"
if [ -e "$FREERDP_SRC/.git" ]; then
    check 'a header-valid patch that does not apply refuses (rule 2)' 1 'apply --check' --patch-dir "$TMP/marker" --freerdp-src "$FREERDP_SRC"
    check 'the real queue passes rule 1 and rule 2 against the pinned checkout' 0 '' --freerdp-src "$FREERDP_SRC"
    # gate r1 m-4: a RELATIVE --patch-dir must be normalised before `git -C <submodule> apply --check`
    # resolves it -- otherwise git looks for the patch inside the submodule (the documented pitfall).
    # Relative names are exercised from inside $TMP (never from the repo, never under .build/).
    mkdir -p "$TMP/rel/queue"
    if compgen -G "$REPO_ROOT/ThirdParty/patches/*.patch" >/dev/null; then
        cp "$REPO_ROOT"/ThirdParty/patches/*.patch "$TMP/rel/queue/"
        pushd "$TMP/rel" >/dev/null
        check 'a relative --patch-dir is normalised before git apply --check' 0 'validated' --patch-dir queue --freerdp-src "$FREERDP_SRC"
        popd >/dev/null
    else
        echo "  skip relative --patch-dir case: the real queue is empty (nothing that applies to copy)"
    fi
else
    echo "  FAIL rule 2 cases need the ThirdParty/FreeRDP submodule checkout (git submodule update --init)"; fail=$((fail + 2))
fi

echo "== one implementation: every enforcement point calls lib.sh, none carries its own grep (gate r1 B-1)"
callers=(Scripts/build-freerdp.sh Scripts/check-patch-queue.sh Scripts/gen-notices.sh)
one_impl=0
for f in "${callers[@]}"; do
    # a CALL line: the function name at the start of a statement (a comment mentioning it is not a call)
    grep -qE '^[[:space:]]*(if[[:space:]]+)?(!?[[:space:]]*)?crdp_patch_record_ok[[:space:]]+"' "$REPO_ROOT/$f" || { one_impl=1; echo "  missing call in $f"; }
    # The link pattern itself may appear in these scripts ONLY as gen-notices.sh's `grep -oE`
    # link EXTRACTION for the SBOM's resolves[] (data, not a verdict). Any other line carrying it
    # -- a grep verdict, a `[[ =~ ]]`, a case pattern -- is a private rule-1 implementation (r3 N-1).
    if grep -E 'FreeRDP/\(issues\|pull\)' "$REPO_ROOT/$f" | grep -vE '^[[:space:]]*#' | grep -vE 'grep -oE' | grep -q .; then one_impl=1; echo "  private rule-1 verdict in $f"; fi
done
if grep -qE 'FreeRDP/\(issues\|pull\)' "$REPO_ROOT/.github/workflows/tier1.yml"; then one_impl=1; echo "  private rule-1 grep in tier1.yml"; fi
if [ "$one_impl" -eq 0 ]; then pass=$((pass + 1)); echo "  ok   build-freerdp.sh, check-patch-queue.sh and gen-notices.sh all call crdp_patch_record_ok; no private copy of the grep"; else fail=$((fail + 1)); echo "  FAIL rule 1 has more than one implementation"; fi

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
