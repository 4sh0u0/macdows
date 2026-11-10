#!/usr/bin/env bash
# test-patch-queue.sh: offline pins for the patch-queue rules (ThirdParty/patches/README.md
# rules 1, 2 and 5) as enforced by Scripts/check-patch-queue.sh, and for lib.sh's
# crdp_patch_record_ok -- the ONE rule-1 implementation Scripts/build-freerdp.sh and Tier 1 both call.
#
# Why this exists (2026-09-07, ADR-0016 D1): the queue gained its first lab-only patch (a
# default-OFF CMake option with no upstream record) and rule 1 gained the owner-ruled
# exception for exactly that shape. Until now rule 1 lived as two copies of one grep (the
# build script and the workflow); an exception added to one copy and not the other would
# have let the build and CI disagree. The regex now lives in lib.sh, and this suite pins what
# it accepts and refuses on synthetic patch files -- no compiler, no network, no shared
# .build/ state. Case 7/8 need the pinned FreeRDP submodule checkout (`git apply --check`
# is rule 2 itself); Tier 1 checks out submodules for that reason.
#
# Rule 5 (2026-11-10, lane patch-pins) compares deps/freerdp.lock's .patches[].file names with the
# queue's *.patch file names. Its fixtures bring a synthetic lock of their own (--lock); every
# rule-1/2 fixture passes --no-lock, because the default lock describes the real queue, not the
# fixture's. Needs jq, like the check itself (preinstalled on Tier 1's ubuntu runner).
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
check 'empty queue passes and says so'                       0 'No patches'          --patch-dir "$TMP/empty" --no-apply --no-lock
mk "$TMP/link"   0001-link.patch   "$LINK"
check 'a GitHub issue/PR link in the header passes'          0 '1 patch(es) validated' --patch-dir "$TMP/link" --no-apply --no-lock
mkdir -p "$TMP/marker"
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; } > "$TMP/marker/0001-lab.patch"
check 'the lab-only marker (default OFF + ADR) with an added default-OFF option passes' 0 '1 patch(es) validated' --patch-dir "$TMP/marker" --no-apply --no-lock
mk "$TMP/none"   0001-none.patch   '# a patch with no record at all'
check 'neither record refuses, naming rule 1 and the file'   1 'rule 1'              --patch-dir "$TMP/none" --no-apply --no-lock
check 'the refusal names the offending file'                 1 '0001-none.patch'     --patch-dir "$TMP/none" --no-apply --no-lock
mk "$TMP/on"     0001-on.patch     '# Lab-only: default ON; ADR: docs/adr/0016-scaledmap-disable-configurable-d1.md'
check 'a lab-only marker that is not default OFF refuses'     1 'rule 1'              --patch-dir "$TMP/on" --no-apply --no-lock
mk "$TMP/noadr"  0001-noadr.patch  '# Lab-only: default OFF'
check 'a lab-only marker without an ADR refuses'              1 'rule 1'              --patch-dir "$TMP/noadr" --no-apply --no-lock
mkdir -p "$TMP/buried"
{ printf '%s\n' '# no record up here'; printf '%s\n' "$BOGUS_HUNK"; printf '%s\n' "+// see $LINK"; } > "$TMP/buried/0001-buried.patch"
check 'a link only inside a hunk (not the header) refuses'   1 'rule 1'              --patch-dir "$TMP/buried" --no-apply --no-lock
mk "$TMP/mixed"  0001-link.patch   "$LINK"
mk "$TMP/mixed"  0002-none.patch   '# nothing'
check 'one bad patch fails the whole queue'                  1 '0002-none.patch'     --patch-dir "$TMP/mixed" --no-apply --no-lock

echo "== rule 1, lab-only exception: the marker alone is a sentence; the patch must ADD a default-OFF option (gate r1 I-3)"
# The fixtures above carry only a bogus hunk. A real lab-only patch adds `option(<NAME> "..." OFF)`
# to a CMake file; a bug fix wearing the marker adds no such line and must be refused.
mkdir -p "$TMP/labopt" "$TMP/labon" "$TMP/labfix"
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; } > "$TMP/labopt/0001-lab.patch"
check 'marker + an added default-OFF option passes'          0 '1 patch(es) validated' --patch-dir "$TMP/labopt" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "${OPTION_HUNK/OFF)/ON)}"; } > "$TMP/labon/0001-lab.patch"
check 'marker + an added option defaulting ON refuses'       1 'rule 1'              --patch-dir "$TMP/labon" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "$BOGUS_HUNK"; } > "$TMP/labfix/0001-bugfix.patch"
check 'marker on a patch that adds no option (a bug fix in disguise) refuses' 1 'rule 1' --patch-dir "$TMP/labfix" --no-apply --no-lock

