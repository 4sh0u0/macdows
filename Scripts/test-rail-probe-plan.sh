#!/usr/bin/env bash
# test-rail-probe-plan.sh: W3 lane F (ADR-0018 §2 lane F, merge = U-7). Pins that Tools/rail-probe's
# pre-connect settings SEQUENCE is unchanged when the two new knobs (--desktop, --scale) are absent,
# that each knob appends exactly its own two settings, that malformed knob values are refused rather
# than silently ignored, and that --help reads as the committed snapshot.
#
# Tool m-1: --print-plan describes, never dials (2026-09-09 step R found it still demanded --app/--out
# regardless). --host/--user stay required under --print-plan (probe_settings_plan never lists them,
# same as before); --app/--out become optional, and omitting them must not open a second code path
# through the (unchanged, single-implementation) plan -- see M1 below for what "must not" is pinned
# against. Without --print-plan, missing --app/--out is refused exactly as before (exit 2).
#
# Gate r1-A I-3 fold: --print-plan no longer requires $WIN_PASS either (the print sink never reads
# a password -- see I3a/I3b below), and BOTH modes' "missing required argument" message now names
# exactly the flags that are actually absent instead of a fixed list (the fixed list used to fire,
# misleadingly, even when every flag it named was present -- see M2's updated assertion).
# Gate r1-A m-4 fold: M1's "identical to --app '' --out ''" half was a tautology (parse_args's
# memset already makes omitted and empty-string the same program state) -- replaced with a
# comparison against a NON-EMPTY --app, which is the claim that actually carries information.
# Gate r1-A m-11 fold: Scripts/probe.sh's own run-time log line is also pinned here (RUNLOG below).
#
# Two kinds of case, same split as Scripts/test-lab-boundary.sh's rail-probe section:
#   * SOURCE PINS run always and hold the structural claim -- ONE implementation
#     (probe_settings_plan) feeds both the connect path and --print-plan, so a settings write that
#     bypasses it is visible as a changed count of freerdp_settings_set_ call sites.
#   * BINARY CASES run when Tools/rail-probe/build/rail-probe exists and is newer than its source;
#     they need cmake and a FreeRDP prefix, which Tier 1 does not have (a missing binary is a NOTE,
#     never a silent pass -- and this suite is not wired into Tier 1). --print-plan exits before any
#     FreeRDP context exists, so no case here can open a socket; the fixture credentials are the
#     documentation-range host and placeholder strings test-lab-boundary.sh uses, and the launcher
#     handshake value is set the way that suite's gated binary cases set it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO_ROOT/Tools/rail-probe/rail-probe.c"
BIN="${RAILPROBE_BIN:-$REPO_ROOT/Tools/rail-probe/build/rail-probe}"
SNAPSHOT="$REPO_ROOT/Tools/rail-probe/rail-probe-help.snapshot"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rail-probe-plan.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
FAILURES=0
NOT_RUN=0

check() {
	if [ "$1" -eq 0 ]; then
		printf 'PASS  %-40s %s\n' "$2" "$3"
	else
		printf 'FAIL  %-40s %s\n' "$2" "$3"
		if [ -n "${4:-}" ] && [ -f "${4:-}" ]; then
			sed -n '1,14p' "$4" | while IFS= read -r evidence_line; do
				printf '      run said: %s\n' "$evidence_line"
			done
		fi
		FAILURES=$((FAILURES + 1))
	fi
}

