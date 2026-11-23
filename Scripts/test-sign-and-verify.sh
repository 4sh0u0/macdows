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
#     -> non-zero, no OK line, the DYLD-check directory preserved and announced; the status of a
#     failing command is kept as is (a plutil stand-in exiting 3 -> exit 3); a failing mktemp -> exit
#     7 and nothing created; a directory that cannot be entered -> non-zero and nothing left;
#   - leftovers: every run of the script under test goes through a recording mktemp (the
#     failing-mktemp case excepted: its stand-in comes first on PATH), and the
#     suite asserts afterwards that no recorded path (nor any name starting with it) exists any
#     more, except the one DYLD-check directory the script announced as preserved, and that no
#     copy of the fixture it launched is still running. Cells that must keep that directory
#     (every failure after it was created) require the announcement, the name shape, the
#     fixture inside it and a physical path equal to a recorded one, independently of what the
#     script says. The oracle does not depend on where the script puts its temporary files, but
#     it only sees paths made through `mktemp`: a file created any other way is not noticed, and
#     only processes launched from a recorded DYLD-check directory are looked for;
#   - notarization path (the part only reachable without --offline), driven by stubs: a fake
#     `xcrun` (plus fail-closed `notarytool` and `stapler`) is first on PATH and answers
#     `notarytool history|submit` and `stapler staple` with scripted output and exit codes, logging
#     every call. Cases: no credentials, Accepted and stapled (the zip handed over is unpacked and
#     checked: one top-level entry, the cdhash of the signed app, no dyld entitlement), submit
#     failing (with and without "Accepted" in its output), Invalid, a non-terminal status, staple
#     failing, the /Debug/ skip and its override, --offline with the stubs on PATH. The real
#     notarytool and stapler are never called, no network is used, and nothing leaves this machine
#     (see the safety rules below);
#   - signals, each case on both interpreters: to the script alone, TERM and HUP while the
#     DYLD-check copy is running (the copy dies slowly on TERM, so a trap that does not wait for
#     it is seen) and TERM and INT while `notarytool submit` is blocked; INT to the whole
#     process group (what Ctrl-C does) in the DYLD window, TERM and INT to the group while
#     submit is blocked;
#     TERM to the script's own foreground child (the cleanup then starts with status 143); a
#     second HUP while the cleanup is running; TERM with stderr closed (injected). Exit
#     codes as measured, no OK line, no stapling, the copy and the private root gone, only the
#     announced directory left. Known limits, not covered: a terminal that is closed (seen under
#     both interpreters) or, with bash 5, a HUP to the whole group while `notarytool submit` is
#     running can end the script before its cleanup is done (for the group HUP under bash 5 the
#     EXIT trap was seen not to start at all); SIGKILL cannot be cleaned up; `notarytool submit
#     --wait` has no timeout;
#   - source pins: no bare "${NAME[@]}" expansion; the trap's success-sentinel shape, closed: the
#     sentinel name occurs exactly three times in the code; every variable the trap reads is
#     initialised before it is installed; one mktemp call and one rm in the whole script, the rm
#     inside the guard function, which is also exercised directly; `trap` occurs exactly twice
#     (the EXIT trap and `trap '' HUP` inside it, after `set +e`); and the pins that make the
#     stubs binding (below).
# Every signing identity used is ad-hoc ("-", a bare --timestamp is ignored by codesign for it, so
# the non-offline runs need no network either) except one case that passes an identity name that
# does not exist; the built bundle is a throwaway (Macdows.app is never launched, and the script
# under test is never run against a real app). The suite stages the repository's own lib.sh next
# to the copy it tests.
#
# Safety rules for the runs without --offline (this machine may hold real notarization credentials):
#   S1 the fake xcrun never forwards notarytool or stapler to the real tool, unknown subcommands
#      fail closed; S2 EVERY run of the script under test, offline or not, uses a copy whose
#      keychain profile name is replaced by one that does not exist, and the stub checks the
#      profile it receives (the direct test of the guard function is not a run of the script:
#      it sources that one function's text, taken from the file as given); S3 before every
#      non-offline run the suite proves that `xcrun`
#      resolves to the stub under both interpreters, and otherwise does not run the script;
#   S4 such runs only ever take the suite's own fixture and the ad-hoc identity; S5 source pins
#      on the script under test and on the lib.sh it sources come first, before anything is run:
#      every notarytool/stapler use goes through `xcrun`, no absolute tool path, no PATH
#      assignment, mktemp as a bare word, none of env / unset PATH / login shell or `sh -c` /
#      function or alias named like a tool / read or printf -v into PATH / eval / osascript,
#      and exactly one assignment of the profile name. If one is red, the script under test is
#      not run AT ALL, and every case that needs a run is reported as FAIL (the case count
#      does not depend on the environment).
#   The pins are a tripwire, not a sandbox: a determined edit can still get past a pattern (a
#   tool name assembled at run time, say). Behind them stand the replaced profile name (a real
#   `history` call could not find credentials), the stubs first on PATH, and, for whoever
#   mutates the script, an outer guard directory on PATH. Variants that bypass the stubs are only
#   ever fed to the pins-only mode, never to a normal run.
#
# Usage: Scripts/test-sign-and-verify.sh
#   SIGN_AND_VERIFY_UNDER_TEST=<path>  test that copy of sign-and-verify.sh instead of the
#                                      repository's (a negative control / mutant). It is staged next
#                                      to a copy of lib.sh, so it may live anywhere.
#   SIGN_AND_VERIFY_PINS_ONLY=1        compute the source pins on that file and report them: no
#                                      fixture is built and the script under test is not run. The last
#                                      line is "test-sign-and-verify: PINS-ONLY ...", never PASS or FAIL.
# Exit: 0 when every case passes, 1 otherwise. Last line: "test-sign-and-verify: PASS|FAIL ...".
# CI judges by that last line, not by the exit status alone. This script has an EXIT trap itself, so
# it fails closed the same way as the script it tests: under bash 3.2 a death on an unbound
# variable would read $? as 0 in the trap, hence the completion sentinel below.
# Cleanup in the per-user temp directory (mktemp -t on macOS uses DARWIN_USER_TEMP_DIR and ignores
# TMPDIR): the suite removes only paths that pass one guard (own_purge, below), and only paths that
# the recording mktemp saw the script under test create (and names starting with them, such as an
# old script's .plist) or a preserved directory holding this suite's fixture.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_IN="${SIGN_AND_VERIFY_UNDER_TEST:-$SCRIPT_DIR/sign-and-verify.sh}"
PINS_ONLY="${SIGN_AND_VERIFY_PINS_ONLY:-0}"
# A stray override would change what the notarization cases mean.
unset SIGN_AND_VERIFY_FORCE_NOTARIZE

if [ "$(uname -s)" != "Darwin" ]; then
	echo "test-sign-and-verify: SKIP not macOS (needs codesign, otool, plutil and PlistBuddy)"
	exit 0
fi
[ -f "$TARGET_IN" ] || {
	echo "test-sign-and-verify: ERROR no such script: $TARGET_IN"
	exit 2
}
for c in cc codesign otool plutil xcrun pgrep pkill ditto /usr/bin/perl /usr/bin/mktemp /usr/libexec/PlistBuddy; do
	command -v "$c" >/dev/null 2>&1 || {
		echo "test-sign-and-verify: ERROR required command not found: $c"
		exit 2
	}
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sign-and-verify-test.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
USER_TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
USER_TMP="${USER_TMP%/}"
USER_TMP_REAL=""
if [ -n "$USER_TMP" ] && [ -d "$USER_TMP" ]; then
	USER_TMP_REAL="$(cd "$USER_TMP" && pwd -P)"
fi

# physical <path>: the path with its parent directory resolved (dyld and the script's own
# announcements use /private/var/..., mktemp prints /var/...).
physical() {
	local p="$1" d
	if d="$(cd "${p%/*}" 2>/dev/null && pwd -P)"; then
		printf '%s/%s' "$d" "${p##*/}"
	else
		printf '%s' "$p"
	fi
}

# own_purge <path> <recording mktemp log, or "">: the ONLY deletion of a path that comes from the
# output or the temporary files of the script under test (the suite's own $TMP is the exception,
# in the EXIT trap: it is created and named here, not taken from anything the script says). A
# path is removed only if it is absolute, has no ".." in it, is named macdows-*, exists and is
# not a symbolic link, is a direct child of the per-user temp directory, and either holds this
# suite's fixture (a preserved DYLD-check directory) or starts with a path the recording mktemp
# saw the script create (so a derived name such as an old script's .plist is covered too).
own_purge() {
	local path="$1" log="${2:-}" parent pp rec recp ok=0
	[ -n "$path" ] && [ -n "$USER_TMP_REAL" ] || return 0
	case "$path" in
	/*) ;;
	*) return 0 ;;
	esac
	case "$path" in
	*..*) return 0 ;;
	esac
	case "${path##*/}" in
	macdows-*) ;;
	*) return 0 ;;
	esac
	if [ -L "$path" ] || [ ! -e "$path" ]; then return 0; fi
	parent="$(cd "${path%/*}" 2>/dev/null && pwd -P)" || return 0
	[ "$parent" = "$USER_TMP_REAL" ] || return 0
	pp="$parent/${path##*/}"
	if [ -d "$path/SvFixture.app" ]; then
		ok=1
	elif [ -n "$log" ] && [ -f "$log" ]; then
		while IFS= read -r rec; do
			[ -n "$rec" ] || continue
			recp="$(physical "$rec")"
			case "$pp" in
			"$recp"*)
				ok=1
				break
				;;
			*) ;;
			esac
		done <"$log"
	fi
	[ "$ok" -eq 1 ] || return 0
	rm -rf "${path:?}"
}

# safe_purge_paths <recording mktemp log>: remove what the script under test created: each recorded
# path and every name that starts with it, through own_purge.
safe_purge_paths() {
	local log="$1" p f
	[ -n "$USER_TMP_REAL" ] && [ -f "$log" ] || return 0
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		for f in "$p"*; do
			if [ -e "$f" ] || [ -L "$f" ]; then own_purge "$f" "$log"; fi
		done
	done < <(cat "$log")
}

purge_all_logs() {
	local lg
	[ -d "$TMP" ] || return 0
	while IFS= read -r lg; do
		safe_purge_paths "$lg"
	done < <(/usr/bin/find "$TMP" -type f -name '*.mktemp')
	while IFS= read -r lg; do
		own_purge "$(sed -n 's/.*DYLD-load-check artifacts preserved for inspection: //p' "$lg" | head -n 1)" ""
	done < <(/usr/bin/find "$TMP" -type f -name 'out.txt')
}

