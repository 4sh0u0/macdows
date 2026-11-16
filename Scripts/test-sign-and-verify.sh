#!/usr/bin/env bash
# test-sign-and-verify.sh: behaviour and source pins for Scripts/sign-and-verify.sh, the release
# gate that THIRD_PARTY_NOTICES.md's checklist requires to exit 0.
#
# Why this exists (2026-11-16 release rehearsal): under the macOS system /bin/bash (3.2.57),
# `--release --offline` on a bundle WITHOUT entitlements (every Release build) died on
# `"${ENTITLEMENTS_ARGS[@]}"` ("unbound variable": bash < 4.4 treats an empty array as unset under
# `set -u`), and the EXIT trap's `local status=$?` then read 0, so the gate exited 0 with the
# embedded dylibs re-signed but the bundle not: a false green. Debug bundles carry get-task-allow,
# the array is non-empty there, and the bug never showed. This suite pins both halves, on both
# interpreters (`/bin/bash <script>` and the shebang's `env bash`).
#
# What runs (macOS only; elsewhere one SKIP line and exit 0):
#   - a minimal .app is built in a temp dir: a tiny sleeping executable plus an embedded dylib (so
#     the inside-out dylib signing has something to do). Only the fixture that carries an
#     entitlement (disable-library-validation) has its executable LINKED against that dylib, so the
#     DYLD load check really loads it; under ad-hoc signing library validation refuses an ad-hoc
#     dylib otherwise, and the entitlement-free fixture just embeds it;
#   - matrix: {/bin/bash, shebang} x {no entitlements, one harmless entitlement}: exit 0, the
#     "sign-and-verify.sh: OK" line, codesign --verify --deep --strict afterwards, and proof that
#     the bundle AND its embedded dylib really were re-signed (both start ad-hoc signed WITHOUT the
#     hardened-runtime flag);
#   - --release: no entitlements -> 0; get-task-allow -> non-zero, naming the entitlement;
#   - fail-closed: an unknown signing identity -> non-zero; a variable made unbound half-way through
#     (injected into a staged copy, once after the dylib step and once after the DYLD load check)
#     -> non-zero, no OK line, the DYLD-check directory preserved (the test then deletes it); the
#     status of a failing command is kept as is (a plutil stand-in exiting 3 -> exit 3);
#   - source pins: no bare "${NAME[@]}" expansion; the trap's success-sentinel shape, closed: the
#     sentinel name occurs exactly three times in the code.
# Only the ad-hoc identity and --offline are used: no network, no notarytool, no real certificate,
# and the built bundle is a throwaway (Macdows.app is never launched).
#
# Usage: Scripts/test-sign-and-verify.sh
#   SIGN_AND_VERIFY_UNDER_TEST=<path>  test that copy of sign-and-verify.sh instead of the
#                                      repository's (a negative control / mutant). It is staged next
#                                      to a copy of lib.sh, so it may live anywhere.
# Exit: 0 when every case passes, 1 otherwise. Last line: "test-sign-and-verify: PASS|FAIL ...".
# CI judges by that last line, not by the exit status alone. This script has an EXIT trap itself, so
# it fails closed the same way as the script it tests: under bash 3.2 a death on an unbound
# variable would read $? as 0 in the trap, hence the completion sentinel below.
# Cleanup in the per-user temp directory (mktemp -t on macOS uses DARWIN_USER_TEMP_DIR and ignores
# TMPDIR): the script under test leaves behind a 0-byte macdows-entitlements.* / macdows-gta-check.*
# base file per run and, on a red run, its macdows-dyld-check.* directory. This suite removes only
# what appeared during its own run and is provably a leftover of the fixture: those 0-byte base
# files and the DYLD-check directories that contain SvFixture.app. The .plist files are left alone
# (ownership cannot be proven; a concurrent real signing run may be using such a name).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_IN="${SIGN_AND_VERIFY_UNDER_TEST:-$SCRIPT_DIR/sign-and-verify.sh}"