echo "== source pins (always) =="
# Every freerdp_settings_set_ call site in rail-probe.c, by construction: three inside the plan's
# apply sink (bool / uint32 / string), three for the credential trio in main, one for
# --decode's DeactivateClientDecoding in client_new. A new site anywhere else means a setting is
# applied outside the plan and --print-plan would no longer describe the connect path.
# Call sites only (the opening parenthesis): comments that name the function family do not count.
SET_SITES="$(grep -cE 'freerdp_settings_set_[a-z0-9]+\(' "$SRC" || true)"
[ "$SET_SITES" -eq 7 ] && OK=0 || OK=1
printf 'freerdp_settings_set_ call sites: %s (expected 7)\n' "$SET_SITES" >"$TEST_DIR/set-sites.txt"
check "$OK" "one implementation" "7 freerdp_settings_set_ sites: 3 sink + 3 credentials + 1 decode" "$TEST_DIR/set-sites.txt"
PLAN_SITES="$(grep -c 'probe_settings_plan(' "$SRC" || true)"
[ "$PLAN_SITES" -eq 3 ] && OK=0 || OK=1
printf 'probe_settings_plan( occurrences: %s (expected 3: definition, pre_connect, --print-plan)\n' "$PLAN_SITES" >"$TEST_DIR/plan-sites.txt"
check "$OK" "plan has two consumers" "definition + pre_connect + --print-plan" "$TEST_DIR/plan-sites.txt"

echo "== binary cases =="
if [ ! -x "$BIN" ]; then
	printf 'NOTE  %-40s no built binary at Tools/rail-probe/build/rail-probe (set RAILPROBE_BIN to override)\n' "binary cases"
	printf '      Building it needs cmake and a FreeRDP prefix; run Scripts/probe.sh once on a maintainer machine.\n'
	NOT_RUN=$((NOT_RUN + 1))
elif [ "$SRC" -nt "$BIN" ]; then
	printf 'FAIL  %-40s binary is older than rail-probe.c -- rebuild before trusting any verdict below\n' "binary freshness"
	FAILURES=$((FAILURES + 1))
else
	# All three helpers below use `env NAME=value ... -- "$BIN" ...` (a single external command,
	# not a `( subshell with export )`) so each invocation's environment is fully self-contained
	# in one place: no earlier helper's export can leak into a later one, and (gate r1-A m-4/I-3
	# fold) shellcheck no longer sees these sibling functions as candidate SC2030/SC2031
	# modify-in-a-subshell pairs across each other, which was a false positive here (each of
	# these three functions is a standalone invocation; none of them relies on a previous one's
	# exports surviving).
	run_probe() {
		RC=0
		env -u MACDOWS_BOUNDARY_GATED WIN_HOST="192.0.2.10" WIN_USER="fixture-user" \
			WIN_PASS="fixture-value-not-a-credential" MACDOWS_BOUNDARY_GATED=1 \
			"$BIN" "$@" >"$TEST_DIR/stdout.txt" 2>"$TEST_DIR/stderr.txt" || RC=$?
	}
	# I3a (gate r1-A I-3): like run_probe, but WIN_PASS is absent from the environment entirely
	# (not even exported as ""), for pinning that --print-plan truly never needs it -- WIN_HOST/
	# WIN_USER are still backfilled as fixtures since this helper is for cases that supply
	# --host/--user on argv anyway and are not testing those two.
	run_probe_no_pass() {
		RC=0
		env -u MACDOWS_BOUNDARY_GATED -u WIN_PASS WIN_HOST="192.0.2.10" WIN_USER="fixture-user" \
			MACDOWS_BOUNDARY_GATED=1 \
			"$BIN" "$@" >"$TEST_DIR/stdout.txt" 2>"$TEST_DIR/stderr.txt" || RC=$?
	}
	# I3b (gate r1-A I-3): none of WIN_HOST/WIN_USER/WIN_PASS exported at all, so a flag omitted
	# on argv is actually absent from cfg -- run_probe's fixture env vars would otherwise
	# silently backfill --host/--user and defeat a "missing --host" test.
	run_probe_bare() {
		RC=0
		env -u MACDOWS_BOUNDARY_GATED -u WIN_HOST -u WIN_USER -u WIN_PASS MACDOWS_BOUNDARY_GATED=1 \
			"$BIN" "$@" >"$TEST_DIR/stdout.txt" 2>"$TEST_DIR/stderr.txt" || RC=$?
	}
	APP='C:\Windows\System32\winver.exe'
	NEVER="$TEST_DIR/never-created.jsonl"
	EXPECTED_BASE="$TEST_DIR/expected-base.txt"
	cat >"$EXPECTED_BASE" <<'PLAN'