# Fail closed: exiting with status 0 before the sentinel is set is turned into a failure.
TEST_COMPLETED=0
cleanup_on_exit() {
	local status=$?
	if [ "$status" -eq 0 ] && [ "$TEST_COMPLETED" -ne 1 ]; then
		status=1
		echo "test-sign-and-verify: ERROR exiting with status 0 before the suite completed (bash 3.2 after an unbound variable, or a signal); failing closed"
	fi
	purge_all_logs || true
	rm -rf "${TMP:?}"
	exit "$status"
}
trap cleanup_on_exit EXIT

# The script sources lib.sh from its own directory, so stage both side by side. STAGE_SRC holds
# the file as given (for the pins); STAGE holds the copy every run uses: same text, except that
# the keychain profile name is replaced by one that does not exist (S2).
STAGE_SRC="$TMP/stage-src"
STAGE="$TMP/stage"
mkdir -p "$STAGE_SRC" "$STAGE"
cp "$TARGET_IN" "$STAGE_SRC/sign-and-verify.sh"
cp "$SCRIPT_DIR/lib.sh" "$STAGE_SRC/lib.sh"
cp "$SCRIPT_DIR/lib.sh" "$STAGE/lib.sh"
SUT_SRC="$STAGE_SRC/sign-and-verify.sh"
LIB_SRC="$STAGE_SRC/lib.sh"
STUB_PROFILE="macdows-no-such-profile-for-tests"
sed "s/^NOTARY_PROFILE=\"macdows\"\$/NOTARY_PROFILE=\"$STUB_PROFILE\"/" "$SUT_SRC" >"$STAGE/sign-and-verify.sh"
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
# fail_cell <count> <message>: report <count> failures (a case that could not run keeps its size).
fail_cell() {
	local n="$1" msg="$2" i=0
	while [ "$i" -lt "$n" ]; do
		bad "$msg"
		i=$((i + 1))
	done
}

# --- source pins, first: nothing is run before they are known ------------------------------------
# Comment-only lines are skipped. NOTARY_SAFE is 0 as soon as one SAFETY pin is red (S5 and S2 and
# the lib.sh scan); then the script under test is never run, and run_script refuses to.
NOTARY_SAFE=1
SAFETY_RED=0
echo "== safety pins (the script under test is not run at all unless every one is green)"
code_only="$(grep -vE '^[[:space:]]*#' "$SUT_SRC" || true)"
lib_code="$(grep -vE '^[[:space:]]*#' "$LIB_SRC" || true)"
code_n="$(grep -vE '^[[:space:]]*#' "$STAGE/sign-and-verify.sh" || true)"

PIN_CODE=""
# pin_hit <label> <ERE>: prints "<label> (<count>); " when the pattern matches the code view.
pin_hit() {
	local n
	n="$(printf '%s\n' "$PIN_CODE" | grep -cE -- "$2" || true)"
	if [ "$n" -ne 0 ]; then printf '%s (%s); ' "$1" "$n"; fi
}
# pin_reasons <kind> <code view>: prints why the pin is red, nothing when it is green.
pin_reasons() {
	local kind="$1" n_exc n_bare
	PIN_CODE="$2"
	case "$kind" in
	xcrun)
		# The one exception is the first word of a die message, which is text.
		n_exc="$(printf '%s\n' "$PIN_CODE" | grep -c 'die "notarytool submit failed' || true)"
		n_bare="$(printf '%s\n' "$PIN_CODE" | sed 's/die "notarytool submit failed/die "X submit failed/' | grep -oE '(xcrun[[:space:]]+)?(notarytool|stapler)' | grep -vc '^xcrun' || true)"
		if [ "$n_exc" -gt 1 ] || [ "$n_bare" -ne 0 ]; then printf "notarytool/stapler used without 'xcrun ' in front: %s use(s), die-message exceptions %s; " "$n_bare" "$n_exc"; fi
		;;
	abs)
		pin_hit "absolute path to xcrun, notarytool or stapler" '/(xcrun|notarytool|stapler)([^A-Za-z0-9_]|$)'
		;;
	path)
		pin_hit "PATH assigned or bypassed" '(^|[^A-Za-z0-9_])PATH\+?=|(^|[^A-Za-z0-9_])(export|declare|typeset|readonly|local)[[:space:]]+(-[A-Za-z]+[[:space:]]+)?PATH([^A-Za-z0-9_]|$)|command[[:space:]]+-p|hash[[:space:]]+-p'
		;;
	mktemp)
		n_exc="$(printf '%s\n' "$PIN_CODE" | grep -oE '[^[:space:](]*mktemp' | grep -cvx 'mktemp' || true)"
		n_bare="$(printf '%s\n' "$PIN_CODE" | grep -cE '(env|command|exec|builtin|xargs)[[:space:]]+mktemp' || true)"
		if [ "$n_exc" -ne 0 ] || [ "$n_bare" -ne 0 ]; then printf 'mktemp called by a path or through a wrapper (%s, %s); ' "$n_exc" "$n_bare"; fi
		;;
	bypass)
		pin_hit "env" '(^|[^A-Za-z0-9_-])env([[:space:]]|$)'
		pin_hit "unset PATH" '(^|[^A-Za-z0-9_])unset[^;&|]*[^A-Za-z0-9_]PATH([^A-Za-z0-9_]|$)'
		pin_hit "login shell or shell -c" '(^|[^A-Za-z0-9_.-])(ba|z|k|da|c|tc|fi)?sh[[:space:]]+(-[A-Za-z]*[lc]|--login)'
		pin_hit "function named like a tool" '(^|[^A-Za-z0-9_.-])(function[[:space:]]+)?(xcrun|notarytool|stapler|mktemp)[[:space:]]*\(\)'
		pin_hit "function keyword with a tool name" '(^|[^A-Za-z0-9_.-])function[[:space:]]+(xcrun|notarytool|stapler|mktemp)([^A-Za-z0-9_-]|$)'
		pin_hit "alias" '(^|[^A-Za-z0-9_.-])alias[[:space:]]+'
		pin_hit "read into PATH" '(^|[^A-Za-z0-9_])read[[:space:]]+([^;&|]*[[:space:]])?PATH([^A-Za-z0-9_]|$)'
		pin_hit "printf -v PATH" "printf[[:space:]]+-v[[:space:]]+[\"']?PATH"
		pin_hit "eval" '(^|[^A-Za-z0-9_.-])eval([[:space:]]|$)'
		pin_hit "osascript" 'osascript'
		;;
	*) printf 'unknown pin kind %s; ' "$kind" ;;
	esac
}
# profile_reasons <code view> <the one assignment line, or "" for none>: the profile name is
# assigned exactly once, by that line (every other mention is a $NOTARY_PROFILE or
# ${NOTARY_PROFILE} reference), and every --keychain-profile argument is such a reference.
profile_reasons() {
	local code="$1" want="$2" toks total=0 refs=0 others lines kp kpok
	# shellcheck disable=SC2016 # the dollar signs are regular-expression text
	toks="$(printf '%s\n' "$code" | grep -oE '[A-Za-z0-9_${]*NOTARY_PROFILE[A-Za-z0-9_}]*' || true)"
	if [ -n "$toks" ]; then
		total="$(printf '%s\n' "$toks" | wc -l | tr -d ' ')"
		refs="$(printf '%s\n' "$toks" | grep -cE '^[$][{]?NOTARY_PROFILE[}]?$' || true)"
	fi
	others=$((total - refs))
	if [ -z "$want" ]; then
		if [ "$others" -ne 0 ]; then printf 'NOTARY_PROFILE mentioned (%s) where it must not be; ' "$others"; fi
	else
		lines="$(printf '%s\n' "$code" | grep -cxF -- "$want" || true)"
		if [ "$others" -ne 1 ] || [ "$lines" -ne 1 ]; then printf 'NOTARY_PROFILE: %s occurrence(s) that are not references (want exactly 1, the line %s, found %s time(s)); ' "$others" "$want" "$lines"; fi
	fi
	kp="$(printf '%s\n' "$code" | { grep -oE -- '--keychain-profile[[:space:]]+[^[:space:]]*' || true; } | wc -l | tr -d ' ')"
	kpok="$(printf '%s\n' "$code" | { grep -oE -- '--keychain-profile[[:space:]]+"?[$][{]?NOTARY_PROFILE' || true; } | wc -l | tr -d ' ')"
	# shellcheck disable=SC2016 # the dollar sign is message text
	if [ "$kp" -ne "$kpok" ]; then printf '%s --keychain-profile argument(s), %s of them a $NOTARY_PROFILE reference; ' "$kp" "$kpok"; fi
}
# safety_cell <label> <reasons>: one ok or one FAIL.
safety_cell() {
	if [ -z "$2" ]; then
		ok "$1"
	else
		bad "$1 -- $2"
		NOTARY_SAFE=0
		SAFETY_RED=$((SAFETY_RED + 1))
	fi
}
safety_cell "every notarytool/stapler use in the code follows 'xcrun ' (one die message excepted)" "$(pin_reasons xcrun "$code_only")"
safety_cell "no absolute path to xcrun, notarytool or stapler" "$(pin_reasons abs "$code_only")"
safety_cell "the script does not assign PATH" "$(pin_reasons path "$code_only")"
safety_cell "mktemp is only ever called as a bare word" "$(pin_reasons mktemp "$code_only")"
safety_cell "no env, unset PATH, login shell or shell -c, tool-named function or alias, read or printf -v into PATH, eval or osascript" "$(pin_reasons bypass "$code_only")"
# S2: the profile name is assigned once, by the line the replacement hits, and nowhere else.
n_src="$(grep -c '^NOTARY_PROFILE="macdows"$' "$SUT_SRC" || true)"
n_new="$(grep -c "^NOTARY_PROFILE=\"$STUB_PROFILE\"\$" "$STAGE/sign-and-verify.sh" || true)"
n_old="$(printf '%s\n' "$code_n" | grep -c '"macdows"' || true)"
s2_reasons="$(profile_reasons "$code_only" 'NOTARY_PROFILE="macdows"')$(profile_reasons "$code_n" "NOTARY_PROFILE=\"$STUB_PROFILE\"")"
if [ "$n_src" -ne 1 ] || [ "$n_new" -ne 1 ] || [ "$n_old" -ne 0 ]; then s2_reasons="${s2_reasons}profile replacement: source lines $n_src (want 1), replaced lines $n_new (want 1), old literal left $n_old (want 0); "; fi
safety_cell "the keychain profile name is assigned once and replaced exactly once in the copy every run uses" "$s2_reasons"
# lib.sh is sourced by the script: the same pins apply to it, and it must not touch the profile.
lib_reasons="$(pin_reasons xcrun "$lib_code")$(pin_reasons abs "$lib_code")$(pin_reasons path "$lib_code")$(pin_reasons mktemp "$lib_code")$(pin_reasons bypass "$lib_code")$(profile_reasons "$lib_code" "")"
safety_cell "lib.sh (staged from the repository, sourced by the script) passes the same pins" "$lib_reasons"

