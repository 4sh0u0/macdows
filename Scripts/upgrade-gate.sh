#!/usr/bin/env bash
# upgrade-gate.sh: the one-command W2 upgrade gate driver.
#
# Answers one question: "if we move the FreeRDP pin (or any other dependency), does the
# RAIL/RDPGFX event stream the server produces still mean the same thing?" It does that in
# three phases, all of them offline:
#
#   1. LOCK    — record what is pinned right now (FreeRDP submodule commit, deps/freerdp.lock,
#                toolchain version), so a drill record can state which build the run describes.
#   2. REPLAY  — run the existing regression gate, Scripts/replay.sh, over the candidate
#                captures. This is the phase3 F-2 reading of M1's acceptance: "the existing
#                replay gate stays green", no expansion. This script deliberately *calls*
#                replay.sh rather than reimplementing it (M1 L5 MUST NOT: do not rewrite
#                Scripts/replay.sh or the replayer).
#   3. DIFF    — run Tools/replay-diff, the semantic differ, over baseline vs candidate and
#                classify every difference.
#
# WITH NO ARGUMENTS this runs the offline self-diff smoke: the frozen phase05 captures
# against themselves. That exercises the whole gate end-to-end without a host and is the
# form CI and a fresh checkout can run -- but a self-diff finds nothing by construction, so
# it is NOT an upgrade release. Deliverable (8)'s drill is only a real drill once
# --candidate points at a fresh, controlled re-record (phase3 §3 边界; owner checkpoint C-3).
#
# NO LIVE HOST, EVER. Unlike Scripts/probe.sh and Scripts/run-window-smoke.command, this
# script never dials anything, so it deliberately does NOT call crdp_assert_lab_boundary:
# there is no target address for the boundary gate to have an opinion about. It reads JSONL
# files and runs a local compiler. If a future phase wants this script to *produce* the
# candidate capture as well as diff it, that phase has to add the boundary gate first --
# the absence of the call here is a statement that nothing here touches a network, not an
# oversight.
#
# EVIDENCE AND RED LINES. Reports are written under .build/ (gitignored) rather than into
# the tree, so a run can never accidentally stage an artifact. replay-diff itself redacts
# certificate/host fields and never echoes a raw capture line, but its output is still a
# capture-derived artifact: read it before copying anything into a tracked drill record.
#
# Usage:
#   Scripts/upgrade-gate.sh [options]
#     --baseline DIR       Frozen reference captures (default: samples/phase05-rail-events-2026-08-19)
#     --candidate DIR      Captures to judge (default: the baseline -- the offline self-diff smoke)
#     --report-dir DIR     Where to write the artifacts (default: .build/upgrade-gate)
#     --format text|json   replay-diff output format for the saved report (default: text)
#     --order-tolerance N  Passed through to replay-diff: movement ACROSS producer lanes
#                          (default: its own, 2).
#     --lane-order-tolerance N
#                          Passed through to replay-diff: movement WITHIN one producer lane
#                          (default: its own, 0). This is the setting that decides whether
#                          "the server did B before A this time" is a finding, so it belongs
#                          on the gate rather than only behind the -- passthrough.
#     --skip-replay        Skip phase 2. For iterating on phase 3 only -- a real drill runs all three.
#                          Not a speed-up: phase 2's ReplayTests.zeroAnomalies is phase 3's
#                          backstop for the cross-lane reordering the differ tolerates by
#                          design (Tools/replay-diff/README.md, "Order: two tolerances").
#     --                   Everything after this is passed through to replay-diff verbatim.
#     -h, --help           This text.
#
# Exit codes: 0 gate passed, 1 gate failed (unexplained differences, or replay gate red),
#             2 the gate could not run.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

EXIT_OK=0
EXIT_GATE_FAILED=1
EXIT_CANNOT_RUN=2

DEFAULT_BASELINE_DIR="$CRDP_REPO_ROOT/samples/phase05-rail-events-2026-08-19"
DIFF_PACKAGE_DIR="$CRDP_REPO_ROOT/Tools/replay-diff"

BASELINE_DIR="$DEFAULT_BASELINE_DIR"
CANDIDATE_DIR=""
REPORT_DIR="$CRDP_BUILD_DIR/upgrade-gate"
FORMAT="text"
ORDER_TOLERANCE=""
LANE_ORDER_TOLERANCE=""
RUN_REPLAY=1
DIFF_PASSTHROUGH=()