if [ "$(uname -s)" != "Darwin" ]; then
	echo "test-sign-and-verify: SKIP not macOS (needs codesign, otool, plutil and PlistBuddy)"
	exit 0
fi
[ -f "$TARGET_IN" ] || {
	echo "test-sign-and-verify: ERROR no such script: $TARGET_IN"
	exit 2
}
for c in cc codesign otool plutil xcrun /usr/libexec/PlistBuddy; do
	command -v "$c" >/dev/null 2>&1 || {
		echo "test-sign-and-verify: ERROR required command not found: $c"
		exit 2
	}
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sign-and-verify-test.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
USER_TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
USER_TMP="${USER_TMP%/}"
USER_TMP_BEFORE=""
if [ -n "$USER_TMP" ] && [ -d "$USER_TMP" ]; then
	USER_TMP_BEFORE="$(ls -1A "$USER_TMP")"
fi
printf '%s\n' "$USER_TMP_BEFORE" >"$TMP/user-tmp-before.lst"

# remove_kept_dyld_dir <path>: remove a DYLD-check directory that the script under test reported as
# preserved. The path is read from that script's output, so it is removed only when it is a direct
# child of the per-user temp directory, is named macdows-dyld-check.*, and holds this suite's
# fixture; anything else is left alone (cleanup_user_tmp may still collect it at exit).
USER_TMP_REAL=""
if [ -n "$USER_TMP" ] && [ -d "$USER_TMP" ]; then
	USER_TMP_REAL="$(cd "$USER_TMP" && pwd -P)"
fi
remove_kept_dyld_dir() {
	local kept="$1" leaf
	[ -n "$USER_TMP_REAL" ] || return 0
	case "$kept" in
	"$USER_TMP_REAL"/*) ;;
	*) return 0 ;;
	esac
	leaf="${kept#"$USER_TMP_REAL"/}"
	case "$leaf" in
	*/* | .*) return 0 ;;
	macdows-dyld-check.*) ;;
	*) return 0 ;;
	esac
	if [ -d "$kept/SvFixture.app" ]; then rm -rf "$kept"; fi
}

# Remove what this run added to the per-user temp directory and can prove to be its own leftovers.
cleanup_user_tmp() {
	local path name
	[ -n "$USER_TMP" ] && [ -d "$USER_TMP" ] || return 0
	for path in "$USER_TMP"/macdows-*; do
		[ -e "$path" ] || continue
		name="${path##*/}"
		if grep -qxF -- "$name" "$TMP/user-tmp-before.lst"; then continue; fi
		case "$name" in
		*.plist) ;;
		macdows-dyld-check.*)
			if [ -d "$path/SvFixture.app" ]; then rm -rf "$path"; fi
			;;
		macdows-entitlements.* | macdows-gta-check.*)
			if [ -f "$path" ] && [ ! -s "$path" ]; then rm -f "$path"; fi
			;;
		*) ;;
		esac
	done
}

# Fail closed: exiting with status 0 before the sentinel is set is turned into a failure.
TEST_COMPLETED=0
cleanup_on_exit() {
	local status=$?
	if [ "$status" -eq 0 ] && [ "$TEST_COMPLETED" -ne 1 ]; then
		status=1
		echo "test-sign-and-verify: ERROR exiting with status 0 before the suite completed (bash 3.2 after an unbound variable, or a signal); failing closed"
	fi
	cleanup_user_tmp
	rm -rf "$TMP"
	exit "$status"
}
trap cleanup_on_exit EXIT

# The script sources lib.sh from its own directory, so stage both side by side.
STAGE="$TMP/stage"
mkdir -p "$STAGE"
cp "$TARGET_IN" "$STAGE/sign-and-verify.sh"
cp "$SCRIPT_DIR/lib.sh" "$STAGE/lib.sh"
chmod +x "$STAGE/sign-and-verify.sh"
SUT="$STAGE/sign-and-verify.sh"

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	echo "  ok   $1"
}
bad() {
	fail=$((fail + 1))
	echo "  FAIL $1"
}

