#!/usr/bin/env bash
# test-window-smoke-pins.sh: source pins on Tools/window-smoke/main.swift for the extra apps'
# single bounded ClientExecute retry (tool m-3; F r2a 2026-09-06 and checkpoint run 1a 2026-09-09
# both sent `[extra-apps] ClientExecute sent: notepad` and never saw a notepad window, which made
# the whole run invalid under the checkpoint pre-registration (v5) and cost a manual rerun).
#
# Why a shell suite and not a test target (gate r1-A m-7): the repo's existing pins on this file
# live in App/MacdowsAppTests/*PinTests.swift, which need a built app target and cannot run in
# Tier 1. These are pure text pins over one source file -- no toolchain, no FreeRDP prefix, no
# binary -- so they run everywhere, in the same "SOURCE PINS always run" shape as
# Scripts/test-rail-probe-plan.sh.
#
# CALL-SHAPE pins only. Per project memory ("source pins must match call shapes, not names") a
# bare name count also counts doc comments and prose, so every pin below anchors on an opening
# parenthesis or on a string interpolation. What they hold together, structurally:
#   * ClientExecute leaves this harness from exactly TWO call sites (the launch loop and the one
#     bounded retry) -- a third is a send path that bypasses the attempt counter;
#   * each of the four log lines a record reads (`RETRY attempt=`, `attempts=/retried=`,
#     `DIAG: retry fired`, `retry-outcome=`) has its text BUILT in exactly one place and PRINTED
#     from exactly one place;
#   * the decision is one pure function with one live caller;
#   * the things this lane promised not to touch are still untouched (rasterScale byte-identical,
#     the hard multi-window gate not relaxed, the pre-exec window-id set captured once).
#
# Usage: test-window-smoke-pins.sh [path to main.swift]   (default: the tracked one; pass an older
# copy -- e.g. `git show <rev>:Tools/window-smoke/main.swift` -- to confirm the pins go red on it.)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="${1:-$REPO_ROOT/Tools/window-smoke/main.swift}"
FAILURES=0

if [ ! -f "$SRC" ]; then
	printf 'FAIL  %-52s %s\n' "source present" "no such file: $SRC"
	exit 1
fi

pin() { # pin <expected> <actual> <name>
	if [ "$1" = "$2" ]; then
		printf 'PASS  %-52s %s\n' "$3" "expected=$1 got=$2"
	else
		printf 'FAIL  %-52s %s\n' "$3" "expected=$1 got=$2"
		FAILURES=$((FAILURES + 1))
	fi
}

# Comment lines never count. This suite caught itself on that once: a `///` doc bullet that NAMES
# the `session.executeProgram(` call shape made the "two send paths" pin read 3 (project memory:
# "source pins must match call shapes, not names" -- a doc comment carrying the shape counts too).
# Anchored at line start, so a legal `let u = "https://..."` is not filtered; two known blind
# spots, neither of which affects the pins below: a trailing comment on a code line still counts,
# and a multi-line string literal whose line starts with `//` would be filtered out.
code_only() { grep -vE '^[[:space:]]*(//|\*)' "$SRC"; }

echo "== send paths (always) =="
# 1. ClientExecute leaves this harness from exactly TWO call sites -- the t>=6s launch loop and
#    the single bounded retry. A third site is a send path that bypasses the attempt counter.
pin 2 "$(code_only | grep -cE 'session\.executeProgram\(' || true)" "executeProgram call sites (launch + retry)"