echo "== source pins"
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
trap_body="$(awk '/^cleanup_on_exit\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$SUT_SRC")"
guard_body="$(awk '/^remove_own_dir\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$SUT_SRC")"
if printf '%s\n' "$trap_body" | grep -qE '[$][{]?'"$sentinel"'([^A-Za-z0-9_]|$)'; then ok "cleanup_on_exit reads the sentinel"; else bad "cleanup_on_exit does not read $sentinel"; fi
if printf '%s\n' "$trap_body" | grep -qE 'status=[1-9]'; then ok "cleanup_on_exit forces a non-zero status when the sentinel is unset"; else bad "cleanup_on_exit has no fail-closed assignment (status=1)"; fi
if printf '%s\n' "$code_only" | grep -qE '^trap cleanup_on_exit EXIT$'; then ok "cleanup_on_exit is installed on EXIT"; else bad "no 'trap cleanup_on_exit EXIT' line"; fi
# `trap` occurs exactly twice in the code: the EXIT trap, and `trap '' HUP` inside the cleanup,
# whose first lines are, in this order, `local status=$?`, `set +e`, `trap '' HUP`. A wider
# signal list, a trap with a body, a second trap, or a missing line is red.
n_trap="$(printf '%s\n' "$code_only" | grep -cE '(^|[^A-Za-z0-9_-])trap([^A-Za-z0-9_]|$)' || true)"
n_trap_top="$(printf '%s\n' "$code_only" | grep -cE '^trap cleanup_on_exit EXIT$' || true)"
body_code="$(printf '%s\n' "$trap_body" | grep -vE '^[[:space:]]*(#|$)' || true)"
head4="$(printf '%s\n' "$body_code" | sed -n '1,4p')"
want_head="$(printf 'cleanup_on_exit() {\n\tlocal status=$?\n\tset +e\n\ttrap %s HUP' "''")"
if [ "$n_trap" -eq 2 ] && [ "$n_trap_top" -eq 1 ] && [ "$head4" = "$want_head" ]; then
	ok "the code has two traps: the EXIT trap and, as the cleanup's third line after set +e, trap '' HUP"
else
	bad "trap occurrences: $n_trap (want 2: the EXIT trap and trap '' HUP), top-level EXIT traps: $n_trap_top; the cleanup begins with: $(printf '%s' "$head4" | tr '\n' '|')"
fi
# Every variable the trap (and the guard it calls) reads is initialised on a top-level line before
# the trap is installed: under bash 3.2 a trap that dies on an unbound variable replaces the
# real exit status. The name list is taken from the two function bodies, uppercase names only.
trap_line="$(printf '%s\n' "$code_only" | grep -nE '^trap cleanup_on_exit EXIT$' | head -n 1 | cut -d: -f1 || true)"
trap_vars="$(printf '%s\n%s\n' "$trap_body" "$guard_body" | grep -oE '[$][{]?[A-Z_][A-Z0-9_]*' | sed 's/^[$][{]*//' | sort -u || true)"
late=""
nvars=0
for v in $trap_vars; do
	nvars=$((nvars + 1))
	init_line="$(printf '%s\n' "$code_only" | grep -nE "^$v=" | head -n 1 | cut -d: -f1 || true)"
	if [ -z "$init_line" ] || [ -z "$trap_line" ] || [ "$init_line" -ge "$trap_line" ]; then late="$late $v"; fi
done
if [ "$nvars" -ge 1 ] && [ -z "$late" ]; then ok "every variable the EXIT trap reads is initialised before the trap is installed ($nvars variables)"; else bad "variable(s) read by the EXIT trap without a top-level initialisation before the trap line:$late (names found: $nvars)"; fi
# The trap stops the DYLD-check copy and then waits for it; the normal path clears the PID right
# after its own wait, so the trap never signals a process that may no longer be ours.
kill_ln="$(printf '%s\n' "$trap_body" | grep -nE '^[[:space:]]*kill "[$]SV_CHECK_PID"' | head -n 1 | cut -d: -f1 || true)"
wait_ln="$(printf '%s\n' "$trap_body" | grep -nE '^[[:space:]]*wait "[$]SV_CHECK_PID"' | head -n 1 | cut -d: -f1 || true)"
if [ -n "$kill_ln" ] && [ -n "$wait_ln" ] && [ "$wait_ln" -gt "$kill_ln" ]; then ok "the trap kills the DYLD-check copy and then waits for it"; else bad "the trap must kill \$SV_CHECK_PID and then wait for it (kill line '$kill_ln', wait line '$wait_ln')"; fi
n_wait_top="$(printf '%s\n' "$code_only" | grep -cE '^wait "[$]SV_CHECK_PID"' || true)"
n_wait_clear="$(printf '%s\n' "$code_only" | grep -A1 -E '^wait "[$]SV_CHECK_PID"' | grep -cE '^SV_CHECK_PID=""$' || true)"
if [ "$n_wait_top" -ge 1 ] && [ "$n_wait_top" -eq "$n_wait_clear" ]; then ok "the normal path clears SV_CHECK_PID right after its wait"; else bad "top-level waits for the copy: $n_wait_top, of which followed by clearing the PID: $n_wait_clear"; fi
# One mktemp call and one rm in the whole script, the rm inside the guard function.
n_mktemp="$(printf '%s\n' "$code_only" | grep -cE '(^|[^A-Za-z0-9_-])mktemp( |$)' || true)"
n_rm="$(printf '%s\n' "$code_only" | grep -cE '(^|[^A-Za-z0-9_-])rm( |$)' || true)"
n_rm_guard="$(printf '%s\n' "$guard_body" | grep -cE '^[[:space:]]*rm -rf "[$]path"$' || true)"
if [ "$n_mktemp" -eq 1 ] && [ "$n_rm" -eq 1 ] && [ "$n_rm_guard" -eq 1 ]; then ok "one mktemp call, and the only rm is the guarded one in remove_own_dir"; else bad "mktemp calls: $n_mktemp (want 1); rm calls: $n_rm (want 1), of which in remove_own_dir: $n_rm_guard (want 1)"; fi

if [ "$PINS_ONLY" = 1 ]; then
	echo
	TEST_COMPLETED=1
	struct_red=$((fail - SAFETY_RED))
	if [ "$NOTARY_SAFE" -eq 1 ]; then verdict="safety pins GREEN"; else verdict="safety pins RED ($SAFETY_RED)"; fi
	echo "test-sign-and-verify: PINS-ONLY $verdict, structural pins red $struct_red, $pass ok / $fail red (nothing was run)"
	[ "$NOTARY_SAFE" -eq 1 ] && [ "$fail" -eq 0 ]
	exit $?
fi

# --- the suite proper ------------------------------------------------------------------------------
# B10: a positive control for pgrep -f, which every "no copy is running" check relies on: an
# error from pgrep (exit 2 or 3) must not pass for "nothing is running".
PG_TOKEN="sv-pgrep-selfcheck-$$"
/usr/bin/perl -e 'sleep 300' "$PG_TOKEN" &
PG_PID=$!
pg_i=0
pg_found=0
while [ "$pg_i" -lt 20 ]; do
	if pgrep -f "$PG_TOKEN" >/dev/null 2>&1; then
		pg_found=1
		break
	fi
	sleep 0.1
	pg_i=$((pg_i + 1))
done
kill "$PG_PID" 2>/dev/null || true
{ wait "$PG_PID" || true; } 2>/dev/null
if [ "$pg_found" -ne 1 ]; then
	echo "test-sign-and-verify: ERROR pgrep -f did not find a known running process; every 'not running' check would be vacuous"
	exit 2
fi

# --- recording mktemp ----------------------------------------------------------------------
# Put first on PATH for the run of the script under test only: it calls the real mktemp, appends
# every path it created to $SV_MKTEMP_LOG, and prints it unchanged with the real exit status.
RECBIN="$TMP/recbin"
mkdir -p "$RECBIN"
cat >"$RECBIN/mktemp" <<'EOF'
#!/bin/bash
[ -n "${SV_MKTEMP_LOG:-}" ] || {
	echo "recording mktemp: SV_MKTEMP_LOG is not set" >&2
	exit 97
}
out="$(/usr/bin/mktemp "$@")" || exit $?
printf '%s\n' "$out" >>"$SV_MKTEMP_LOG"
printf '%s\n' "$out"
EOF
# The same directory carries fail-closed xcrun, notarytool and stapler: a run that is not given
# stubs of its own (every run without a notarization case) must never reach a notarization tool;
# if one does, it is logged in violations.log and refused with 99 (asserted after those runs).
for tool in xcrun notarytool stapler; do
	printf '#!/bin/bash\necho "%s called without stubs: $*" >>"%s/violations.log"\nexit 99\n' "$tool" "$RECBIN" >"$RECBIN/$tool"
	chmod +x "$RECBIN/$tool"
done
chmod +x "$RECBIN/mktemp"

# kept_of <out-file>: the directory the script announced as preserved ("" if none).
kept_of() { sed -n 's/.*DYLD-load-check artifacts preserved for inspection: //p' "$1" | head -n 1; }