# --- fixture: a minimal app bundle ---------------------------------------------------------
cat >"$TMP/foo.c" <<'EOF'
int sv_fixture_value(void) { return 42; }
EOF
cat >"$TMP/main.c" <<'EOF'
#include <unistd.h>
int sv_fixture_value(void);
int main(void) { sleep(30); return sv_fixture_value() == 42 ? 0 : 1; }
EOF
cat >"$TMP/ent-harmless.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
</plist>
EOF
cat >"$TMP/ent-gta.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.get-task-allow</key>
	<true/>
</dict>
</plist>
EOF

cc -dynamiclib -o "$TMP/libsvfixture.dylib" -install_name @rpath/libsvfixture.dylib "$TMP/foo.c" >/dev/null 2>&1 \
	|| {
		echo "test-sign-and-verify: ERROR could not compile the fixture dylib"
		exit 2
	}
cc -o "$TMP/SvFixture-linked" "$TMP/main.c" -L"$TMP" -lsvfixture -Wl,-rpath,@executable_path/../Frameworks >/dev/null 2>&1 \
	|| {
		echo "test-sign-and-verify: ERROR could not compile the fixture executable"
		exit 2
	}
cat >"$TMP/main-plain.c" <<'EOF'
#include <unistd.h>
int main(void) { sleep(30); return 0; }
EOF
cc -o "$TMP/SvFixture-plain" "$TMP/main-plain.c" >/dev/null 2>&1 \
	|| {
		echo "test-sign-and-verify: ERROR could not compile the plain fixture executable"
		exit 2
	}

# make_app <dir> <entitlements plist or "">: build <dir>/SvFixture.app, ad-hoc signed WITHOUT
# the hardened-runtime flag, so a later flags=...runtime proves the script's re-sign happened.
# Every bundle embeds a dylib (so the inside-out dylib signing runs), but only a bundle that
# carries an entitlements plist has its executable LINKED against it: the script's DYLD load
# check re-signs a copy with the hardened runtime, and under ad-hoc signing library validation
# refuses an ad-hoc dylib ("different Team IDs") unless disable-library-validation is present.
# That is the check working as intended, not something to bypass, so the entitlement-free
# fixture simply does not load the dylib.
make_app() {
	local dir="$1" ent="$2" app="$1/SvFixture.app"
	mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
	if [ -n "$ent" ]; then
		cp "$TMP/SvFixture-linked" "$app/Contents/MacOS/SvFixture"
	else
		cp "$TMP/SvFixture-plain" "$app/Contents/MacOS/SvFixture"
	fi
	cp "$TMP/libsvfixture.dylib" "$app/Contents/Frameworks/libsvfixture.dylib"
	cat >"$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>SvFixture</string>
	<key>CFBundleIdentifier</key>
	<string>test.sign-and-verify.fixture</string>
	<key>CFBundleName</key>
	<string>SvFixture</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
EOF
	codesign --force --sign - "$app/Contents/Frameworks/libsvfixture.dylib" >/dev/null 2>&1
	if [ -n "$ent" ]; then
		codesign --force --sign - --entitlements "$ent" "$app" >/dev/null 2>&1
	else
		codesign --force --sign - "$app" >/dev/null 2>&1
	fi
	printf '%s' "$app"
}

flags_of() { codesign -dv "$1" 2>&1 | sed -n 's/^CodeDirectory.*flags=\([^ ]*\).*/\1/p'; }

# run_script <interpreter: bash32|shebang> <script> <out-file> <args...>: prints the exit code.
run_script() {
	local how="$1" script="$2" out="$3" rc
	shift 3
	set +e
	if [ "$how" = "bash32" ]; then
		/bin/bash "$script" "$@" >"$out" 2>&1
	else
		"$script" "$@" >"$out" 2>&1
	fi
	rc=$?
	set -e
	printf '%s' "$rc"
}
run_sut() {
	local how="$1" out="$2"
	shift 2
	run_script "$how" "$SUT" "$out" "$@"
}