echo "== the added option must be a NEW option in a CMake file's hunk (gate r2 I-7)"
mkdir -p "$TMP/opthdr" "$TMP/optmd" "$TMP/optflip"
# (a) the option line sits in the HEADER (before any diff line), not in a hunk
{ printf '%s\n' "$MARKER"; printf '%s\n' '+option(MACDOWS_LAB_FIXTURE "smuggled into the header" OFF)'; printf '%s\n' "$BOGUS_HUNK"; } > "$TMP/opthdr/0001-lab.patch"
check 'an option line in the header (not a hunk) does not count'   1 'rule 1' --patch-dir "$TMP/opthdr" --no-apply --no-lock
# (b) the option line is added to a non-CMake file
MD_HUNK='diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1,1 +1,2 @@
 # FreeRDP
+option(MACDOWS_LAB_FIXTURE "not a CMake file" OFF)'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$MD_HUNK"; } > "$TMP/optmd/0001-lab.patch"
check 'an option line added to a non-CMake file does not count'     1 'rule 1' --patch-dir "$TMP/optmd" --no-apply --no-lock
# (c) an existing upstream option flipped ON -> OFF is a behaviour change, not a new knob
FLIP_HUNK='diff --git a/cmake/ConfigOptions.cmake b/cmake/ConfigOptions.cmake
--- a/cmake/ConfigOptions.cmake
+++ b/cmake/ConfigOptions.cmake
@@ -1,1 +1,1 @@
-option(WITH_SWSCALE "Use SWScale image library for screen resizing" ON)
+option(WITH_SWSCALE "Use SWScale image library for screen resizing" OFF)'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$FLIP_HUNK"; } > "$TMP/optflip/0001-lab.patch"
check 'flipping an existing option ON->OFF is not an added knob'   1 'rule 1' --patch-dir "$TMP/optflip" --no-apply --no-lock

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
check 'a diff --git line that disagrees with --- / +++ refuses'      1 'rule 1' --patch-dir "$TMP/lie" --no-apply --no-lock
# (b) CRLF line endings must not turn a valid lab patch into a refusal (r3 N-2)
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; } | sed 's/$/\r/' > "$TMP/crlf/0001-lab.patch"
check 'a CRLF-terminated lab patch with an added default-OFF option passes' 0 '1 patch(es) validated' --patch-dir "$TMP/crlf" --no-apply --no-lock
# (c) CMake allows whitespace after the opening parenthesis (r3 N-3)
{ printf '%s\n' "$MARKER"; printf '%s\n' "${OPTION_HUNK/option(MACDOWS_LAB_FIXTURE/option( MACDOWS_LAB_FIXTURE}"; } > "$TMP/spaced/0001-lab.patch"
check '"option( NAME ..." with a space after the parenthesis passes'  0 '1 patch(es) validated' --patch-dir "$TMP/spaced" --no-apply --no-lock
# (d) a removed option line in a DIFFERENT file: not a flip of the new knob (r3 N-4), but under the
#     shape rules below it is an unrelated removal with no guarded re-add, so the patch is refused.
OTHER_REMOVE='diff --git a/client/CMakeLists.txt b/client/CMakeLists.txt
--- a/client/CMakeLists.txt
+++ b/client/CMakeLists.txt
@@ -1,2 +1,1 @@
 project(client)
-option(MACDOWS_LAB_FIXTURE "an unrelated line in another file" ON)'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$OTHER_REMOVE"; } > "$TMP/xfile/0001-lab.patch"
check 'a same-named removal in another file is an unrelated change and refuses' 1 'rule 1' --patch-dir "$TMP/xfile" --no-apply --no-lock

echo "== the lab-only SHAPE: every other hunk may only insert the knob's guard or comments (gate r4 B-6)"
# The real lab patch's shape: a source hunk that re-writes an #if line with one more !defined(<NAME>)
# term and a one-line comment. Every added line names the knob or is a comment; every removed line
# is re-added in the same hunk carrying the knob's name.
GUARD_HUNK='diff --git a/channels/rdpgfx/client/rdpgfx_main.c b/channels/rdpgfx/client/rdpgfx_main.c
--- a/channels/rdpgfx/client/rdpgfx_main.c
+++ b/channels/rdpgfx/client/rdpgfx_main.c
@@ -1,3 +1,4 @@
 	capsSet->flags = caps10Flags;
