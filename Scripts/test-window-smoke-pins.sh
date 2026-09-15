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
# printed, and RemoteWindow.edgeProfileSample(currentMapped:) is never entered. That is structural
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
# ... its text is built in one place. DELIBERATE PIN CHANGE, O-A finish 2026-09-15 (E-D (e3)): the
# builder used to take `profile: RemoteWindow.EdgeBorderProfile?` and now takes
# `sample: RemoteWindow.EdgeProfileSample?` -- a sum type, so "this surface is stale" and "here are
# the profile numbers" cannot be stated at the same time (the numbers would be about the older
# surface, which is exactly what the 2026-09-15 finish line read like). Same pin, same property,
# new call shape; a builder that went back to taking a bare optional profile goes red here.
pin 1 "$(code_only | grep -cE 'windowId: UInt32, sample: RemoteWindow\.EdgeProfileSample\?, hasDisplayedContent: Bool,' || true)" "EdgeProfile.line definition"
# Three shapes, TWO builders: the profiled line, and the one `unavailable=` grammar all three
# reasons share (no-displayed-surface / surface-not-readable / stale-surface, the last one with a
# detail between the token and `visible=`). Still 2 -- a third `[edge] id=` site would be a shape
# no pin below governs.
pin 2 "$(code_only | grep -cE '\[edge\] id=\\\(windowId\)' || true)" "[edge] text built in one place (profile + unavailable)"
pin 1 "$(code_only | grep -cE 'private static func unavailableLine\(' || true)" "one unavailable= grammar"
# ... and printed from one place. A second print site is a line no pin above governs.
pin 1 "$(code_only | grep -cE 'print\(EdgeProfile\.line\(' || true)" "[edge] printed from one site"
# One first-frame sample per window per run (a 60fps stream would otherwise print per frame).
pin 1 "$(code_only | grep -cE 'edgeProfileFirstFrameSampled\.insert\(' || true)" "first-frame sample deduped once per window"
# ... and one -- at most one -- "nothing displayed yet" line per window in that same phase, from a
# SECOND set: inserting into the set above would cost that window its real first-frame sample.
pin 1 "$(code_only | grep -cE 'edgeProfileFirstFrameUnavailable\.insert\(' || true)" "the unavailable first-frame line deduped separately"
# THIRD set, same reasoning one more time (gate r1 I-1). `stale-surface` is a transient state -- a
# window sitting between a `.surfaceMapped` and the frame behind it -- and the first-frame sample
# fires once per drain batch that saw ANY window's frame, so a window under study can be caught
# stale by a batch that was about somebody else. Routing that line into the `sampled` set would
# spend the window's single profiled first-frame slot on it and cost the run its first-frame
# baseline for the whole run; a third set keeps the window eligible. Ceiling: three lines per
# window per first-frame phase, each state at most once.
pin 1 "$(code_only | grep -cE 'edgeProfileFirstFrameStale\.insert\(' || true)" "the stale first-frame line deduped separately"
# The sample is fetched ONCE, above the dedupe, because the dedupe now keys on its SHAPE; a second
# fetch inside the branches could observe a different state than the line eventually printed.
pin 1 "$(code_only | grep -cE 'let sample = registry\.edgeBorderProfile\(windowId: snapshot\.windowId\)' || true)" "the sample is read once, before the dedupe"
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
# O-A finish: the third reason, and the two mapped sizes it exists to name. `edge-mapped=` is the
# mapping the DISPLAYED surface was presented under, `current-mapped=` the one the registry holds
# now -- without both, a reader cannot tell which surface the missing profile would have been about.
pin 1 "$(code_only | grep -cE 'case staleSurface = "stale-surface"' || true)" "stale-surface token"
pin 1 "$(code_only | grep -cE 'edge-mapped=\\\(fmtSize\(edgeMapped\)\) current-mapped=\\\(fmtSize\(currentMapped\)\)' || true)" "both mapped sizes on the stale shape"
pin 1 "$(code_only | grep -cE 'visible=\\\(isVisible \? 1 : 0\)' || true)" "visible= on the unavailable shape"
# The inward scan (gate O-A r1 I-1) is on the line, in the same edge order as the ratios, and is
# built from the profile's own fields rather than re-derived here.
pin 1 "$(code_only | grep -cE 'firstDark=\\\(fmtOffset\(profile\.firstDarkRowFromTop\)\)' || true)" "firstDark= built from the profile"
pin 1 "$(code_only | grep -cE 'static func fmtOffset\(' || true)" "one absent-offset formatter"
# gate r1 m-2: the stale shape's two sizes are formatted BY `[f1]`'s own formatter, not by a second
# copy of its rule -- the doc comment sells character-for-character comparability with an `[f1]`
# line, and two copies of "integral as integer, otherwise %.3f" can drift apart silently.
pin 1 "$(code_only | grep -cE 'static func fmtSize\(' || true)" "one declared-size formatter"
pin 2 "$(code_only | grep -A4 -E 'static func fmtSize\(' | grep -cE 'F1BackingVsMapped\.Observation\.fmt\(' || true)" "fmtSize defers to the [f1] formatter"

