#!/usr/bin/env bash
# replay.sh: run the RAIL/RDPGFX replay regression gate — RailEvent + WindowModel replaying
# samples/phase05-rail-events-2026-08-19/*.jsonl through Packages/MacdowsCore's
# ReplayTests suite (adr/0005 §6 / adr/0006 §4's hard-coupling point, now closed: the
# shared window model is a pure function of the event stream, so this is a real regression
# gate, not just a "server behavior fixture").
#
# Usage: Scripts/replay.sh [samples-dir]
#   samples-dir defaults to samples/phase05-rail-events-2026-08-19 (ReplayTests.swift's own
#   default, derived from its own #filePath) if neither an argument nor $SAMPLES_DIR is
#   given. An explicit argument here wins over an already-exported $SAMPLES_DIR.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd swift

if [ $# -gt 0 ]; then
	SAMPLES_DIR="$1"
fi
SAMPLES_DIR="${SAMPLES_DIR:-}"

if [ -n "$SAMPLES_DIR" ]; then
	[ -d "$SAMPLES_DIR" ] || die "samples directory does not exist: $SAMPLES_DIR"
	# Normalize to an absolute path so ReplayTests.swift (and this log line) don't depend
	# on the caller's cwd at the moment this script was invoked.
	SAMPLES_DIR="$(cd "$SAMPLES_DIR" && pwd)"
	log "Replaying samples from: $SAMPLES_DIR"
else
	log "Replaying samples from ReplayTests.swift's own default (samples/phase05-rail-events-2026-08-19)"
fi
export SAMPLES_DIR

# No --filter here: `swift test --filter <pattern>` exits 0 with only a printed warning
# when the pattern matches zero tests, which would silently turn a broken/renamed suite
# into a "passing" regression gate. Run the whole package's suite instead, and
# independently verify the run wasn't vacuous by parsing swift test's own "Test run with
# N tests" summary line and dying if N is 0 or unparseable, regardless of swift test's own
# exit code.
set +e
output="$(swift test --package-path "$CRDP_REPO_ROOT/Packages/MacdowsCore" 2>&1)"
swift_exit=$?
set -e
printf '%s\n' "$output"

ran_count="$(printf '%s\n' "$output" | grep -oE 'Test run with [0-9]+ tests?' | grep -oE '[0-9]+' | tail -1 || true)"
if [ -z "$ran_count" ] || [ "$ran_count" -eq 0 ]; then
	die "swift test reported zero tests ran (parsed count: '${ran_count:-<none>}') — refusing to treat an empty run as a passing regression gate"
fi
log "swift test ran $ran_count tests"

if [ "$swift_exit" -ne 0 ]; then
	die "swift test failed (exit $swift_exit)"
fi