-#if !defined(WITH_CAIRO) && !defined(WITH_SWSCALE)
+/* Macdows lab patch: the lab-only option omits the flag. */
+#if !defined(WITH_CAIRO) && !defined(WITH_SWSCALE) && !defined(MACDOWS_LAB_FIXTURE)
 	capsSet->flags |= RDPGFX_CAPS_FLAG_SCALEDMAP_DISABLE;'
UNRELATED_HUNK='diff --git a/libfreerdp/core/rdp.c b/libfreerdp/core/rdp.c
--- a/libfreerdp/core/rdp.c
+++ b/libfreerdp/core/rdp.c
@@ -1,2 +1,2 @@
 	int x;
-	return TRUE;
+	return FALSE;'
BARE_UNRELATED='--- a/libfreerdp/core/rdp.c
+++ b/libfreerdp/core/rdp.c
@@ -1,2 +1,2 @@
 	int x;
-	return TRUE;
+	return FALSE;'
RENAME_HDR='diff --git a/libfreerdp/core/rdp.c b/libfreerdp/core/rdp2.c
similarity index 100%
rename from libfreerdp/core/rdp.c
rename to libfreerdp/core/rdp2.c'
NEWFILE_HUNK='diff --git a/libfreerdp/core/lab.c b/libfreerdp/core/lab.c
new file mode 100644
--- /dev/null
+++ b/libfreerdp/core/lab.c
@@ -0,0 +1,1 @@
+/* MACDOWS_LAB_FIXTURE */'
mkdir -p "$TMP/shape-ok" "$TMP/shape-unrel" "$TMP/shape-line" "$TMP/shape-rm" "$TMP/shape-bare" "$TMP/shape-rename" "$TMP/shape-new" "$TMP/shape-prefix"
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$GUARD_HUNK"; } > "$TMP/shape-ok/0001-lab.patch"
check 'option hunk + a guard-insertion hunk (comment + re-written #if naming the knob) passes' 0 '1 patch(es) validated' --patch-dir "$TMP/shape-ok" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$UNRELATED_HUNK"; } > "$TMP/shape-unrel/0001-lab.patch"
check 'option hunk + an honest unrelated hunk in another file refuses (B-6)'   1 'rule 1' --patch-dir "$TMP/shape-unrel" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "${GUARD_HUNK/+\/\* Macdows lab patch: the lab-only option omits the flag. \*\//+	settings->foo = 1;}"; } > "$TMP/shape-line/0001-lab.patch"
check 'an added source line that neither names the knob nor is a comment refuses'  1 'rule 1' --patch-dir "$TMP/shape-line" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "${GUARD_HUNK/+#if !defined(WITH_CAIRO) && !defined(WITH_SWSCALE) && !defined(MACDOWS_LAB_FIXTURE)/+#if 0}"; } > "$TMP/shape-rm/0001-lab.patch"
check 'a removed line not re-added with the knob name in the same hunk refuses'    1 'rule 1' --patch-dir "$TMP/shape-rm" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$BARE_UNRELATED"; } > "$TMP/shape-bare/0001-lab.patch"
check 'a bare --- / +++ hunk (no diff --git line) is still judged, and refuses here' 1 'rule 1' --patch-dir "$TMP/shape-bare" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$RENAME_HDR"; } > "$TMP/shape-rename/0001-lab.patch"
check 'a rename header refuses (lab patches modify files in place only)'           1 'rule 1' --patch-dir "$TMP/shape-rename" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$NEWFILE_HUNK"; } > "$TMP/shape-new/0001-lab.patch"
check 'a new-file hunk refuses (even one naming the knob)'                        1 'rule 1' --patch-dir "$TMP/shape-new" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "${OPTION_HUNK//MACDOWS_LAB_FIXTURE/LAB_FIXTURE}"; } > "$TMP/shape-prefix/0001-lab.patch"
check 'a knob not named MACDOWS_LAB_* refuses (the prefix is what the line rule keys on)' 1 'rule 1' --patch-dir "$TMP/shape-prefix" --no-apply --no-lock
mkdir -p "$TMP/shape-two"
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "${OPTION_HUNK//MACDOWS_LAB_FIXTURE/MACDOWS_LAB_SECOND}"; } > "$TMP/shape-two/0001-lab.patch"
check 'two new knobs in one patch refuses (exactly one knob per lab patch)'         1 'rule 1' --patch-dir "$TMP/shape-two" --no-apply --no-lock