echo "== O-A finish: the present counter (WINDOW_SMOKE_EDGE_PROFILE) =="
# `[edge-presents]` is what tells "the server published no frame for the newer mapping" from "it
# did and this client is behind" -- the question the 2026-09-15 record could not answer. Same
# one-place-built / one-place-printed shape as `[edge]` itself, and read through the registry's
# read-only forwarder rather than counted here (a harness-side counter would count what the
# harness saw, not what the window presented).
pin 1 "$(code_only | grep -cE 'static func presentsLine\(windowId: UInt32, count: Int, at phase: Phase\)' || true)" "presentsLine definition"
pin 1 "$(code_only | grep -cE '\[edge-presents\] id=\\\(windowId\)' || true)" "[edge-presents] text built in one place"
pin 1 "$(code_only | grep -cE 'print\(EdgeProfile\.presentsLine\(' || true)" "[edge-presents] printed from one site"
pin 1 "$(code_only | grep -cE 'registry\.presentCount\(windowId:' || true)" "one registry.presentCount call site"

echo "== ADR-0018 §5.2 (2): the per-surface [gfx-frames] rows (WINDOW_SMOKE_EDGE_PROFILE) =="
# The row is the lane's whole product and it is MEASUREMENT ONLY, so the same
# one-place-built / one-place-printed / inside-the-knob-guard shape the [edge] lines already
# have applies here too. `code_only` drops comment lines, so each pin anchors on a call shape
# or on a string interpolation rather than on a name (project memory: a doc comment naming a
# shape counts too).
pin 1 "$(code_only | grep -cE 'static func framesLine\(row: RemoteWindowRegistry\.GfxFrameRow, at phase: Phase\)' || true)" "framesLine definition"
# One builder for BOTH shapes -- a window's own surface and the `id=none` orphan. A second
# `[gfx-frames]` site would be a grammar no pin governs, and the orphan shape's `id=none` comes
# from the row itself rather than from a second format string.
pin 1 "$(code_only | grep -cE '\[gfx-frames\] id=\\\(row\.windowId' || true)" "[gfx-frames] text built in one place"
# shellcheck disable=SC2016  # `$0` is a Swift closure parameter inside the ERE, not shell
pin 1 "$(code_only | grep -cE 'row\.windowId\.map \{ String\(\$0\) \} \?\? "none"' || true)" "the orphan id token comes from the row, not a second shape"
# Printed from exactly the two loops below, both inside the sampler.
pin 2 "$(code_only | grep -cE 'print\(EdgeProfile\.framesLine\(row: row, at: phase\)\)' || true)" "[gfx-frames] printed from the two row loops"
pin 1 "$(code_only | grep -cE 'for row in registry\.gfxFrameRows\(windowId: snapshot\.windowId\)' || true)" "per-window rows read once, per window"
pin 1 "$(code_only | grep -cE 'for row in registry\.gfxFrameOrphanRows\(\)' || true)" "orphan rows read once"
# The orphan pass is finish-only: at first-frame the mapping set is still filling, so a surface
# mapped a moment later would be printed as orphaned and then contradicted by the finish pass.
# Checked positionally (same known brittleness as the guard pin above: a reflowed `if` makes
# this red against correct code, which is the fail-safe direction).
pin 1 "$(code_only | grep -A1 -E 'if phase == \.finish \{' | grep -cE 'for row in registry\.gfxFrameOrphanRows\(\)' || true)" "the orphan rows are finish-only"
# THE KNOB PIN THAT MATTERS: with WINDOW_SMOKE_EDGE_PROFILE unset the registry must not be
# asked for a single row. Both readers exist exactly twice in the whole file -- once each -- and
# both of those live inside `sampleEdgeProfiles`, whose first statement is the knob guard
# (pinned above). `-A38` spans that function's body in the comment-filtered stream; a body that
# outgrows it makes this pin red rather than silently permissive.
pin 2 "$(code_only | grep -cE 'registry\.gfxFrame(Rows|OrphanRows)\(' || true)" "the two row readers, called from nowhere else"
pin 2 "$(code_only | grep -A38 -E 'private func sampleEdgeProfiles\(registry: ' | grep -cE 'registry\.gfxFrame(Rows|OrphanRows)\(' || true)" "both row readers sit inside the guarded sampler"
# The harness reports the registry's numbers and derives none of its own: a locally computed
# count would measure what this harness observed, not what the client did.
pin 0 "$(code_only | grep -cE '(gfxFrameCount|framesSeen|presentsSeen)[[:space:]]*\+= 1' || true)" "no harness-side frame counter"
# gate r1 I-1: the drain's generation filter is the last thing that can eat a published frame,
# and it sits BETWEEN `publishes=` and `ready=` -- both that it is on the line at all and that it
# is in that position (a key printed after `ready=` would read as a disposition of a delivered
# frame rather than as a reason one was never delivered).
pin 1 "$(code_only | grep -cE 'stale=\\\(row\.stale\)' || true)" "stale= built from the row"
pin 1 "$(code_only | grep -A2 -E 'publishes=\\\(row\.publishes\)' | grep -cE '\+ " stale=\\\(row\.stale\)"' || true)" "stale= sits between publishes= and ready="
# The declared size on the row is formatted by the same `[f1]` formatter the stale `[edge]`
# shape uses, so a mapped size can be compared with an `[f1]` line character for character.
# shellcheck disable=SC2016  # `$0` is a Swift closure parameter inside the ERE, not shell
pin 1 "$(code_only | grep -cE 'mapped=\\\(row\.mappedSize\.map \{ fmtSize\(\$0\) \} \?\? "n/a"\)' || true)" "the row's mapped size uses the [f1] formatter, or says n/a"

echo "== summary =="
printf 'failures=%s\n' "$FAILURES"
[ "$FAILURES" -eq 0 ]
