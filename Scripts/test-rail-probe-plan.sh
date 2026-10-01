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
# R-6 lane G (adr/0019 §2 row G) added --reconnect-leg <a>,<g>: one run, two connections, each on
# a NEW client context, one --out file. S3-S6 below hold the structure that knob must not break
# (one textual copy of the lifecycle, in order; no same-context reconnect entry point; the frozen
# JSONL event-name set; one leg-line print point, after the plan's). P6-P8 and I8-I16 hold its plan
# line and its grammar.
#
# Lane LB-1 (ADR-0021 L-B) turned the refusal of --reconnect-leg next to --second-exec into an
# accepted combination: the second ClientExecute is sent in leg 1 only (leg 2's fresh context starts
# with second_exec_sent already true, so the one send point never fires there), and the leg line
# then ends in " second-exec=leg1-only" -- without --second-exec it is byte-identical to before
# (P6-P7, I8-I16, I30-I31 unchanged). X1-X2 pin the accepted plan path in both argument orders; S8
# pins the leg-1-only structure. The connect path's acceptance cannot be tested offline (it dials):
# only an online batch can show it. Gate r1 I-1 fold: leg 1 must outlast --second-delay (the send
# waits that long from leg 1's ConnectSucceeded), so the pair is refused when leg1_seconds <=
# second_delay, default delay 8 included; X3-X9 pin the refusal, its boundary and the untouched
# cases, and S8 pins that the refusal sits ahead of the --print-plan branch.
#
# The seconds knobs (--duration, --second-delay) were bare atoi() until the lane that added
# parse_seconds_knob: "abc" ran as 0, "-5" as -5, "+10" and "25abc" as 10 and 25, all with exit 0.
# They now go through parse_decimal_field, the one field grammar each --reconnect-leg half uses
# too (ASCII digits, leading zeros normalise, --duration 1..3600, --second-delay 0..3600).
# I17-I29, P9-P16, M3 and M4 hold that grammar, the accepted values and the unchanged
# missing-value path; I8-I16, I30-I31 and P6-P8 hold it for --reconnect-leg (I30-I31, gate r1 I-1:
# the gap half's own sign and whitespace), and S7 holds the structure behind "one grammar" -- each
# of those parsers calls parse_decimal_field and none re-implements it.
#
# Gate r1 B-1/B-2 fold: the checks above did not catch two ways to make "a second leg" mean "the
# same leg, reused" -- reusing leg 1's client context for leg 2 (B-1), and copying cross-leg state
# (the mutex, the run clock, the g_probe pointer, the only-after-a-clean-timer gate into leg 2) by
# value instead of carrying it by reference (B-2). S4 now also pins that context creation sits
# inside the leg loop and that the matching free runs exactly once, before the inter-leg gap
# sleep; S3 now also pins that probeRun has exactly one by-value home, that the mutex and the run
# clock are each initialised exactly once (before leg 1's --out fopen), that every leg re-points
# g_probe at its OWN context, and that leg 2 only starts when leg 1's own timer ended it cleanly.
#
# Two kinds of case, same split as Scripts/test-lab-boundary.sh's rail-probe section:
#   * SOURCE PINS (S1-S8) run always and hold the structural claims -- ONE implementation
#     (probe_settings_plan) feeds both the connect path and --print-plan, so a settings write that
#     bypasses it is visible as a changed count of freerdp_settings_set_ call sites; and a second
#     leg is the same lifecycle text run twice, never a second path; and every numeric knob in
#     S7's scope parses through the one field grammar; and the second launch of a two-leg run
#     happens in leg 1 only (S8). Tier 1 runs this suite
#     (.github/workflows/tier1.yml, step "rail-probe plan source pins") and requires exactly eight
#     `PASS  S<n>` lines and no FAIL.
#   * BINARY CASES run when Tools/rail-probe/build/rail-probe exists and is newer than its source;
#     they need cmake and a FreeRDP prefix, which Tier 1 does not have (a missing binary is a NOTE,
#     never a silent pass; Tier 1 accepts that NOTE and still requires the eight source pins). Tier 2
#     (.github/workflows/tier2.yml, step "rail-probe plan suite (source pins + binary cases)") does
#     build the binary and requires all 63 to PASS with `not_run=0`. No case
#     here can open a socket: every case that gets past parse_args' missing-argument check runs on
#     the --print-plan path, which exits before any FreeRDP context exists (S6). Since lane LB-1 no
#     connect-path case gets that far: the one that did (X2, a refusal) became a plan-path case,
#     because an accepted connect path would dial. The fixture credentials are the
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
# S1. Every freerdp_settings_set_ call site in rail-probe.c, by construction: three inside the plan's
# apply sink (bool / uint32 / string), three for the credential trio in main's leg loop (one
# textual copy serves both legs of --reconnect-leg), one for DeactivateClientDecoding in
# probe_post_connect (written when --decode is absent). A new site anywhere else means a setting is
# applied outside the plan and --print-plan would no longer describe the connect path.
# Call sites only (the opening parenthesis): comments that name the function family do not count.
SET_SITES="$(grep -cE 'freerdp_settings_set_[a-z0-9]+\(' "$SRC" || true)"
[ "$SET_SITES" -eq 7 ] && OK=0 || OK=1
printf 'freerdp_settings_set_ call sites: %s (expected 7)\n' "$SET_SITES" >"$TEST_DIR/set-sites.txt"
check "$OK" "S1 one implementation" "7 freerdp_settings_set_ sites: 3 sink + 3 credentials + 1 decode" "$TEST_DIR/set-sites.txt"
# S2. The plan has exactly two consumers. A --reconnect-leg run does not call it again for leg 2:
# each leg's PreConnect applies it to that leg's own fresh context, and --print-plan prints it once.
PLAN_SITES="$(grep -c 'probe_settings_plan(' "$SRC" || true)"
[ "$PLAN_SITES" -eq 3 ] && OK=0 || OK=1
printf 'probe_settings_plan( occurrences: %s (expected 3: definition, pre_connect, --print-plan)\n' "$PLAN_SITES" >"$TEST_DIR/plan-sites.txt"
check "$OK" "S2 plan has two consumers" "definition + pre_connect + --print-plan" "$TEST_DIR/plan-sites.txt"

# Positions below are character offsets into the source folded onto one line, every whitespace
# run collapsed to a single space (the fold MacdowsAppTests' source pins use), so an ordering pin
# holds however a call is wrapped or indented. Needles are written with single spaces; `index` is
# POSIX awk and each needle's FIRST occurrence counts. FS is a newline, which the folded text no
# longer contains, so awk never splits the one long record into fields.
FOLDED="$TEST_DIR/rail-probe.folded"
tr -s '[:space:]' ' ' <"$SRC" >"$FOLDED"
fold_pos() {
	awk -F '\n' -v needle="$1" '{ print index($0, needle) }' "$FOLDED"
}
# fold_pos_lit (gate r1 B-1): fold_pos for needles that carry a backslash. `awk -v` processes escape
# sequences, so a needle's '\0' would reach awk as a NUL byte (macOS awk truncates the needle there,
# gawk and mawk keep it and then never match). ENVIRON passes the needle verbatim, as file_cnt does.
fold_pos_lit() {
	NEEDLE="$1" awk -F '\n' '{ print index($0, ENVIRON["NEEDLE"]) }' "$FOLDED"
}
# fold_cnt: how many times a needle occurs in the folded source. Only needed for needles that
# straddle a line break in rail-probe.c (grep -cF, which matches within one line, cannot see
# those); single-line needles below still use grep -cF directly, as S1/S4 already did.
fold_cnt() {
	awk -F '\n' -v needle="$1" '{ s = $0; n = 0; while ((i = index(s, needle)) > 0) { n++; s = substr(s, i + length(needle)) } print n + 0 }' "$FOLDED"
}