echo "== rules 2/3 are a GRAMMAR, not a token test (gate r5 B-8); blocks without text hunks refuse (B-7)"
CMAKEDEFINE_HUNK='diff --git a/include/config/config.h.in b/include/config/config.h.in
--- a/include/config/config.h.in
+++ b/include/config/config.h.in
@@ -1,2 +1,4 @@
 #cmakedefine WITH_SWSCALE
+/* Macdows lab patch: lab-only, default OFF */
+#cmakedefine MACDOWS_LAB_FIXTURE
 #cmakedefine WITH_SWSCALE_LOADING'
mkdir -p "$TMP/g-ok" "$TMP/g-if" "$TMP/g-append" "$TMP/g-set" "$TMP/g-bracket" "$TMP/g-tail" "$TMP/g-mode" "$TMP/g-binary"
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$GUARD_HUNK"; printf '%s\n' "$CMAKEDEFINE_HUNK"; } > "$TMP/g-ok/0001-lab.patch"
check 'the real shape -- option, #cmakedefine KNOB, comments, #if lines re-added with && !defined(KNOB) -- passes' 0 '1 patch(es) validated' --patch-dir "$TMP/g-ok" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "${GUARD_HUNK/+\/\* Macdows lab patch: the lab-only option omits the flag. \*\//+	if (MACDOWS_LAB_FIXTURE) system(\"x\");}"; } > "$TMP/g-if/0001-lab.patch"
check 'a new runtime line that merely names the knob refuses (B-8)'                1 'rule 1' --patch-dir "$TMP/g-if" --no-apply --no-lock
APPEND_HUNK='diff --git a/libfreerdp/core/rdp.c b/libfreerdp/core/rdp.c
--- a/libfreerdp/core/rdp.c
+++ b/libfreerdp/core/rdp.c
@@ -1,2 +1,2 @@
 	int x;
-	foo(a);
+	foo(a); bar(); /* MACDOWS_LAB_FIXTURE */'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$APPEND_HUNK"; } > "$TMP/g-append/0001-lab.patch"
check 'a removed line re-added with code appended (knob only in a comment) refuses (B-8)' 1 'rule 1' --patch-dir "$TMP/g-append" --no-apply --no-lock
SET_HUNK='diff --git a/CMakeLists.txt b/CMakeLists.txt
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -1,1 +1,2 @@
 project(FreeRDP)
+set(MACDOWS_LAB_FIXTURE ON CACHE BOOL "override" FORCE)'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$SET_HUNK"; } > "$TMP/g-set/0001-lab.patch"
check 'a set(KNOB ON ... FORCE) line refuses (it would defeat "default OFF")'       1 'rule 1' --patch-dir "$TMP/g-set" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "${OPTION_HUNK/@@ -1,1 +1,2 @@/@@ -1,1 +1,3 @@}" | sed 's|^+option(MACDOWS_LAB_FIXTURE|+#[[ bracket comment start\n+option(MACDOWS_LAB_FIXTURE|'; } > "$TMP/g-bracket/0001-lab.patch"
check 'a CMake bracket-comment opener as an added line refuses'                    1 'rule 1' --patch-dir "$TMP/g-bracket" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "${GUARD_HUNK/+\/\* Macdows lab patch: the lab-only option omits the flag. \*\//+\/* MACDOWS_LAB_FIXTURE *\/ system(\"x\");}"; } > "$TMP/g-tail/0001-lab.patch"
check 'a comment followed by code on the same line refuses'                        1 'rule 1' --patch-dir "$TMP/g-tail" --no-apply --no-lock
MODE_BLOCK='diff --git a/scripts/run.sh b/scripts/run.sh
old mode 100644
new mode 100755'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$MODE_BLOCK"; } > "$TMP/g-mode/0001-lab.patch"
check 'a mode-only block (no text hunk) refuses (B-7)'                             1 'rule 1' --patch-dir "$TMP/g-mode" --no-apply --no-lock
BINARY_BLOCK='diff --git a/resources/icon.png b/resources/icon.png
index 1111111..2222222 100644
Binary files a/resources/icon.png and b/resources/icon.png differ'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$BINARY_BLOCK"; } > "$TMP/g-binary/0001-lab.patch"
check 'a binary block refuses (B-7)'                                                1 'rule 1' --patch-dir "$TMP/g-binary" --no-apply --no-lock
mkdir -p "$TMP/g-tail2" "$TMP/g-lone"
# rule 3's tail is exactly " && !defined(KNOB)": a #if re-added with any other tail -- even one that
# names the knob and keeps the removed text as its prefix -- is a changed condition and refuses.
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "${GUARD_HUNK/&& !defined(MACDOWS_LAB_FIXTURE)/|| defined(MACDOWS_LAB_FIXTURE)}"; } > "$TMP/g-tail2/0001-lab.patch"
check 'a #if re-added with a different tail (|| defined(KNOB)) refuses'               1 'rule 1' --patch-dir "$TMP/g-tail2" --no-apply --no-lock
# a guard-shaped added line with no removed twin is a NEW condition, not a guard appended: refused.
LONE_HUNK='diff --git a/libfreerdp/core/rdp.c b/libfreerdp/core/rdp.c
--- a/libfreerdp/core/rdp.c
+++ b/libfreerdp/core/rdp.c
@@ -1,2 +1,3 @@
 	int x;
