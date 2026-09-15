#!/usr/bin/env bash
# test-display-mode-pins.sh: source pins on Scripts/lab/display_mode.swift,
# Scripts/lab/display-mode.command and (for the literal-panel-geometry pin only) the offline
# suite's own fixtures, run on Tier 1 alongside (not instead of) the offline suite's fake-driven
# cases. Tier 1 is compile-free by policy (adr/0006 §6, this file's own header, and
# test-display-mode-offline.sh's own case 12, which SKIPS its real-swiftc self-test there) -- these
# are pure text pins over source files, no toolchain, no display, in the same "SOURCE PINS always
# run" shape as Scripts/test-window-smoke-pins.sh and Scripts/test-rail-probe-plan.sh.
#
# What these pins hold together, structurally, about selectMode's own arithmetic (the one thing
# this repo cannot otherwise verify without a Mac) -- gate r1 B1 added the last two of these four:
#   * HiDPI ("2x") modes are only visible to CGDisplayCopyAllDisplayModes when explicitly asked
#     for via kCGDisplayShowDuplicateLowResolutionModes -- without it every enumeration this file
#     does would silently see none of them, and `select 2x` / `set 2x` would refuse on every
#     Retina-style display (measured against the real display while building this tool: the
#     scratch helper the brief describes found its target mode invisible without this option);
#   * the refresh-rate match is an INTEGER equality, so a fractional analogue rate is rounded once
#     (readCurrentMode/readAllModes) and compared as a whole Hz thereafter, never re-derived;
#   * "2x" requires BOTH dimensions to double, not just one -- a mode scaled on width alone (or
#     height alone) is not a HiDPI mode of the current native size;
#   * "2x" ALSO requires the candidate's pixel size to match the CURRENT mode's native pixel size --
#     without this a doubling mode of a DIFFERENT panel satisfies the arithmetic and `set 2x`
#     changes the display's RESOLUTION, not its scale (gate r1 B1's finding: the shipped
#     --self-test survived this exact mutation before the fixture existed);
#   * "1x" requires looks == pixels (no HiDPI scaling) -- without this a HiDPI mode satisfies 1x and
#     `select 1x` reports OK while having chosen a 2x mode (gate r1 B1's second finding);
#   * isUsableForDesktopGUI is the one CoreGraphics call that keeps this tool from ever choosing a
#     mode the system itself would refuse to drive a desktop from.
#
# gate r1 I2: the `[display]` LINE GRAMMAR the wrapper's sed parses (both for the cross-check's
# AFTER_LOOKS extraction and, by the same shape, its CURRENT_LOOKS extraction) is pinned here too --
# `ModeInfo.description`'s `looks=\(width)x\(height)` interpolation and the two `[display] after: `
# print call sites. The offline suite's fake helper REPRODUCES this grammar rather than checking
# the real one; this is the pin that notices if the real one drifts out from under it.
#
# THE NEGATIVE PIN THAT MATTERS: no numeric literal that LOOKS like a display dimension survives in
# either tracked TOOL file -- not a "WxH" token, and not a standalone real-panel number (the four
# the brief's own scratch-helper example used, plus the refresh rate that example ran at -- gate r1
# B5 found the offline suite carrying the maintainer's exact panel-size-plus-refresh fingerprint). Both tool
# files derive every size from the CURRENT mode at run time (see display_mode.swift's own header,
# "NO PANEL GEOMETRY"); this pin is what keeps a future edit from quietly reintroducing one. The
# OFFLINE SUITE PATH, when given, is checked ONLY for the standalone-number half of that rule (it
# legitimately carries synthetic "WxH" tokens for its fixtures -- gate r1 B5's fold replaced them
# with values outside this pin's forbidden set, never removed the tokens themselves).
#
# CALL-SHAPE pins only (project memory: "source pins must match call shapes, not names" -- a bare
# name count also counts a doc comment that mentions the same call). gate r1 m2: an "exactly once"
# pin that used `grep -c` (lines matched) rather than `grep -o | wc -l` (occurrences matched) would
# still read 1 if a second occurrence landed on the same line as the first -- every "expected 1"
# pin below counts occurrences.
#
# Usage: test-display-mode-pins.sh [swift-path] [command-path] [suite-path]   (defaults: the
# tracked files; pass an older or hand-mutated copy of any to confirm a pin goes red against it.)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_SRC="${1:-$SCRIPT_DIR/display_mode.swift}"
COMMAND_SRC="${2:-$SCRIPT_DIR/display-mode.command}"
SUITE_SRC="${3:-$SCRIPT_DIR/test-display-mode-offline.sh}"
FAILURES=0