BASH_VER="$(/bin/bash -c 'printf %s "$BASH_VERSION"')"
# shellcheck disable=SC2016 # the single quotes are deliberate: the child shell expands it
ENV_BASH_VER="$(env bash -c 'printf %s "$BASH_VERSION"')"
echo "== system /bin/bash is $BASH_VER; shebang interpreter (env bash) is $ENV_BASH_VER"

echo "== matrix: ad-hoc, --offline, {/bin/bash, shebang} x {no entitlements, harmless entitlement}"
for how in bash32 shebang; do
	for variant in noent ent; do
		name="$how / $variant"
		dir="$TMP/m-$how-$variant"
		mkdir -p "$dir"
		if [ "$variant" = "ent" ]; then
			app="$(make_app "$dir" "$TMP/ent-harmless.plist")"
		else
			app="$(make_app "$dir" "")"
		fi
		before="$(flags_of "$app")"
		dylib_before="$(flags_of "$app/Contents/Frameworks/libsvfixture.dylib")"
		rc="$(run_sut "$how" "$dir/out.txt" --identity - --offline "$app")"
		after="$(flags_of "$app")"
		dylib_after="$(flags_of "$app/Contents/Frameworks/libsvfixture.dylib")"
		if [ "$rc" -eq 0 ]; then ok "$name: exit 0"; else bad "$name: exit $rc (want 0); tail: $(tail -n 3 "$dir/out.txt" | tr '\n' '|')"; fi
		if grep -qF 'sign-and-verify.sh: OK' "$dir/out.txt"; then ok "$name: prints the OK line"; else bad "$name: no 'sign-and-verify.sh: OK' line"; fi
		if codesign --verify --deep --strict "$app" >/dev/null 2>&1; then ok "$name: codesign --verify --deep --strict passes afterwards"; else bad "$name: the bundle does not verify afterwards"; fi
		case "$before" in *runtime*) bad "$name: fixture precondition broken (already hardened: $before)" ;; *) ;; esac
		case "$after" in *runtime*) ok "$name: the bundle was re-signed (flags $before -> $after)" ;; *) bad "$name: the bundle was NOT re-signed (flags $before -> $after)" ;; esac
		case "$dylib_before" in *runtime*) bad "$name: fixture precondition broken (dylib already hardened: $dylib_before)" ;; *) ;; esac
		case "$dylib_after" in *runtime*) ok "$name: the embedded dylib was re-signed (flags $dylib_before -> $dylib_after)" ;; *) bad "$name: the embedded dylib was NOT re-signed (flags $dylib_before -> $dylib_after)" ;; esac
		if [ "$variant" = "ent" ]; then
			if codesign -d --entitlements - "$app" 2>/dev/null | grep -qF 'disable-library-validation'; then ok "$name: the existing entitlement is preserved"; else bad "$name: the entitlement was lost"; fi
		fi
	done
done

echo "== --release: no entitlements passes; get-task-allow is refused"
for how in bash32 shebang; do
	dir="$TMP/r-$how"
	mkdir -p "$dir/a" "$dir/b"
	app="$(make_app "$dir/a" "")"
	rc="$(run_sut "$how" "$dir/a.txt" --identity - --offline --release "$app")"
	if [ "$rc" -eq 0 ] && grep -qF 'sign-and-verify.sh: OK' "$dir/a.txt" && codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
		ok "$how --release, no entitlements: exit 0, OK line, verifies"
	else
		bad "$how --release, no entitlements: exit $rc; tail: $(tail -n 3 "$dir/a.txt" | tr '\n' '|')"
	fi
	app="$(make_app "$dir/b" "$TMP/ent-gta.plist")"
	rc="$(run_sut "$how" "$dir/b.txt" --identity - --offline --release "$app")"
	if [ "$rc" -ne 0 ] && grep -qF 'com.apple.security.get-task-allow' "$dir/b.txt" && ! grep -qF 'sign-and-verify.sh: OK' "$dir/b.txt"; then
		ok "$how --release, get-task-allow: refused (exit $rc), entitlement named"
	else
		bad "$how --release, get-task-allow: exit $rc (want non-zero, message naming it, no OK line)"
	fi
done