echo "== the decision, as one pure function with one live caller =="
pin 1 "$(code_only | grep -cE 'static func programsToResend\(' || true)" "programsToResend definition"
# The self-test calls programsToResend with literals; only the LIVE caller feeds it this run's own
# answer bookkeeping, so that argument shape is what identifies it.
pin 1 "$(code_only | grep -cE 'answered: execAnsweredPrograms' || true)" "one live programsToResend caller"
# gate r1-A I-2: the "everything answered but the count is short -> resend them all" fallback is
# gone. It was the only path that could duplicate an already-launched program.
pin 0 "$(code_only | grep -cE 'unanswered\.isEmpty \? all' || true)" "no all-answered resend-everything fallback"
pin 1 "$(code_only | grep -cE 'unanswered\.filter \{ !failed\.contains\(' || true)" "a rejected path is never resent"
pin 1 "$(code_only | grep -cE 'private func runExtraAppsRetry\(' || true)" "runExtraAppsRetry definition"
pin 1 "$(code_only | grep -cE '[^.]runExtraAppsRetry\(session: session, elapsed: elapsed\)' || true)" "runExtraAppsRetry driven from tick once"
# gate r1-A I-1: the count the retry ACTS on and the count its DIAG line REPORTS must be the same
# measurement, taken once at the decision moment -- a second call would print a number the
# decision never saw.
pin 1 "$(code_only | grep -cE 'let observedAtRetry = newExtraAppContentWindowCount\(\)' || true)" "the retry measures once and reuses it"
# ... and the whole harness reads that measure exactly twice: once when the retry decides, once at
# finish for the outcome line. A third read is a number printed that no decision was taken on.
pin 2 "$(code_only | grep -cE '(= |: )newExtraAppContentWindowCount\(\)' || true)" "the live measure is read twice: decision, finish"

echo "== the four lines a record reads: built once, printed once =="
# `RETRY attempt=2 program=<p>` and `attempts=<n> retried=<0|1>` are the shapes the T3 task book
# fixed; `DIAG: retry fired ...` and `retry-outcome=...` are gate r1-A I-1's additions, which let a
# record tell "no window at all" from "a window that was merely slow" without guessing.
pin 1 "$(code_only | grep -cE 'RETRY attempt=\\\(' || true)" "RETRY text built in one place"
pin 1 "$(code_only | grep -cE 'static func retryLine\(' || true)" "retryLine definition"
pin 1 "$(code_only | grep -cE 'print\(ExtraAppsRetry\.retryLine\(' || true)" "retryLine printed from one site"
pin 1 "$(code_only | grep -cE 'attempts=\\\(attempts\)' || true)" "summary text built in one place"
pin 1 "$(code_only | grep -cE 'static func summaryLine\(' || true)" "summaryLine definition"
pin 1 "$(code_only | grep -cE 'print\(ExtraAppsRetry\.summaryLine\(' || true)" "summaryLine printed from one site"
pin 1 "$(code_only | grep -cE 'DIAG: retry fired at t=\\\(' || true)" "retry DIAG text built in one place"
pin 1 "$(code_only | grep -cE 'static func diagLine\(' || true)" "diagLine definition"
pin 1 "$(code_only | grep -cE 'print\(ExtraAppsRetry\.diagLine\(' || true)" "diagLine printed from one site"
pin 1 "$(code_only | grep -cE 'retry-outcome=\\\(' || true)" "retry-outcome text built in one place"
pin 1 "$(code_only | grep -cE 'static func outcomeLine\(' || true)" "outcomeLine definition"
pin 1 "$(code_only | grep -cE 'print\(ExtraAppsRetry\.outcomeLine\(' || true)" "outcomeLine printed from one site"
# ... and it compares against the count the RETRY decided on. Feeding it a fresh finish-time
# measure would make the line say "none" on every run, unfailably.
pin 1 "$(code_only | grep -cE 'observedAtRetry: extraAppsObservedAtRetry' || true)" "outcome measured against the retry-time baseline"
# The DIAG line rides the channel the F r2a record already reads; the gate's own short-count line
# on that channel stays exactly where it was.
pin 1 "$(code_only | grep -cE 'DIAG: fewer new non-About content windows' || true)" "the gate's own DIAG line untouched"

echo "== the knob (default ON, and only the literal \"0\" disables it) =="
pin 1 "$(code_only | grep -cE 'WINDOW_SMOKE_EXTRA_APPS_RETRY"\] != "0"' || true)" "retry knob read once, default-on"
pin 0 "$(code_only | grep -cE 'WINDOW_SMOKE_EXTRA_APPS_RETRY"\] == "1"' || true)" "retry knob is not opt-in"