for f in "$SWIFT_SRC" "$COMMAND_SRC" "$SUITE_SRC"; do
	if [ ! -f "$f" ]; then
		printf 'FAIL  %-58s %s\n' "source present" "no such file: $f"
		exit 1
	fi
done

pin() { # pin <expected> <actual> <name>
	if [ "$1" = "$2" ]; then
		printf 'PASS  %-58s %s\n' "$3" "expected=$1 got=$2"
	else
		printf 'FAIL  %-58s %s\n' "$3" "expected=$1 got=$2"
		FAILURES=$((FAILURES + 1))
	fi
}

# Comment lines never count -- a `//` bullet that NAMES a call shape would otherwise inflate its
# own pin (test-window-smoke-pins.sh caught itself on exactly this). Anchored at line start.
code_only() { grep -vE '^[[:space:]]*(//|///|\*)' "$1"; }

# gate r1 m2: OCCURRENCES, not lines -- `grep -oE pattern | wc -l` counts every match, even two on
# one line, where `grep -c` would still read 1.
occ() { code_only "$1" | grep -oE "$2" | wc -l | tr -d ' '; } # occ <file> <ere>

echo "== display_mode.swift: HiDPI enumeration =="
# Exactly one occurrence: every enumeration in the file (readAllModes and findCGDisplayMode) shares
# the ONE allModesOptions dictionary rather than each re-stating the option -- a second, divergent
# occurrence would mean an enumeration path this pin does not know about.
pin 1 "$(occ "$SWIFT_SRC" 'kCGDisplayShowDuplicateLowResolutionModes: true')" "kCGDisplayShowDuplicateLowResolutionModes requested exactly once"

echo "== display_mode.swift: selectMode's own arithmetic =="
pin 1 "$(occ "$SWIFT_SRC" 'guard mode\.refreshHz == current\.refreshHz else \{ continue \}')" "integer refresh-rate equality filters every candidate"
# Anchored on the leading `if `, which only twoX's OWN native-pixel-size check line carries -- 1x
# needs the identical check too (its own occurrence continues from 1x's `if` on the line above and
# so does not match this anchored pattern), so an UNANCHORED count of this substring is 2 by design
# and would not isolate a mutation to twoX alone.
pin 1 "$(occ "$SWIFT_SRC" 'if mode\.pixelWidth == nativeWidth, mode\.pixelHeight == nativeHeight')" "2x requires the CURRENT mode's native pixel size (gate r1 B1)"
pin 1 "$(occ "$SWIFT_SRC" 'mode\.width \* 2 == mode\.pixelWidth')" "2x requires width doubling"
pin 1 "$(occ "$SWIFT_SRC" 'mode\.height \* 2 == mode\.pixelHeight')" "2x requires height doubling (not width alone)"
pin 1 "$(occ "$SWIFT_SRC" 'mode\.width == mode\.pixelWidth, mode\.height == mode\.pixelHeight')" "1x requires looks == pixels, i.e. no HiDPI scaling (gate r1 B1)"
pin 1 "$(occ "$SWIFT_SRC" 'mode\.isUsableForDesktopGUI\(\)')" "isUsableForDesktopGUI consulted when building a ModeInfo"

echo "== display_mode.swift: the [display] line grammar the wrapper parses (gate r1 I2) =="
# ModeInfo.description is the ONE place `looks=WxH` is built; both `current:` and `after:` print it
# unmodified (interpolating the whole struct), so pinning this one interpolation covers both of the
# wrapper's sed extractions (CURRENT_LOOKS and AFTER_LOOKS parse the identical shape).
pin 1 "$(occ "$SWIFT_SRC" 'looks=\\\(width\)x\\\(height\)')" "ModeInfo.description's looks=WxH interpolation"
# Two call sites print it: the already-in-target branch (after: current) and the switched branch
# (after: after) -- both must keep the SAME `[display] after: ` prefix the wrapper's sed anchors on.
pin 2 "$(occ "$SWIFT_SRC" 'print\("\[display\] after: ')" "[display] after: printed from exactly two call sites"