+#if 0 && !defined(MACDOWS_LAB_FIXTURE)
 	int y;'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$LONE_HUNK"; } > "$TMP/g-lone/0001-lab.patch"
check 'a guard-shaped added line with no removed twin refuses (bijection)'            1 'rule 1' --patch-dir "$TMP/g-lone" --no-apply --no-lock

echo "== a CMake '#' line is not provably a comment (it may sit inside a multi-line string), so none is admitted (gate r6 B-9)"
mkdir -p "$TMP/g-hash" "$TMP/g-cmakedefine-c"
{ printf '%s\n' "$MARKER"; printf '%s\n' "${OPTION_HUNK/@@ -1,1 +1,2 @@/@@ -1,1 +1,3 @@}" | sed 's|^+option(MACDOWS_LAB_FIXTURE|+# a comment-looking line in a CMake file\n+option(MACDOWS_LAB_FIXTURE|'; } > "$TMP/g-hash/0001-lab.patch"
check 'an added "#" line in a CMake file refuses (could be inside a quoted argument)'   1 'rule 1' --patch-dir "$TMP/g-hash" --no-apply --no-lock
CMAKEDEFINE_C_HUNK='diff --git a/libfreerdp/core/rdp.c b/libfreerdp/core/rdp.c
--- a/libfreerdp/core/rdp.c
+++ b/libfreerdp/core/rdp.c
@@ -1,1 +1,2 @@
 	int x;
+#cmakedefine MACDOWS_LAB_FIXTURE'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$CMAKEDEFINE_C_HUNK"; } > "$TMP/g-cmakedefine-c/0001-lab.patch"
check 'a #cmakedefine KNOB line outside a *.in template refuses'                        1 'rule 1' --patch-dir "$TMP/g-cmakedefine-c" --no-apply --no-lock

echo "== a comment line must not splice: no trailing backslash, no trigraph (gate r7 B-10)"
mkdir -p "$TMP/g-splice" "$TMP/g-splice2" "$TMP/g-trigraph" "$TMP/g-slashslash"
SPLICE_HUNK='diff --git a/channels/rdpgfx/client/rdpgfx_main.c b/channels/rdpgfx/client/rdpgfx_main.c
--- a/channels/rdpgfx/client/rdpgfx_main.c
+++ b/channels/rdpgfx/client/rdpgfx_main.c
@@ -1,2 +1,3 @@
 #include <freerdp/config.h>
+// Macdows lab patch: cosmetic note \
 #include <winpr/assert.h>'
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "$SPLICE_HUNK"; } > "$TMP/g-splice/0001-lab.patch"
check 'a // comment ending in a backslash (splices the next line) refuses (B-10)'      1 'rule 1' --patch-dir "$TMP/g-splice" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "${SPLICE_HUNK/+\/\/ Macdows lab patch: cosmetic note \\/+\/* Macdows lab patch *\/ \\}"; } > "$TMP/g-splice2/0001-lab.patch"
check 'a /* */ comment followed by a backslash refuses'                                 1 'rule 1' --patch-dir "$TMP/g-splice2" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "${SPLICE_HUNK/+\/\/ Macdows lab patch: cosmetic note \\/+\/\/ Macdows lab patch: note ??\/}"; } > "$TMP/g-trigraph/0001-lab.patch"
check 'a // comment ending in the ??/ trigraph (a backslash in ISO mode) refuses'       1 'rule 1' --patch-dir "$TMP/g-trigraph" --no-apply --no-lock
{ printf '%s\n' "$MARKER"; printf '%s\n' "$OPTION_HUNK"; printf '%s\n' "${SPLICE_HUNK/+\/\/ Macdows lab patch: cosmetic note \\/+\/\/ Macdows lab patch: a plain note}"; } > "$TMP/g-slashslash/0001-lab.patch"
check 'a plain // comment line passes'                                                   0 '1 patch(es) validated' --patch-dir "$TMP/g-slashslash" --no-apply --no-lock