# assert_clean <label> <recording mktemp log> <announced kept dir or ""> [allow-empty-log] [must-keep]:
# exactly one ok/bad. Every recorded path P: neither P nor any name starting with P exists, except
# the announced directory itself (which must exist and have nothing derived from its name); no copy
# of the fixture launched from a recorded DYLD-check directory is still running. With must-keep=1
# the directory must be there independently of what the script says it did: an announcement
# naming a */macdows-dyld-check.* directory that holds SvFixture.app and is one of the recorded
# paths. Purges afterwards.
assert_clean() {
	local label="$1" log="$2" kept="$3" allow_empty="${4:-0}" must_keep="${5:-0}" p pp f keptp="" left="" running="" kept_seen=0
	if [ -n "$kept" ]; then keptp="$(physical "$kept")"; fi
	if [ "$must_keep" = 1 ]; then
		case "$kept" in
		*/macdows-dyld-check.*)
			if [ ! -d "$kept/SvFixture.app" ]; then left="$left [the announced directory holds no SvFixture.app]"; fi
			;;
		*) left="$left [no 'preserved for inspection' announcement naming a macdows-dyld-check directory]" ;;
		esac
	fi
	if [ ! -s "$log" ]; then
		if [ "$allow_empty" = 1 ] && [ -z "$kept" ]; then
			ok "$label: nothing left behind (no temporary path was created)"
		else
			bad "$label: the recording mktemp saw no temporary path (the leftover check would be vacuous)"
		fi
		return 0
	fi
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		pp="$(physical "$p")"
		if [ -n "$keptp" ] && [ "$pp" = "$keptp" ]; then
			kept_seen=1
			if [ ! -d "$p" ]; then left="$left [announced directory missing]"; fi
			for f in "$p"?*; do
				if [ -e "$f" ] || [ -L "$f" ]; then left="$left ${f##*/}"; fi
			done
		else
			for f in "$p"*; do
				if [ -e "$f" ] || [ -L "$f" ]; then left="$left ${f##*/}"; fi
			done
		fi
		case "${pp##*/}" in
		macdows-dyld-check.*)
			if pgrep -f "$pp/SvFixture.app" >/dev/null 2>&1; then running="$running ${pp##*/}"; fi
			;;
		*) ;;
		esac
	done <"$log"
	if [ -n "$keptp" ] && [ "$kept_seen" -eq 0 ]; then left="$left [announced directory was not created by the script's own mktemp]"; fi
	if [ -z "$left$running" ]; then
		if [ -n "$kept" ]; then
			ok "$label: only the announced DYLD-check directory is left, no copy still running"
		else
			ok "$label: nothing left behind, no copy still running"
		fi
	else
		bad "$label: left behind:$left; still running:$running"
	fi
	safe_purge_paths "$log"
	own_purge "$kept" "$log"
}

echo "== the purge guard, exercised directly"
# Shapes the guard must refuse, and one it must accept. The directories are made in the per-user
# temp directory under a name the guard looks at; each is removed by its exact path afterwards
# (these are the test's own creations, not paths taken from a script's output). If the suite is
# killed inside this block, up to four of them, all empty, stay behind: the EXIT trap does not
# know them.
GUARD_LOG="$TMP/guard.mktemp"
: >"$GUARD_LOG"
g_ok="$(/usr/bin/mktemp -d -t macdows-guardtest)"
g_other="$(/usr/bin/mktemp -d -t other-guardtest)"
g_unrec="$(/usr/bin/mktemp -d -t macdows-guardunrec)"
g_link="$(/usr/bin/mktemp -d -t macdows-guardlink)"
rmdir "$g_link"
mkdir -p "$TMP/guard-target" "$TMP/macdows-guardoutside.x"
ln -s "$TMP/guard-target" "$g_link"
printf '%s\n' "$g_ok" "$g_other" "$g_link" "$TMP/macdows-guardoutside.x" >"$GUARD_LOG"
own_purge "$g_ok" "$GUARD_LOG"
if [ ! -e "$g_ok" ]; then ok "guard: a recorded, correctly named direct child of the per-user temp directory is removed"; else bad "guard: a recorded, correctly named directory was not removed"; fi
g_dots="$(/usr/bin/mktemp -d -t macdows-guarddots)"
printf '%s\n' "$g_dots" >>"$GUARD_LOG"
own_purge "$g_dots/../${g_dots##*/}" "$GUARD_LOG"
if [ -d "$g_dots" ]; then ok "guard: a path with .. in it is left alone"; else bad "guard: a path with .. in it was removed"; fi
own_purge "$TMP/macdows-guardoutside.x" "$GUARD_LOG"
if [ -d "$TMP/macdows-guardoutside.x" ]; then ok "guard: a directory outside the per-user temp directory is left alone"; else bad "guard: a directory outside the per-user temp directory was removed"; fi
own_purge "$g_other" "$GUARD_LOG"
if [ -d "$g_other" ]; then ok "guard: a directory with another name is left alone"; else bad "guard: a directory with another name was removed"; fi
own_purge "$g_link" "$GUARD_LOG"
if [ -L "$g_link" ] && [ -d "$TMP/guard-target" ]; then ok "guard: a symbolic link is left alone, and so is its target"; else bad "guard: a symbolic link or its target was removed"; fi
own_purge "$g_unrec" "$GUARD_LOG"
if [ -d "$g_unrec" ]; then ok "guard: a directory nobody recorded is left alone"; else bad "guard: an unrecorded directory was removed"; fi
for g in "$g_other" "$g_unrec" "$g_dots"; do
	if [ -d "$g" ]; then rm -rf "${g:?}"; fi
done
if [ -L "$g_link" ]; then rm -f "$g_link"; fi

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
# The slow fixture dies two seconds after SIGTERM (and writes $SV_SLOW_MARK when it gets it), so a
# cleanup that does not wait for the copy is seen. Only the signal cases in the DYLD window use it.
cat >"$TMP/main-slow.c" <<'EOF'
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
static void on_term(int s) {
	const char *m = getenv("SV_SLOW_MARK");
	(void)s;
	if (m) {
		int fd = open(m, O_WRONLY | O_CREAT, 0600);
		if (fd >= 0) close(fd);
	}
	sleep(2);
	_exit(0);
}
int main(void) {
	signal(SIGTERM, on_term);
	sleep(30);
	return 0;
}
EOF
cc -o "$TMP/SvFixture-slow" "$TMP/main-slow.c" >/dev/null 2>&1 \
	|| {
		echo "test-sign-and-verify: ERROR could not compile the slow fixture executable"
		exit 2
	}

# make_app <dir> <entitlements plist or ""> [1 = slow fixture]: build <dir>/SvFixture.app, ad-hoc
# signed WITHOUT the hardened-runtime flag, so a later flags=...runtime proves the script's re-sign
# happened. Every bundle embeds a dylib (so the inside-out dylib signing runs), but only a bundle
# that carries an entitlements plist has its executable LINKED against it: the script's DYLD load
# check re-signs a copy with the hardened runtime, and under ad-hoc signing library validation
# refuses an ad-hoc dylib ("different Team IDs") unless disable-library-validation is present.
# That is the check working as intended, not something to bypass, so the entitlement-free
# fixture simply does not load the dylib.
make_app() {
	local dir="$1" ent="$2" slow="${3:-0}" app="$1/SvFixture.app"
	mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
	if [ -n "$ent" ]; then
		cp "$TMP/SvFixture-linked" "$app/Contents/MacOS/SvFixture"
	elif [ "$slow" = 1 ]; then
		cp "$TMP/SvFixture-slow" "$app/Contents/MacOS/SvFixture"
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
cdhash_of() { { codesign -dvvv "$1" 2>&1 || true; } | sed -n 's/^CDHash=//p' | head -n 1; }

# run_script <interpreter: bash32|shebang> <script> <out-file> <args...>: prints the exit code. The
# recording mktemp (or, when RUN_PATH_PREFIX is set, that directory, which must provide one) is
# first on PATH; what it saw goes to <out-file>.mktemp. Refuses, printing -1, while a safety pin
# is red: no cell reaches this call then, so this is a second lock on the same door.
run_script() {
	local how="$1" script="$2" out="$3" rc
	shift 3
	if [ "$NOTARY_SAFE" -ne 1 ]; then
		printf '%s' "-1"
		return 0
	fi
	set +e
	if [ "$how" = "bash32" ]; then
		SV_MKTEMP_LOG="$out.mktemp" PATH="${RUN_PATH_PREFIX:-$RECBIN}:$PATH" /bin/bash "$script" "$@" >"$out" 2>&1
	else
		SV_MKTEMP_LOG="$out.mktemp" PATH="${RUN_PATH_PREFIX:-$RECBIN}:$PATH" "$script" "$@" >"$out" 2>&1
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
NOT_RUN="not run (a safety pin is red)"

echo "== matrix: ad-hoc, --offline, {/bin/bash, shebang} x {no entitlements, harmless entitlement}"
for how in bash32 shebang; do
	for variant in noent ent; do
		name="$how / $variant"
		if [ "$NOTARY_SAFE" -ne 1 ]; then
			if [ "$variant" = "ent" ]; then fail_cell 7 "$name: $NOT_RUN"; else fail_cell 6 "$name: $NOT_RUN"; fi
			continue
		fi
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
		assert_clean "$name" "$dir/out.txt.mktemp" ""
	done
done

echo "== --release: no entitlements passes; get-task-allow is refused"
for how in bash32 shebang; do
	if [ "$NOTARY_SAFE" -ne 1 ]; then
		fail_cell 4 "$how --release: $NOT_RUN"
		continue
	fi
	dir="$TMP/r-$how"
	mkdir -p "$dir/a" "$dir/b"
	app="$(make_app "$dir/a" "")"
	rc="$(run_sut "$how" "$dir/a.txt" --identity - --offline --release "$app")"
	if [ "$rc" -eq 0 ] && grep -qF 'sign-and-verify.sh: OK' "$dir/a.txt" && codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
		ok "$how --release, no entitlements: exit 0, OK line, verifies"
	else
		bad "$how --release, no entitlements: exit $rc; tail: $(tail -n 3 "$dir/a.txt" | tr '\n' '|')"
	fi
	assert_clean "$how --release, no entitlements" "$dir/a.txt.mktemp" ""
	app="$(make_app "$dir/b" "$TMP/ent-gta.plist")"
	rc="$(run_sut "$how" "$dir/b.txt" --identity - --offline --release "$app")"
	# 'is present on' is the refusal's own wording; the entitlement name alone also appears in
	# the "No ... entitlement on the signed bundle" line of a run that was not refused.
	if [ "$rc" -ne 0 ] && grep -qF 'com.apple.security.get-task-allow is present on' "$dir/b.txt" && ! grep -qF 'sign-and-verify.sh: OK' "$dir/b.txt"; then
		ok "$how --release, get-task-allow: refused (exit $rc), entitlement named"
	else
		bad "$how --release, get-task-allow: exit $rc (want non-zero, 'is present on' message naming it, no OK line)"
	fi
	assert_clean "$how --release, get-task-allow" "$dir/b.txt.mktemp" ""
done

echo "== fail-closed"
for how in bash32 shebang; do
	if [ "$NOTARY_SAFE" -ne 1 ]; then
		fail_cell 2 "$how unknown identity: $NOT_RUN"
		continue
	fi
	dir="$TMP/f-$how"
	mkdir -p "$dir"
	app="$(make_app "$dir" "")"
	rc="$(run_sut "$how" "$dir/out.txt" --identity "sign-and-verify-test-no-such-identity" --offline "$app")"
	if [ "$rc" -ne 0 ] && ! grep -qF 'sign-and-verify.sh: OK' "$dir/out.txt"; then ok "$how unknown identity: exit $rc, no OK line"; else bad "$how unknown identity: exit $rc (want non-zero, no OK line)"; fi
	assert_clean "$how unknown identity" "$dir/out.txt.mktemp" ""
done
# A variable that is unbound half-way through, injected into a staged copy right after the line
# that starts with the given anchor: the script must not exit 0. On bash 3.2 this is exactly the
# trap bug, independent of the empty-array spelling. Two points: after the dylib step (the DYLD
# directory does not exist yet) and after the DYLD load check (it does; a sentinel set too early
# anywhere before the end is caught by the second one). Each injected copy is a fresh stage, made
# from the copy every run uses (profile name replaced).
# injected_case <label> <anchor prefix> <1 if the DYLD-check directory must be preserved>
injected_case() {
	local label="$1" anchor="$2" want_dir="$3" inj how dir app rc kept
	inj="$TMP/inject-$label"
	mkdir -p "$inj"
	awk -v anchor="$anchor" 'index($0, anchor) == 1 { print; print ": \"${SIGN_AND_VERIFY_TEST_UNBOUND}\""; next } { print }' "$SUT" >"$inj/sign-and-verify.sh"
	cp "$STAGE/lib.sh" "$inj/lib.sh"
	chmod +x "$inj/sign-and-verify.sh"
	if [ "$(grep -c 'SIGN_AND_VERIFY_TEST_UNBOUND' "$inj/sign-and-verify.sh")" -ne 1 ]; then
		bad "the $label injection did not land exactly once (the anchor line '$anchor...' moved)"
		return 0
	fi
	if [ "$NOTARY_SAFE" -ne 1 ]; then
		fail_cell $((2 * (2 + want_dir))) "unbound variable $label: $NOT_RUN"
		return 0
	fi
	for how in bash32 shebang; do
		dir="$TMP/u-$label-$how"
		mkdir -p "$dir"
		app="$(make_app "$dir" "")"
		rc="$(run_script "$how" "$inj/sign-and-verify.sh" "$dir/out.txt" --identity - --offline "$app")"
		if [ "$rc" -ne 0 ] && ! grep -qF 'sign-and-verify.sh: OK' "$dir/out.txt"; then ok "$how unbound variable $label: exit $rc, no OK line"; else bad "$how unbound variable $label: exit $rc (want non-zero; the EXIT trap must not turn a mid-script death into 0)"; fi
		kept=""
		if [ "$want_dir" -eq 1 ]; then
			kept="$(kept_of "$dir/out.txt")"
			case "$kept" in
			*/macdows-dyld-check.*)
				if [ -d "$kept" ]; then
					ok "$how unbound variable $label: the DYLD-check directory is preserved and named"
				else
					bad "$how unbound variable $label: the named DYLD-check directory does not exist: $kept"
				fi
				;;
			*) bad "$how unbound variable $label: no 'DYLD-load-check artifacts preserved for inspection: <dir>' line" ;;
			esac
		fi
		assert_clean "$how unbound variable $label" "$dir/out.txt.mktemp" "$kept" 0 "$want_dir"
	done
}
injected_case "half-way (after the dylib step)" 'log "Signed ' 0
injected_case "late (after the DYLD load check)" 'log "No unexpected loads detected' 1