echo "== fail-closed"
for how in bash32 shebang; do
	dir="$TMP/f-$how"
	mkdir -p "$dir"
	app="$(make_app "$dir" "")"
	rc="$(run_sut "$how" "$dir/out.txt" --identity "sign-and-verify-test-no-such-identity" --offline "$app")"
	if [ "$rc" -ne 0 ] && ! grep -qF 'sign-and-verify.sh: OK' "$dir/out.txt"; then ok "$how unknown identity: exit $rc, no OK line"; else bad "$how unknown identity: exit $rc (want non-zero, no OK line)"; fi
done
# A variable that is unbound half-way through, injected into a staged copy right after the line
# that starts with the given anchor: the script must not exit 0. On bash 3.2 this is exactly the
# trap bug, independent of the empty-array spelling. Two points: after the dylib step (the DYLD
# directory does not exist yet) and after the DYLD load check (it does; a sentinel set too early
# anywhere before the end is caught by the second one). Each injected copy is a fresh stage.
# injected_case <label> <anchor prefix> <1 if the DYLD-check directory must be preserved>
injected_case() {
	local label="$1" anchor="$2" want_dir="$3" inj how dir app rc kept
	inj="$TMP/inject-$label"
	mkdir -p "$inj"
	awk -v anchor="$anchor" 'index($0, anchor) == 1 { print; print ": \"${SIGN_AND_VERIFY_TEST_UNBOUND}\""; next } { print }' "$SUT" >"$inj/sign-and-verify.sh"
	cp "$SCRIPT_DIR/lib.sh" "$inj/lib.sh"
	chmod +x "$inj/sign-and-verify.sh"
	if [ "$(grep -c 'SIGN_AND_VERIFY_TEST_UNBOUND' "$inj/sign-and-verify.sh")" -ne 1 ]; then
		bad "the $label injection did not land exactly once (the anchor line '$anchor...' moved)"
		return 0
	fi
	for how in bash32 shebang; do
		dir="$TMP/u-$label-$how"
		mkdir -p "$dir"
		app="$(make_app "$dir" "")"
		rc="$(run_script "$how" "$inj/sign-and-verify.sh" "$dir/out.txt" --identity - --offline "$app")"
		if [ "$rc" -ne 0 ] && ! grep -qF 'sign-and-verify.sh: OK' "$dir/out.txt"; then ok "$how unbound variable $label: exit $rc, no OK line"; else bad "$how unbound variable $label: exit $rc (want non-zero; the EXIT trap must not turn a mid-script death into 0)"; fi
		if [ "$want_dir" -eq 1 ]; then
			kept="$(sed -n 's/.*DYLD-load-check artifacts preserved for inspection: //p' "$dir/out.txt" | head -n 1)"
			case "$kept" in
			*/macdows-dyld-check.*)
				if [ -d "$kept" ]; then
					ok "$how unbound variable $label: the DYLD-check directory is preserved and named"
					remove_kept_dyld_dir "$kept"
				else
					bad "$how unbound variable $label: the named DYLD-check directory does not exist: $kept"
				fi
				;;
			*) bad "$how unbound variable $label: no 'DYLD-load-check artifacts preserved for inspection: <dir>' line" ;;
			esac
		fi
	done
}
injected_case "half-way (after the dylib step)" 'log "Signed ' 0
injected_case "late (after the DYLD load check)" 'log "No unexpected loads detected' 1