echo "== header boundary: only a real diff line ends the header (gate r1 m-3)"
mkdir -p "$TMP/dashes"
{ printf '%s\n' '# a header comment'; printf '%s\n' '--- notes: this line starts with three dashes but is prose'; printf '%s\n' "$LINK"; printf '%s\n' "$BOGUS_HUNK"; } > "$TMP/dashes/0001-dashes.patch"
check 'a header line starting with "--- " (prose) does not cut the header' 0 '1 patch(es) validated' --patch-dir "$TMP/dashes" --no-apply --no-lock

echo "== rule 5: deps/freerdp.lock .patches names exactly the queue's *.patch files, both directions (lane rail-clientstatus M3 / gate r1 m-6)"
# Each fixture is a queue directory plus a synthetic lock of its own (--lock). The patches carry a
# valid rule-1 header and run with --no-apply, so a refusal here can only be rule 5's.
lock_json() { # lock_json <file> <names...>: a lock whose .patches lists exactly <names>, in order
    local file="$1" sep="" n; shift
    {
        printf '{\n  "patches": ['
        for n in "$@"; do printf '%s\n    {"file": "%s", "upstream": "fixture"}' "$sep" "$n"; sep=","; done
        printf '\n  ]\n}\n'
    } > "$file"
}
R5="$TMP/r5"
mk "$R5/same" 0003-x.patch "$LINK"; lock_json "$R5/same.lock" 0003-x.patch
check 'rule 5: the lock and the directory name the same patch: passes'      0 'Lock inventory matches the queue: 1 patch(es)' --patch-dir "$R5/same" --lock "$R5/same.lock" --no-apply
mkdir -p "$R5/empty"; lock_json "$R5/empty.lock"
check 'rule 5: an empty directory and an empty .patches pass'                0 'Lock inventory matches the queue: 0 patch(es)' --patch-dir "$R5/empty" --lock "$R5/empty.lock" --no-apply
check 'rule 5: ... and the empty queue still ends as "No patches"'          0 'No patches'                  --patch-dir "$R5/empty" --lock "$R5/empty.lock" --no-apply
mk "$R5/two" 0003-a.patch "$LINK"; mk "$R5/two" 0004-b.patch "$LINK"; lock_json "$R5/two.lock" 0004-b.patch 0003-a.patch
check 'rule 5: two patches listed in the other order pass (a set, not a sequence)' 0 '2 patch(es) validated'  --patch-dir "$R5/two" --lock "$R5/two.lock" --no-apply
mk "$R5/notes" 0003-x.patch "$LINK"; printf 'notes\n' > "$R5/notes/README.md"; lock_json "$R5/notes.lock" 0003-x.patch
check 'rule 5: a non-*.patch file in the directory is not part of the queue' 0 'Lock inventory matches the queue: 1 patch(es)' --patch-dir "$R5/notes" --lock "$R5/notes.lock" --no-apply
printf '{"patches": [], "retired_patches": [{"file": "0003-x.patch", "retired_on": "fixture"}]}\n' > "$R5/retired.lock"
check 'rule 5: a retired patch (file deleted, entry moved to .retired_patches) passes: .retired_patches is not compared' 0 'Lock inventory matches the queue: 0 patch(es)' --patch-dir "$R5/empty" --lock "$R5/retired.lock" --no-apply
# The three shapes of disagreement.
mkdir -p "$R5/deleted"; lock_json "$R5/deleted.lock" 0003-x.patch
check 'rule 5: a patch file deleted with its lock entry left behind refuses (m-6: this was "No patches", green)' 1 'listed in the lock with no file in the queue directory: 0003-x.patch;' --patch-dir "$R5/deleted" --lock "$R5/deleted.lock" --no-apply
mk "$R5/unlisted" 0003-x.patch "$LINK"; lock_json "$R5/unlisted.lock"
check 'rule 5: .patches emptied with the file still in the queue refuses (M3)' 1 'in the queue directory but not listed in the lock: 0003-x.patch.' --patch-dir "$R5/unlisted" --lock "$R5/unlisted.lock" --no-apply
mk "$R5/renamed" 0003-b.patch "$LINK"; lock_json "$R5/renamed.lock" 0003-a.patch
check 'rule 5: a renamed patch refuses, naming the lock-side name'          1 'listed in the lock with no file in the queue directory: 0003-a.patch;' --patch-dir "$R5/renamed" --lock "$R5/renamed.lock" --no-apply
check 'rule 5: ... and naming the directory-side name'                      1 'in the queue directory but not listed in the lock: 0003-b.patch.' --patch-dir "$R5/renamed" --lock "$R5/renamed.lock" --no-apply
mk "$R5/case" 0003-X.patch "$LINK"; lock_json "$R5/case.lock" 0003-x.patch
check 'rule 5: names differing only in case refuse (the comparison is case-sensitive)' 1 'listed in the lock with no file in the queue directory: 0003-x.patch;' --patch-dir "$R5/case" --lock "$R5/case.lock" --no-apply
# A lock that does not state its inventory refuses: "lists nothing" must be written as [].
printf '{"tag": "3.32.1"}\n' > "$R5/nolist.lock"
check 'rule 5: a lock with no .patches array refuses, even next to an empty directory' 1 'cannot read a .patches array' --patch-dir "$R5/empty" --lock "$R5/nolist.lock" --no-apply
printf '{"patches": {"file": "0003-x.patch"}}\n' > "$R5/object.lock"
check 'rule 5: .patches as an object, not an array, refuses'                1 'cannot read a .patches array' --patch-dir "$R5/same" --lock "$R5/object.lock" --no-apply
printf '{"patches": [{"upstream": "fixture"}]}\n' > "$R5/nofile.lock"
check 'rule 5: a .patches entry without .file refuses'                      1 'cannot read a .patches array' --patch-dir "$R5/empty" --lock "$R5/nofile.lock" --no-apply
printf '{"patches": [{"file": "ThirdParty/patches/0003-x.patch"}]}\n' > "$R5/path.lock"
check 'rule 5: a .file naming a path, not a bare file name, refuses'        1 'cannot read a .patches array' --patch-dir "$R5/same" --lock "$R5/path.lock" --no-apply
mk "$R5/nl" 0003-a.patch "$LINK"; mk "$R5/nl" 0004-b.patch "$LINK"
printf '{"patches": [{"file": "0003-a.patch\\n0004-b.patch"}]}\n' > "$R5/nl.lock"
check 'rule 5: a .file with an embedded newline refuses (it would read as two names)' 1 'cannot read a .patches array' --patch-dir "$R5/nl" --lock "$R5/nl.lock" --no-apply
lock_json "$R5/twice.lock" 0003-x.patch 0003-x.patch
check 'rule 5: a name listed twice refuses'                                 1 'lists 0003-x.patch twice'    --patch-dir "$R5/same" --lock "$R5/twice.lock" --no-apply
lock_json "$R5/aba.lock" 0003-a.patch 0004-b.patch 0003-a.patch
check 'rule 5: a name listed twice with another between them refuses'      1 'lists 0003-a.patch twice'    --patch-dir "$R5/two" --lock "$R5/aba.lock" --no-apply
printf 'not json\n' > "$R5/garbage.lock"
check 'rule 5: a lock jq cannot parse refuses'                              1 'cannot read a .patches array' --patch-dir "$R5/empty" --lock "$R5/garbage.lock" --no-apply
check 'rule 5: a missing lock file refuses'                                 1 'no lock file at'             --patch-dir "$R5/empty" --lock "$R5/absent.lock" --no-apply
# Wiring: the default lock, the opt-out, and rule 5 passing never standing in for rule 1.
mk "$R5/nolockarg" 0001-link.patch "$LINK"
check 'rule 5: --lock with no value is an argument error'                   1 '--lock needs a file'         --patch-dir "$R5/nolockarg" --no-apply --lock
check 'rule 5: a --patch-dir with no --lock is compared with the real deps/freerdp.lock (refuses here)' 1 'rule 5' --patch-dir "$R5/nolockarg" --no-apply
check 'rule 5: --no-lock skips the rule and says so'                         0 'Rule 5 (lock inventory) skipped' --patch-dir "$R5/nolockarg" --no-apply --no-lock
mk "$R5/r1" 0003-none.patch '# a patch with no record at all'; lock_json "$R5/r1.lock" 0003-none.patch
check 'rule 5 passing does not stand in for rule 1'                         1 'rule 1'                      --patch-dir "$R5/r1" --lock "$R5/r1.lock" --no-apply
check 'the real deps/freerdp.lock and ThirdParty/patches agree (rule 5 on the real tree, no checkout needed)' 0 'Lock inventory matches the queue' --no-apply