# S3 (R-6 lane G). The leg loop is ONE copy of the connection lifecycle: each call shape appears
# exactly once in rail-probe.c whether one leg runs or two, so a second leg written as a second
# path -- its own context creation, start or main-loop call, above main or below it -- is red here.
# Call shapes, not names: a doc comment naming freerdp_client_context_new is not a call. And the
# copy is in lifecycle order -- context, then the --out fopen, then start, then the main loop --
# which the socket-free note in the header relies on for any future connect-path case.
S3_OK=0
S3_WHY=""
: >"$TEST_DIR/s3.txt"
for shape in '= freerdp_client_context_new(&entryPoints)' 'fopen(cfg.out_path' 'freerdp_client_start(context)' 'probe_main_loop(context->instance'; do
	n="$(grep -cF -- "$shape" "$SRC" || true)"
	printf '%-44s occurrences %s (expected 1), folded offset %s\n' "$shape" "$n" "$(fold_pos "$shape")" >>"$TEST_DIR/s3.txt"
	[ "$n" -eq 1 ] || S3_OK=1
done
S3_CTX="$(fold_pos '= freerdp_client_context_new(&entryPoints)')"
S3_FOPEN="$(fold_pos 'fopen(cfg.out_path')"
S3_START="$(fold_pos 'freerdp_client_start(context)')"
S3_LOOP="$(fold_pos 'probe_main_loop(context->instance')"
[ "$S3_CTX" -gt 0 ] && [ "$S3_CTX" -lt "$S3_FOPEN" ] || S3_OK=1
[ "$S3_FOPEN" -lt "$S3_START" ] || S3_OK=1
[ "$S3_START" -lt "$S3_LOOP" ] || S3_OK=1

# (R-6 lane G fold, gate r1 B-2): cross-leg state is never copied by value. rail-probe.c:109 says
# so in a comment, and the mutations gate r1 filed as (vii)/(x)/(xi)/(xii)/(xiv) all pass every
# check above while breaking that promise, so it gets its own shapes here: probeRun has exactly
# one by-value home and exactly one pointer to it (legshape:b); the run-wide mutex and clock are
# each initialised exactly once, before leg 1's --out fopen (legshape:c1/c2); every leg re-points
# g_probe at ITS OWN context, in one folded string (legshape:d); and leg 2 only ever starts when
# leg 1's own timer ended it cleanly (legshape:e).
BYVAL="$(grep -cE '(^|[^A-Za-z0-9_])probeRun[[:space:]]+[A-Za-z_]' "$SRC" || true)"
PRUN_ASSIGN="$(grep -cF -- 'p->run = ' "$SRC" || true)"
PRUN_TARGET="$(grep -cF -- 'p->run = &run;' "$SRC" || true)"
{ [ "$BYVAL" -eq 1 ] && [ "$PRUN_ASSIGN" -eq 1 ] && [ "$PRUN_TARGET" -eq 1 ]; } || { S3_OK=1; S3_WHY="$S3_WHY legshape:b"; }
MUTEX_INIT_N="$(grep -cF -- 'pthread_mutex_init(' "$SRC" || true)"
CLOCK_N="$(grep -cF -- 'clock_gettime(CLOCK_MONOTONIC, &run.t0)' "$SRC" || true)"
{ [ "$MUTEX_INIT_N" -eq 1 ] && [ "$CLOCK_N" -eq 1 ]; } || { S3_OK=1; S3_WHY="$S3_WHY legshape:c1"; }
S3_IF1="$(fold_pos 'if (leg == 1) {')"
S3_MUTEX="$(fold_pos 'pthread_mutex_init(&run.log_lock, NULL);')"
S3_CLOCK="$(fold_pos 'clock_gettime(CLOCK_MONOTONIC, &run.t0);')"
{ [ "$S3_IF1" -gt 0 ] && [ "$S3_IF1" -lt "$S3_MUTEX" ] && [ "$S3_MUTEX" -lt "$S3_CLOCK" ] && [ "$S3_CLOCK" -lt "$S3_FOPEN" ]; } || { S3_OK=1; S3_WHY="$S3_WHY legshape:c2"; }
GPROBE_N="$(fold_cnt 'probeContext* p = (probeContext*)context; g_probe = p;')"
[ "$GPROBE_N" -eq 1 ] || { S3_OK=1; S3_WHY="$S3_WHY legshape:d"; }
TIMER_OK_N="$(grep -cF -- 'if (timer_elapsed && rc == 0)' "$SRC" || true)"
TIMER_STOP_N="$(grep -cF -- 'if (!timer_elapsed || rc != 0 || run.stop_requested)' "$SRC" || true)"
{ [ "$TIMER_OK_N" -eq 1 ] && [ "$TIMER_STOP_N" -eq 1 ]; } || { S3_OK=1; S3_WHY="$S3_WHY legshape:e"; }
{
	printf 'legshape:b probeRun byval declarations: %s (expected 1); p->run assignments: %s (expected 1, of which p->run = &run;: %s)\n' "$BYVAL" "$PRUN_ASSIGN" "$PRUN_TARGET"
	printf 'legshape:c1 pthread_mutex_init( occurrences: %s (expected 1); clock_gettime(...&run.t0) occurrences: %s (expected 1)\n' "$MUTEX_INIT_N" "$CLOCK_N"
	printf 'legshape:c2 folded offsets: if(leg==1) %s < mutex_init %s < clock_gettime %s < out=fopen %s\n' "$S3_IF1" "$S3_MUTEX" "$S3_CLOCK" "$S3_FOPEN"
	printf 'legshape:d "probeContext* p = (probeContext*)context; g_probe = p;" occurrences: %s (expected 1)\n' "$GPROBE_N"
	printf 'legshape:e timer-gated re-entry conditions: %s / %s (each expected 1)\n' "$TIMER_OK_N" "$TIMER_STOP_N"
} >>"$TEST_DIR/s3.txt"
S3_NAME="S3 one lifecycle copy, in order"
[ -z "$S3_WHY" ] || S3_NAME="S3${S3_WHY}"
check "$S3_OK" "$S3_NAME" "context_new / fopen(--out) / client_start / probe_main_loop: 1 each, in order; cross-leg state (mutex, clock, g_probe, timer gate) never copied by value" "$TEST_DIR/s3.txt"