set FreeRDP_CertificateCallbackPreferPEM = TRUE
set FreeRDP_OsMajorType = 4
set FreeRDP_OsMinorType = 7
set FreeRDP_RemoteApplicationMode = TRUE
set FreeRDP_RemoteApplicationProgram = "C:\Windows\System32\winver.exe"
set FreeRDP_SupportGraphicsPipeline = TRUE
set FreeRDP_HiDefRemoteApp = TRUE
set FreeRDP_NlaSecurity = TRUE
PLAN

	# H1: --help is the committed snapshot (argv[0] normalised on the Usage line).
	run_probe --help
	sed '1s|^Usage: .* --host|Usage: rail-probe --host|' "$TEST_DIR/stdout.txt" >"$TEST_DIR/help.txt"
	if diff -u "$SNAPSHOT" "$TEST_DIR/help.txt" >"$TEST_DIR/help.diff"; then OK=0; else OK=1; fi
	[ "$RC" -eq 0 ] || OK=1
	check "$OK" "--help snapshot" "matches Tools/rail-probe/rail-probe-help.snapshot, exit 0" "$TEST_DIR/help.diff"

	# P1: no knobs -> today's eight settings, in order, nothing else; exit 0; no output file.
	run_probe --print-plan --app "$APP" --out "$NEVER"
	if diff -u "$EXPECTED_BASE" "$TEST_DIR/stdout.txt" >"$TEST_DIR/p1.diff"; then OK=0; else OK=1; fi
	[ "$RC" -eq 0 ] || OK=1
	[ ! -e "$NEVER" ] || OK=1
	check "$OK" "plan without knobs" "the eight pre-connect settings, verbatim and in order; exit 0; no JSONL created" "$TEST_DIR/p1.diff"

	# P2: --desktop appends exactly DesktopWidth then DesktopHeight after the base sequence.
	{ cat "$EXPECTED_BASE"; printf 'set FreeRDP_DesktopWidth = 2560\nset FreeRDP_DesktopHeight = 1440\n'; } >"$TEST_DIR/expected-p2.txt"
	run_probe --print-plan --app "$APP" --out "$NEVER" --desktop 2560x1440
	if diff -u "$TEST_DIR/expected-p2.txt" "$TEST_DIR/stdout.txt" >"$TEST_DIR/p2.diff"; then OK=0; else OK=1; fi
	[ "$RC" -eq 0 ] || OK=1
	check "$OK" "plan with --desktop" "base + DesktopWidth=2560 + DesktopHeight=1440, nothing else" "$TEST_DIR/p2.diff"

	# P3: --scale d,v appends DesktopScaleFactor then DeviceScaleFactor.
	{ cat "$EXPECTED_BASE"; printf 'set FreeRDP_DesktopScaleFactor = 200\nset FreeRDP_DeviceScaleFactor = 180\n'; } >"$TEST_DIR/expected-p3.txt"
	run_probe --print-plan --app "$APP" --out "$NEVER" --scale 200,180
	if diff -u "$TEST_DIR/expected-p3.txt" "$TEST_DIR/stdout.txt" >"$TEST_DIR/p3.diff"; then OK=0; else OK=1; fi
	[ "$RC" -eq 0 ] || OK=1
	check "$OK" "plan with --scale d,v" "base + DesktopScaleFactor=200 + DeviceScaleFactor=180" "$TEST_DIR/p3.diff"

	# P4: --scale d alone -> device 100 is still WRITTEN (both fields, like the App's pair).
	{ cat "$EXPECTED_BASE"; printf 'set FreeRDP_DesktopScaleFactor = 200\nset FreeRDP_DeviceScaleFactor = 100\n'; } >"$TEST_DIR/expected-p4.txt"
	run_probe --print-plan --app "$APP" --out "$NEVER" --scale 200
	if diff -u "$TEST_DIR/expected-p4.txt" "$TEST_DIR/stdout.txt" >"$TEST_DIR/p4.diff"; then OK=0; else OK=1; fi
	[ "$RC" -eq 0 ] || OK=1
	check "$OK" "plan with --scale d" "base + DesktopScaleFactor=200 + DeviceScaleFactor=100" "$TEST_DIR/p4.diff"

	# P5: both knobs -> desktop pair first, then the scale pair (fixed order, like the App).
	{ cat "$EXPECTED_BASE"; printf 'set FreeRDP_DesktopWidth = 1280\nset FreeRDP_DesktopHeight = 720\nset FreeRDP_DesktopScaleFactor = 150\nset FreeRDP_DeviceScaleFactor = 140\n'; } >"$TEST_DIR/expected-p5.txt"
	run_probe --print-plan --app "$APP" --out "$NEVER" --scale 150,140 --desktop 1280x720
	if diff -u "$TEST_DIR/expected-p5.txt" "$TEST_DIR/stdout.txt" >"$TEST_DIR/p5.diff"; then OK=0; else OK=1; fi
	[ "$RC" -eq 0 ] || OK=1
	check "$OK" "plan with both knobs" "desktop pair then scale pair regardless of argument order" "$TEST_DIR/p5.diff"

	# I1..I7: malformed knob values are refused (exit 2, usage on stderr, NO plan line on stdout).
	for bad in "--desktop 0x768" "--desktop 1024x" "--desktop 70000x768" "--desktop 1024X768" "--scale 600" "--scale 200,150" "--scale 200,"; do
		# shellcheck disable=SC2086
		run_probe --print-plan --app "$APP" --out "$NEVER" $bad
		OK=0
		[ "$RC" -eq 2 ] || OK=1
		[ "$(grep -c '^set ' "$TEST_DIR/stdout.txt" || true)" -eq 0 ] || OK=1
		# usage() prints to stdout (as it always has); the refusal itself names the option on stderr.
		grep -q 'Usage:' "$TEST_DIR/stdout.txt" || OK=1
		grep -q -- "${bad%% *}" "$TEST_DIR/stderr.txt" || OK=1
		{
			printf 'rc=%s\n--- stdout ---\n' "$RC"
			cat "$TEST_DIR/stdout.txt"
			printf -- '--- stderr ---\n'
			head -3 "$TEST_DIR/stderr.txt"
		} >"$TEST_DIR/bad.txt"
		check "$OK" "refuses $bad" "exit 2, option named on stderr, usage on stdout, no plan line" "$TEST_DIR/bad.txt"
	done

	# M1 (tool m-1, updated by gate r1-A m-4): --print-plan with --app/--out omitted must not open
	# a second code path through the (unchanged, single-implementation) plan. Gate r1-A m-4:
	# comparing the omitted run against `--app '' --out ''` is a tautology -- parse_args's
	# memset(cfg, 0, sizeof(*cfg)) already makes "omitted" and "supplied as empty string" the same
	# program state, so that diff is empty by construction and pins nothing. The comparison that
	# actually carries information is against a NON-EMPTY --app: the two runs must differ in
	# exactly the FreeRDP_RemoteApplicationProgram line and nothing else.
	run_probe --print-plan --host h --user u --desktop 2560x1440 --scale 200
	RC_OMITTED="$RC"
	cp "$TEST_DIR/stdout.txt" "$TEST_DIR/m1-omitted.txt"
	run_probe --print-plan --host h --user u --desktop 2560x1440 --scale 200 --app "$APP" --out "$NEVER"
	OK=0
	[ "$RC_OMITTED" -eq 0 ] || OK=1
	[ "$RC" -eq 0 ] || OK=1
	[ ! -e "$NEVER" ] || OK=1
	diff "$TEST_DIR/m1-omitted.txt" "$TEST_DIR/stdout.txt" >"$TEST_DIR/m1.diff" || true
	CHANGED_LINES="$(grep -c '^[<>]' "$TEST_DIR/m1.diff" || true)"
	[ "$CHANGED_LINES" -eq 2 ] || OK=1
	grep -qF -- '< set FreeRDP_RemoteApplicationProgram = ""' "$TEST_DIR/m1.diff" || OK=1
	grep -qF -- "> set FreeRDP_RemoteApplicationProgram = \"$APP\"" "$TEST_DIR/m1.diff" || OK=1
	check "$OK" "print-plan without --app/--out" "exit 0 both ways; a non-empty --app/--out changes only the RemoteApplicationProgram line (gate r1-A m-4)" "$TEST_DIR/m1.diff"

	# I3a (gate r1-A I-3): --print-plan never reads --pass. probe_plan_print (the print sink fed
	# to probe_settings_plan) only ever reads item->{boolValue,uint32Value,stringValue} -- cfg->app
	# is the only cfg field the plan touches at all -- and main()'s one cfg->pass read
	# (FreeRDP_Password) sits on the connect path, after the --print-plan branch has already
	# returned. WIN_PASS entirely absent from the environment (run_probe_no_pass, not even ""),
	# host/user given on argv, must be exit 0 with the SAME plan the fixture-WIN_PASS M1 run above
	# produces for the identical arguments -- not just "some" 12-line plan.
	run_probe_no_pass --print-plan --host h --user u --desktop 2560x1440 --scale 200
	OK=0
	[ "$RC" -eq 0 ] || OK=1
	if diff -u "$TEST_DIR/m1-omitted.txt" "$TEST_DIR/stdout.txt" >"$TEST_DIR/i3a.diff"; then :; else OK=1; fi
	check "$OK" "print-plan without WIN_PASS at all" "exit 0; byte-identical to the same args with a fixture WIN_PASS (M1's omitted run)" "$TEST_DIR/i3a.diff"

	# I3b (gate r1-A I-3): --print-plan missing only --host (--user IS supplied) must name --host
	# alone in the refusal -- not --user (present), and not --pass (no longer required at all, per
	# I3a). This is the shape m-1 was originally filed for (exit 2, can't tell what's actually
	# missing), reproduced one flag later by the old fixed "--host/--user" text, which used to fire
	# even when both were present and only --pass (now removed from this check) was absent.
	run_probe_bare --print-plan --user u
	OK=0
	[ "$RC" -eq 2 ] || OK=1
	grep -qx 'Missing required argument(s): --host (may come from WIN_HOST/WIN_USER env vars); --print-plan does not require --app/--out/--pass' "$TEST_DIR/stderr.txt" || OK=1
	{
		printf 'rc=%s\n--- stderr ---\n' "$RC"
		cat "$TEST_DIR/stderr.txt"
	} >"$TEST_DIR/i3b.txt"
	check "$OK" "print-plan missing only --host" "exit 2, names --host only (not --user, not --pass)" "$TEST_DIR/i3b.txt"

	# M2 (gate r1-A I-3 fold): without --print-plan, a missing --app is still refused (exit 2), but
	# the message text changed: it now names exactly the flags that are actually absent (here, just
	# --app -- --host/--user/--out are all supplied) instead of the old fixed
	# "--host/--user/--app/--out" list, which used to fire even when three of those four were
	# present. Rationale for the changed expected string: same I-3 reorg as I3b above, applied to
	# the connect-path check too (controller ruling: "两种模式各自的提示都要有用例").
	run_probe --host h --user u --out "$NEVER"
	OK=0
	[ "$RC" -eq 2 ] || OK=1
	grep -qx 'Missing required argument(s): --app (host/user/pass may come from WIN_HOST/WIN_USER/WIN_PASS env vars; pass is env-only, there is no --pass flag)' "$TEST_DIR/stderr.txt" || OK=1
	grep -q 'Usage:' "$TEST_DIR/stdout.txt" || OK=1
	{
		printf 'rc=%s\n--- stdout ---\n' "$RC"
		cat "$TEST_DIR/stdout.txt"
		printf -- '--- stderr ---\n'
		head -3 "$TEST_DIR/stderr.txt"
	} >"$TEST_DIR/m2.txt"
	check "$OK" "missing --app without --print-plan" "exit 2, message now names only --app (gate r1-A I-3 reorg; was a fixed --host/--user/--app/--out list)" "$TEST_DIR/m2.txt"
fi

echo "== summary =="
printf 'failures=%s not_run=%s\n' "$FAILURES" "$NOT_RUN"
[ "$FAILURES" -eq 0 ]
