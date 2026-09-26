#!/usr/bin/env bash
# test-window-count-sampler.sh: ADR-0020 lane V blueprint §2.1 / O-6. Pins
# Tools/window-count-sampler/main.swift, lane V's external window counter for DA-1 (the RAIL
# window count before / after the Disconnect press and after the reconnect). Its l25 field is
# printed as §2.1 asks, but status items are structurally absent from the on-screen table (gate
# r1 O-A), so DA-2 has no observation surface through this tool. The tool has no unit-test target:
# it is a single file built with `swiftc`, no package, no Xcode project.
#
# Two kinds of case, the same split as Scripts/test-rail-probe-plan.sh uses for a tool with no
# test target:
#   * SOURCE PINS (W1, W2, W3, W5) are pure grep/tr over main.swift and run everywhere, including
#     Tier 1 (.github/workflows/tier1.yml, step "window-count-sampler source pins", which demands
#     exactly one `PASS  W1 `, `PASS  W2 `, `PASS  W3 ` and `PASS  W5 ` and no FAIL). They are
#     default-deny grammars in the sense of the D1 lesson: they enumerate the shapes the file may
#     contain and refuse anything else, instead of listing a few forbidden names.
#       W1  red line (blueprint §5): the exact set of window-related identifiers (only the four
#           allowed dictionary keys, never kCGWindowName / kCGWindowOwnerName); a window
#           dictionary (`item`) appears only in the for-in and the four key subscripts; the window
#           table (`windowTable`) only in its seven pinned shapes (so it can reach nothing but the
#           extraction and a count); one output function (`print(` once, inside writeLine) and no
#           other output sink, serialiser, spawn or process-name API; imports exactly CoreGraphics
#           and Foundation; WindowEntry carries four Ints and nothing else.
#       W2  line grammar: each of the five line builders' whole format string, verbatim; the five
#           prefix literals once each and no sixth; every writeLine( call is one of nine pinned
#           builder-call shapes (so every line is printed, and nothing else is); the reason set is
#           exactly done / pid-gone / timeout / enum-nil.
#       W3  one CGWindowListCopyWindowInfo( call, with .optionOnScreenOnly and kCGNullWindowID,
#           behind copyWindowList(), which --self-check and the main loop call once each.
#       W5  sampling semantics, verbatim: the main loop (timeout on ContinuousClock, then done,
#           then cur-a, the one enumeration with the enum-nil end, the extraction, cur-b, found,
#           the row, pid-gone -- in that order and contiguous); the owner-PID filter; the
#           missing-layer sentinel; the four layer buckets; the number-ascending wins list; found =
#           process existence; print-then-fflush; the self-check decision; one handler for
#           SIGTERM / SIGINT / SIGHUP; --pid >= 1; helper-sha8 from Bundle.main.executablePath.
#   * BINARY CASES (W4*) need a built executable. They run only when WCS_BIN names one; with
#     WCS_BIN unset (a compile-free runner, Tier 1) they are one NOTE (not_run=1), never a pass.
#     There is no default binary path. Build outside the repository tree with
#     `swiftc -O -o <dir>/window-count-sampler Tools/window-count-sampler/main.swift` and pass
#     WCS_BIN=<dir>/window-count-sampler. W4m compiles the source under test in both language
#     modes (default and -swift-version 6) inside this suite's temporary directory and requires
#     WCS_BIN to be byte-identical to the default-mode build (the build is deterministic for the
#     same source, output name and toolchain), so every binary verdict below is about THIS source;
#     a mismatch is a FAIL and the behavioural cases are skipped. The behavioural cases also build
#     a small AppKit fixture there (one borderless layer-0 window, 160x90, and one floating layer-3
#     window, 120x70, shown for a few seconds, plus one window that is never shown; no title) and
#     so need a logged-in GUI session: they are for a maintainer machine. None of them opens a
#     socket or reads a window title.
#
# Comment-stripping (code_only, below) is the same shape as test-window-smoke-pins.sh's own
# function of that name: lines whose first non-blank character is `//` or `*` are dropped before
# any count runs, so main.swift's header comments (which necessarily NAME kCGWindowName and
# kCGWindowOwnerName to say they must never be read) do not trip W1. Known blind spot, accepted
# there and here: a TRAILING comment on a code line still counts, and a multi-line string literal
# whose line starts with `//` would be filtered out (main.swift has neither). Tokens are every
# [A-Za-z_][A-Za-z0-9_]* run of the stripped code, string literals included; shape needles are
# matched against the stripped code folded onto one line with every whitespace run collapsed to a
# single space (the fold test-rail-probe-plan.sh uses), so a shape holds however it is wrapped.
#
# Usage: [WCS_BIN=<built binary>] test-window-count-sampler.sh [path to main.swift]
# (default source: the tracked one; pass a mutated copy -- named main.swift, with WCS_BIN built
# from it -- to confirm a pin goes red on it; see the mutation table in this lane's reports.)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="${1:-$REPO_ROOT/Tools/window-count-sampler/main.swift}"
BIN="${WCS_BIN:-}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/window-count-sampler.XXXXXX")"
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

if [ ! -f "$SRC" ]; then
	printf 'FAIL  %-40s %s\n' "source present" "no such file: $SRC"
	printf 'failures=1 not_run=0\n'
	exit 1
fi

code_only() { grep -vE '^[[:space:]]*(//|\*)' "$SRC" || true; }
CODE="$TEST_DIR/code-only.swift"
code_only >"$CODE"
FOLDED="$TEST_DIR/code-only.folded"
tr -s '[:space:]' ' ' <"$CODE" >"$FOLDED"
TOKENS="$TEST_DIR/code-only.tokens"
{ grep -oE '[A-Za-z_][A-Za-z0-9_]*' "$CODE" || true; } >"$TOKENS"

