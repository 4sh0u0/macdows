#!/usr/bin/env bash
# test-k-consumer-pins.sh: the "K has no product consumer" claim, as a Tier 1 source pin.
#
# K is the per-window client-area inset carried by the four RAIL client-rect fields
# `clientOffsetX/Y` and `windowClientDeltaX/Y` (K = delta - off). The 2026-09-21 read-only map
# (docs/reviews/2026-09-21-w3-map/map-w3-k-and-tear.md §1) found that on the product path those
# four are CARRIED and never CONSUMED: `RemoteWindowRegistry.macContentRect` still uses `off`
# alone as the client-area origin, so K == 0 by construction everywhere it would matter. That map
# said its own evidence was "grep plus one read, not a test run", and by project rule a
# researcher's claim is not first-hand evidence. This suite is the first-hand form of it: an
# enumeration that is red the moment any file outside the carry set so much as names one of the
# four, and red the moment a carry site's own occurrence count moves.
#
# Why a shell suite and not a test target: the repo's Swift pin on the same claim
# (App/MacdowsAppTests/ClientRectPlumbingPinTests.swift) needs a built app target and cannot run
# in Tier 1 -- ubuntu-latest has no Xcode, so the App bundle's suites never execute on CI. These
# are pure text pins over tracked sources -- no toolchain, no FreeRDP prefix, no binary -- so they
# run everywhere, in the same "SOURCE PINS always run" shape as Scripts/test-window-smoke-pins.sh
# and Scripts/lab/test-display-mode-pins.sh.
#
# TWO LAYERS, DELIBERATELY DIFFERENT ABOUT COMMENTS. The project has been bitten twice by name
# counts that also counted doc comments (project memory: "source pins must match call shapes, not
# names"), so the two layers here count different text on purpose:
#
#   (1) MEMBERSHIP is raw: a scanned file that mentions any of the four ANYWHERE -- code, doc
#       comment, string literal, a `#` note in a lab job file -- and is not on the allow-list is a
#       failure. A new consumer usually arrives with a comment explaining itself, and a mention in
#       a file that had none is exactly the signal this suite exists to raise. Raw matching also
#       means the allow-list cannot be evaded by parking the name in a comment.
#
#       MEMBERSHIP IS SPLIT IN TWO, because the two roots support two different claims and a
#       reader of a red line deserves to know which one just moved:
#         - PRODUCT roots (`App/`, `Packages/`, `Tools/`): an unlisted mention here is the claim
#           itself moving -- something on the product path now names a K field.
#         - The LAB root (`Scripts/`): an unlisted mention here is a MEASUREMENT-side change. It
#           does NOT contradict the product claim; lab scripts are in scope so that the map's
#           §1.1(c) PowerShell/env carry points stay declared rather than drifting, and the fix is
#           to add the file to the allow-list with its purpose, not to wire or unwire anything.
#
#   (2) The per-file OCCURRENCE COUNTS are comment-stripped: `//` and `/* */` for C-family
#       sources, `#` and `<# #>` for PowerShell/shell/env files. A frozen number that moves every
#       time somebody improves a doc block is a number people learn to bump without reading, which
#       is how a count pin stops being a pin. Stripped, the numbers only move when the CODE moves
#       -- which is the event worth being red for: "a carry site quietly grew a consumer".
#
#   Known blind spots of the stripper, neither of which affects any pin below: it does not know
#   about string literals, so a `"//"` or a `"#"` inside a literal truncates that line; and it does
#   not know about heredocs. Both are one-directional -- they can only LOWER a count, never raise
#   one -- and every allow-listed count below was read off the real files and is asserted exactly.
#
# WHAT THE ALLOW-LIST IS. Every entry is a carry point from the map's §1.1 tables, with its
# purpose stated in one line. The list is closed: anything else is red. Entries are also checked
# to still exist and still mention the fields, so a file that is renamed or emptied cannot leave
# this suite iterating nothing and reporting green -- the vacuous-pin failure mode, which reads as
# coverage and is not.
#
# WHAT THIS SUITE IS NOT. It is not an argument that K should stay unwired, and it does not
# reproduce the map's wiring blueprint. It holds two facts steady while that decision is open:
# (i) nothing on the PRODUCT path reads these four, and (ii) every LAB file that so much as names
# them is registered here with its purpose. If a later lane wires K, this suite is SUPPOSED to go
# red, and the lane declares the new consumer by adding it here with its purpose and its count --
# the same "declare it deliberately" discipline the H2' lane used for the seven left-border pins.
#
# Usage: test-k-consumer-pins.sh [repo root]   (default: this script's parent; pass an older
# checkout to confirm the pins behave there.)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FAILURES=0