# A failing command keeps its own exit status: a plutil stand-in that fails `-convert` with 3 (only
# a bundle that carries entitlements reaches that call) must surface as exit 3, not 1 and not 0.
# Every other plutil call goes to the real tool; the recording mktemp stays in front of it on PATH.
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
	if [ "$NOTARY_SAFE" -ne 1 ]; then
		fail_cell 2 "$how a failing plutil: $NOT_RUN"
		continue
	fi
	dir="$TMP/p-$how"
	mkdir -p "$dir"
	app="$(make_app "$dir" "$TMP/ent-harmless.plist")"
	rc="$(RUN_PATH_PREFIX="$TMP/stubbin:$RECBIN" run_sut "$how" "$dir/out.txt" --identity - --offline "$app")"
	if [ "$rc" -eq 3 ] && ! grep -qF 'sign-and-verify.sh: OK' "$dir/out.txt"; then ok "$how a failing plutil (exit 3) keeps its status"; else bad "$how a failing plutil (exit 3): script exit $rc (want 3, no OK line); tail: $(tail -n 3 "$dir/out.txt" | tr '\n' '|')"; fi
	assert_clean "$how a failing plutil" "$dir/out.txt.mktemp" "$(kept_of "$dir/out.txt")" 0 1
done

# A failing mktemp: the script stops with exit 7 (the stand-in's own status), creates nothing, and
# does not claim success. The stand-in exits 7 and prints nothing.
mkdir -p "$TMP/mkfail"
printf '#!/bin/bash\nexit 7\n' >"$TMP/mkfail/mktemp"
chmod +x "$TMP/mkfail/mktemp"
for how in bash32 shebang; do
	if [ "$NOTARY_SAFE" -ne 1 ]; then
		fail_cell 2 "$how a failing mktemp: $NOT_RUN"
		continue
	fi
	dir="$TMP/k-$how"
	mkdir -p "$dir"
	app="$(make_app "$dir" "")"
	rc="$(RUN_PATH_PREFIX="$TMP/mkfail:$RECBIN" run_sut "$how" "$dir/out.txt" --identity - --offline "$app")"
	if [ "$rc" -eq 7 ] && ! grep -qF 'sign-and-verify.sh: OK' "$dir/out.txt" && ! grep -qF 'preserved for inspection' "$dir/out.txt"; then ok "$how a failing mktemp: exit 7, no OK line, nothing announced"; else bad "$how a failing mktemp: exit $rc (want 7, no OK line, nothing announced)"; fi
	assert_clean "$how a failing mktemp" "$dir/out.txt.mktemp" "" 1
done

# A directory that was created but cannot be entered (mode 000): make_tmp_dir must remove it and
# the script must stop non-zero. The stand-in makes the real directory, records it, then chmods it.
mkdir -p "$TMP/cdfail"
cat >"$TMP/cdfail/mktemp" <<'EOF'
#!/bin/bash
out="$(/usr/bin/mktemp "$@")" || exit $?
printf '%s\n' "$out" >>"$SV_MKTEMP_LOG"
chmod 000 "$out"
printf '%s\n' "$out"
EOF
chmod +x "$TMP/cdfail/mktemp"
for how in bash32 shebang; do
	if [ "$NOTARY_SAFE" -ne 1 ]; then
		fail_cell 2 "$how a directory that cannot be entered: $NOT_RUN"
		continue
	fi
	dir="$TMP/c-$how"
	mkdir -p "$dir"
	app="$(make_app "$dir" "")"
	rc="$(RUN_PATH_PREFIX="$TMP/cdfail:$RECBIN" run_sut "$how" "$dir/out.txt" --identity - --offline "$app")"
	if [ "$rc" -ne 0 ] && ! grep -qF 'sign-and-verify.sh: OK' "$dir/out.txt"; then ok "$how a directory that cannot be entered: exit $rc, no OK line"; else bad "$how a directory that cannot be entered: exit $rc (want non-zero, no OK line)"; fi
	assert_clean "$how a directory that cannot be entered" "$dir/out.txt.mktemp" ""
done
if [ "$NOTARY_SAFE" -ne 1 ]; then
	fail_cell 1 "no run without stubs of its own reached a notarization tool: $NOT_RUN"
elif [ ! -s "$RECBIN/violations.log" ]; then
	ok "no run without stubs of its own reached a notarization tool"
else
	bad "a run without stubs reached a notarization tool: $(head -n 3 "$RECBIN/violations.log" | tr '\n' '|')"
fi

echo "== the guard function, exercised directly"
cat >"$TMP/guard-driver.sh" <<'EOF'
#!/bin/bash
# usage: guard-driver.sh <file with the function> <scratch dir>
set -u
root="$2"
SV_NL=$'\n'
SV_MADE_DIRS=""
# shellcheck source=/dev/null
. "$1"
mkdir -p "$root"
mkdir "$root/macdows-sign.aaa"
remove_own_dir "$root/macdows-sign.aaa" macdows-sign
if [ -d "$root/macdows-sign.aaa" ]; then echo a:ok; else echo a:BAD; fi
mkdir "$root/other.bbb"
SV_MADE_DIRS="$SV_NL$root/other.bbb"
remove_own_dir "$root/other.bbb" macdows-sign
if [ -d "$root/other.bbb" ]; then echo b:ok; else echo b:BAD; fi
mkdir "$root/real.ccc"
ln -s "$root/real.ccc" "$root/macdows-sign.ccc"
SV_MADE_DIRS="$SV_NL$root/macdows-sign.ccc"
remove_own_dir "$root/macdows-sign.ccc" macdows-sign
if [ -d "$root/real.ccc" ] && [ -L "$root/macdows-sign.ccc" ]; then echo c:ok; else echo c:BAD; fi
SV_MADE_DIRS="$SV_NL"
(cd "$root" && remove_own_dir "" macdows-sign)
if [ -d "$root" ] && [ -d "$root/real.ccc" ]; then echo d:ok; else echo d:BAD; fi
mkdir "$root/macdows-sign.eee"
SV_MADE_DIRS="${SV_NL}macdows-sign.eee"
(cd "$root" && remove_own_dir "macdows-sign.eee" macdows-sign)
if [ -d "$root/macdows-sign.eee" ]; then echo e:ok; else echo e:BAD; fi
mkdir "$root/macdows-sign.fff"
SV_MADE_DIRS="$SV_NL$root/macdows-sign.fff"
remove_own_dir "$root/macdows-sign.fff" macdows-sign
if [ ! -e "$root/macdows-sign.fff" ]; then echo f:ok; else echo f:BAD; fi
EOF
chmod +x "$TMP/guard-driver.sh"
printf '%s\n' "$guard_body" >"$TMP/guard-fn.sh"
guard_desc_a="a path this run did not get from mktemp is left alone"
guard_desc_b="a path with another name prefix is left alone"
guard_desc_c="a symbolic link is left alone, and so is its target"
guard_desc_d="an empty path removes nothing"
guard_desc_e="a relative path is left alone"
guard_desc_f="a recorded, correctly named real directory is removed"
for how in bash32 shebang; do
	if [ "$NOTARY_SAFE" -ne 1 ]; then
		fail_cell 6 "$how remove_own_dir: $NOT_RUN"
		continue
	fi
	if [ "$how" = bash32 ]; then
		guard_out="$(/bin/bash "$TMP/guard-driver.sh" "$TMP/guard-fn.sh" "$TMP/guard-$how" 2>&1 || true)"
	else
		guard_out="$(env bash "$TMP/guard-driver.sh" "$TMP/guard-fn.sh" "$TMP/guard-$how" 2>&1 || true)"
	fi
	for key in a b c d e f; do
		case "$key" in
		a) desc="$guard_desc_a" ;;
		b) desc="$guard_desc_b" ;;
		c) desc="$guard_desc_c" ;;
		d) desc="$guard_desc_d" ;;
		e) desc="$guard_desc_e" ;;
		*) desc="$guard_desc_f" ;;
		esac
		if [ -n "$guard_body" ] && printf '%s\n' "$guard_out" | grep -qxF "$key:ok"; then ok "$how remove_own_dir: $desc"; else bad "$how remove_own_dir: $desc"; fi
	done