echo "== rule 2: git apply --check against the pinned checkout"
if [ -e "$FREERDP_SRC/.git" ]; then
    check 'a header-valid patch that does not apply refuses (rule 2)' 1 'apply --check' --patch-dir "$TMP/marker" --freerdp-src "$FREERDP_SRC" --no-lock
    check 'the real queue passes rule 1 and rule 2 against the pinned checkout' 0 '' --freerdp-src "$FREERDP_SRC"
    # gate r1 m-4: a RELATIVE --patch-dir must be normalised before `git -C <submodule> apply --check`
    # resolves it -- otherwise git looks for the patch inside the submodule (the documented pitfall).
    # Relative names are exercised from inside $TMP (never from the repo, never under .build/), with a
    # SYNTHETIC patch that applies to the pinned checkout -- built from the real first two lines of its
    # README.md so the case never depends on the live queue being non-empty (retire-gate m-1).
    mkdir -p "$TMP/rel/queue"
    {
        printf '%s\n' "$LINK"
        printf '%s\n' 'diff --git a/README.md b/README.md' '--- a/README.md' '+++ b/README.md' '@@ -1,2 +1,3 @@'
        sed -n '1p' "$FREERDP_SRC/README.md" | sed 's/^/ /'
        printf '%s\n' '+<!-- test-patch-queue fixture line (never applied; --check only) -->'
        sed -n '2p' "$FREERDP_SRC/README.md" | sed 's/^/ /'
    } > "$TMP/rel/queue/0001-synthetic.patch"
    pushd "$TMP/rel" >/dev/null
    check 'a relative --patch-dir is normalised before git apply --check' 0 'validated' --patch-dir queue --freerdp-src "$FREERDP_SRC" --no-lock
    popd >/dev/null