NAMES="clientOffsetX clientOffsetY windowClientDeltaX windowClientDeltaY"
NAME_RE='clientOffsetX|clientOffsetY|windowClientDeltaX|windowClientDeltaY'

if [ ! -d "$ROOT/App" ] || [ ! -d "$ROOT/Packages" ] || [ ! -d "$ROOT/Packages/MacdowsCore/Sources" ]; then
	printf 'FAIL  %-56s %s\n' "repo root usable" "not a checkout: $ROOT"
	exit 1
fi

pin() { # pin <expected> <actual> <name> [what to do about it -- printed only on failure]
	if [ "$1" = "$2" ]; then
		printf 'PASS  %-56s %s\n' "$3" "expected=$1 got=$2"
	else
		printf 'FAIL  %-56s %s\n' "$3" "expected=$1 got=$2"
		[ "$#" -lt 4 ] || printf '      -> %s\n' "$4"
		FAILURES=$((FAILURES + 1))
	fi
}

# --- comment strippers -------------------------------------------------------------------------
# One character-wise pass each, so a block comment opened on a code line is handled in the same
# state machine as the line comment that may precede it. A line-anchored regex (the older
# `grep -vE '^[[:space:]]*(//|\*)'` shape used elsewhere in Scripts/) cannot do that: it leaves
# trailing comments on code lines counted, which is precisely how a doc mention slips into a count.
strip_c() { # C, ObjC++, Swift: // to end of line, /* */ across lines
	awk '
	{ line = $0; out = ""; i = 1; n = length(line)
	  while (i <= n) { c2 = substr(line, i, 2)
	    if (blk) { if (c2 == "*/") { blk = 0; i += 2 } else { i++ } }
	    else if (c2 == "/*") { blk = 1; i += 2 }
	    else if (c2 == "//") { i = n + 1 }
	    else { out = out substr(line, i, 1); i++ } }
	  print out }
	' "$1"
}

strip_hash() { # PowerShell, shell, env: # to end of line, <# #> across lines
	awk '
	{ line = $0; out = ""; i = 1; n = length(line)
	  while (i <= n) { c2 = substr(line, i, 2)
	    if (blk) { if (c2 == "#>") { blk = 0; i += 2 } else { i++ } }
	    else if (c2 == "<#") { blk = 1; i += 2 }
	    else if (substr(line, i, 1) == "#") { i = n + 1 }
	    else { out = out substr(line, i, 1); i++ } }
	  print out }
	' "$1"
}

strip_for() {
	case "$1" in
	*.swift | *.c | *.cpp | *.h | *.mm | *.m) strip_c "$1" ;;
	*) strip_hash "$1" ;; # .ps1 .psm1 .sh .command .py .env -- all `#`-commented
	esac
}

# The four counts of one file, comment-stripped, as a single space-separated string. One pin per
# file rather than four keeps the report readable while still resolving WHICH field moved.
counts_of() {
	local file="$1" name out=""
	for name in $NAMES; do
		out="$out $(strip_for "$file" | grep -o -- "$name" | wc -l | tr -d ' ' || true)"
	done
	printf '%s' "${out# }"
}

# --- the scanned set ---------------------------------------------------------------------------
# Product and tool sources only. Test sources are pruned because a pin file naturally names the
# thing it pins -- this very suite was its own first failure on the first run, and it is excluded
# by exact name rather than by a `test-*.sh` glob so the hole stays one file wide: any OTHER
# script that starts naming the four still has to declare itself on the allow-list.
#
# `build*` directories are pruned, not just `build`: they are copies of build PRODUCTS --
# untracked, gitignored, and carrying stale duplicates of CRSession.h and crdpq.h. A checkout that
# has run a sanitizer build also has `App/build-asan/` and `App/build-tsan/` holding the same
# headers, so pruning only `build` made this suite red on a build artefact the first time anyone
# ran one -- red for the wrong reason, against yesterday's copy of a file that is already listed.
# The glob covers future siblings (`build-ubsan`, ...) for the same reason.
#
# ONE extension list for all four roots. A root that is in scope while its file types are not is
# only half in scope: `Scripts/` holds `.command` and `.py` next to its `.ps1` and `.sh`, and a
# consumer added in one of those was invisible here until 2026-09-21. `.cpp` is forward-looking
# (the repo has none today) and is stripped as C-family below.
EXTS="swift m mm h c cpp command py sh ps1 psm1 env"
scanned_files() {
	local ext
	local args=()
	for ext in $EXTS; do args+=(-o -name "*.$ext"); done
	# `Packages` whole, not one package of it: a new package under it would otherwise be outside
	# every pin here. `Tests` stays pruned, so the extra cost is one Package.swift per package.
	find "$ROOT/App" "$ROOT/Packages" "$ROOT/Tools" "$ROOT/Scripts" \
		-type d \( -name 'build*' -o -name .build -o -name Tests -o -name MacdowsAppTests \) -prune -o \
		-type f \( "${args[@]:1}" \) -print |
		grep -vE '\.Tests\.ps1$|Tests\.swift$' |
		# Strip the root prefix with awk, not `sed "s|^$ROOT/||"`: a `|` anywhere in the path the
		# caller passed would break that expression, and the failure mode is silent -- every path
		# stays absolute, every floor reads 0, and the membership loop greps files that are not
		# there. Fixed-string prefix removal has no metacharacters at all.
		awk -v prefix="$ROOT/" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); next } { print }' |
		grep -vxF 'Scripts/test-k-consumer-pins.sh' |
		LC_ALL=C sort
}