done

# --- notarization path: stubs -------------------------------------------------------------------
# make_notary_stubs <dir> <history rc> <submit rc> <submit output> <staple rc> <block submit: 0|1>
# Scripted answers live in files so the stub itself is fixed. S1: nothing is forwarded to a real
# tool; an unknown subcommand, or the notarytool / stapler names called directly, fails closed
# (exit 99) and is logged in violations.log; the profile argument is checked against profile. On
# submit the zip is copied to submitted.zip (with cp: a mktemp here would be recorded as a path
# the script made).
make_notary_stubs() {
	local d="$1" n
	mkdir -p "$d"
	printf '%s\n' "$STUB_PROFILE" >"$d/profile"
	printf '%s\n' "$2" >"$d/history_rc"
	printf '%s\n' "$3" >"$d/submit_rc"
	printf '%s\n' "$4" >"$d/submit_out"
	printf '%s\n' "$5" >"$d/staple_rc"
	if [ "$6" = 1 ]; then : >"$d/block"; fi
	cat >"$d/xcrun" <<'EOF'
#!/bin/bash
d="$(cd "$(dirname "$0")" && pwd)"
printf 'xcrun %s\n' "$*" >>"$d/calls.log"
profile_ok() {
	local prev="" a found=""
	for a in "$@"; do
		if [ "$prev" = "--keychain-profile" ]; then found="$a"; fi
		prev="$a"
	done
	[ "$found" = "$(cat "$d/profile")" ]
}
case "${1:-}:${2:-}" in
notarytool:history)
	profile_ok "$@" || {
		echo "history: unexpected profile argument: $*" >>"$d/violations.log"
		exit 98
	}
	exit "$(cat "$d/history_rc")"
	;;
notarytool:submit)
	profile_ok "$@" || {
		echo "submit: unexpected profile argument: $*" >>"$d/violations.log"
		exit 98
	}
	echo $$ >"$d/submit.pid"
	if [ -s "${3:-}" ]; then
		echo yes >"$d/zip-seen-nonempty"
		cp "$3" "$d/submitted.zip"
	fi
	if [ -e "$d/block" ]; then
		i=0
		while [ ! -e "$d/release" ] && [ "$i" -lt 150 ]; do
			sleep 0.2
			i=$((i + 1))
		done
	fi
	cat "$d/submit_out"
	exit "$(cat "$d/submit_rc")"
	;;
stapler:staple)
	exit "$(cat "$d/staple_rc")"
	;;
*)
	echo "unknown subcommand: $*" >>"$d/violations.log"
	exit 99
	;;
esac
EOF
	for n in notarytool stapler; do
		printf '#!/bin/bash\necho "called %s directly: $*" >>"%s/violations.log"\nexit 99\n' "$n" "$d" >"$d/$n"
	done
	cp "$RECBIN/mktemp" "$d/mktemp"
	chmod +x "$d/xcrun" "$d/notarytool" "$d/stapler" "$d/mktemp"
}

# S3: `xcrun` must resolve to the stub, under both interpreters, with the PATH the run will use.
stub_in_place() {
	local d="$1" r1 r2
	r1="$(PATH="$d:$PATH" /bin/bash -c 'command -v xcrun' || true)"
	r2="$(PATH="$d:$PATH" env bash -c 'command -v xcrun' || true)"
	[ "$r1" = "$d/xcrun" ] && [ "$r2" = "$d/xcrun" ]
}

# call_seq <calls.log>: the notarytool / stapler calls as "tool:subcommand " in order.
call_seq() {
	if [ -f "$1" ]; then sed -n 's/^xcrun \([a-z]*\) \([a-z]*\).*/\1:\2 /p' "$1" | tr -d '\n'; fi
}
no_violations() { [ ! -s "$1/violations.log" ]; }

# notary_case <id> <interpreter> <history rc> <submit rc> <submit output> <staple rc> <app subdir or ""> <extra flag or ""> <force 0|1>
# Runs the copy with the replaced profile name against the fixture, ad-hoc, no --offline unless the
# extra flag says so. S4: the app must be the suite's own fixture. Sets N_* for the assertions;
# returns 1, without running anything, when the pins are red or the stub is not in place.
N_RC="" N_OUT="" N_STUBS="" N_LOG="" N_APP=""
notary_case() {
	local id="$1" how="$2" dir app
	N_RC="" N_OUT="" N_STUBS="" N_LOG="" N_APP=""
	[ "$NOTARY_SAFE" -eq 1 ] || return 1
	dir="$TMP/n-$id-$how"
	mkdir -p "$dir"
	N_STUBS="$dir/stubs"
	make_notary_stubs "$N_STUBS" "$3" "$4" "$5" "$6" 0
	stub_in_place "$N_STUBS" || return 1
	if [ -n "$7" ]; then mkdir -p "$dir/$7"; app="$(make_app "$dir/$7" "")"; else app="$(make_app "$dir" "")"; fi
	case "$app" in
	"$TMP"/n-*/SvFixture.app | "$TMP"/n-*/Debug/SvFixture.app) ;;
	*) return 1 ;;
	esac
	N_APP="$app"
	N_OUT="$dir/out.txt"
	N_LOG="$N_OUT.mktemp"
	if [ "$9" = 1 ]; then
		N_RC="$(SIGN_AND_VERIFY_FORCE_NOTARIZE=1 RUN_PATH_PREFIX="$N_STUBS" run_script "$how" "$SUT" "$N_OUT" --identity - ${8:+"$8"} "$app")"
	else
		N_RC="$(RUN_PATH_PREFIX="$N_STUBS" run_script "$how" "$SUT" "$N_OUT" --identity - ${8:+"$8"} "$app")"
	fi
}
dyld_kept() { kept_of "$1"; }