usage() {
	cat <<'EOF'
upgrade-gate.sh -- the one-command W2 upgrade gate driver (offline; never dials a host).

  Scripts/upgrade-gate.sh [options]

    --baseline DIR       Frozen reference captures
                         (default: samples/phase05-rail-events-2026-08-19)
    --candidate DIR      Captures to judge (default: the baseline, i.e. the offline
                         self-diff smoke, which is NOT an upgrade release)
    --report-dir DIR     Artifact directory (default: .build/upgrade-gate)
    --format text|json   Saved diff report format (default: text)
    --order-tolerance N  Movement ACROSS producer lanes, passed to replay-diff
    --lane-order-tolerance N
                         Movement WITHIN one producer lane, passed to replay-diff.
                         Decides whether "the server did B before A this time" is a
                         finding; default 0 (a lane is one thread, its order is causal).
    --skip-replay        Skip the Scripts/replay.sh phase (iteration only). Gives up
                         ReplayTests.zeroAnomalies, phase 3's backstop for tolerated
                         cross-lane reordering.
    --                   Pass everything after this to replay-diff verbatim
    -h, --help           This text

  Phases: 1 build lock, 2 Scripts/replay.sh over the candidate, 3 Tools/replay-diff
  baseline-vs-candidate. Exit 0 passed, 1 failed, 2 could not run.
  See this file's header comment for the full rationale, and `replay-diff --legend`
  for the difference-class vocabulary.
EOF
}

# `die` from lib.sh exits 1, which this script reserves for "the gate ran and failed".
# A setup problem must be distinguishable from a red gate in a drill record.
cannot_run() {
	log "ERROR: $*"
	exit "$EXIT_CANNOT_RUN"
}

require_value() {
	# $1 = option name, $2 = number of arguments still available
	[ "$2" -ge 2 ] || cannot_run "$1 requires a value"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--baseline)
		require_value "$1" "$#"
		BASELINE_DIR="$2"
		shift 2
		;;
	--candidate)
		require_value "$1" "$#"
		CANDIDATE_DIR="$2"
		shift 2
		;;
	--report-dir)
		require_value "$1" "$#"
		REPORT_DIR="$2"
		shift 2
		;;
	--format)
		require_value "$1" "$#"
		FORMAT="$2"
		shift 2
		;;
	--order-tolerance)
		require_value "$1" "$#"
		ORDER_TOLERANCE="$2"
		shift 2
		;;
	--lane-order-tolerance)
		require_value "$1" "$#"
		LANE_ORDER_TOLERANCE="$2"
		shift 2
		;;
	--skip-replay)
		RUN_REPLAY=0
		shift
		;;
	--)
		shift
		while [ $# -gt 0 ]; do
			DIFF_PASSTHROUGH+=("$1")
			shift
		done
		;;
	-h | --help)
		usage
		exit "$EXIT_OK"
		;;
	*)
		cannot_run "unknown argument: $1 (see --help)"
		;;
	esac
done

case "$FORMAT" in
text | json) ;;
*) cannot_run "--format must be text or json, got: $FORMAT" ;;
esac
if [ -n "$ORDER_TOLERANCE" ]; then
	case "$ORDER_TOLERANCE" in
	'' | *[!0-9]*) cannot_run "--order-tolerance must be a non-negative integer, got: $ORDER_TOLERANCE" ;;
	esac
fi
if [ -n "$LANE_ORDER_TOLERANCE" ]; then
	case "$LANE_ORDER_TOLERANCE" in
	'' | *[!0-9]*) cannot_run "--lane-order-tolerance must be a non-negative integer, got: $LANE_ORDER_TOLERANCE" ;;
	esac
fi

require_cmd swift

[ -d "$BASELINE_DIR" ] || cannot_run "baseline directory does not exist: $BASELINE_DIR"
BASELINE_DIR="$(cd "$BASELINE_DIR" && pwd)"

SELF_DIFF=0
if [ -z "$CANDIDATE_DIR" ]; then
	CANDIDATE_DIR="$BASELINE_DIR"
	SELF_DIFF=1
else
	[ -d "$CANDIDATE_DIR" ] || cannot_run "candidate directory does not exist: $CANDIDATE_DIR"
	CANDIDATE_DIR="$(cd "$CANDIDATE_DIR" && pwd)"
	# A plain `[ … ] && SELF_DIFF=1` would be the last command of this branch, so under
	# `set -e` a *non*-self-diff run would exit here with status 1.
	if [ "$CANDIDATE_DIR" = "$BASELINE_DIR" ]; then
		SELF_DIFF=1
	fi