# --- the allow-list ----------------------------------------------------------------------------
# path | four comment-stripped counts | what that file does with the fields.
# The zero-count entries are real entries, not padding: those files mention the fields only in
# prose, and their membership is what keeps the raw layer from flagging them every run.
allowlist() {
	cat <<'LIST'
App/CRBridge/CRSession.h|1 1 1 1|read-out surface: the four readonly int32_t properties on CRDPEvent
App/CRBridge/CRSession.mm|5 5 5 5|bridge: each PAIR copied in behind its own validity bit, then copied out of the payload
Packages/MacdowsCore/Sources/CRDPQueue/include/crdpq.h|1 1 1 1|queue POD: the four int32_t slots at the window-order struct tail
Packages/MacdowsCore/Sources/MacdowsCore/RailEvent.swift|7 7 7 7|replay event model: stored properties, JSON decode defaulting to 0, memberwise init
Packages/MacdowsCore/Sources/MacdowsCore/WindowModel.swift|3 3 3 3|replay WindowState: stored properties and the bit-gated incremental merge
Tools/rail-probe/rail-probe.c|2 2 2 2|recorder: the single probe_window_common format string shared by create and update
Tools/window-smoke/main.swift|1 1 1 1|harness: the [client-rect] line's coff= and delta= fields, print only, no downstream
Tools/replay-diff/Sources/ReplayDiffKit/KnownDifferenceTable.swift|2 1 2 1|diff CLI: declares the four as recorder-growth fields, measurement only
Scripts/lab/share/window-rects-probe.ps1|0 0 0 0|host probe: header prose explaining delta = off + K; the script itself never emits K
Scripts/lab/jobs/smoke-1x-D.env|0 0 0 0|lab job: one comment line naming the field set; no parameter consumes it
Scripts/lab/jobs/smoke-1x-D-keep.env|0 0 0 0|lab job: same comment line on the keep-open variant
LIST
}

# --- pins --------------------------------------------------------------------------------------
echo "== the scan is not vacuous =="
# Floors, not equalities: ordinary new files must not turn this suite red, but a pruned or
# relocated root must. Without these the whole suite would pass while enumerating nothing.
app_n="$(scanned_files | grep -c '^App/' || true)"
packages_n="$(scanned_files | grep -c '^Packages/' || true)"
tools_n="$(scanned_files | grep -c '^Tools/' || true)"
scripts_n="$(scanned_files | grep -c '^Scripts/' || true)"
pin yes "$([ "$app_n" -ge 10 ] && echo yes || echo no)" "App/ non-test sources scanned (>=10, got $app_n)"
pin yes "$([ "$packages_n" -ge 24 ] && echo yes || echo no)" "Packages/ non-test sources scanned (>=24, got $packages_n)"
pin yes "$([ "$tools_n" -ge 15 ] && echo yes || echo no)" "Tools/ non-test sources scanned (>=15, got $tools_n)"
pin yes "$([ "$scripts_n" -ge 60 ] && echo yes || echo no)" "Scripts/ non-test sources scanned (>=60, got $scripts_n)"
# Build-products copies: if one were ever scanned, its duplicate CRSession.h would show up as an
# unlisted mention and this suite would be red for the wrong reason on any machine that has built
# the app. The first pin is the general form -- NOTHING scanned may sit under a path beginning
# `App/build` -- so a future `App/build-ubsan/` is covered the day someone creates it; the two
# after it name today's sanitizer trees so a regression in the prune glob says which one came back.
pin 0 "$(scanned_files | grep -c '^App/build' || true)" "nothing scanned lives under App/build*"
pin 0 "$(scanned_files | grep -c '^App/build-asan/' || true)" "App/build-asan (sanitizer products) is pruned"
pin 0 "$(scanned_files | grep -c '^App/build-tsan/' || true)" "App/build-tsan (sanitizer products) is pruned"