# tok_cnt: occurrences of one exact token. fold_cnt: occurrences of a shape needle (written with
# single spaces) in the folded code; grep -F, so a needle's backslashes and brackets are literal.
tok_cnt() { grep -cxF -- "$1" "$TOKENS" || true; }
fold_cnt() { { grep -oF -- "$1" "$FOLDED" || true; } | wc -l | tr -d '[:space:]'; }

# Every pin below goes through one of these. A pin that does not hold is written to the .bad half
# of its evidence (printed first on FAIL) and its label is appended to the case name.
PIN_BAD=0
PIN_WHY=""
PIN_EVID=""
pin_begin() {
	PIN_BAD=0
	PIN_WHY=""
	PIN_EVID="$TEST_DIR/$1"
	: >"$PIN_EVID.bad"
	: >"$PIN_EVID.all"
}
pin_record() { # <label> <got> <expected> <what>
	local line
	line="$(printf '%-12s got %s expected %s: %s' "$1" "$2" "$3" "$4")"
	printf '%s\n' "$line" >>"$PIN_EVID.all"
	if [ "$2" != "$3" ]; then
		printf 'MISMATCH %s\n' "$line" >>"$PIN_EVID.bad"
		PIN_BAD=1
		case " $PIN_WHY " in *" $1 "*) ;; *) PIN_WHY="$PIN_WHY $1" ;; esac
	fi
}
pin_fold() { pin_record "$1" "$(fold_cnt "$3")" "$2" "$3"; }  # <label> <expected> <needle>
pin_tok() { pin_record "$1" "$(tok_cnt "$3")" "$2" "token $3"; } # <label> <expected> <token>
pin_end() { cat "$PIN_EVID.bad" "$PIN_EVID.all" >"$PIN_EVID"; }
pin_name() { if [ -z "$PIN_WHY" ]; then printf '%s' "$1"; else printf '%s%s' "${1%% *}" "$PIN_WHY"; fi; }
sorted_words() { LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'; }

echo "== source pins (always) =="

# W1: the red line as a default-deny grammar (gate r1 I-3). A window title or another process's
# name can reach this tool's output only through a key, API or sink this grammar refuses.
pin_begin w1
# W1 ids: the exact set of window-related identifiers. The four dictionary keys are the only
# kCGWindow* names; `window` is the tool's own name inside the usage literal.
WIN_IDS="$({ grep -E '[Ww]indow' "$TOKENS" || true; } | sorted_words)"
WIN_WANT="$(printf '%s\n' CGWindowListCopyWindowInfo WindowEntry copyWindowList kCGNullWindowID \
	kCGWindowBounds kCGWindowLayer kCGWindowNumber kCGWindowOwnerPID window windowTable | sorted_words)"
pin_record ids "$WIN_IDS" "$WIN_WANT" "window-related identifier set"
# W1 item: a window dictionary appears in exactly five places -- the for-in and one subscript per
# allowed key -- so it is never printed, interpolated, dumped or passed anywhere.
pin_tok item 5 item
pin_fold item 1 'for item in windowTable {'
for key in kCGWindowOwnerPID kCGWindowLayer kCGWindowNumber kCGWindowBounds; do
	pin_fold item 1 "item[$key as String]"
done
# W1 table: the window table appears only in these seven shapes: the extraction's parameter and
# for-in, the two enumerations, the two extractions, and the self-check's total count.
pin_tok table 7 windowTable
pin_fold table 1 'func filterEntries(_ windowTable: [[String: AnyObject]], pid: Int32) -> [WindowEntry] {'
pin_fold table 1 'for item in windowTable {'
pin_fold table 1 'guard let windowTable = copyWindowList() else { exit(2) }'
pin_fold table 1 'let entries = filterEntries(windowTable, pid: targetPid).count'
pin_fold table 1 'let total = windowTable.count'
pin_fold table 1 'guard let windowTable = copyWindowList() else { writeLine(buildEndLine(rows: seq, reason: "enum-nil")) exit(2) }'
pin_fold table 1 'let entries = filterEntries(windowTable, pid: pid)'
# W1 entry: what leaves the extraction is four Ints, nothing else.
pin_fold entry 1 'struct WindowEntry { let number: Int let layer: Int let width: Int let height: Int }'
# W1 sink: one output function; stdout only through it; no other sink or serialiser.
pin_tok sink 1 print
pin_tok sink 2 stdout
pin_tok sink 1 fflush
pin_tok sink 1 FileHandle
pin_fold sink 1 'guard let handle = FileHandle(forReadingAtPath: path) else { return 0 }'
pin_tok sink 1 FileManager
for tok in stderr standardError standardOutput NSLog os_log Logger OSLog os_signpost syslog asl_log \
	perror write fwrite fputs puts putchar fputc printf fprintf vprintf dprintf debugPrint dump \
	description debugDescription describing reflecting Mirror CFShow CFShowStr CFCopyDescription \
	JSONSerialization JSONEncoder PropertyListSerialization PropertyListEncoder NSKeyedArchiver \
	createFile fopen open URLSession socket sendto sendmsg; do
	pin_tok sink 0 "$tok"
done
# W1 spawn: no child process, no process-name or process-table API, no private symbol binding.
for tok in Process NSTask posix_spawn posix_spawnp system popen fork vfork execv execve execvp execvP \
	execl execlp execle NSWorkspace NSRunningApplication NSAppleScript NSUserScriptTask processName \
	proc_name proc_pidpath proc_pidinfo proc_listpids proc_listallpids sysctl sysctlbyname kinfo_proc \
	dlopen dlsym _silgen_name _cdecl _extern; do
	pin_tok spawn 0 "$tok"
done
# W1 import: exactly these two modules (no AppKit, ScreenCaptureKit, ApplicationServices, ...).
IMPORTS="$({ grep -E '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]' "$CODE" || true; } | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | sorted_words)"
pin_record import "$IMPORTS" "import CoreGraphics import Foundation" "import lines"
pin_end
check "$PIN_BAD" "$(pin_name "W1 red-line grammar (default-deny)")" "window ids = 4 keys + tool names; item / windowTable only in pinned shapes; one output fn; no sink/serialiser/spawn/name API; 2 imports" "$PIN_EVID"

# W2: the line grammar, printed and not just built (gate r1 I-2 1, m-6).
pin_begin w2
pin_fold format 1 'return "[wincount-start] app-pid=\(pid) period-s=\(periodS) helper-sha8=\(sha8)"'
pin_fold format 1 'return "[wincount] seq=\(seq) ts=\(ts) cur-a=\(curA) cur-b=\(curB) pid=\(pid) found=\(found ? 1 : 0) l0=\(l0) l3=\(l3) l25=\(l25) lx=\(lx) wins=\(wins)"'
pin_fold format 1 'return "[wincount-end] rows=\(rows) reason=\(reason)"'
pin_fold format 1 'return "[wincount-selfcheck] \(status) entries=\(entries) total=\(total) keys=owner-pid,layer,number,bounds"'
pin_fold format 1 'return "[wincount-usage] window-count-sampler --pid <p> --period-s <P> --judgement-file <path> [--timeout-s <T>] [--self-check] (p, P, T: whole numbers >= 1)"'
for prefix in '[wincount-start]' '[wincount]' '[wincount-end]' '[wincount-selfcheck]' '[wincount-usage]'; do
	pin_fold prefix 1 "$prefix"
done
pin_fold prefix 5 '[wincount'
# Every writeLine( call is one of these nine; the tenth writeLine token is the definition.
pin_tok print 10 writeLine
pin_fold print 1 'func writeLine(_ line: String) {'
pin_fold print 1 'writeLine(buildUsageLine())'
pin_fold print 1 'writeLine(buildSelfCheckLine(status: "ok", entries: entries, total: total))'
pin_fold print 1 'writeLine(buildSelfCheckLine(status: "empty", entries: entries, total: total))'
pin_fold print 1 'writeLine(buildStartLine(pid: pid, periodS: periodS, sha8: sha8))'
pin_fold print 1 'writeLine(buildEndLine(rows: seq, reason: "timeout"))'
pin_fold print 1 'writeLine(buildEndLine(rows: seq, reason: "done"))'
pin_fold print 1 'writeLine(buildEndLine(rows: seq, reason: "enum-nil"))'
pin_fold print 1 'writeLine(buildSampleLine( seq: seq, ts: ts, curA: curA, curB: curB, pid: pid, found: found, l0: l0, l3: l3, l25: l25, lx: lx, wins: wins ))'
pin_fold print 1 'writeLine(buildEndLine(rows: seq, reason: "pid-gone"))'
# Each builder: its definition plus exactly the calls above.
pin_tok builder 2 buildStartLine
pin_tok builder 2 buildSampleLine
pin_tok builder 5 buildEndLine
pin_tok builder 3 buildSelfCheckLine
pin_tok builder 2 buildUsageLine
REASONS="$({ grep -oE 'reason: "[^"]*"' "$CODE" || true; } | sed 's/^reason: "//; s/"$//' | sorted_words)"
pin_record reason "$REASONS" "done enum-nil pid-gone timeout" "reason literal set"
pin_fold reason 4 'reason: "'
pin_end
check "$PIN_BAD" "$(pin_name "W2 line grammar, every line printed")" "5 whole format strings verbatim; 5 prefixes, no sixth; 9 writeLine(build...) call shapes; reasons = done/pid-gone/timeout/enum-nil" "$PIN_EVID"

# W3: one CGWindowListCopyWindowInfo( call (gate r1 m-5), on-screen only, behind one function
# with two consumers.
pin_begin w3
pin_tok call 1 CGWindowListCopyWindowInfo
pin_fold call 1 'CGWindowListCopyWindowInfo('
pin_fold call 1 'return CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: AnyObject]]'
pin_tok option 1 optionOnScreenOnly
pin_tok option 1 kCGNullWindowID
OPTIONS="$({ grep -E '^option' "$TOKENS" || true; } | sorted_words)"
pin_record option "$OPTIONS" "optionOnScreenOnly" "CGWindowListOption token set"
pin_tok consumer 3 copyWindowList
pin_fold consumer 1 'func copyWindowList() -> [[String: AnyObject]]? {'
pin_fold consumer 2 '= copyWindowList()'
pin_end
check "$PIN_BAD" "$(pin_name "W3 one CGWindowListCopyWindowInfo call")" "1 call, .optionOnScreenOnly + kCGNullWindowID, no other option; copyWindowList(): definition + 2 consumers" "$PIN_EVID"

# W5: the sampling semantics, verbatim (gate r1 I-2 2, I-1, m-1..m-4, m-7, m-9).
pin_begin w5
# W5 loop: the whole main loop, contiguous. cur-a is read before the one enumeration and cur-b
# after the extraction (gate r1 M4/M5/M6), found is process existence (M10), a nil table ends
# the run as enum-nil instead of reading as an empty row (m-1), the timeout is measured on
# ContinuousClock (m-9) and is the only end printed as reason=timeout (M13).
pin_fold loop 1 'guard let sha8 = helperSha8() else { exit(2) } writeLine(buildStartLine(pid: pid, periodS: periodS, sha8: sha8)) let clock = ContinuousClock() let startedAt = clock.now var seq = 0 while true { if let timeoutS = opts.timeoutS, clock.now - startedAt >= .seconds(timeoutS) { writeLine(buildEndLine(rows: seq, reason: "timeout")) exit(0) } if terminateRequested { writeLine(buildEndLine(rows: seq, reason: "done")) exit(0) } let curA = countNewlines(path: judgementFile) guard let windowTable = copyWindowList() else { writeLine(buildEndLine(rows: seq, reason: "enum-nil")) exit(2) } let entries = filterEntries(windowTable, pid: pid) let curB = countNewlines(path: judgementFile) let found = processExists(pid: pid) let (l0, l3, l25, lx, wins) = summarizeEntries(entries) let ts = Int(Date().timeIntervalSince1970) seq += 1 writeLine(buildSampleLine( seq: seq, ts: ts, curA: curA, curB: curB, pid: pid, found: found, l0: l0, l3: l3, l25: l25, lx: lx, wins: wins )) if !found { writeLine(buildEndLine(rows: seq, reason: "pid-gone")) exit(0) } sleepInterruptible(seconds: periodS) }'
pin_tok loop 3 countNewlines
pin_tok loop 2 processExists
pin_tok loop 2 summarizeEntries
pin_tok loop 3 filterEntries
pin_tok loop 2 sleepInterruptible
pin_tok clock 1 Date
pin_tok clock 1 ContinuousClock
# W5 cursor: wc -l semantics, newline bytes only.
pin_fold cursor 1 'for byte in chunk where byte == 0x0A { count += 1 }'
# W5 filter: the owner-PID filter, once (M7); a missing layer key lands in lx, not l0 (m-2).
pin_fold filter 1 'guard let ownerPID = item[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid else { continue }'
pin_tok filter 2 ownerPID
pin_fold filter 1 'let layer = (item[kCGWindowLayer as String] as? Int) ?? Int.min'
# W5 bucket: the four layer buckets (M15) and the number-ascending wins list (M9).
pin_fold bucket 1 'switch e.layer { case 0: l0 += 1 case 3: l3 += 1 case 25: l25 += 1 default: lx += 1 }'
# shellcheck disable=SC2016  # $0 / $1 are Swift closure arguments, matched literally
pin_fold bucket 1 'let sorted = entries.sorted { $0.number < $1.number } let wins = sorted.isEmpty ? "none" : sorted.map { "\($0.number):\($0.layer):\($0.width)x\($0.height)" }.joined(separator: ",")'
# W5 found: process existence, independent of windows (M10).
pin_fold found 1 'func processExists(pid: Int32) -> Bool { if kill(pid, 0) == 0 { return true } return errno == EPERM }'
# W5 flush: print then fflush in the one output function, stdout line-buffered (M14).
pin_fold flush 1 'setvbuf(stdout, nil, _IOLBF, 1 << 12)'
pin_fold flush 1 'func writeLine(_ line: String) { print(line) fflush(stdout) }'
# W5 selfcheck: entries come from the extraction for the target PID; with --pid, zero entries is
# a fail (exit 3), never ok (gate r1 I-1, M17).
pin_fold selfcheck 1 'if opts.selfCheck { let targetPid = opts.pid ?? getpid() guard let windowTable = copyWindowList() else { exit(2) } let entries = filterEntries(windowTable, pid: targetPid).count let total = windowTable.count let passed = opts.pid == nil ? total > 0 : entries > 0 if passed { writeLine(buildSelfCheckLine(status: "ok", entries: entries, total: total)) exit(0) } writeLine(buildSelfCheckLine(status: "empty", entries: entries, total: total)) exit(3) }'
# W5 signal: one handling for SIGTERM, SIGINT and SIGHUP (M12, m-7).
pin_fold signal 1 'nonisolated(unsafe) var terminateRequested = false signal(SIGTERM) { _ in terminateRequested = true } signal(SIGINT) { _ in terminateRequested = true } signal(SIGHUP) { _ in terminateRequested = true }'
pin_tok signal 3 signal
pin_tok signal 6 terminateRequested
# W5 usage: --pid >= 1 (m-3); every refusal is the usage line and exit 64.
pin_fold usage 1 'func usageErrorExit() -> Never { writeLine(buildUsageLine()) exit(64) }'
pin_fold usage 1 'guard i < args.count, let v = Int32(args[i]), v >= 1 else { usageErrorExit() }'
pin_fold usage 2 'guard i < args.count, let v = Int(args[i]), v >= 1 else { usageErrorExit() }'
# W5 sha8: the executable's own bytes via Bundle.main.executablePath, never argv[0] (m-4).
pin_fold sha8 1 'guard let path = Bundle.main.executablePath, let data = FileManager.default.contents(atPath: path) else { return nil }'
pin_tok sha8 1 Bundle
pin_tok sha8 1 CommandLine
pin_fold sha8 1 'let opts = parseArgs(Array(CommandLine.arguments.dropFirst()))'
pin_end
check "$PIN_BAD" "$(pin_name "W5 sampling semantics, verbatim")" "main loop contiguous (timeout/done/cur-a/enum/cur-b/found/row/pid-gone); filter, sentinel, buckets, sort, found, flush, self-check, signals, --pid>=1, sha8 path" "$PIN_EVID"

echo "== binary cases =="
SAMPLE_RE='^\[wincount\] seq=[1-9][0-9]* ts=[0-9]+ cur-a=[0-9]+ cur-b=[0-9]+ pid=[1-9][0-9]* found=[01] l0=[0-9]+ l3=[0-9]+ l25=[0-9]+ lx=[0-9]+ wins=(none|[0-9]+:-?[0-9]+:[0-9]+x[0-9]+(,[0-9]+:-?[0-9]+:[0-9]+x[0-9]+)*)$'
SELFCHECK_TAIL=' keys=owner-pid,layer,number,bounds$'
NO_PID=99999999

# wait_for_line <file> <ERE> <tenths>: polls until a line of <file> matches, at most <tenths> x 0.1 s.
wait_for_line() {
	local i=0
	while [ "$i" -lt "$3" ]; do
		if grep -qE -- "$2" "$1" 2>/dev/null; then return 0; fi
		sleep 0.1
		i=$((i + 1))
	done
	return 1
}

# run_bounded <seconds> <stdout+stderr file> <command...>: runs one command in the background and
# kills it if it has not ended after <seconds>, so a regressed binary that never ends (a refused
# argument accepted, a lost timeout) fails its case instead of hanging the suite. Sets BOUNDED_RC
# (137 when the watchdog fired).
BOUNDED_RC=0
run_bounded() {
	local secs="$1" out="$2" pid wd
	shift 2
	"$@" >"$out" 2>&1 &
	pid=$!
	(
		sleep "$secs"
		kill -s KILL "$pid" 2>/dev/null
	) &
	wd=$!
	BOUNDED_RC=0
	wait "$pid" || BOUNDED_RC=$?
	kill "$wd" 2>/dev/null || true
	wait "$wd" 2>/dev/null || true
}

if [ -z "$BIN" ]; then
	printf 'NOTE  %-40s WCS_BIN is not set, so there is no binary under test (there is no default path)\n' "binary cases"
	printf '      Build outside the repository tree with: swiftc -O -o <dir>/window-count-sampler Tools/window-count-sampler/main.swift, then set WCS_BIN=<dir>/window-count-sampler.\n'
	NOT_RUN=$((NOT_RUN + 1))
elif [ ! -x "$BIN" ]; then
	printf 'FAIL  %-40s WCS_BIN is set but is not an executable file\n' "binary present"
	FAILURES=$((FAILURES + 1))
else
	BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

	# W4m: both language modes compile (gate r1 m-8), and WCS_BIN is exactly the default-mode
	# build of the source under test (m-10: freshness by content, not by mtime).
	mkdir -p "$TEST_DIR/build/src" "$TEST_DIR/build/default" "$TEST_DIR/build/v6"
	cp "$SRC" "$TEST_DIR/build/src/main.swift"
	RC5=127
	RC6=127
	if command -v swiftc >/dev/null 2>&1; then
		RC5=0
		swiftc -O -o "$TEST_DIR/build/default/window-count-sampler" "$TEST_DIR/build/src/main.swift" >"$TEST_DIR/w4m-default.txt" 2>&1 || RC5=$?
		RC6=0
		swiftc -swift-version 6 -O -o "$TEST_DIR/build/v6/window-count-sampler" "$TEST_DIR/build/src/main.swift" >"$TEST_DIR/w4m-v6.txt" 2>&1 || RC6=$?
	fi
	SAME=1
	if [ "$RC5" -eq 0 ] && cmp -s "$BIN" "$TEST_DIR/build/default/window-count-sampler"; then SAME=0; fi
	OK=0
	[ "$RC5" -eq 0 ] || OK=1
	[ "$RC6" -eq 0 ] || OK=1
	[ "$SAME" -eq 0 ] || OK=1
	{
		printf 'swiftc -O rc=%s; swiftc -swift-version 6 -O rc=%s; WCS_BIN identical to the default-mode build: %s\n' "$RC5" "$RC6" "$([ "$SAME" -eq 0 ] && echo yes || echo no)"
		cat "$TEST_DIR/w4m-default.txt" "$TEST_DIR/w4m-v6.txt" 2>/dev/null || true
	} >"$TEST_DIR/w4m.txt"
	check "$OK" "W4m both language modes; binary is fresh" "swiftc -O and -swift-version 6 -O both build; WCS_BIN byte-identical to the default-mode build" "$TEST_DIR/w4m.txt"
fi

if [ -n "$BIN" ] && [ -x "$BIN" ] && [ "${SAME:-1}" -ne 0 ]; then
	printf 'NOTE  %-40s skipped: WCS_BIN is not the build of this source (rebuild it with the command above)\n' "behavioural cases"
	NOT_RUN=$((NOT_RUN + 1))
elif [ -n "$BIN" ] && [ -x "$BIN" ]; then
	EXPECT_SHA8="$(shasum -a 256 "$BIN" | cut -c1-8)"
	JF3="$TEST_DIR/judgement-3.txt"
	printf 'one\ntwo\nthree\n' >"$JF3"

	# The fixture: one borderless normal (layer 0) window, then one borderless floating (layer 3)
	# window, so the floating one has the higher number but sits in front (the table's own order
	# is front to back, the reverse of the number order); then one window that is created but never
	# shown, which only a non-on-screen enumeration would count. No title is ever set.
	mkdir -p "$TEST_DIR/fixture"
	cat >"$TEST_DIR/fixture/main.swift" <<'SWIFT'
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let normal = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 160, height: 90), styleMask: [.borderless], backing: .buffered, defer: false)
normal.orderFrontRegardless()
let floating = NSWindow(contentRect: NSRect(x: 220, y: 40, width: 120, height: 70), styleMask: [.borderless], backing: .buffered, defer: false)
floating.level = .floating
floating.orderFrontRegardless()
let hidden = NSWindow(contentRect: NSRect(x: 380, y: 40, width: 100, height: 50), styleMask: [.borderless], backing: .buffered, defer: false)
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(0) }
app.run()
SWIFT
	FIX_PID=""
	if swiftc -O -o "$TEST_DIR/fixture/wcs-fixture" "$TEST_DIR/fixture/main.swift" >"$TEST_DIR/fixture-build.txt" 2>&1; then
		"$TEST_DIR/fixture/wcs-fixture" >/dev/null 2>&1 &
		FIX_PID=$!
	fi

	# W4a: the self-check discriminates (gate r1 I-1): own PID => ok with entries=0 and a non-empty
	# table; a PID that does not exist => empty, exit 3; the fixture => ok with its two entries.
	RC=0
	"$BIN" --self-check >"$TEST_DIR/w4a-own.txt" 2>&1 || RC=$?
	OK=0
	[ "$RC" -eq 0 ] || OK=1
	[ "$(wc -l <"$TEST_DIR/w4a-own.txt" | tr -d '[:space:]')" -eq 1 ] || OK=1
	grep -qE "^\[wincount-selfcheck\] ok entries=0 total=[1-9][0-9]*$SELFCHECK_TAIL" "$TEST_DIR/w4a-own.txt" || OK=1
	RC_NO=0
	"$BIN" --self-check --pid "$NO_PID" >"$TEST_DIR/w4a-none.txt" 2>&1 || RC_NO=$?
	[ "$RC_NO" -eq 3 ] || OK=1
	[ "$(wc -l <"$TEST_DIR/w4a-none.txt" | tr -d '[:space:]')" -eq 1 ] || OK=1
	grep -qE "^\[wincount-selfcheck\] empty entries=0 total=[0-9]+$SELFCHECK_TAIL" "$TEST_DIR/w4a-none.txt" || OK=1
	RC_FIX=1
	: >"$TEST_DIR/w4a-fixture.txt"
	if [ -n "$FIX_PID" ]; then
		for _ in $(seq 1 50); do
			RC_FIX=0
			"$BIN" --self-check --pid "$FIX_PID" >"$TEST_DIR/w4a-fixture.txt" 2>&1 || RC_FIX=$?
			if [ "$RC_FIX" -eq 0 ] && grep -qE ' entries=2 ' "$TEST_DIR/w4a-fixture.txt"; then break; fi
			sleep 0.1
		done
	fi
	[ "$RC_FIX" -eq 0 ] || OK=1
	grep -qE "^\[wincount-selfcheck\] ok entries=2 total=[1-9][0-9]*$SELFCHECK_TAIL" "$TEST_DIR/w4a-fixture.txt" || OK=1
	{
		printf 'own pid: rc=%s: %s\n' "$RC" "$(cat "$TEST_DIR/w4a-own.txt")"
		printf 'no such pid: rc=%s (expected 3): %s\n' "$RC_NO" "$(cat "$TEST_DIR/w4a-none.txt")"
		printf 'fixture (%s): rc=%s: %s\n' "${FIX_PID:-not started, see fixture build}" "$RC_FIX" "$(cat "$TEST_DIR/w4a-fixture.txt")"
	} >"$TEST_DIR/w4a.txt"
	check "$OK" "W4a --self-check discriminates" "own pid: ok entries=0 total>0; no such pid: empty, exit 3; fixture: ok entries=2" "$TEST_DIR/w4a.txt"

	# W4b / W4c / W4e: one run against a PID that does not exist, with a static 3-line file. The
	# start line carries the executable's own sha8, also when the tool is found through PATH (m-4);
	# the one row reads cur-a=3 cur-b=3 and nothing but zeros and none (M7); the run ends pid-gone.
	run_bounded 8 "$TEST_DIR/w4b-stdout.txt" "$BIN" --pid "$NO_PID" --period-s 1 --timeout-s 5 --judgement-file "$JF3"
	RC=$BOUNDED_RC
	mkdir -p "$TEST_DIR/pathbin"
	ln -s "$BIN" "$TEST_DIR/pathbin/window-count-sampler"
	run_bounded 8 "$TEST_DIR/w4b-path.txt" env PATH="$TEST_DIR/pathbin:$PATH" window-count-sampler --pid "$NO_PID" --period-s 1 --timeout-s 5 --judgement-file "$JF3"
	RC_PATH=$BOUNDED_RC
	START_WANT="[wincount-start] app-pid=$NO_PID period-s=1 helper-sha8=$EXPECT_SHA8"
	OK=0
	[ "$RC" -eq 0 ] || OK=1
	[ "$RC_PATH" -eq 0 ] || OK=1
	[ "$(wc -l <"$TEST_DIR/w4b-stdout.txt" | tr -d '[:space:]')" -eq 3 ] || OK=1
	[ "$(sed -n 1p "$TEST_DIR/w4b-stdout.txt")" = "$START_WANT" ] || OK=1
	[ "$(sed -n 1p "$TEST_DIR/w4b-path.txt")" = "$START_WANT" ] || OK=1
	[ "$(sed -n 3p "$TEST_DIR/w4b-stdout.txt")" = "[wincount-end] rows=1 reason=pid-gone" ] || OK=1
	{
		printf 'rc=%s (via PATH rc=%s); expected start line: %s\n--- stdout ---\n' "$RC" "$RC_PATH" "$START_WANT"
		cat "$TEST_DIR/w4b-stdout.txt"
		printf -- '--- via PATH, first line ---\n'
		sed -n 1p "$TEST_DIR/w4b-path.txt"
	} >"$TEST_DIR/w4b.txt"
	check "$OK" "W4b pid-gone lifecycle, own sha8" "start line with the executable's sha8 (also via PATH), one row, [wincount-end] rows=1 reason=pid-gone" "$TEST_DIR/w4b.txt"
	ROW="$(sed -n 2p "$TEST_DIR/w4b-stdout.txt")"
	OK=0
	case "$ROW" in *" cur-a=3 cur-b=3 "*) ;; *) OK=1 ;; esac
	printf 'row: %s\n' "$ROW" >"$TEST_DIR/w4c.txt"
	check "$OK" "W4c cur-a/cur-b against a 3-line file" "a static 3-line judgement file reads cur-a=3 cur-b=3" "$TEST_DIR/w4c.txt"
	OK=0
	printf '%s\n' "$ROW" | grep -qE "$SAMPLE_RE" || OK=1
	case "$ROW" in *" pid=$NO_PID found=0 l0=0 l3=0 l25=0 lx=0 wins=none") ;; *) OK=1 ;; esac
	printf 'row: %s\n' "$ROW" >"$TEST_DIR/w4e.txt"
	check "$OK" "W4e no such PID: nothing counted" "the row matches the full WC-1 grammar and ends found=0 l0=0 l3=0 l25=0 lx=0 wins=none" "$TEST_DIR/w4e.txt"

	# W4b′: the fixture's one row -- found=1, l0=1, l3=1, and exactly its two on-screen entries in
	# number order with their frame sizes; the never-shown window is not counted (M2, M7, M9, M15;
	# I-2 4).
	RC=1
	: >"$TEST_DIR/w4b2-stdout.txt"
	if [ -n "$FIX_PID" ]; then
		run_bounded 5 "$TEST_DIR/w4b2-stdout.txt" "$BIN" --pid "$FIX_PID" --period-s 1 --timeout-s 1 --judgement-file "$JF3"
		RC=$BOUNDED_RC
	fi
	ROW="$(sed -n 2p "$TEST_DIR/w4b2-stdout.txt")"
	OK=0
	[ "$RC" -eq 0 ] || OK=1
	printf '%s\n' "$ROW" | grep -qE "$SAMPLE_RE" || OK=1
	case "$ROW" in *" pid=$FIX_PID found=1 l0=1 l3=1 l25=0 lx=0 wins="*) ;; *) OK=1 ;; esac
	WINS="${ROW##* wins=}"
	printf '%s\n' "$WINS" | grep -qE '^[0-9]+:0:160x90,[0-9]+:3:120x70$' || OK=1
	N1="$(printf '%s' "$WINS" | sed -n 's/^\([0-9]*\):.*/\1/p')"
	N2="$(printf '%s' "$WINS" | sed -n 's/^[^,]*,\([0-9]*\):.*/\1/p')"
	[ -n "$N1" ] && [ -n "$N2" ] && [ "$N1" -lt "$N2" ] || OK=1
	{
		printf 'rc=%s fixture pid=%s\n--- stdout ---\n' "$RC" "${FIX_PID:-none}"
		cat "$TEST_DIR/w4b2-stdout.txt"
	} >"$TEST_DIR/w4b2.txt"
	check "$OK" "W4b′ a PID with windows is counted" "fixture row: found=1 l0=1 l3=1 l25=0 lx=0, wins <n1>:0:160x90,<n2>:3:120x70 with n1<n2" "$TEST_DIR/w4b2.txt"
	if [ -n "$FIX_PID" ]; then
		kill "$FIX_PID" 2>/dev/null || true
		wait "$FIX_PID" 2>/dev/null || true
	fi

	# W4d: cur-a / cur-b are live reads of the file on every row: two lines appended while a live,
	# window-less PID (this shell) is sampled show up as cur-b=5 on the row that straddles them or
	# as cur-a=5 on a later row; every row keeps cur-a <= cur-b, never decreases, reads found=1 with
	# wins=none (M10), and the run ends by timeout.
	JFD="$TEST_DIR/judgement-grow.txt"
	printf 'one\ntwo\nthree\n' >"$JFD"
	"$BIN" --pid "$$" --period-s 1 --timeout-s 4 --judgement-file "$JFD" >"$TEST_DIR/w4d-stdout.txt" 2>&1 &
	SPID=$!
	wait_for_line "$TEST_DIR/w4d-stdout.txt" '^\[wincount\] seq=1 ' 50 || true
	printf 'four\nfive\n' >>"$JFD"
	wait_for_line "$TEST_DIR/w4d-stdout.txt" '^\[wincount-end\] ' 80 || kill -s KILL "$SPID" 2>/dev/null || true
	RC=0
	wait "$SPID" || RC=$?
	OK=0
	[ "$RC" -eq 0 ] || OK=1
	grep -E '^\[wincount\] ' "$TEST_DIR/w4d-stdout.txt" >"$TEST_DIR/w4d-rows.txt" || true
	[ "$(wc -l <"$TEST_DIR/w4d-rows.txt" | tr -d '[:space:]')" -ge 3 ] || OK=1
	if grep -vqE "$SAMPLE_RE" "$TEST_DIR/w4d-rows.txt"; then OK=1; fi
	if grep -vqE " pid=$$ found=1 l0=0 l3=0 l25=0 lx=0 wins=none\$" "$TEST_DIR/w4d-rows.txt"; then OK=1; fi
	sed -n 1p "$TEST_DIR/w4d-rows.txt" | grep -qE ' cur-a=3 ' || OK=1
	awk '{ a = $4; b = $5; sub(/^cur-a=/, "", a); sub(/^cur-b=/, "", b); a += 0; b += 0
		if (a > b || a < pb) bad = 1
		if (a == 3 && b == 5) straddle = 1
		if (NR > 1 && a == 5) later = 1
		pb = b }
		END { exit (bad || !(straddle || later)) ? 1 : 0 }' "$TEST_DIR/w4d-rows.txt" || OK=1
	[ "$(tail -1 "$TEST_DIR/w4d-stdout.txt")" = "[wincount-end] rows=$(wc -l <"$TEST_DIR/w4d-rows.txt" | tr -d '[:space:]') reason=timeout" ] || OK=1
	{
		printf 'rc=%s\n--- stdout ---\n' "$RC"
		cat "$TEST_DIR/w4d-stdout.txt"
	} >"$TEST_DIR/w4d.txt"
	check "$OK" "W4d cursors are live, around each read" "3 -> 5 lines appended mid-run: cur-a=3 first, then cur-b=5 or a later cur-a=5; cur-a<=cur-b, monotone; found=1 wins=none" "$TEST_DIR/w4d.txt"

	# W4f: --timeout-s ends the run as reason=timeout (M13).
	run_bounded 5 "$TEST_DIR/w4f-stdout.txt" "$BIN" --pid "$$" --period-s 1 --timeout-s 1 --judgement-file "$JF3"
	RC=$BOUNDED_RC
	OK=0
	[ "$RC" -eq 0 ] || OK=1
	[ "$(wc -l <"$TEST_DIR/w4f-stdout.txt" | tr -d '[:space:]')" -eq 3 ] || OK=1
	[ "$(tail -1 "$TEST_DIR/w4f-stdout.txt")" = "[wincount-end] rows=1 reason=timeout" ] || OK=1
	{
		printf 'rc=%s\n--- stdout ---\n' "$RC"
		cat "$TEST_DIR/w4f-stdout.txt"
	} >"$TEST_DIR/w4f.txt"
	check "$OK" "W4f --timeout-s ends as timeout" "--timeout-s 1 --period-s 1: one row, then [wincount-end] rows=1 reason=timeout, exit 0" "$TEST_DIR/w4f.txt"

	# W4g: SIGTERM, SIGINT and SIGHUP each end the run as reason=done within a slice of the sleep,
	# exit 0 (M12, m-7). The sampler runs in the background of this non-interactive shell, so it
	# starts with SIGINT ignored: its own handler has to replace that.
	OK=0
	: >"$TEST_DIR/w4g.txt"
	for sig in TERM INT HUP; do
		"$BIN" --pid "$$" --period-s 5 --timeout-s 30 --judgement-file "$JF3" >"$TEST_DIR/w4g-$sig.txt" 2>&1 &
		SPID=$!
		wait_for_line "$TEST_DIR/w4g-$sig.txt" '^\[wincount\] seq=1 ' 50 || true
		kill -s "$sig" "$SPID" 2>/dev/null || true
		ENDED=0
		wait_for_line "$TEST_DIR/w4g-$sig.txt" '^\[wincount-end\] ' 30 || ENDED=1
		[ "$ENDED" -eq 0 ] || kill -s KILL "$SPID" 2>/dev/null || true
		RC=0
		wait "$SPID" || RC=$?
		[ "$ENDED" -eq 0 ] || OK=1
		[ "$RC" -eq 0 ] || OK=1
		[ "$(tail -1 "$TEST_DIR/w4g-$sig.txt")" = "[wincount-end] rows=1 reason=done" ] || OK=1
		printf 'SIG%s: rc=%s, end line within 3 s: %s, last line: %s\n' "$sig" "$RC" "$([ "$ENDED" -eq 0 ] && echo yes || echo no)" "$(tail -1 "$TEST_DIR/w4g-$sig.txt")" >>"$TEST_DIR/w4g.txt"
	done
	check "$OK" "W4g TERM / INT / HUP end as done" "each signal after the first row: [wincount-end] rows=1 reason=done within 3 s, exit 0" "$TEST_DIR/w4g.txt"

	# W4h: every refusal is the usage line alone and exit 64 -- --pid 0 and -1 included (m-3).
	USAGE_WANT='[wincount-usage] window-count-sampler --pid <p> --period-s <P> --judgement-file <path> [--timeout-s <T>] [--self-check] (p, P, T: whole numbers >= 1)'
	OK=0
	: >"$TEST_DIR/w4h.txt"
	usage_case() {
		local rc
		run_bounded 5 "$TEST_DIR/w4h-out.txt" "$BIN" "$@"
		rc=$BOUNDED_RC
		[ "$rc" -eq 64 ] || OK=1
		[ "$(wc -l <"$TEST_DIR/w4h-out.txt" | tr -d '[:space:]')" -eq 1 ] || OK=1
		[ "$(cat "$TEST_DIR/w4h-out.txt")" = "$USAGE_WANT" ] || OK=1
		printf 'args [%s]: rc=%s, %s line(s)\n' "$*" "$rc" "$(wc -l <"$TEST_DIR/w4h-out.txt" | tr -d '[:space:]')" >>"$TEST_DIR/w4h.txt"
	}
	# --timeout-s bounds the two --pid cases: a binary that wrongly accepts them samples a live
	# "process" (kill(0|-1, 0) succeeds) and would otherwise never end.
	usage_case --pid 0 --period-s 1 --judgement-file "$JF3" --timeout-s 2
	usage_case --pid -1 --period-s 1 --judgement-file "$JF3" --timeout-s 2
	usage_case --self-check --pid 0
	usage_case --pid "$NO_PID" --period-s 0 --judgement-file "$JF3"
	usage_case --pid "$NO_PID" --period-s 1 --judgement-file "$JF3" --timeout-s 0
	usage_case --pid "$NO_PID" --period-s 1
	usage_case --pid "$NO_PID" --period-s 1 --judgement-file "$JF3" --bogus
	check "$OK" "W4h usage refusals" "--pid 0 / -1, --period-s 0, --timeout-s 0, missing --judgement-file, unknown flag: the usage line alone, exit 64" "$TEST_DIR/w4h.txt"
fi

echo "== summary =="
printf 'failures=%s not_run=%s\n' "$FAILURES" "$NOT_RUN"
[ "$FAILURES" -eq 0 ]