fi
SELF_DIFF_TEXT=no
if [ "$SELF_DIFF" -eq 1 ]; then
	SELF_DIFF_TEXT=yes
fi

mkdir -p "$REPORT_DIR" || cannot_run "cannot create report directory: $REPORT_DIR"
REPORT_DIR="$(cd "$REPORT_DIR" && pwd)"

log "baseline : $BASELINE_DIR"
log "candidate: $CANDIDATE_DIR"
log "reports  : $REPORT_DIR"
if [ "$SELF_DIFF" -eq 1 ]; then
	log "MODE: offline self-diff smoke -- the candidate IS the baseline."
	log "MODE: this exercises the gate end to end but finds nothing by construction;"
	log "MODE: it is NOT an upgrade release (phase3 §3 边界). Pass --candidate for a real drill."
fi

# ---------------------------------------------------------------------------
# Phase 1/3 -- build lock
# ---------------------------------------------------------------------------
# What the drill record needs in order to say which build the rest of the run describes.
# Everything here degrades to "unavailable" rather than failing: a contributor checkout
# without submodules must still be able to run the differ.
#
# The pin's identity, not the pin's prose: deps/freerdp.lock is several hundred lines of
# rationale, and copying it wholesale into every drill artifact would bury the four facts a
# drill record actually cites. The digest below is what makes that safe -- any edit to the
# lock, including one to a field not extracted here, changes it.
log "phase 1/3: recording the build lock"
LOCK_FILE="$REPORT_DIR/build-lock.txt"
FREERDP_LOCK="$CRDP_REPO_ROOT/deps/freerdp.lock"

digest_of() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		printf 'unavailable (no shasum/sha256sum)'
	fi
}

{
	printf 'swift              : %s\n' "$(swift --version 2>&1 | head -1)"
	if [ -f "$FREERDP_LOCK" ]; then
		# Top-level keys are the ones indented exactly two spaces; the nested blocks
		# (patches, cmake_config, ffmpeg, openssl) are deeper and stay out.
		printf 'freerdp.lock tag   : %s\n' "$(grep -E '^  "tag":' "$FREERDP_LOCK" | head -1 | sed -e 's/.*: *"//' -e 's/".*//')"
		printf 'freerdp.lock commit: %s\n' "$(grep -E '^  "commit":' "$FREERDP_LOCK" | head -1 | sed -e 's/.*: *"//' -e 's/".*//')"
		printf 'freerdp.lock sha256: %s\n' "$(digest_of "$FREERDP_LOCK")"
	else
		printf 'freerdp.lock       : unavailable\n'
	fi
	if git -C "$CRDP_REPO_ROOT/ThirdParty/FreeRDP" rev-parse HEAD >/dev/null 2>&1; then
		printf 'FreeRDP submodule  : %s\n' "$(git -C "$CRDP_REPO_ROOT/ThirdParty/FreeRDP" rev-parse HEAD)"
	else
		printf 'FreeRDP submodule  : unavailable (not initialised)\n'
	fi
	if [ -d "$CRDP_REPO_ROOT/ThirdParty/patches" ]; then
		printf 'patch queue        : %s patch(es)\n' \
			"$(find "$CRDP_REPO_ROOT/ThirdParty/patches" -maxdepth 1 -name '*.patch' | wc -l | tr -d ' ')"
	fi
	printf 'baseline captures  : %s\n' "$(basename "$BASELINE_DIR")"
	printf 'candidate captures : %s\n' "$(basename "$CANDIDATE_DIR")"
	printf 'self-diff smoke    : %s\n' "$SELF_DIFF_TEXT"
} >"$LOCK_FILE"
log "phase 1/3: wrote $LOCK_FILE"

# ---------------------------------------------------------------------------
# Phase 2/3 -- the existing replay regression gate
# ---------------------------------------------------------------------------
GATE_FAILED=0
if [ "$RUN_REPLAY" -eq 1 ]; then
	log "phase 2/3: replay regression gate (Scripts/replay.sh) over the candidate captures"
	set +e
	"$SCRIPT_DIR/replay.sh" "$CANDIDATE_DIR" >"$REPORT_DIR/replay.log" 2>&1
	replay_exit=$?
	set -e
	if [ "$replay_exit" -ne 0 ]; then
		GATE_FAILED=1
		log "phase 2/3: FAILED (exit $replay_exit) -- see $REPORT_DIR/replay.log"
		tail -20 "$REPORT_DIR/replay.log" >&2
	else
		log "phase 2/3: green ($REPORT_DIR/replay.log)"
	fi