echo "== every mention lives on the allow-list (raw: comments and string literals included) =="
# Two pins, not one, because the two roots carry two different claims -- see TWO LAYERS above.
unlisted_product=""
unlisted_lab=""
unreadable=""
while IFS= read -r f; do
	rc=0
	grep -qE "$NAME_RE" "$ROOT/$f" || rc=$?
	# rc 1 = no match (the ordinary case), rc 2 = grep could not read the file. Treating those two
	# the same would let an unreadable file be skipped in silence, and a file this suite cannot
	# read is a file it has not checked -- which is the vacuous-pin failure mode, one file at a time.
	if [ "$rc" -eq 2 ]; then
		unreadable="$unreadable $f"
		continue
	fi
	[ "$rc" -eq 0 ] || continue
	allowlist | cut -d'|' -f1 | grep -qxF "$f" && continue
	case "$f" in
	Scripts/*) unlisted_lab="$unlisted_lab $f" ;;
	*) unlisted_product="$unlisted_product $f" ;;
	esac
done < <(scanned_files)
pin "" "$unlisted_product" "product paths (App/ Packages/ Tools/) name none of the four" \
	"a product path now mentions a K field: wire it deliberately or register the carrier"
pin "" "$unlisted_lab" "every lab path (Scripts/) naming the four is registered" \
	"a lab script names the K field set: add it to the allow-list with its purpose (declare-it, not a consumer)"
pin "" "$unreadable" "every scanned file could be read" \
	"grep exited 2 on these paths; an unreadable file is an unchecked file, not a clean one"

echo "== the allow-list is closed, live, and its counts are frozen =="
while IFS='|' read -r file expected purpose; do
	[ -n "$file" ] || continue
	if [ ! -f "$ROOT/$file" ]; then
		pin present missing "allow-list entry exists: $file"
		continue
	fi
	# A listed file that no longer mentions the fields is a stale entry: the carry point moved,
	# and leaving the entry behind would silently widen the allow-list for whatever takes its name.
	pin yes "$(grep -qE "$NAME_RE" "$ROOT/$file" && echo yes || echo no)" "still a carry point: $file"
	pin "$expected" "$(counts_of "$ROOT/$file")" "counts [$purpose]"
done < <(allowlist)

echo "== the consumer that would exist first, if one existed =="
# macContentRect is the single place the map names as the one that WOULD read K (it is the client
# rect's only source for both rendering and input mapping, per RemoteWindowInput.swift's own note),
# and today it builds its rect from state.offsetX/offsetY -- `off`, no K. Pinned as the function
# BODY, not the file, so the pin says what it means even if the file later gains an unrelated
# mention that the allow-list has accepted.
REG="$ROOT/App/RemoteWindowRendering/RemoteWindowRegistry.swift"
mac_content_rect_body() {
	awk '/private func macContentRect\(for state: PendingWindowState/{f=1} f{print} f && /^    \}$/{exit}' "$REG"
}
pin yes "$([ -f "$REG" ] && echo yes || echo no)" "RemoteWindowRegistry.swift present"
# Non-vacuity for the extractor itself: an awk anchor that stops matching would print nothing, and
# "nothing contains the four names" is true of nothing.
pin yes "$([ "$(mac_content_rect_body | wc -l | tr -d ' ')" -ge 5 ] && echo yes || echo no)" "macContentRect body extracted"
pin 1 "$(mac_content_rect_body | grep -cE 'let railRect = WindowsRect\(x: Double\(state\.offsetX\), y: Double\(state\.offsetY\)' || true)" "macContentRect origin is off, spelled out"
pin 0 "$(mac_content_rect_body | grep -cE "$NAME_RE" || true)" "macContentRect body reads none of the four"
# And the whole rendering package, as a package: the claim the Swift pin makes about
# App/RemoteWindowRendering/ restated where Tier 1 can actually run it.
pin 0 "$(find "$ROOT/App/RemoteWindowRendering" -type f -name '*.swift' -exec grep -lE "$NAME_RE" {} + 2>/dev/null | wc -l | tr -d ' ' || true)" "App/RemoteWindowRendering/ reads none of the four"
pin 0 "$(grep -cE "$NAME_RE" "$ROOT/Packages/MacdowsCore/Sources/MacdowsCore/WindowGeometry.swift" || true)" "WindowGeometry.swift reads none of the four"

echo "== summary =="
printf 'failures=%s\n' "$FAILURES"
[ "$FAILURES" -eq 0 ]