else
    echo "  FAIL rule 2 cases need the ThirdParty/FreeRDP submodule checkout (git submodule update --init)"; fail=$((fail + 2))
fi

echo "== one implementation: every enforcement point calls lib.sh, none carries its own grep (gate r1 B-1)"
# Known limit (gate r4 N-1): this pin recognises the link PATTERN on a line; a deliberately
# obfuscated private verdict (a case-glob, a pattern split across variables) is a review matter.
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

echo "== Tier 1 runs check-patch-queue.sh bare, so rule 5 cannot be switched off or aimed elsewhere there (gate r1 m-3)"
# The pinned line is the call in tier1.yml's "Patch queue validation" step. It is located by
# content, not by line number: every line of .github/workflows/tier1.yml naming
# check-patch-queue.sh, minus comment lines (first non-blank character '#'). Exactly one may remain
# and it must be the whole command `./Scripts/check-patch-queue.sh` with no argument -- no
# --no-lock, --lock or --patch-dir, nor anything else. A second call, a call through a variable or
# a wrapper, or a `run: ./Scripts/check-patch-queue.sh` one-liner fail this too: re-pin on purpose.
# grep -E with POSIX classes only, so GNU grep (ubuntu) and BSD grep (macOS) agree.
cpq_lines="$(grep -n 'check-patch-queue\.sh' "$REPO_ROOT/.github/workflows/tier1.yml" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
cpq_count="$(printf '%s\n' "$cpq_lines" | grep -c . || true)"
if [ "$cpq_count" -eq 1 ] && printf '%s\n' "$cpq_lines" | grep -qE '^[0-9]+:[[:space:]]*\./Scripts/check-patch-queue\.sh[[:space:]]*$'; then
    pass=$((pass + 1)); echo "  ok   tier1.yml calls ./Scripts/check-patch-queue.sh exactly once, with no argument (line ${cpq_lines%%:*})"
else
    fail=$((fail + 1)); echo "  FAIL tier1.yml must call ./Scripts/check-patch-queue.sh exactly once with no argument; non-comment lines naming it: ${cpq_lines:-<none>}"
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