echo "== display_mode.swift: --sample-line is display-free CI coverage of the grammar (hotfix after Tier 1 run 34916920114) =="
# Exists, and is reachable before the CoreGraphics split (same guard shape as --self-test) --
# without this, a runner with swiftc but no display builds fine and then has no `current:` line
# for the wrapper-grammar case (gate r1 I2) to parse at all.
pin 1 "$(occ "$SWIFT_SRC" 'subcommand == "--sample-line"')" "--sample-line subcommand exists"
# It must print the SAME shared formatter status/select/set already use, not a private literal
# format string of its own -- a duplicated "looks=..." here would let the sample drift out from
# under the real grammar and still report PASS.
pin 1 "$(occ "$SWIFT_SRC" 'print\("\[display\] current: \\\(sample\)"\)')" "--sample-line prints through the shared description formatter, not its own literal"

echo "== negative: no literal that looks like a display dimension (tool files only) =="
# Neither TOOL file may carry a "WxH"-shaped token (any digits, not just real panel sizes) -- this
# tool's whole premise is that every size comes from the display at run time (display_mode.swift's
# own header, "NO PANEL GEOMETRY"). The offline suite's synthetic fixtures may (checked separately,
# standalone-number only, below).
pin 0 "$(grep -cE '[0-9]{3,4}x[0-9]{3,4}' "$SWIFT_SRC" || true)" "display_mode.swift carries no WxH-shaped literal"
pin 0 "$(grep -cE '[0-9]{3,4}x[0-9]{3,4}' "$COMMAND_SRC" || true)" "display-mode.command carries no WxH-shaped literal"
# The four numbers the brief's own scratch-helper example used, plus the refresh rate that same
# example ran at (gate r1 B5: a refresh-rate literal is the maintainer's fingerprint just as much as the
# resolution is, and appeared in no tracked file before this suite existed). Bounded by
# NON-DIGIT-or-edge on both sides, deliberately NOT `\b`: to ERE, a digit and a following letter
# (a refresh literal) or `x` (a WxH literal) are BOTH "word" characters with no boundary between them, so
# a `\bN\b` pattern silently does not match `NHz` or `NxM` at all -- measured while writing this pin, and exactly
# the shape gate r1 B5's own numbers took in the file this extends to. A digit immediately adjacent
# (an id in the low five figures, `21440`) still correctly does not trip this: the boundary
# character classes below explicitly exclude another digit, so only a MATCHING, ISOLATED four-digit
# run counts, whatever non-digit character (or nothing) surrounds it.
FORBIDDEN_NUMBERS='(^|[^0-9])(1280|720|2560|1440|180)([^0-9]|$)'
pin 0 "$(grep -cE "$FORBIDDEN_NUMBERS" "$SWIFT_SRC" || true)" "display_mode.swift carries no standalone real-panel/refresh number"
pin 0 "$(grep -cE "$FORBIDDEN_NUMBERS" "$COMMAND_SRC" || true)" "display-mode.command carries no standalone real-panel/refresh number"

echo "== negative: the offline suite carries only synthetic fixture numbers (gate r1 B5) =="
# Extended to the THIRD file: the tool files deriving every size at run time is only half the
# guarantee if the suite that is supposed to prove that carries this maintainer's own panel and
# refresh rate instead of made-up ones. Same forbidden set, suite file only -- the suite's WxH
# TOKENS themselves are fine (that is the whole point of a synthetic fixture); only these four
# specific numbers and 180 are not.
pin 0 "$(grep -cE "$FORBIDDEN_NUMBERS" "$SUITE_SRC" || true)" "test-display-mode-offline.sh carries no standalone real-panel/refresh number"

echo "== summary =="
printf 'failures=%s\n' "$FAILURES"
[ "$FAILURES" -eq 0 ]