# S4 (R-6 lane G). A reconnect is a NEW context, never the old one reconnected: the upstream
# same-context entry points are absent -- freerdp_reconnect skips PreConnect (so the plan) and
# replays the auto-reconnect cookie; freerdp_context_reset and the deprecated
# disconnect-before-reconnect restore a settings backup the product never uses -- and the probe's
# one connect call is still the one in probe_main_loop.
S4_SAME="$(grep -cE 'freerdp_reconnect|freerdp_context_reset|freerdp_disconnect_before_reconnect' "$SRC" || true)"
S4_CONNECT="$(grep -cF 'freerdp_connect(instance)' "$SRC" || true)"
printf 'same-context reconnect entry points: %s (expected 0)\nfreerdp_connect(instance): %s (expected 1)\n' "$S4_SAME" "$S4_CONNECT" >"$TEST_DIR/s4.txt"
OK=0
S4_WHY=""
[ "$S4_SAME" -eq 0 ] || OK=1
[ "$S4_CONNECT" -eq 1 ] || OK=1
# (R-6 lane G fold, gate r1 B-1): a reconnect is also a NEW context by CONSTRUCTION, not just by
# the absence of the entry points above -- context_new sits inside the leg loop, after its
# header (legshape:a1), and the matching free (with g_probe cleared alongside it) runs exactly
# once per run, before the inter-leg gap sleep (legshape:a2), so leg 2 can never start on leg 1's
# context.
S4_LOOP="$(fold_pos 'for (int leg = 1; leg <= legs; leg++) {')"
S4_CTX="$(fold_pos '= freerdp_client_context_new(&entryPoints)')"
{ [ "$S4_LOOP" -gt 0 ] && [ "$S4_LOOP" -lt "$S4_CTX" ]; } || { OK=1; S4_WHY="$S4_WHY legshape:a1"; }
S4_FREE_N="$(fold_cnt 'freerdp_client_context_free(context); g_probe = NULL;')"
S4_FREE="$(fold_pos 'freerdp_client_context_free(context); g_probe = NULL;')"
S4_SLEEP="$(fold_pos '(void)sleep(1);')"
{ [ "$S4_FREE_N" -eq 1 ] && [ "$S4_FREE" -lt "$S4_SLEEP" ]; } || { OK=1; S4_WHY="$S4_WHY legshape:a2"; }
{
	printf 'legshape:a1 folded offsets: leg-loop head %s < context_new %s\n' "$S4_LOOP" "$S4_CTX"
	printf 'legshape:a2 "freerdp_client_context_free(context); g_probe = NULL;" occurrences: %s (expected 1), folded offset %s < gap-sleep %s\n' "$S4_FREE_N" "$S4_FREE" "$S4_SLEEP"
} >>"$TEST_DIR/s4.txt"
S4_NAME="S4 no same-context reconnect"
[ -z "$S4_WHY" ] || S4_NAME="S4${S4_WHY}"
check "$OK" "$S4_NAME" "no reconnect/context-reset entry point; one freerdp_connect(instance); new context per leg, freed exactly once before the gap" "$TEST_DIR/s4.txt"

# S5 (R-6 lane G). The JSONL vocabulary is frozen -- the Tier 1 mirror of MacdowsCore's
# EmitterContractTests, which only Tier 2 runs. The knob adds no event: legs are told apart by the
# existing lifecycle lines (the second PreConnect is the leg boundary), because a new name decodes
# as .unknown in RailEventKind and reds that suite, whose fix lies outside this tool. Two measures,
# as that suite takes them: the raw count of the call token (the function's definition plus 41
# call sites, one of them the WindowCreate/WindowUpdate ternary), and the sorted names taken from
# each call's name argument, against the committed list.
EXPECTED_NAMES="$TEST_DIR/expected-names.txt"
cat >"$EXPECTED_NAMES" <<'NAMES'
ChannelConnected
ChannelDisconnected
CheckEventHandlesFailed
ClientRailServerStartCmd
CodecStats
ConnectFailed
ConnectSucceeded
DecodePathRefused
DurationElapsed
EventHandlesFailed
GfxCapsAdvertise
GfxCapsConfirm
GfxMapSurfaceToScaledWindow
GfxMapSurfaceToWindow
GfxResetGraphics
LogonErrorInfo
MonitoredDesktop
NonMonitoredDesktop
NotifyIconCreate
NotifyIconDelete
NotifyIconUpdate
PostConnect
PostDisconnect
PostFinalDisconnect
PreConnect
SecondExecBegin
SecondExecEnd
ServerExecuteResult
ServerGetAppIdResponse
ServerHandshake
ServerHandshakeEx
ServerLocalMoveSize
ServerMinMaxInfo
ServerSystemParam
ServerZOrderSync
VerifyCertificateEx
WaitFailed
WindowCachedIcon
WindowCreate
WindowDelete
WindowIcon
WindowUpdate
NAMES
S5_OCC="$(awk '{ n += gsub(/log_event[(]/, "&") } END { print n + 0 }' "$SRC")"
{ grep -o 'log_event(p, [^,]*' "$SRC" || true; } | { grep -oE '"[A-Za-z0-9]+"' || true; } | tr -d '"' | LC_ALL=C sort >"$TEST_DIR/s5-names.txt"
OK=0
[ "$S5_OCC" -eq 42 ] || OK=1
{
	printf 'log_event( occurrences: %s (expected 42 = definition + 41 call sites)\n' "$S5_OCC"
	diff -u "$EXPECTED_NAMES" "$TEST_DIR/s5-names.txt" || OK=1
} >"$TEST_DIR/s5.txt"
check "$OK" "S5 event vocabulary frozen" "42 log_event( occurrences; the 42 event names, verbatim" "$TEST_DIR/s5.txt"

# S6 (R-6 lane G). --print-plan's leg line has exactly one print point, and it sits after the
# plan's print call and before the first context is created -- that is, on the --print-plan
# branch, after every set line. The option itself is recognised in exactly one place.
S6_PRINT="$(grep -cF '"reconnect-leg leg1-seconds=' "$SRC" || true)"
S6_TOKEN="$(grep -cF 'strcmp(a, "--reconnect-leg")' "$SRC" || true)"
S6_PLAN="$(fold_pos 'probe_settings_plan(&cfg, probe_plan_print, stdout)')"
S6_LEG="$(fold_pos '"reconnect-leg leg1-seconds=')"
S6_CTX="$(fold_pos '= freerdp_client_context_new(&entryPoints)')"
printf 'leg-line print points: %s (expected 1)\noption token parsed: %s (expected 1)\nfolded offsets: plan print %s < leg line %s < first context %s\n' \
	"$S6_PRINT" "$S6_TOKEN" "$S6_PLAN" "$S6_LEG" "$S6_CTX" >"$TEST_DIR/s6.txt"
OK=0
[ "$S6_PRINT" -eq 1 ] || OK=1
[ "$S6_TOKEN" -eq 1 ] || OK=1
[ "$S6_PLAN" -gt 0 ] && [ "$S6_PLAN" -lt "$S6_LEG" ] || OK=1
[ "$S6_LEG" -lt "$S6_CTX" ] || OK=1
check "$OK" "S6 one leg-line print point" "printed once, after the plan's print call, before any context exists" "$TEST_DIR/s6.txt"