# A failing command keeps its own exit status: a plutil stand-in that fails `-convert` with 3 (only
# a bundle that carries entitlements reaches that call) must surface as exit 3, not 1 and not 0.
# Every other plutil call goes to the real tool; no other system tool is replaced.
mkdir -p "$TMP/stubbin"
REAL_PLUTIL="$(command -v plutil)"
cat >"$TMP/stubbin/plutil" <<EOF
#!/bin/bash
case "\${1:-}" in
-convert) exit 3 ;;
*) exec "$REAL_PLUTIL" "\$@" ;;
esac
EOF
chmod +x "$TMP/stubbin/plutil"
for how in bash32 shebang; do
	dir="$TMP/p-$how"
	mkdir -p "$dir"
	app="$(make_app "$dir" "$TMP/ent-harmless.plist")"
	rc="$(PATH="$TMP/stubbin:$PATH" run_sut "$how" "$dir/out.txt" --identity - --offline "$app")"
	if [ "$rc" -eq 3 ] && ! grep -qF 'sign-and-verify.sh: OK' "$dir/out.txt"; then ok "$how a failing plutil (exit 3) keeps its status"; else bad "$how a failing plutil (exit 3): script exit $rc (want 3, no OK line); tail: $(tail -n 3 "$dir/out.txt" | tr '\n' '|')"; fi
	remove_kept_dyld_dir "$(sed -n 's/.*DYLD-load-check artifacts preserved for inspection: //p' "$dir/out.txt" | head -n 1)"
done

echo "== source pins"
# Comment-only lines are skipped. A "${NAME[@]}" or "${NAME[*]}" that is not the tail of the
# ${NAME[@]+"${NAME[@]}"} form is a bare expansion (unbound under set -u on bash < 4.4 when empty).
code_only="$(grep -vE '^[[:space:]]*#' "$SUT" || true)"
bare="$(printf '%s\n' "$code_only" | grep -nE '(^|[^+])"\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}"' || true)"
if [ -z "$bare" ]; then ok "no bare \"\${NAME[@]}\" array expansion"; else bad "bare array expansion(s): $bare"; fi
last_code="$(printf '%s\n' "$code_only" | grep -vE '^[[:space:]]*$' | tail -n 1)"
sentinel="${last_code%%=*}"
case "$last_code" in
*=1) ;;
*) sentinel="" ;;
esac
if [ -n "$sentinel" ] && printf '%s' "$sentinel" | grep -qE '^[A-Z][A-Z0-9_]*$'; then
	ok "the last code line sets a success sentinel ($sentinel=1)"
else
	bad "the last code line of the script must set the success sentinel to 1; got: $last_code"
	sentinel="__none__"
fi
if [ "$(printf '%s\n' "$code_only" | grep -cE "^$sentinel=0\$")" -eq 1 ]; then ok "the sentinel starts at 0, set once"; else bad "the sentinel $sentinel must be initialised to 0 exactly once"; fi
# Closed shape: the name occurs exactly three times in the code, wherever it sits on the line
# (init, the read in the trap, the final set), so an indented or otherwise disguised early
# assignment, a declare/readonly or an arithmetic write cannot hide.
mentions="$(printf '%s\n' "$code_only" | grep -oE "[A-Za-z0-9_]*${sentinel}[A-Za-z0-9_]*" | grep -cxF "$sentinel" || true)"
if [ "$mentions" -eq 3 ]; then ok "the sentinel name occurs exactly 3 times in the code (init, trap read, final set)"; else bad "the sentinel $sentinel occurs $mentions times in the code (want exactly 3: init, trap read, final set)"; fi
trap_body="$(awk '/^cleanup_on_exit\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$SUT")"
if printf '%s\n' "$trap_body" | grep -qE '[$][{]?'"$sentinel"'([^A-Za-z0-9_]|$)'; then ok "cleanup_on_exit reads the sentinel"; else bad "cleanup_on_exit does not read $sentinel"; fi
if printf '%s\n' "$trap_body" | grep -qE 'status=[1-9]'; then ok "cleanup_on_exit forces a non-zero status when the sentinel is unset"; else bad "cleanup_on_exit has no fail-closed assignment (status=1)"; fi
if printf '%s\n' "$code_only" | grep -qE '^trap cleanup_on_exit EXIT$'; then ok "cleanup_on_exit is installed on EXIT"; else bad "no 'trap cleanup_on_exit EXIT' line"; fi

echo
TEST_COMPLETED=1
if [ "$fail" -eq 0 ]; then
	echo "test-sign-and-verify: PASS $pass cases, 0 failed (system bash $BASH_VER)"
else
	echo "test-sign-and-verify: FAIL $pass passed, $fail failed (system bash $BASH_VER)"
fi
[ "$fail" -eq 0 ]