echo "== notarization (stubbed): {/bin/bash, shebang} x N1..N8"
for how in bash32 shebang; do
	# N1: no stored credentials -> skipped, not a failure.
	n="$how N1 (history fails)"
	if notary_case N1 "$how" 1 0 "" 0 "" "" 0; then
		if [ "$N_RC" -eq 0 ] && grep -qF 'sign-and-verify.sh: OK' "$N_OUT" && grep -qF 'skipping notarization (not a failure)' "$N_OUT"; then ok "$n: exit 0, OK line, skipped as 'not a failure'"; else bad "$n: exit $N_RC (want 0, OK line, skip message)"; fi
		if [ "$(call_seq "$N_STUBS/calls.log")" = "notarytool:history " ] && no_violations "$N_STUBS"; then ok "$n: only 'history' was called"; else bad "$n: calls were '$(call_seq "$N_STUBS/calls.log")', violations: $(cat "$N_STUBS/violations.log" 2>/dev/null || true)"; fi
		assert_clean "$n" "$N_LOG" ""
	else
		fail_cell 3 "$n: not run (source pins red or the stub is not in place)"
	fi

	# N2: Accepted -> stapled; the zip handed to submit is unpacked and looked at.
	n="$how N2 (Accepted)"
	if notary_case N2 "$how" 0 0 "status: Accepted" 0 "" "" 0; then
		if [ "$N_RC" -eq 0 ] && grep -qF 'sign-and-verify.sh: OK' "$N_OUT" && grep -qF 'Notarization complete' "$N_OUT"; then ok "$n: exit 0, OK line, 'Notarization complete'"; else bad "$n: exit $N_RC (want 0, OK line, completion message)"; fi
		if [ "$(call_seq "$N_STUBS/calls.log")" = "notarytool:history notarytool:submit stapler:staple " ] && no_violations "$N_STUBS"; then ok "$n: calls were history, submit, staple in that order"; else bad "$n: calls were '$(call_seq "$N_STUBS/calls.log")', violations: $(cat "$N_STUBS/violations.log" 2>/dev/null || true)"; fi
		sub_line="$(grep '^xcrun notarytool submit ' "$N_STUBS/calls.log" | head -n 1 || true)"
		zip="$(printf '%s' "$sub_line" | awk '{print $4}')"
		if [ -n "$zip" ] && [ "$sub_line" = "xcrun notarytool submit $zip --keychain-profile $STUB_PROFILE --wait" ] && [ "${zip##*/}" = "SvFixture.zip" ] && [ -f "$N_STUBS/zip-seen-nonempty" ]; then ok "$n: submit got the zip (present and non-empty when called), the replaced profile and --wait"; else bad "$n: submit call was '$sub_line' (zip seen non-empty: $([ -f "$N_STUBS/zip-seen-nonempty" ] && echo yes || echo no))"; fi
		if [ "$(grep '^xcrun stapler ' "$N_STUBS/calls.log" | head -n 1 || true)" = "xcrun stapler staple $N_APP" ]; then ok "$n: stapler was given the app path"; else bad "$n: stapler call was '$(grep '^xcrun stapler ' "$N_STUBS/calls.log" | head -n 1 || true)' (want 'xcrun stapler staple $N_APP')"; fi
		if [ -n "$zip" ] && [ ! -e "${zip%/*}" ]; then ok "$n: the zip's directory is gone afterwards"; else bad "$n: the zip's directory still exists (or no zip was submitted): ${zip%/*}"; fi
		# What was handed over: unpack the copy the stub took.
		mkdir -p "$N_STUBS/unzipped"
		ditto -x -k "$N_STUBS/submitted.zip" "$N_STUBS/unzipped" >/dev/null 2>&1 || true
		top="$(/bin/ls -A "$N_STUBS/unzipped" 2>/dev/null || true)"
		if [ "$top" = "SvFixture.app" ]; then ok "$n: the zip holds exactly one top-level entry, SvFixture.app"; else bad "$n: the zip's top level is '$(printf '%s' "$top" | tr '\n' ' ')' (want exactly SvFixture.app)"; fi
		want_hash="$(cdhash_of "$N_APP")"
		got_hash="$(cdhash_of "$N_STUBS/unzipped/SvFixture.app")"
		if [ -n "$want_hash" ] && [ "$got_hash" = "$want_hash" ]; then ok "$n: the zipped app has the cdhash of the signed app"; else bad "$n: cdhash of the zipped app '$got_hash' differs from the signed app's '$want_hash'"; fi
		if [ -d "$N_STUBS/unzipped/SvFixture.app" ] && ! codesign -d --entitlements - "$N_STUBS/unzipped/SvFixture.app" 2>&1 | grep -qF 'allow-dyld-environment-variables'; then ok "$n: the zipped app does not carry allow-dyld-environment-variables"; else bad "$n: the zipped app carries allow-dyld-environment-variables (or is missing)"; fi
		assert_clean "$n" "$N_LOG" ""
	else
		fail_cell 9 "$n: not run (source pins red or the stub is not in place)"
	fi

	# N3a / N3b: submit exits non-zero; the output must not matter.
	for variant in a b; do
		if [ "$variant" = a ]; then
			n="$how N3a (submit fails)"
			sub_out="error: stub failure"
		else
			n="$how N3b (submit fails, output says Accepted)"
			sub_out="status: Accepted"
		fi
		if notary_case "N3$variant" "$how" 0 1 "$sub_out" 0 "" "" 0; then
			if [ "$N_RC" -ne 0 ] && grep -qF 'notarytool submit failed' "$N_OUT"; then ok "$n: non-zero exit (rc $N_RC), 'submit failed' message"; else bad "$n: exit $N_RC (want non-zero with the 'submit failed' message)"; fi
			if [ "$variant" = a ]; then
				if grep -qF "$sub_out" "$N_OUT"; then ok "$n: the notary output is shown (the failure message points at it)"; else bad "$n: the notary output '$sub_out' does not appear in the run's output"; fi
			fi
			if ! grep -qF 'sign-and-verify.sh: OK' "$N_OUT" && ! grep -qF 'Notarization complete' "$N_OUT"; then ok "$n: no OK line, no completion message"; else bad "$n: the run claims success"; fi
			if [ "$(call_seq "$N_STUBS/calls.log")" = "notarytool:history notarytool:submit " ] && no_violations "$N_STUBS"; then ok "$n: no staple call"; else bad "$n: calls were '$(call_seq "$N_STUBS/calls.log")', violations: $(cat "$N_STUBS/violations.log" 2>/dev/null || true)"; fi
			assert_clean "$n" "$N_LOG" "$(dyld_kept "$N_OUT")" 0 1
		else
			if [ "$variant" = a ]; then fail_cell 5 "$n: not run (source pins red or the stub is not in place)"; else fail_cell 4 "$n: not run (source pins red or the stub is not in place)"; fi
		fi
	done

	# N4 / N5: submit succeeds but the status is not Accepted.
	for variant in 4 5; do
		if [ "$variant" = 4 ]; then
			n="$how N4 (status: Invalid)"
			sub_out="status: Invalid"
		else
			n="$how N5 (non-terminal status)"
			sub_out="status: In Progress"
		fi
		if notary_case "N$variant" "$how" 0 0 "$sub_out" 0 "" "" 0; then
			if [ "$N_RC" -ne 0 ] && grep -qF "did not reach 'Accepted'" "$N_OUT"; then ok "$n: non-zero exit (rc $N_RC), \"did not reach 'Accepted'\""; else bad "$n: exit $N_RC (want non-zero with the 'did not reach' message)"; fi
			if ! grep -qF 'sign-and-verify.sh: OK' "$N_OUT" && ! grep -qF 'Notarization complete' "$N_OUT"; then ok "$n: no OK line, no completion message"; else bad "$n: the run claims success"; fi
			if [ "$(call_seq "$N_STUBS/calls.log")" = "notarytool:history notarytool:submit " ] && no_violations "$N_STUBS"; then ok "$n: no staple call"; else bad "$n: calls were '$(call_seq "$N_STUBS/calls.log")', violations: $(cat "$N_STUBS/violations.log" 2>/dev/null || true)"; fi
			assert_clean "$n" "$N_LOG" "$(dyld_kept "$N_OUT")" 0 1
		else
			fail_cell 4 "$n: not run (source pins red or the stub is not in place)"
		fi
	done

	# N6: Accepted, then stapling fails with a recognisable code.
	n="$how N6 (staple fails with 65)"
	if notary_case N6 "$how" 0 0 "status: Accepted" 65 "" "" 0; then
		if [ "$N_RC" -eq 65 ]; then ok "$n: the exit status is the failing command's own (65)"; else bad "$n: exit $N_RC (want 65)"; fi
		if ! grep -qF 'sign-and-verify.sh: OK' "$N_OUT" && ! grep -qF 'Notarization complete' "$N_OUT"; then ok "$n: no OK line, no completion message"; else bad "$n: the run claims success"; fi
		if [ "$(call_seq "$N_STUBS/calls.log")" = "notarytool:history notarytool:submit stapler:staple " ] && no_violations "$N_STUBS"; then ok "$n: staple was attempted once, after submit"; else bad "$n: calls were '$(call_seq "$N_STUBS/calls.log")', violations: $(cat "$N_STUBS/violations.log" 2>/dev/null || true)"; fi
		assert_clean "$n" "$N_LOG" "$(dyld_kept "$N_OUT")" 0 1
	else
		fail_cell 4 "$n: not run (source pins red or the stub is not in place)"
	fi

	# N7: an app under a directory named Debug.
	n="$how N7 (Debug path)"
	if notary_case N7a "$how" 1 0 "" 0 Debug "" 0; then
		if [ "$N_RC" -eq 0 ] && grep -qF 'Debug build path detected' "$N_OUT" && ! grep -qF 'WARNING: --release' "$N_OUT"; then ok "$n: exit 0, skipped, no --release warning"; else bad "$n: exit $N_RC (want 0, the skip line, no warning)"; fi
		if [ ! -s "$N_STUBS/calls.log" ]; then ok "$n: no tool was called at all"; else bad "$n: calls were '$(call_seq "$N_STUBS/calls.log")'"; fi
		assert_clean "$n" "$N_LOG" ""
	else
		fail_cell 3 "$n: not run (source pins red or the stub is not in place)"
	fi
	n="$how N7 (Debug path, --release)"
	if notary_case N7b "$how" 1 0 "" 0 Debug "--release" 0; then
		if [ "$N_RC" -eq 0 ] && grep -qF 'WARNING: --release was given but this path is under a /Debug/ directory' "$N_OUT" && [ ! -s "$N_STUBS/calls.log" ]; then ok "$n: exit 0, the WARNING line, no tool called"; else bad "$n: exit $N_RC (want 0, the WARNING line, no call; calls '$(call_seq "$N_STUBS/calls.log")')"; fi
		assert_clean "$n" "$N_LOG" ""
	else
		fail_cell 2 "$n: not run (source pins red or the stub is not in place)"
	fi
	n="$how N7 (Debug path, SIGN_AND_VERIFY_FORCE_NOTARIZE=1)"
	if notary_case N7c "$how" 1 0 "" 0 Debug "" 1; then
		if [ "$N_RC" -eq 0 ] && [ "$(call_seq "$N_STUBS/calls.log")" = "notarytool:history " ]; then ok "$n: exit 0, 'history' was called (the skip is overridden)"; else bad "$n: exit $N_RC, calls '$(call_seq "$N_STUBS/calls.log")' (want 0 and history)"; fi
		assert_clean "$n" "$N_LOG" ""
	else
		fail_cell 2 "$n: not run (source pins red or the stub is not in place)"
	fi

	# N8: --offline with the stubs on PATH.
	n="$how N8 (--offline, stubs on PATH)"
	if notary_case N8 "$how" 0 0 "status: Accepted" 0 "" "--offline" 0; then
		if [ "$N_RC" -eq 0 ] && grep -qF 'sign-and-verify.sh: OK' "$N_OUT" && grep -qF 'Offline mode: skipping notarization' "$N_OUT"; then ok "$n: exit 0, OK line, notarization skipped"; else bad "$n: exit $N_RC (want 0, OK line, skip message)"; fi
		if [ ! -s "$N_STUBS/calls.log" ]; then ok "$n: no tool was called at all"; else bad "$n: calls were '$(call_seq "$N_STUBS/calls.log")'"; fi
		assert_clean "$n" "$N_LOG" ""
	else
		fail_cell 3 "$n: not run (source pins red or the stub is not in place)"
	fi
done