# S7 (seconds-knob lane, gate r1 I-1). One field grammar: --reconnect-leg (each half), --duration
# and --second-delay all parse through parse_decimal_field, and none of their parsers carries a
# copy of it -- an equivalent hand-written copy passes every binary case, so only the source can
# tell. Call shapes, not names: parse_seconds_knob's doc comment itself says "bare atoi()", so a
# name count would be red on a correct tree. Function bodies are cut from the folded source,
# signature to the first "return true; }" (each knob parser ends that way), which keeps the doc
# comment of the NEXT function out of them. Needles go through ENVIRON, not -v, so the '\0' in a
# needle reaches awk verbatim instead of as an escape.
#   grammar:leg / grammar:sec  parse_reconnect_leg_knob calls it twice (',' then '\0' terminator),
#                              parse_seconds_knob once ('\0'); grammar:total -- definition + those
#                              three, so no other function calls it (desktop/scale keep their own
#                              registered copies, below).
#   grammar:own                neither of those two bodies calls strtoul/strtol/atoi/isdigit itself.
#   convert                    strtoul( calls: 1 in parse_decimal_field + 2 each in
#                              parse_desktop_knob/parse_scale_knob (their private copies, registered
#                              for a later lane) = 5 in the file, none anywhere else; no atoi( call
#                              and no other converter (strtol/strtoll/strtoull/atol/atoll/sscanf).
#   sites / assign             each seconds knob is one refusal-guarded parse_seconds_knob call with
#                              its own field and range, and the defaults are the only other writes.
fold_body() {
	START="$1" awk -F '\n' '{ i = index($0, ENVIRON["START"]); if (i == 0) exit; s = substr($0, i); e = "return true; }"; j = index(s, e); if (j == 0) exit; printf "%s", substr(s, 1, j + length(e) - 1) }' "$FOLDED" >"$2"
}
file_cnt() {
	NEEDLE="$1" awk -F '\n' '{ n = ENVIRON["NEEDLE"]; s = $0; while ((i = index(s, n)) > 0) { c++; s = substr(s, i + length(n)) } } END { print c + 0 }' "$2"
}
call_cnt() {
	{ grep -oE "(^|[^A-Za-z0-9_])($1)[[:space:]]*[(][^)]" "$2" || true; } | wc -l | tr -d ' '
}
S7_OK=0
S7_WHY=""
fold_body 'static bool parse_decimal_field(' "$TEST_DIR/s7-field.txt"
fold_body 'static bool parse_reconnect_leg_knob(' "$TEST_DIR/s7-leg.txt"
fold_body 'static bool parse_seconds_knob(' "$TEST_DIR/s7-sec.txt"
fold_body 'static bool parse_desktop_knob(' "$TEST_DIR/s7-desktop.txt"
fold_body 'static bool parse_scale_knob(' "$TEST_DIR/s7-scale.txt"
S7_LEG_N="$(file_cnt 'parse_decimal_field(' "$TEST_DIR/s7-leg.txt")"
S7_LEG_A="$(file_cnt "parse_decimal_field(text, ',', " "$TEST_DIR/s7-leg.txt")"
S7_LEG_G="$(file_cnt "parse_decimal_field(comma + 1, '\\0', " "$TEST_DIR/s7-leg.txt")"
{ [ "$S7_LEG_N" -eq 2 ] && [ "$S7_LEG_A" -eq 1 ] && [ "$S7_LEG_G" -eq 1 ]; } || { S7_OK=1; S7_WHY="$S7_WHY grammar:leg"; }
S7_SEC_N="$(file_cnt 'parse_decimal_field(' "$TEST_DIR/s7-sec.txt")"
S7_SEC_S="$(file_cnt "parse_decimal_field(s, '\\0', " "$TEST_DIR/s7-sec.txt")"
{ [ "$S7_SEC_N" -eq 1 ] && [ "$S7_SEC_S" -eq 1 ]; } || { S7_OK=1; S7_WHY="$S7_WHY grammar:sec"; }
S7_TOTAL="$(file_cnt 'parse_decimal_field(' "$FOLDED")"
[ "$S7_TOTAL" -eq 4 ] || { S7_OK=1; S7_WHY="$S7_WHY grammar:total"; }
S7_OWN="$(cat "$TEST_DIR/s7-leg.txt" "$TEST_DIR/s7-sec.txt" >"$TEST_DIR/s7-own.txt"; call_cnt 'strtoul|strtol|atoi|isdigit' "$TEST_DIR/s7-own.txt")"
[ "$S7_OWN" -eq 0 ] || { S7_OK=1; S7_WHY="$S7_WHY grammar:own"; }
S7_STRTOUL_FILE="$(call_cnt 'strtoul' "$FOLDED")"
S7_STRTOUL_FIELD="$(call_cnt 'strtoul' "$TEST_DIR/s7-field.txt")"
S7_STRTOUL_COPIES="$(( $(call_cnt 'strtoul' "$TEST_DIR/s7-desktop.txt") + $(call_cnt 'strtoul' "$TEST_DIR/s7-scale.txt") ))"
S7_ATOI="$(call_cnt 'atoi' "$FOLDED")"
S7_OTHER="$(call_cnt 'strtol|strtoll|strtoull|atol|atoll|sscanf' "$FOLDED")"
{ [ "$S7_STRTOUL_FILE" -eq 5 ] && [ "$S7_STRTOUL_FIELD" -eq 1 ] && [ "$S7_STRTOUL_COPIES" -eq 4 ] && [ "$S7_ATOI" -eq 0 ] && [ "$S7_OTHER" -eq 0 ]; } || { S7_OK=1; S7_WHY="$S7_WHY convert"; }
S7_SD_SITE="$(file_cnt 'if (!parse_seconds_knob(argv[i], 0, 3600, &cfg->second_delay)) {' "$FOLDED")"
S7_DUR_SITE="$(file_cnt 'if (!parse_seconds_knob(argv[i], 1, 3600, &cfg->duration)) {' "$FOLDED")"
S7_SEC_TOTAL="$(file_cnt 'parse_seconds_knob(' "$FOLDED")"
{ [ "$S7_SD_SITE" -eq 1 ] && [ "$S7_DUR_SITE" -eq 1 ] && [ "$S7_SEC_TOTAL" -eq 3 ]; } || { S7_OK=1; S7_WHY="$S7_WHY sites"; }
S7_SD_ASSIGN="$(file_cnt 'cfg->second_delay =' "$FOLDED")"
S7_DUR_ASSIGN="$(file_cnt 'cfg->duration =' "$FOLDED")"
{ [ "$S7_SD_ASSIGN" -eq 1 ] && [ "$S7_DUR_ASSIGN" -eq 1 ]; } || { S7_OK=1; S7_WHY="$S7_WHY assign"; }
{
	printf 'grammar:leg parse_decimal_field( in parse_reconnect_leg_knob: %s (expected 2: ",", then "\\0" terminator: %s / %s)\n' "$S7_LEG_N" "$S7_LEG_A" "$S7_LEG_G"
	printf 'grammar:sec parse_decimal_field( in parse_seconds_knob: %s (expected 1, "\\0" terminator: %s)\n' "$S7_SEC_N" "$S7_SEC_S"
	printf 'grammar:total parse_decimal_field( in the file: %s (expected 4 = definition + 3 calls)\n' "$S7_TOTAL"
	printf 'grammar:own strtoul/strtol/atoi/isdigit calls in those two bodies: %s (expected 0)\n' "$S7_OWN"
	printf 'convert strtoul( calls: file %s (expected 5), parse_decimal_field %s (expected 1), desktop+scale copies %s (expected 4); atoi( calls %s, other converters %s (expected 0 each)\n' "$S7_STRTOUL_FILE" "$S7_STRTOUL_FIELD" "$S7_STRTOUL_COPIES" "$S7_ATOI" "$S7_OTHER"
	printf 'sites guarded seconds-knob calls: second-delay %s, duration %s (expected 1 each); parse_seconds_knob( total %s (expected 3)\n' "$S7_SD_SITE" "$S7_DUR_SITE" "$S7_SEC_TOTAL"
	printf 'assign cfg->second_delay = %s, cfg->duration = %s (expected 1 each: the defaults)\n' "$S7_SD_ASSIGN" "$S7_DUR_ASSIGN"
} >"$TEST_DIR/s7.txt"
S7_NAME="S7 one field grammar"
[ -z "$S7_WHY" ] || S7_NAME="S7${S7_WHY}"
check "$S7_OK" "$S7_NAME" "leg halves, --duration, --second-delay parse through parse_decimal_field only; no own copy, no atoi" "$TEST_DIR/s7.txt"

# S8 (lane LB-1, ADR-0021 L-B). --reconnect-leg with --second-exec sends the second ClientExecute in
# leg 1 only, through the one send point that already existed -- not through a second one, and not
# by a refusal. Call shapes on the folded source (S3's fold), each needle its exact expression:
#   assign  second_exec_sent is assigned in exactly two places: `p->second_exec_sent = (leg != 1);`
#           in main's leg loop, after the context is created and before freerdp_client_start, and
#           `p->second_exec_sent = true;` right after the send. `(leg == 1)`, a dropped leg-loop
#           write or a third write anywhere is red. Gate r1 m-1: `->second_exec_sent` occurs exactly
#           three times (the condition, the `= true` write, the leg-loop write) and its address is
#           never taken (`&p->second_exec_sent` 0), so a write through a pointer is red too.
#   send    `!p->second_exec_sent` occurs once, inside the send condition, which occurs once and sits
#           in probe_main_loop (before probe_leg_stop_signal, the next function), followed by the
#           one `probe_run_second_exec(p);` call and then the `= true` write.
#   refuse  the old refusal's wording ("cannot be combined") occurs nowhere.
#   plan    the leg line's suffix is printed once, by
#           `if (cfg.second_exec[0] != '\0' && fprintf(stdout, " second-exec=leg1-only") <= 0)`,
#           after the leg line's own print and before the first context exists; the quoted literal
#           occurs nowhere else.
#   window  (gate r1 I-1) the refusal of a leg 1 that cannot outlast --second-delay is one guarded
#           condition, `if (cfg->leg1_seconds > 0 && cfg->second_exec[0] != '\0' &&
#           cfg->leg1_seconds <= (uint32_t)cfg->second_delay)`, ahead of `if (cfg->print_plan)`, so
#           it covers the plan path and the connect path alike.
# Needles carrying '\0' go through fold_pos_lit / file_cnt (ENVIRON), never fold_pos (gate r1 B-1).
S8_OK=0
S8_WHY=""
S8_ASSIGN_ALL="$({ grep -oE 'second_exec_sent[[:space:]]*=[^=]' "$SRC" || true; } | wc -l | tr -d ' ')"
S8_ASSIGN_LEG="$(file_cnt 'p->second_exec_sent = (leg != 1);' "$FOLDED")"
S8_ASSIGN_TRUE="$(file_cnt 'p->second_exec_sent = true;' "$FOLDED")"
S8_CTX="$(fold_pos '= freerdp_client_context_new(&entryPoints)')"
S8_LEGPOS="$(fold_pos 'p->second_exec_sent = (leg != 1);')"
S8_START="$(fold_pos 'freerdp_client_start(context)')"
S8_ARROW="$(file_cnt '->second_exec_sent' "$FOLDED")"
S8_ADDR="$(file_cnt '&p->second_exec_sent' "$FOLDED")"
{ [ "$S8_ASSIGN_ALL" -eq 2 ] && [ "$S8_ASSIGN_LEG" -eq 1 ] && [ "$S8_ASSIGN_TRUE" -eq 1 ] && [ "$S8_ARROW" -eq 3 ] && [ "$S8_ADDR" -eq 0 ] && [ "$S8_CTX" -gt 0 ] && [ "$S8_CTX" -lt "$S8_LEGPOS" ] && [ "$S8_LEGPOS" -lt "$S8_START" ]; } || { S8_OK=1; S8_WHY="$S8_WHY assign"; }
S8_NOT_SENT="$(file_cnt '!p->second_exec_sent' "$FOLDED")"
S8_COND_SHAPE="if (p->cfg.second_exec[0] != '\\0' && !p->second_exec_sent && p->rail &&"
S8_COND="$(file_cnt "$S8_COND_SHAPE" "$FOLDED")"
S8_CALL="$(file_cnt 'probe_run_second_exec(p);' "$FOLDED")"
S8_LOOP="$(fold_pos 'static DWORD probe_main_loop(')"
S8_CONDPOS="$(fold_pos_lit "$S8_COND_SHAPE")"
S8_CALLPOS="$(fold_pos 'probe_run_second_exec(p);')"
S8_TRUEPOS="$(fold_pos 'p->second_exec_sent = true;')"
S8_NEXT="$(fold_pos 'static void probe_leg_stop_signal(')"
{ [ "$S8_NOT_SENT" -eq 1 ] && [ "$S8_COND" -eq 1 ] && [ "$S8_CALL" -eq 1 ] && [ "$S8_LOOP" -gt 0 ] && [ "$S8_LOOP" -lt "$S8_CONDPOS" ] && [ "$S8_CONDPOS" -lt "$S8_CALLPOS" ] && [ "$S8_CALLPOS" -lt "$S8_TRUEPOS" ] && [ "$S8_TRUEPOS" -lt "$S8_NEXT" ]; } || { S8_OK=1; S8_WHY="$S8_WHY send"; }
S8_REFUSE="$(grep -cF 'cannot be combined' "$SRC" || true)"
[ "$S8_REFUSE" -eq 0 ] || { S8_OK=1; S8_WHY="$S8_WHY refuse"; }
S8_PLAN_SHAPE="if (cfg.second_exec[0] != '\\0' && fprintf(stdout, \" second-exec=leg1-only\") <= 0)"
S8_PLAN="$(file_cnt "$S8_PLAN_SHAPE" "$FOLDED")"
S8_LITERAL="$(file_cnt '" second-exec=leg1-only"' "$FOLDED")"
S8_PLANPOS="$(fold_pos_lit "$S8_PLAN_SHAPE")"
S8_LEGLINE="$(fold_pos '"reconnect-leg leg1-seconds=')"
{ [ "$S8_PLAN" -eq 1 ] && [ "$S8_LITERAL" -eq 1 ] && [ "$S8_LEGLINE" -gt 0 ] && [ "$S8_LEGLINE" -lt "$S8_PLANPOS" ] && [ "$S8_PLANPOS" -lt "$S8_CTX" ]; } || { S8_OK=1; S8_WHY="$S8_WHY plan"; }
S8_WIN_SHAPE="if (cfg->leg1_seconds > 0 && cfg->second_exec[0] != '\\0' && cfg->leg1_seconds <= (uint32_t)cfg->second_delay)"
S8_WIN="$(file_cnt "$S8_WIN_SHAPE" "$FOLDED")"
S8_WINPOS="$(fold_pos_lit "$S8_WIN_SHAPE")"
S8_PPBRANCH="$(fold_pos 'if (cfg->print_plan)')"
{ [ "$S8_WIN" -eq 1 ] && [ "$S8_WINPOS" -gt 0 ] && [ "$S8_WINPOS" -lt "$S8_PPBRANCH" ]; } || { S8_OK=1; S8_WHY="$S8_WHY window"; }
{
	printf 'assign second_exec_sent writes: %s (expected 2); leg-loop (leg != 1) %s, after-send true %s (expected 1 each); ->second_exec_sent %s (expected 3), &p->second_exec_sent %s (expected 0); folded offsets: context %s < leg-loop write %s < start %s\n' "$S8_ASSIGN_ALL" "$S8_ASSIGN_LEG" "$S8_ASSIGN_TRUE" "$S8_ARROW" "$S8_ADDR" "$S8_CTX" "$S8_LEGPOS" "$S8_START"
	printf 'send !p->second_exec_sent %s, send condition %s, probe_run_second_exec(p); %s (expected 1 each); folded offsets: probe_main_loop %s < condition %s < call %s < true %s < probe_leg_stop_signal %s\n' "$S8_NOT_SENT" "$S8_COND" "$S8_CALL" "$S8_LOOP" "$S8_CONDPOS" "$S8_CALLPOS" "$S8_TRUEPOS" "$S8_NEXT"
	printf 'refuse "cannot be combined": %s (expected 0)\n' "$S8_REFUSE"
	printf 'plan guarded suffix print %s, quoted literal %s (expected 1 each); folded offsets: leg line %s < suffix %s < first context %s\n' "$S8_PLAN" "$S8_LITERAL" "$S8_LEGLINE" "$S8_PLANPOS" "$S8_CTX"
	printf 'window leg-1-outlasts-delay refusal %s (expected 1); folded offsets: refusal %s < --print-plan branch %s\n' "$S8_WIN" "$S8_WINPOS" "$S8_PPBRANCH"
} >"$TEST_DIR/s8.txt"
S8_NAME="S8 second exec in leg 1 only"
[ -z "$S8_WHY" ] || S8_NAME="S8${S8_WHY}"
check "$S8_OK" "$S8_NAME" "one send point; leg 2 starts sent; no pair refusal; plan suffix only with --second-exec; leg 1 must outlast the delay" "$TEST_DIR/s8.txt"

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

	# ---- R-6 lane G: --reconnect-leg <a>,<g> ----
	LEG_LINE_20_5='reconnect-leg leg1-seconds=20 gap-seconds=5 leg2-seconds=25 context=new settings=same'

	# P6: the knob appends exactly one line after the eight settings -- the leg line, carrying both
	# knob values and --duration's default for leg 2 -- and nothing else; exit 0; no JSONL.
	{ cat "$EXPECTED_BASE"; printf '%s\n' "$LEG_LINE_20_5"; } >"$TEST_DIR/expected-p6.txt"
	run_probe --print-plan --app "$APP" --out "$NEVER" --reconnect-leg 20,5
	if diff -u "$TEST_DIR/expected-p6.txt" "$TEST_DIR/stdout.txt" >"$TEST_DIR/p6.diff"; then OK=0; else OK=1; fi
	[ "$RC" -eq 0 ] || OK=1
	[ ! -e "$NEVER" ] || OK=1
	check "$OK" "plan with --reconnect-leg" "the eight settings + one leg line, verbatim; exit 0; no JSONL created" "$TEST_DIR/p6.diff"

	# P7: both knob pairs and the leg knob, given in an order unlike the output's -> desktop pair,
	# scale pair, then the leg line last. Leading zeros normalise (030,00 prints 30 and 0) and
	# --duration becomes leg 2's seconds.
	{ cat "$EXPECTED_BASE"; printf 'set FreeRDP_DesktopWidth = 1280\nset FreeRDP_DesktopHeight = 720\nset FreeRDP_DesktopScaleFactor = 150\nset FreeRDP_DeviceScaleFactor = 140\nreconnect-leg leg1-seconds=30 gap-seconds=0 leg2-seconds=40 context=new settings=same\n'; } >"$TEST_DIR/expected-p7.txt"
	run_probe --print-plan --reconnect-leg 030,00 --app "$APP" --scale 150,140 --duration 40 --out "$NEVER" --desktop 1280x720
	if diff -u "$TEST_DIR/expected-p7.txt" "$TEST_DIR/stdout.txt" >"$TEST_DIR/p7.diff"; then OK=0; else OK=1; fi
	[ "$RC" -eq 0 ] || OK=1
	check "$OK" "leg line after both knob pairs" "desktop pair, scale pair, leg line last; 030,00 prints 30/0; --duration 40 is leg 2's" "$TEST_DIR/p7.diff"

	# P8: relative, independent of the heredocs: against the same arguments without the knob (the
	# twelve-line two-pair plan), the knob changes exactly one line -- one added, none removed --
	# and that line is the leg line, printed last; the set lines stay twelve.
	run_probe --print-plan --app "$APP" --desktop 2560x1440 --scale 200
	RC_WITHOUT="$RC"
	cp "$TEST_DIR/stdout.txt" "$TEST_DIR/p8-without.txt"
	run_probe --print-plan --app "$APP" --desktop 2560x1440 --scale 200 --reconnect-leg 20,5
	OK=0
	[ "$RC_WITHOUT" -eq 0 ] || OK=1
	[ "$RC" -eq 0 ] || OK=1
	diff "$TEST_DIR/p8-without.txt" "$TEST_DIR/stdout.txt" >"$TEST_DIR/p8.diff" || true
	[ "$(grep -c '^[<>]' "$TEST_DIR/p8.diff" || true)" -eq 1 ] || OK=1
	grep -qxF -- "> $LEG_LINE_20_5" "$TEST_DIR/p8.diff" || OK=1
	[ "$(tail -1 "$TEST_DIR/stdout.txt")" = "$LEG_LINE_20_5" ] || OK=1
	[ "$(grep -c '^set ' "$TEST_DIR/stdout.txt" || true)" -eq 12 ] || OK=1
	check "$OK" "leg knob adds exactly one line" "vs the same args without it: one '>' line, the leg line, last; 12 set lines" "$TEST_DIR/p8.diff"

	# I8..I16: the leg knob's grammar is as strict as --scale's, with both halves required (a 1..3600,
	# g 0..3600): out of range, a missing half, a trailing comma, a third field, a sign and hex are
	# each refused -- exit 2, the grammar refusal naming the option on stderr, usage on stdout, and
	# no plan line of either kind on stdout. I30/I31 (gate r1 I-1): the gap half's own sign and
	# leading whitespace -- I15 only signs the first half, so a gap half parsed outside
	# parse_decimal_field could take "+5" and stay green. Each value is passed as one argument, so
	# the one with a space survives as itself.
	for val in "0,5" "3601,5" "20,3601" "20" "20," ",5" "20,5,1" "+20,5" "20,0x5" "20,+5" "20, 5"; do
		bad="--reconnect-leg $val"
		run_probe --print-plan --app "$APP" --out "$NEVER" --reconnect-leg "$val"
		OK=0
		[ "$RC" -eq 2 ] || OK=1
		[ "$(grep -c '^set ' "$TEST_DIR/stdout.txt" || true)" -eq 0 ] || OK=1
		[ "$(grep -c '^reconnect-leg ' "$TEST_DIR/stdout.txt" || true)" -eq 0 ] || OK=1
		grep -q 'Usage:' "$TEST_DIR/stdout.txt" || OK=1
		grep -qF -- "Invalid value for ${bad%% *}:" "$TEST_DIR/stderr.txt" || OK=1
		{
			printf 'rc=%s\n--- stdout ---\n' "$RC"
			cat "$TEST_DIR/stdout.txt"
			printf -- '--- stderr ---\n'
			head -3 "$TEST_DIR/stderr.txt"
		} >"$TEST_DIR/bad.txt"
		check "$OK" "refuses $bad" "exit 2, grammar refusal names the option, usage on stdout, no plan line" "$TEST_DIR/bad.txt"
	done

	# X1/X2 (lane LB-1, ADR-0021 L-B): --reconnect-leg with --second-exec is accepted, in either
	# argument order. The plan is the eight settings plus the leg line ending in
	# " second-exec=leg1-only" (the second launch happens in leg 1 only); exit 0, stderr empty, no
	# --out file. Both cases run on the --print-plan path: the connect path's acceptance would dial,
	# so it cannot be tested offline and is left to an online batch (S8 pins its structure).
	SECOND='C:\Windows\System32\notepad.exe'
	{ cat "$EXPECTED_BASE"; printf 'reconnect-leg leg1-seconds=20 gap-seconds=5 leg2-seconds=25 context=new settings=same second-exec=leg1-only\n'; } >"$TEST_DIR/expected-x.txt"
	for order in leg-first exec-first; do
		if [ "$order" = leg-first ]; then
			run_probe --print-plan --app "$APP" --out "$NEVER" --reconnect-leg 20,5 --second-exec "$SECOND"
		else
			run_probe --print-plan --second-exec "$SECOND" --reconnect-leg 20,5 --app "$APP" --out "$NEVER"
		fi
		OK=0
		diff -u "$TEST_DIR/expected-x.txt" "$TEST_DIR/stdout.txt" >"$TEST_DIR/x.diff" || OK=1
		[ "$RC" -eq 0 ] || OK=1
		[ ! -s "$TEST_DIR/stderr.txt" ] || OK=1
		[ ! -e "$NEVER" ] || OK=1
		{
			printf 'rc=%s\n--- stderr ---\n' "$RC"
			head -3 "$TEST_DIR/stderr.txt"
			cat "$TEST_DIR/x.diff"
		} >"$TEST_DIR/x.txt"
		check "$OK" "leg + --second-exec accepted ($order)" "exit 0, stderr empty, base + leg line ending second-exec=leg1-only, no JSONL" "$TEST_DIR/x.txt"
	done

	# X3-X5 (gate r1 I-1): with --second-exec, leg 1 must outlast --second-delay, or the second launch
	# is never sent (leg 1 shorter) or lands on the very disconnect (equal). Refused on the plan path
	# like any knob error: exit 2, stderr exactly one line naming both values, usage on stdout, no
	# plan line of either kind, no --out file. X3 is the equality boundary under the DEFAULT delay
	# (8, never passed), X4 an explicit equal delay, X5 a shorter leg 1 in reversed argument order.
	for bad in "8|8|--reconnect-leg 8,5 --second-exec SECOND" "5|5|--reconnect-leg 5,5 --second-exec SECOND --second-delay 5" "3|10|--second-delay 10 --second-exec SECOND --reconnect-leg 3,0"; do
		want_leg="${bad%%|*}"
		rest="${bad#*|}"
		want_delay="${rest%%|*}"
		argline="${rest#*|}"
		set -f
		# shellcheck disable=SC2206
		args=($argline)
		set +f
		for i in "${!args[@]}"; do
			[ "${args[$i]}" != SECOND ] || args[i]="$SECOND"
		done
		run_probe --print-plan --app "$APP" --out "$NEVER" "${args[@]}"
		OK=0
		[ "$RC" -eq 2 ] || OK=1
		[ "$(grep -c '' "$TEST_DIR/stderr.txt" || true)" -eq 1 ] || OK=1
		grep -qxF -- "--reconnect-leg leg 1 ($want_leg s) must exceed --second-delay ($want_delay s) when --second-exec is set" "$TEST_DIR/stderr.txt" || OK=1
		grep -q 'Usage:' "$TEST_DIR/stdout.txt" || OK=1
		[ "$(grep -c -e '^set ' -e '^reconnect-leg ' "$TEST_DIR/stdout.txt" || true)" -eq 0 ] || OK=1
		[ ! -e "$NEVER" ] || OK=1
		{
			printf 'rc=%s\n--- stdout (plan lines only) ---\n' "$RC"
			grep -e '^set ' -e '^reconnect-leg ' "$TEST_DIR/stdout.txt" || true
			printf -- '--- stderr ---\n'
			head -3 "$TEST_DIR/stderr.txt"
		} >"$TEST_DIR/bad.txt"
		check "$OK" "refuses leg 1 $want_leg s <= delay $want_delay s" "exit 2, one stderr line naming both values, usage on stdout, no plan line, no JSONL" "$TEST_DIR/bad.txt"
	done

	# X6-X9 (gate r1 I-1): the boundary's accepting side and the untouched cases. X6: 9,5 under the
	# default delay 8 (one second over); X7: 1,0 with --second-delay 0 -- both print the leg1-only
	# suffix. X8: no --second-exec at all, X9: --second-exec '' (absent, as before) -- neither is
	# refused however short leg 1 is, and both print the leg line without the suffix, byte for byte
	# as before this lane. Each: exit 0, stderr empty, no --out file.
	for good in "9|5|second-exec=leg1-only|--reconnect-leg 9,5 --second-exec SECOND" "1|0|second-exec=leg1-only|--reconnect-leg 1,0 --second-exec SECOND --second-delay 0" "3|5||--reconnect-leg 3,5 --second-delay 10" "3|5||--reconnect-leg 3,5 --second-exec EMPTY"; do
		g_leg="${good%%|*}"
		rest="${good#*|}"
		g_gap="${rest%%|*}"
		rest="${rest#*|}"
		g_suffix="${rest%%|*}"
		argline="${rest#*|}"
		set -f
		# shellcheck disable=SC2206
		args=($argline)
		set +f
		for i in "${!args[@]}"; do
			[ "${args[$i]}" != SECOND ] || args[i]="$SECOND"
			[ "${args[$i]}" != EMPTY ] || args[i]=""
		done
		{
			cat "$EXPECTED_BASE"
			if [ -n "$g_suffix" ]; then
				printf 'reconnect-leg leg1-seconds=%s gap-seconds=%s leg2-seconds=25 context=new settings=same %s\n' "$g_leg" "$g_gap" "$g_suffix"
			else
				printf 'reconnect-leg leg1-seconds=%s gap-seconds=%s leg2-seconds=25 context=new settings=same\n' "$g_leg" "$g_gap"
			fi
		} >"$TEST_DIR/expected-x.txt"
		run_probe --print-plan --app "$APP" --out "$NEVER" "${args[@]}"
		OK=0
		diff -u "$TEST_DIR/expected-x.txt" "$TEST_DIR/stdout.txt" >"$TEST_DIR/x.diff" || OK=1
		[ "$RC" -eq 0 ] || OK=1
		[ ! -s "$TEST_DIR/stderr.txt" ] || OK=1
		[ ! -e "$NEVER" ] || OK=1
		{
			printf 'rc=%s\n--- stderr ---\n' "$RC"
			head -3 "$TEST_DIR/stderr.txt"
			cat "$TEST_DIR/x.diff"
		} >"$TEST_DIR/x.txt"
		check "$OK" "accepts $argline" "exit 0, stderr empty, base + leg line${g_suffix:+ ending $g_suffix}, no JSONL" "$TEST_DIR/x.txt"
	done

	# ---- seconds knobs: --duration and --second-delay (parse_seconds_knob) ----

	# I17..I29: out-of-grammar values are refused, the way --desktop/--scale/--reconnect-leg refuse
	# theirs: exit 2, stderr is exactly ONE line and that line is the full refusal naming the option
	# and quoting the value, usage on stdout, and no plan line of either kind on stdout (parse_args
	# returned before the plan was reached). Each entry is "<option>|<value>", so the empty value
	# and one with a leading space survive as themselves. ' 25' pins that leading whitespace (which
	# atoi and strtoul both skip) is refused; 4294967321 is 2^32 + 25, which a 32-bit wrap would
	# turn into 25.
	for bad in "--duration|abc" "--duration|-5" "--duration|+10" "--duration|0" "--duration|3601" "--duration|25abc" "--duration|" "--duration| 25" "--duration|4294967321" "--second-delay|abc" "--second-delay|-1" "--second-delay|+8" "--second-delay|3601"; do
		opt="${bad%%|*}"
		val="${bad#*|}"
		want='0..3600'
		[ "$opt" != "--duration" ] || want='1..3600'
		run_probe --print-plan --app "$APP" --out "$NEVER" "$opt" "$val"
		OK=0
		[ "$RC" -eq 2 ] || OK=1
		[ "$(grep -c '' "$TEST_DIR/stderr.txt" || true)" -eq 1 ] || OK=1
		grep -qxF -- "Invalid value for $opt: '$val' (want whole seconds $want)" "$TEST_DIR/stderr.txt" || OK=1
		grep -q 'Usage:' "$TEST_DIR/stdout.txt" || OK=1
		[ "$(grep -c -e '^set ' -e '^reconnect-leg ' "$TEST_DIR/stdout.txt" || true)" -eq 0 ] || OK=1
		{
			printf 'rc=%s\n--- stdout (plan lines only) ---\n' "$RC"
			grep -e '^set ' -e '^reconnect-leg ' "$TEST_DIR/stdout.txt" || true
			printf -- '--- stderr ---\n'
			head -3 "$TEST_DIR/stderr.txt"
		} >"$TEST_DIR/bad.txt"
		check "$OK" "refuses $opt '$val'" "exit 2, one stderr line: the refusal quoting the value; usage on stdout; no plan line" "$TEST_DIR/bad.txt"
	done

	# P9..P12: --duration 1, 25, 3600 and 010 are accepted. The plan's one field that carries
	# --duration is the leg line's leg2-seconds, so each case adds --reconnect-leg 20,5 and the
	# output must be the eight settings plus that line carrying the normalised value; exit 0,
	# nothing on stderr. Each entry is "<value>|<printed>": 010 prints 10, the leading zero
	# normalising as in P7's 030,00. (25 is also the default, so that case pins acceptance only.)
	for good in "1|1" "25|25" "3600|3600" "010|10"; do
		val="${good%%|*}"
		printed="${good#*|}"
		{ cat "$EXPECTED_BASE"; printf 'reconnect-leg leg1-seconds=20 gap-seconds=5 leg2-seconds=%s context=new settings=same\n' "$printed"; } >"$TEST_DIR/expected-dur.txt"
		run_probe --print-plan --app "$APP" --out "$NEVER" --reconnect-leg 20,5 --duration "$val"
		OK=0
		diff -u "$TEST_DIR/expected-dur.txt" "$TEST_DIR/stdout.txt" >"$TEST_DIR/good.diff" || OK=1
		[ "$RC" -eq 0 ] || OK=1
		[ ! -s "$TEST_DIR/stderr.txt" ] || OK=1
		{ printf 'rc=%s\n' "$RC"; head -3 "$TEST_DIR/stderr.txt"; cat "$TEST_DIR/good.diff"; } >"$TEST_DIR/good.txt"
		check "$OK" "accepts --duration $val" "exit 0, stderr empty; the leg line carries leg2-seconds=$printed" "$TEST_DIR/good.txt"
	done

	# P13..P16: --second-delay 0, 8, 3600 and 08 are accepted. No plan line carries --second-delay
	# (the plan lists pre-connect settings; only the main loop reads the delay), so what is
	# pinnable is exit 0, nothing on stderr, and a plan byte-identical to P1's.
	for good in 0 8 3600 08; do
		run_probe --print-plan --app "$APP" --out "$NEVER" --second-delay "$good"
		OK=0
		diff -u "$EXPECTED_BASE" "$TEST_DIR/stdout.txt" >"$TEST_DIR/good.diff" || OK=1
		[ "$RC" -eq 0 ] || OK=1
		[ ! -s "$TEST_DIR/stderr.txt" ] || OK=1
		{ printf 'rc=%s\n' "$RC"; head -3 "$TEST_DIR/stderr.txt"; cat "$TEST_DIR/good.diff"; } >"$TEST_DIR/good.txt"
		check "$OK" "accepts --second-delay $good" "exit 0, stderr empty; plan byte-identical to P1's" "$TEST_DIR/good.txt"
	done

	# M3: --duration as the last argument, with no value, still takes parse_args' missing-value path
	# (exit 2, stderr exactly "Missing value for --duration", usage on stdout, no plan line), not
	# the grammar refusal.
	run_probe --print-plan --app "$APP" --out "$NEVER" --duration
	OK=0
	[ "$RC" -eq 2 ] || OK=1
	[ "$(grep -c '' "$TEST_DIR/stderr.txt" || true)" -eq 1 ] || OK=1
	grep -qxF -- 'Missing value for --duration' "$TEST_DIR/stderr.txt" || OK=1
	grep -q 'Usage:' "$TEST_DIR/stdout.txt" || OK=1
	[ "$(grep -c -e '^set ' -e '^reconnect-leg ' "$TEST_DIR/stdout.txt" || true)" -eq 0 ] || OK=1
	{
		printf 'rc=%s\n--- stderr ---\n' "$RC"
		head -3 "$TEST_DIR/stderr.txt"
	} >"$TEST_DIR/m3.txt"
	check "$OK" "missing value for --duration" "exit 2, stderr exactly 'Missing value for --duration', usage on stdout, no plan line" "$TEST_DIR/m3.txt"

	# M4 (gate r1 m-2): the same for --second-delay, whose `goto missing` M3 does not reach -- without
	# it the parser would read argv[argc] (NULL) and refuse "(null)" as a grammar error instead.
	run_probe --print-plan --app "$APP" --out "$NEVER" --second-delay
	OK=0
	[ "$RC" -eq 2 ] || OK=1
	[ "$(grep -c '' "$TEST_DIR/stderr.txt" || true)" -eq 1 ] || OK=1
	grep -qxF -- 'Missing value for --second-delay' "$TEST_DIR/stderr.txt" || OK=1
	grep -q 'Usage:' "$TEST_DIR/stdout.txt" || OK=1
	[ "$(grep -c -e '^set ' -e '^reconnect-leg ' "$TEST_DIR/stdout.txt" || true)" -eq 0 ] || OK=1
	{
		printf 'rc=%s\n--- stderr ---\n' "$RC"
		head -3 "$TEST_DIR/stderr.txt"
	} >"$TEST_DIR/m4.txt"
	check "$OK" "missing value for --second-delay" "exit 2, stderr exactly 'Missing value for --second-delay', usage on stdout, no plan line" "$TEST_DIR/m4.txt"
fi

echo "== summary =="
printf 'failures=%s not_run=%s\n' "$FAILURES" "$NOT_RUN"
[ "$FAILURES" -eq 0 ]