else
	log "phase 2/3: SKIPPED (--skip-replay) -- a real drill must not skip this"
	# Name what was given up, not just that something was. Phase 2 is phase 3's backstop
	# for the one reorder class the differ tolerates by design: cross-lane movement inside
	# --order-tolerance. ReplayTests.zeroAnomalies catches the lifecycle-breaking subset of
	# that (an update/icon/delete for a window that does not exist yet) by replaying the
	# candidate through WindowModel. Skipping phase 2 removes it.
	log "phase 2/3: this gives up ReplayTests.zeroAnomalies, phase 3's backstop for"
	log "phase 2/3: tolerated cross-lane reordering -- see Tools/replay-diff/README.md"
	printf 'skipped via --skip-replay -- ReplayTests.zeroAnomalies did NOT run\n' >"$REPORT_DIR/replay.log"
fi

# ---------------------------------------------------------------------------
# Phase 3/3 -- semantic diff
# ---------------------------------------------------------------------------
# `swift build` then invoke the binary, rather than `swift run`: `swift run` interleaves
# its build output with the program's stdout, and this stdout is captured into an artifact.
# The build needs no network -- Tools/replay-diff's only dependency is a path dependency on
# Packages/MacdowsCore (see its Package.swift header).
log "phase 3/3: building Tools/replay-diff"
swift build --package-path "$DIFF_PACKAGE_DIR" >"$REPORT_DIR/replay-diff-build.log" 2>&1 ||
	cannot_run "could not build Tools/replay-diff -- see $REPORT_DIR/replay-diff-build.log"
DIFF_BIN="$(swift build --package-path "$DIFF_PACKAGE_DIR" --show-bin-path)/replay-diff"
[ -x "$DIFF_BIN" ] || cannot_run "replay-diff binary not found after a successful build: $DIFF_BIN"

DIFF_ARGS=(--format "$FORMAT")
if [ -n "$ORDER_TOLERANCE" ]; then
	DIFF_ARGS+=(--order-tolerance "$ORDER_TOLERANCE")
fi
if [ -n "$LANE_ORDER_TOLERANCE" ]; then
	DIFF_ARGS+=(--lane-order-tolerance "$LANE_ORDER_TOLERANCE")
fi
# ${arr[@]+"${arr[@]}"} rather than "${arr[@]}": under `set -u`, expanding an empty array
# is an error on bash 3.2, which is still what /bin/bash is on macOS.
DIFF_ARGS+=(${DIFF_PASSTHROUGH[@]+"${DIFF_PASSTHROUGH[@]}"})

REPORT_EXT="txt"
if [ "$FORMAT" = "json" ]; then
	REPORT_EXT="json"
fi
REPORT_FILE="$REPORT_DIR/diff.$REPORT_EXT"
log "phase 3/3: diffing candidate against baseline"
set +e
"$DIFF_BIN" "${DIFF_ARGS[@]}" "$BASELINE_DIR" "$CANDIDATE_DIR" >"$REPORT_FILE"
diff_exit=$?
set -e
cat "$REPORT_FILE"

case "$diff_exit" in
0)
	log "phase 3/3: no unexplained differences"
	;;
1)
	GATE_FAILED=1
	log "phase 3/3: FAILED -- unexplained differences, see $REPORT_FILE"
	;;
*)
	cannot_run "replay-diff could not run (exit $diff_exit) -- see $REPORT_FILE"
	;;
esac

log "artifacts: $LOCK_FILE, $REPORT_DIR/replay.log, $REPORT_FILE"
if [ "$GATE_FAILED" -ne 0 ]; then
	log "upgrade-gate.sh: FAILED"
	exit "$EXIT_GATE_FAILED"
fi
if [ "$SELF_DIFF" -eq 1 ]; then
	log "upgrade-gate.sh: PASSED (offline self-diff smoke -- not an upgrade release)"
else
	log "upgrade-gate.sh: PASSED"
fi
exit "$EXIT_OK"