# --- signals ---------------------------------------------------------------------------------
# A signal sent to the script, at two moments: while the DYLD check copy runs (the script sits in
# its 2-second sleep; --offline, nothing else involved) and while the stubbed `notarytool submit`
# is blocked. Delivery is to the script alone ("single": kill -SIG <pid>), to its whole process
# group ("group": kill -SIG -- -<pgid>, what Ctrl-C does), to the script's own foreground child
# ("child": the script then fails with status 128 + signal, which the cleanup sees as its
# status), or, for the cleanup case, a first HUP
# to the script and a second one as soon as the slow copy has been told to stop ("cleanup").
# The script is started through perl with INT, HUP and TERM reset to their defaults and in a
# process group of its own (so a group signal cannot reach this suite): a background job of a
# non-interactive shell inherits "ignore SIGINT", and a suite started under nohup (or by a parent
# that ignores SIGHUP) would otherwise hand "ignore" on to the script and make the case measure the
# wrong thing. Exit codes are the ones measured on both interpreters (128 + signal). There is
# deliberately no case for INT sent to the script alone during the sleep: both shells then ignore
# it and the run completes with exit 0, which is not a property of this script. Synchronisation
# is by marker (the copy's dyld log is non-empty / the stub wrote its pid / the slow copy wrote
# its marker), every wait is bounded, and a run that does not finish within its bound is killed
# and reported.
# signal_case <id> <interpreter> <signal> <win5|submit> [single|group|child|cleanup] [plain|slow]; sets
# SG_RC (or SYNCFAIL / HANG).
SG_RC="" SG_OUT="" SG_STUBS="" SG_LOG=""
# reap_copies <recording mktemp log>: end any copy of the fixture launched from a recorded
# DYLD-check directory (a run killed with -9 cannot do it itself).
reap_copies() {
	local p pp cpid
	[ -s "$1" ] || return 0
	while IFS= read -r p; do
		case "$p" in
		*/macdows-dyld-check.*)
			pp="$(physical "$p")"
			while IFS= read -r cpid; do
				[ -n "$cpid" ] || continue
				kill -9 "$cpid" 2>/dev/null || true
			done < <(pgrep -f "$pp/SvFixture.app" 2>/dev/null || true)
			;;
		*) ;;
		esac
	done <"$1"
}
signal_case() {
	local id="$1" how="$2" sig="$3" point="$4" deliver="${5:-single}" fixture="${6:-plain}" dir app i=0 pid synced=0 dyld spid rc
	local interp=() offl=()
	SG_RC="" SG_OUT="" SG_STUBS="" SG_LOG=""
	[ "$NOTARY_SAFE" -eq 1 ] || return 1
	dir="$TMP/n-$id-$how"
	mkdir -p "$dir"
	SG_STUBS="$dir/stubs"
	if [ "$point" = submit ]; then
		make_notary_stubs "$SG_STUBS" 0 0 "status: Accepted" 0 1
	else
		make_notary_stubs "$SG_STUBS" 0 0 "status: Accepted" 0 0
	fi
	stub_in_place "$SG_STUBS" || return 1
	if [ "$fixture" = slow ]; then app="$(make_app "$dir" "" 1)"; else app="$(make_app "$dir" "")"; fi
	case "$app" in
	"$TMP"/n-*/SvFixture.app) ;;
	*) return 1 ;;
	esac
	SG_OUT="$dir/out.txt"
	SG_LOG="$SG_OUT.mktemp"
	if [ "$how" = bash32 ]; then interp=(/bin/bash); fi
	if [ "$point" = win5 ]; then offl=(--offline); fi
	SV_SLOW_MARK="$dir/term.mark" SV_MKTEMP_LOG="$SG_LOG" PATH="$SG_STUBS:$PATH" /usr/bin/perl -e '$SIG{INT}=$SIG{HUP}=$SIG{TERM}="DEFAULT"; setpgrp(0,0); exec @ARGV' ${interp[@]+"${interp[@]}"} "$SUT" --identity - ${offl[@]+"${offl[@]}"} "$app" >"$SG_OUT" 2>&1 </dev/null &
	pid=$!
	while [ "$i" -lt 200 ]; do
		if [ "$point" = win5 ]; then
			dyld="$(grep 'macdows-dyld-check' "$SG_LOG" 2>/dev/null | head -n 1 || true)"
			if [ -n "$dyld" ] && [ -s "$dyld/dyld-print-libraries.log" ]; then
				synced=1
				break
			fi
		elif [ -s "$SG_STUBS/submit.pid" ]; then
			synced=1
			break
		fi
		sleep 0.1
		i=$((i + 1))
	done
	if [ "$synced" -ne 1 ]; then
		kill -9 "$pid" 2>/dev/null || true
		{ wait "$pid" || true; } 2>/dev/null
		reap_copies "$SG_LOG"
		SG_RC="SYNCFAIL"
		return 0
	fi
	case "$deliver" in
	group) kill "-$sig" -- "-$pid" 2>/dev/null || true ;;
	child)
		# the script's own foreground child (the 2-second sleep), not the script
		pkill "-$sig" -P "$pid" -x sleep 2>/dev/null || true
		;;
	cleanup)
		kill "-$sig" "$pid" 2>/dev/null || true
		i=0
		while [ ! -e "$dir/term.mark" ] && [ "$i" -lt 100 ]; do
			sleep 0.05
			i=$((i + 1))
		done
		kill "-$sig" "$pid" 2>/dev/null || true
		;;
	*) kill "-$sig" "$pid" 2>/dev/null || true ;;
	esac
	sleep 0.3
	: >"$SG_STUBS/release"
	i=0
	while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 200 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill -9 "$pid" 2>/dev/null || true
		SG_RC="HANG"
	fi
	rc=0
	{ wait "$pid" || rc=$?; } 2>/dev/null
	if [ "$SG_RC" = "HANG" ]; then reap_copies "$SG_LOG"; else SG_RC="$rc"; fi
	# Reap what the stub may have left (it is bounded to 30 s, and was released above).
	if [ -s "$SG_STUBS/submit.pid" ]; then
		spid="$(cat "$SG_STUBS/submit.pid")"
		i=0
		while kill -0 "$spid" 2>/dev/null && [ "$i" -lt 50 ]; do
			sleep 0.1
			i=$((i + 1))
		done
		if kill -0 "$spid" 2>/dev/null; then kill -9 "$spid" 2>/dev/null || true; fi
	fi
	return 0
}
# copy_running <recording mktemp log>: succeeds if a fixture launched from a recorded DYLD-check
# directory is still running.
copy_running() {
	local p pp
	[ -s "$1" ] || return 1
	while IFS= read -r p; do
		case "$p" in
		*/macdows-dyld-check.*)
			pp="$(physical "$p")"
			if pgrep -f "$pp/SvFixture.app" >/dev/null 2>&1; then return 0; fi
			;;
		*) ;;
		esac
	done <"$1"
	return 1
}

echo "== signals: the DYLD-check window and while submit is blocked, to the script and to its group"
# sig_cell <id> <label> <signal> <point> <expected exit code> [single|group|child|cleanup] [plain|slow]
sig_cell() {
	local id="$1" label="$2" sig="$3" point="$4" want="$5" deliver="${6:-single}" fixture="${7:-plain}" how n
	for how in bash32 shebang; do
		n="$how $label"
		if signal_case "$id" "$how" "$sig" "$point" "$deliver" "$fixture"; then
			if [ "$SG_RC" = "$want" ]; then ok "$n: exit status $SG_RC"; else bad "$n: exit status $SG_RC (want $want)"; fi
			if ! grep -qF 'sign-and-verify.sh: OK' "$SG_OUT"; then ok "$n: no OK line"; else bad "$n: the interrupted run printed the OK line"; fi
			if [ "$point" = win5 ]; then
				if ! copy_running "$SG_LOG"; then ok "$n: the DYLD-check copy is not running any more"; else bad "$n: the DYLD-check copy outlived the script"; fi
			else
				if [ "$(call_seq "$SG_STUBS/calls.log")" = "notarytool:history notarytool:submit " ] && no_violations "$SG_STUBS"; then ok "$n: no staple call"; else bad "$n: calls were '$(call_seq "$SG_STUBS/calls.log")', violations: $(cat "$SG_STUBS/violations.log" 2>/dev/null || true)"; fi
			fi
			assert_clean "$n" "$SG_LOG" "$(kept_of "$SG_OUT")" 0 1
		else
			fail_cell 4 "$n: not run (source pins red, the stub is not in place, or $SG_RC)"
		fi
	done
}
sig_cell G1 "G1 TERM during the DYLD-check window" TERM win5 143 single slow
sig_cell G2 "G2 TERM while submit is blocked" TERM submit 143
sig_cell G3a "G3 HUP during the DYLD-check window" HUP win5 129 single slow
sig_cell G3b "G3 INT while submit is blocked" INT submit 130
sig_cell PG1 "PG1 INT to the process group during the DYLD-check window (Ctrl-C)" INT win5 130 group slow
sig_cell PG2 "PG2 TERM to the process group while submit is blocked" TERM submit 143 group
sig_cell PG3 "PG3 INT to the process group while submit is blocked" INT submit 130 group
sig_cell SC "SC TERM to the script's own foreground child during the DYLD-check window (the cleanup starts with status 143)" TERM win5 143 child slow
sig_cell HC "HC a second HUP while the cleanup is waiting for the copy" HUP win5 129 cleanup slow

# TERM with stderr already closed: the cleanup used to stop at its first write to stderr (`set -e`
# is inherited by an EXIT trap) and leave the private root behind. The injected copy closes stderr
# and sends itself TERM right after the DYLD load check; the trap then enters with status 0 on both
# interpreters, as it does for an external TERM. No announcement can be written, so the preserved
# directory is taken from what the recording mktemp saw.
# closed_stderr_case: a fresh staged copy per run; the lines are added after the second anchor.
closed_stderr_case() {
	local inj how dir app rc kept n
	inj="$TMP/inject-closed-stderr"
	mkdir -p "$inj"
	awk 'index($0, "log \"No unexpected loads detected") == 1 { print; print "exec 2>&-"; print "kill -TERM $$"; print "sleep 1"; next } { print }' "$SUT" >"$inj/sign-and-verify.sh"
	cp "$STAGE/lib.sh" "$inj/lib.sh"
	chmod +x "$inj/sign-and-verify.sh"
	if [ "$(grep -c '^exec 2>&-$' "$inj/sign-and-verify.sh")" -ne 1 ]; then
		bad "the closed-stderr injection did not land exactly once (the anchor line moved)"
		return 0
	fi
	if [ "$NOTARY_SAFE" -ne 1 ]; then
		fail_cell 6 "TERM with stderr closed: $NOT_RUN"
		return 0
	fi
	for how in bash32 shebang; do
		n="$how TERM with stderr closed"
		dir="$TMP/u-closed-$how"
		mkdir -p "$dir"
		app="$(make_app "$dir" "")"
		rc="$(run_script "$how" "$inj/sign-and-verify.sh" "$dir/out.txt" --identity - --offline "$app")"
		if [ "$rc" = 143 ]; then ok "$n: exit status 143"; else bad "$n: exit status $rc (want 143)"; fi
		if ! grep -qF 'sign-and-verify.sh: OK' "$dir/out.txt"; then ok "$n: no OK line"; else bad "$n: the run printed the OK line"; fi
		kept="$(grep 'macdows-dyld-check' "$dir/out.txt.mktemp" 2>/dev/null | head -n 1 || true)"
		assert_clean "$n" "$dir/out.txt.mktemp" "$kept" 0 0
	done
}
closed_stderr_case

echo
TEST_COMPLETED=1
if [ "$fail" -eq 0 ]; then
	echo "test-sign-and-verify: PASS $pass cases, 0 failed (system bash $BASH_VER)"
else
	echo "test-sign-and-verify: FAIL $pass passed, $fail failed (system bash $BASH_VER)"
fi
[ "$fail" -eq 0 ]