echo "== untouched by this lane =="
# windowIdsBeforeExtraApps is captured ONCE, at the launch -- a retry that recaptured it would
# disqualify a window the first attempt did produce.
pin 1 "$(code_only | grep -cE 'windowIdsBeforeExtraApps = Set\(' || true)" "pre-exec id set captured once"
# Task book: not one byte of rasterScale. Holds "these lines changed", not "nothing near them
# changed" -- the independent check is a diff against the merge base.
pin e1ef86b57fc2f275 "$(grep 'rasterScale' "$SRC" | shasum -a 256 | cut -c1-16)" "rasterScale lines byte-identical to d99aed8"
# The retry does not relax the verdict: a still-short count after it is the same hard failure.
pin 1 "$(code_only | grep -cE 'newContentIds\.count >= extraApps\.count,' || true)" "the hard multi-window gate still there"

echo "== O-A edge profile: opt-in, one sampler, one printer (WINDOW_SMOKE_EDGE_PROFILE) =="
# ADR-0018 §5.1 增补 2026-09-10 14:27 item (1). The whole diagnostic is measurement-only, so what
# has to hold is NEGATIVE as much as positive: with the knob unset nothing is sampled, nothing is
# printed, and RemoteWindow.edgeBorderProfile() is never entered. That is structural here -- the
# knob is opt-in, the sampler's FIRST statement is the guard, and every read and every print lives
# inside that one guarded function.
pin 1 "$(code_only | grep -cE 'WINDOW_SMOKE_EDGE_PROFILE"\] == "1"' || true)" "edge knob read once, opt-in"
pin 0 "$(code_only | grep -cE 'WINDOW_SMOKE_EDGE_PROFILE"\] != "0"' || true)" "edge knob is not default-on"
pin 1 "$(code_only | grep -cE 'private func sampleEdgeProfiles\(' || true)" "sampleEdgeProfiles definition"
pin 1 "$(code_only | grep -cE 'guard edgeProfileEnabled else \{ return \}' || true)" "the knob guard, once"
# The guard is the FIRST statement of the sampler: a guard placed after the loop would still pin
# above while sampling every window. Checked positionally, not by counting.
# KNOWN BRITTLENESS (gate O-A r1 m-5): `grep -A1` reads the line that physically follows the
# signature, so wrapping the signature onto two lines turns this pin red against code that is
# perfectly correct. Fail-safe, and stated here so the next reader fixes the pin rather than
# doubting the guard.
pin 1 "$(code_only | grep -A1 -E 'private func sampleEdgeProfiles\(' | grep -cE 'guard edgeProfileEnabled else \{ return \}' || true)" "the guard is the sampler's first line"
# Exactly three CALL SHAPES: the definition and its two callers (first frame, finish). Anchored on
# `(registry:` rather than on the bare name (gate O-A r1 m-6, and the project's own rule that a
# name count also counts prose): `code_only` only drops lines that START with a comment marker, so
# a trailing comment naming the function would otherwise pollute the count.
pin 3 "$(code_only | grep -cE 'sampleEdgeProfiles\(registry: ' || true)" "sampleEdgeProfiles: definition + two callers"
pin 1 "$(code_only | grep -cE 'sampleEdgeProfiles\(registry: registry, at: \.firstFrame\)' || true)" "first-frame sample driven once"
pin 1 "$(code_only | grep -cE 'sampleEdgeProfiles\(registry: registry, at: \.finish\)' || true)" "finish sample driven once"
# The diagnostic is reached from exactly one place in the whole harness ...
pin 1 "$(code_only | grep -cE 'registry\.edgeBorderProfile\(windowId:' || true)" "one registry.edgeBorderProfile call site"
# ... its text is built in one place (two return shapes, both inside EdgeProfile.line) ...
pin 1 "$(code_only | grep -cE 'windowId: UInt32, profile: RemoteWindow\.EdgeBorderProfile\?, hasDisplayedContent: Bool,' || true)" "EdgeProfile.line definition"
pin 2 "$(code_only | grep -cE '\[edge\] id=\\\(windowId\)' || true)" "[edge] text built in one place (profile + unavailable)"
# ... and printed from one place. A second print site is a line no pin above governs.
pin 1 "$(code_only | grep -cE 'print\(EdgeProfile\.line\(' || true)" "[edge] printed from one site"
# One first-frame sample per window per run (a 60fps stream would otherwise print per frame).
pin 1 "$(code_only | grep -cE 'edgeProfileFirstFrameSampled\.insert\(' || true)" "first-frame sample deduped once per window"
# ... and one -- at most one -- "nothing displayed yet" line per window in that same phase, from a
# SECOND set: inserting into the set above would cost that window its real first-frame sample.
pin 1 "$(code_only | grep -cE 'edgeProfileFirstFrameUnavailable\.insert\(' || true)" "the unavailable first-frame line deduped separately"
# THE NEGATIVE PIN THAT MATTERS (gate O-A r1 B-1). No content filter on the sampler's loop: every
# window in the registry gets a line, and one that has displayed nothing says so. A `where` clause
# here would silently drop exactly the window this diagnostic exists to report (C-2' run 2's About
# held `layer.contents == nil` for its whole run) while the other windows kept the knob looking
# alive.
# Scoped to the sampler's own body: `sampleF1BackingVsMapped` above KEEPS its `where` clause and
# is right to (it pairs a presented frame with a mapped size and has nothing to say without one),
# so a file-wide count of that clause is 1 and always will be. `-A25` covers this function and
# stops well short of the next one; a body that grew past it would relax the pin, not break it,
# which is why the positive loop-shape pin below is the one that actually holds the line.
pin 0 "$(code_only | grep -A25 -E 'private func sampleEdgeProfiles\(registry: ' | grep -cE 'where snapshot\.hasDisplayedContent' || true)" "no content filter inside the edge sampler"
# The loop shape itself: every snapshot, sorted, and the line ENDS at the opening brace -- a
# `where` clause of any kind would have to sit between the two and would break this pin.
# shellcheck disable=SC2016  # `$0`/`$1` are Swift closure parameters inside the ERE, not shell
pin 1 "$(code_only | grep -cE 'for snapshot in registry\.windowSnapshots\(\)\.sorted\(by: \{ \$0\.windowId < \$1\.windowId \}\) \{$' || true)" "the edge sampler iterates every window"
# The window's own displayed-content flag reaches the line builder as DATA (it picks the reason
# token), which is the shape that replaced the filter.
pin 1 "$(code_only | grep -cE 'hasDisplayedContent: snapshot\.hasDisplayedContent' || true)" "hasDisplayedContent is passed, not filtered on"
pin 1 "$(code_only | grep -cE 'hasDisplayedContent \? \.surfaceNotReadable : \.noDisplayedSurface' || true)" "the two unavailable reasons, decided in one place"
pin 1 "$(code_only | grep -cE 'case noDisplayedSurface = "no-displayed-surface"' || true)" "no-displayed-surface token"
pin 1 "$(code_only | grep -cE 'case surfaceNotReadable = "surface-not-readable"' || true)" "surface-not-readable token"
pin 1 "$(code_only | grep -cE 'visible=\\\(isVisible \? 1 : 0\)' || true)" "visible= on the unavailable shape"
# The inward scan (gate O-A r1 I-1) is on the line, in the same edge order as the ratios, and is
# built from the profile's own fields rather than re-derived here.
pin 1 "$(code_only | grep -cE 'firstDark=\\\(fmtOffset\(profile\.firstDarkRowFromTop\)\)' || true)" "firstDark= built from the profile"
pin 1 "$(code_only | grep -cE 'static func fmtOffset\(' || true)" "one absent-offset formatter"

echo "== summary =="
printf 'failures=%s\n' "$FAILURES"
[ "$FAILURES" -eq 0 ]
