#!/usr/bin/env bash
# Offline test suite for Scripts/lab/relay.command -- the one-shot RemoteApp relay that
# Terminal.app runs against the owner's lab host. Its sibling, test-run-matrix-offline.sh,
# deliberately does NOT copy relay.command into its sandbox (a shim of `open` stands in for
# the whole Terminal hop), so until this file existed the relay's OWN logic -- the fail-closed
# boundary refusal, the job.env contract, the argv it hands xfreerdp, the TIMEOUT kill, the
# DONE line every caller polls on, the log-truncation-at-start -- had no offline coverage at
# all and rotted unnoticed by construction. This suite drives the REAL relay.command, with the
# REAL jobs/*.env as inputs where a job is involved.
#
# Safe in CI, by construction rather than by promise:
#   1. `xfreerdp`, `osascript` and `nc` are PATH-shimmed, and the suite ASSERTS before the first
#      case that the shim is what PATH resolves each of them to. The xfreerdp shim records its
#      argv and either exits at once or `exec`s a sleep (so the relay's TIMEOUT kill has a real
#      process to kill and killing it leaves no orphan). It opens no socket. The client-pin cases
#      (13*) pin copies of the same shim that live under the sandbox's pins/ directory, never on
#      PATH; every copy answers `--version` with its own fixed line (or fails it on purpose). Case
#      13l also compiles a tiny C stub with `cc`, when one is available, because a #! script never
#      sees its own argv[0]; it records its argv and exits, and opens nothing either.
#   2. HOME is redirected into the sandbox. Its host.env carries an RFC 5737 documentation
#      address and placeholder account strings (never a real host, never a real credential).
#   3. relay.command is copied into a sandbox tree at the same depth as the real one, so its
#      own `$LAB_DIR/../..` derivation lands REPO_ROOT (and therefore .build/lab-runtime,
#      job.env, relay.log and the share) inside the sandbox. The real runtime is never touched.
#   4. TERM_PROGRAM is cleared, so the relay's Terminal self-close branch is never taken; the
#      osascript/nc shims exit 97 and record the call in a trace that is NOT reset between
#      cases, so the "never reached" assertion at the end covers the whole run.
#   5. The boundary gate's address check is pure arithmetic on the literal (Scripts/lib.sh
#      parses an IP literal directly; no DNS is ever consulted for one).
#
# Each case starts with `begin`, which resets the per-case trace and the sandbox log, so no
# case depends on what the previous one left behind. The mutation proofs (M1-M11) copy the
# relay with one guard disabled and require the case that claims to pin it to FAIL against
# the mutant. A pin that would also pass against the broken code pins nothing.
#
# Exit: 0 if every case passed, 1 otherwise.
set -uo pipefail

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB/../.." && pwd)"

KEEP=0
if [ "${1:-}" = "--keep" ]; then KEEP=1; fi

PASSES=0
FAILURES=0
CASE=''
pass() { printf 'PASS  %s\n' "$*"; PASSES=$((PASSES + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
note() { printf '        %s\n' "$*"; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/macdows-relay-offline.XXXXXX")" || exit 1
# Normalised, because the relay derives its own paths with `cd … && pwd` and this suite compares
# them as strings: a TMPDIR ending in `/` (macOS's does) would otherwise leave a `//` in $SB that
# the relay's argv does not carry, and a case would fail on a path spelling, not on behaviour.
SB="$(cd "$SB" && pwd)" || exit 1
# shellcheck disable=SC2329,SC2317  # invoked by the EXIT trap below
cleanup() {
	if [ "$KEEP" -eq 1 ]; then
		printf 'sandbox kept: %s\n' "$SB"
	else
		rm -rf "$SB"
	fi
}
trap cleanup EXIT

SBROOT="$SB/root"
SBLAB="$SBROOT/Scripts/lab"
SBRUNTIME="$SBROOT/.build/lab-runtime"
SBHOME="$SB/home"
LOG="$SBRUNTIME/relay.log"
# Per-case trace of xfreerdp invocations (reset by `begin`) and a run-long trace of the
# shims that must never be reached (never reset).
export LABTEST_TRACE="$SB/trace.txt"
export LABTEST_REFUSED_TRACE="$SB/refused-trace.txt"
# Run-long ledger of every xfreerdp-shim pid (never reset; the orphan check at the end reads it
# -- reading the per-case trace there would read a file `begin` had just emptied, review r3 B2).
export LABTEST_PID_LEDGER="$SB/pid-ledger.txt"
: > "$LABTEST_REFUSED_TRACE"
: > "$LABTEST_PID_LEDGER"

mkdir -p "$SBLAB" "$SBRUNTIME" "$SBHOME/.config/macdows" "$SB/bin" || exit 1
cp "$LAB/relay.command" "$SBLAB/relay.command" || exit 1
cp "$REPO_ROOT/Scripts/lib.sh" "$SBROOT/Scripts/lib.sh" || exit 1

# RFC 5737 TEST-NET-1 address and placeholder strings: never a real host, never a real
# credential. The password value is chosen to be greppable, because one case asserts that it
# never reaches relay.log.
cat > "$SBHOME/.config/macdows/host.env" <<'HOSTENV' || exit 1
WIN_HOST=192.0.2.10
WIN_USER=labtest-placeholder
WIN_PASS=LABTEST-PLACEHOLDER-SECRET-3f9a
HOSTENV
# The DEFAULT boundary file location (what the relay resolves when MACDOWS_LAB_BOUNDARY_FILE is
# unset) allows the placeholder segment; the deny file lives elsewhere and is injected by path.
ALLOW_FILE="$SBHOME/.config/macdows/lab-boundary.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="192.0.2.0/24"\n' > "$ALLOW_FILE" || exit 1
DENY_FILE="$SB/deny-boundary.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="198.51.100.0/24"\n' > "$DENY_FILE" || exit 1

# Census of the sandbox's TRACKED tree, taken once after construction: a run must write
# nothing there (only under .build/lab-runtime). Names and contents both count. The mutation
# proofs write their mutant copies into this directory on purpose (the relay derives REPO_ROOT
# from its own location), hence the exclusion; `labtest-mutant-*` is a namespace no shipping
# script produces or reads, so excluding it cannot mask a write by the code under test.
snapshot_tracked() {
	(
		cd "$SBLAB" || exit 1
		find . -type f ! -name 'labtest-mutant-*' | sort | while IFS= read -r f; do
			printf '%s  %s\n' "$(cksum < "$f")" "$f"
		done
	)
}
TRACKED_PRISTINE="$SB/tracked-pristine.txt"
snapshot_tracked > "$TRACKED_PRISTINE" || exit 1

# -- PATH shims ------------------------------------------------------------------------------

# One shim body, several copies: the PATH shim and the pinned stubs under $SB/pins (never on PATH)
# differ only in how they answer `--version`, so each copy also has its own SHA-256 -- which is
# what lets the client-line cases (13*) tell them apart.
write_xfreerdp_shim() { # <path> <--version answer line> [probe mode: ok|exit127|abort|noisy]
	{
		printf '#!/usr/bin/env bash\n'
		printf 'LABTEST_SHIM_VERSION_LINE=%q\n' "$2"
		printf 'LABTEST_SHIM_PROBE_MODE=%q\n' "${3:-ok}"
		cat <<'SHIM_XFREERDP'
# OFFLINE TEST SHIM. `--version` follows LABTEST_SHIM_PROBE_MODE:
#   ok       answer the line above, exit 0; the probe is recorded as a `version` trace line,
#            never as a dial
#   exit127  exit 127 without answering or recording (a client that cannot start)
#   abort    die of SIGABRT without answering or recording (the shape of a dyld load failure)
#   noisy    like ok, but also write $0 to stderr, record any stdin line it can read as
#            `version stdin=<line>`, and answer in FreeRDP's print_version_ex form
#            `This is FreeRDP version [<$0>] <line above>`
# Any other call records its own path ($0) and its argv, writes LABTEST_SHIM_EMIT's bytes (if set)
# to stdout, and either exits at once or `exec`s a
# sleep so the relay's TIMEOUT kill has a real process to kill. `exec` matters: it makes THIS pid
# the sleeping process, so the pid the relay kills (and the pid this suite reads from the trace)
# is the sleep itself -- no orphaned child outlives the case. Opens nothing.
set -u
if [ "${1:-}" = "--version" ]; then
	case "$LABTEST_SHIM_PROBE_MODE" in
	exit127) exit 127 ;;
	abort) kill -ABRT "$$"; exit 1 ;;
	esac
	printf 'version argv0=%s\n' "$0" >> "$LABTEST_TRACE"
	if [ "$LABTEST_SHIM_PROBE_MODE" = noisy ]; then
		printf '%s\n' "$0" >&2
		if IFS= read -r -t 1 l; then printf 'version stdin=%s\n' "$l" >> "$LABTEST_TRACE"; fi
		printf 'This is FreeRDP version [%s] %s\n' "$0" "$LABTEST_SHIM_VERSION_LINE"
	else
		printf '%s\n' "$LABTEST_SHIM_VERSION_LINE"
	fi
	exit 0
fi
{
	printf 'xfreerdp pid=%s argv0=%s' "$$" "$0"
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
} >> "$LABTEST_TRACE"
# Stand-in for FreeRDP's own log output (14*): when LABTEST_SHIM_EMIT names a file, its bytes go to
# stdout -- which is relay.log -- before anything slower runs, so a TIMEOUT=2 run has them in.
if [ -n "${LABTEST_SHIM_EMIT:-}" ]; then cat "$LABTEST_SHIM_EMIT"; fi
# pid<TAB>identity: identity is this process's own start time plus argv (ps -o lstart=,args=),
# fixed to LC_ALL=C TZ=UTC0 -- gate r1 I-2 measured that plain `ps -o lstart=` renders differently
# under a maintainer's own locale or exported TZ (a Chinese Terminal, or TZ=UTC, made every
# identity comparison miss and the orphan check below silently stopped catching real leaks). The
# orphan check at the end of this suite re-reads the SAME fixed-locale command for the same pid
# and only kills a match -- a pid the OS has since handed to an unrelated process practically
# never reproduces the same start time and argv together.
#
# THE ARGS HALF IS RECORDED AS IT WILL READ ONCE SETTLED, not as it reads on this line: lstart is
# an exec-invariant kernel property of THIS pid, but `exec sleep 30` below replaces this process's
# own argv with the sleeping child's ("sleep 30", confirmed byte for byte against a real `ps`) the
# instant it runs -- there is no code path after an exec to re-record anything. Recording the
# PRE-exec args here would permanently disagree with what orphan_scan reads from the live process
# afterwards, which is the exact kind of mismatch this fix exists to remove; predicting the known,
# deterministic post-exec argv instead keeps the write side and the read side describing the SAME
# process state. The non-sleeping modes never reach a live orphan check (they exit at once), so
# their own argv is recorded as invoked -- it is written for completeness, not because anything
# ever depends on it matching after the fact.
case "${LABTEST_XFREERDP_MODE:-exit0}" in
sleep) LABTEST_SHIM_ARGS='sleep 30' ;;
*) LABTEST_SHIM_ARGS="$0" ;;
esac
LABTEST_SHIM_LSTART="$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$$" 2>/dev/null | tr -s '[:space:]' ' ')"
LABTEST_SHIM_IDENT="$(printf '%s %s' "$LABTEST_SHIM_LSTART" "$LABTEST_SHIM_ARGS" | tr -s '[:space:]' ' ')"
LABTEST_SHIM_IDENT="$(printf '%s' "$LABTEST_SHIM_IDENT" | sed 's/^ *//;s/ *$//')"
printf '%s\t%s\n' "$$" "$LABTEST_SHIM_IDENT" >> "$LABTEST_PID_LEDGER"
case "${LABTEST_XFREERDP_MODE:-exit0}" in
sleep) exec sleep 30 ;;
exit1) exit 1 ;;
*) exit 0 ;;
esac
SHIM_XFREERDP
	} > "$1" && chmod +x "$1"
}
write_xfreerdp_shim "$SB/bin/xfreerdp" 'This is FreeRDP version 9.9.9 (n/a)' || exit 1
# Pinned stubs for the client-pin cases: three that answer a version (or none), one that is not
# executable and a directory (which `-x` alone would accept).
PINS="$SB/pins"
PIN_A="$PINS/a/xfreerdp"
PIN_B="$PINS/b/xfreerdp"
PIN_NOVERSION="$PINS/noversion/xfreerdp"
PIN_NOEXEC="$PINS/noexec/xfreerdp"
PIN_DIR="$PINS/dir-pin"
mkdir -p "$PINS/a" "$PINS/b" "$PINS/noversion" "$PINS/noexec" "$PIN_DIR" || exit 1
write_xfreerdp_shim "$PIN_A" 'This is FreeRDP version 8.8.8 (n/a)' || exit 1
write_xfreerdp_shim "$PIN_B" 'This is FreeRDP version 7.7.7 (n/a)' || exit 1
# Two lines: the version token is taken from the FIRST line only, so the x.y.z on the second must
# not be picked up (13f).
write_xfreerdp_shim "$PIN_NOVERSION" "$(printf '%s\n%s' 'This is FreeRDP version n/a (no release tag)' 'Build configuration: 1.2.3')" || exit 1
write_xfreerdp_shim "$PIN_NOEXEC" 'This is FreeRDP version 6.6.6 (n/a)' || exit 1
chmod -x "$PIN_NOEXEC" || exit 1
# Clients that fail the --version probe (13k): exit 127, SIGABRT, and an interpreter that is gone.
PIN_V127="$PINS/v127/xfreerdp"
PIN_ABORT="$PINS/abort/xfreerdp"
PIN_BADINTERP="$PINS/badinterp/xfreerdp"
mkdir -p "$PINS/v127" "$PINS/abort" "$PINS/badinterp" || exit 1
write_xfreerdp_shim "$PIN_V127" 'This is FreeRDP version 5.0.1 (n/a)' exit127 || exit 1
write_xfreerdp_shim "$PIN_ABORT" 'This is FreeRDP version 5.0.2 (n/a)' abort || exit 1
printf '#!/nonexistent/labtest-interpreter\n' > "$PIN_BADINTERP" || exit 1
chmod +x "$PIN_BADINTERP" || exit 1
# A noisy client (13n) in a directory whose name carries a version of its own, as the pinned build's
# does: its print_version_ex answer puts that path before the real version, which repeats in the
# revision field.
PIN_NOISY="$PINS/xfreerdp-1.1.1/xfreerdp"
mkdir -p "$PINS/xfreerdp-1.1.1" || exit 1
write_xfreerdp_shim "$PIN_NOISY" '4.4.4 (4.4.4)' noisy || exit 1
# A `shasum` that answers no digest (13n), put on PATH only for the run that needs it.
mkdir -p "$SB/badsha" || exit 1
cat > "$SB/badsha/shasum" <<'SHIM_BADSHA' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM: a digest tool that answers something that is not a digest.
printf '%s\n' 'not-a-digest  -'
SHIM_BADSHA
chmod +x "$SB/badsha/shasum" || exit 1
# Stdin the relay is given in 13n: a probe that inherited it would read this line.
printf 'LABTEST-STDIN-SENTINEL\n' > "$SB/stdin-data.txt" || exit 1
# A compiled client for 13l (a #! script never sees its own argv[0]), built only when a working
# `cc` exists; without one 13l runs its source-shape half alone and says so. One copy doubles as
# the PATH form (via RELAY_PATH_OVERRIDE), one is execute-only (mode 0111) for the sha8 fallback.
CSTUB_DIR="$SB/cstub"
CSTUB_BIN="$CSTUB_DIR/bin/xfreerdp"
CSTUB_EXEC_ONLY="$CSTUB_DIR/exec-only/xfreerdp"
CSTUB_OK=0
mkdir -p "$CSTUB_DIR/bin" "$CSTUB_DIR/exec-only" || exit 1
cat > "$CSTUB_DIR/xfreerdp-stub.c" <<'CSTUB_SRC' || exit 1
/* OFFLINE TEST STUB: answers --version; any other call echoes argv[0] on stderr the way FreeRDP's
 * usage and error banners do, records its argv (argv[0] included) and exits. Opens nothing. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv)
{
	const char *trace = getenv("LABTEST_TRACE");
	const char *ledger = getenv("LABTEST_PID_LEDGER");
	FILE *t;
	int i;
	if (argc > 1 && strcmp(argv[1], "--version") == 0) {
		if (trace && (t = fopen(trace, "a")) != NULL) {
			fprintf(t, "version argv0=%s\n", argv[0]);
			fclose(t);
		}
		printf("This is FreeRDP version 5.5.5 (n/a)\n");
		return 0;
	}
	fprintf(stderr, "%s - offline stub banner\n", argv[0]);
	if (trace && (t = fopen(trace, "a")) != NULL) {
		fprintf(t, "xfreerdp pid=%d argv0=%s", (int)getpid(), argv[0]);
		for (i = 1; i < argc; i++)
			fprintf(t, " [%s]", argv[i]);
		fprintf(t, "\n");
		fclose(t);
	}
	if (ledger && (t = fopen(ledger, "a")) != NULL) {
		fprintf(t, "%d\n", (int)getpid());
		fclose(t);
	}
	return 0;
}
CSTUB_SRC
if command -v cc >/dev/null 2>&1 && cc -o "$CSTUB_BIN" "$CSTUB_DIR/xfreerdp-stub.c" >/dev/null 2>&1; then
	cp "$CSTUB_BIN" "$CSTUB_EXEC_ONLY" && chmod 0111 "$CSTUB_EXEC_ONLY" && CSTUB_OK=1
fi

# A real, reliably-observable zombie for the orphan-check zombie case: this platform's own
# non-interactive bash reaps a plain `( exit 0 ) &` between one `ps` call and the next -- too fast
# to catch the Z state from shell alone. This helper forks a child that exits at once and holds
# off its own wait() (so the child stays a zombie) until it is sent SIGTERM, giving the test a
# window of its own choosing. Same guard shape as CSTUB_OK; without a working `cc` the case says
# so and does not claim anything. Opens nothing, connects nothing.
ZOMBIE_MAKER="$SB/cstub/zombie-maker"
ZOMBIE_MAKER_OK=0
cat > "$SB/cstub/zombie-maker.c" <<'ZOMBIE_SRC' || exit 1
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
static volatile sig_atomic_t stop = 0;
static void on_term(int sig) { (void)sig; stop = 1; }
int main(void)
{
	pid_t child = fork();
	if (child < 0) return 1;
	if (child == 0) { _exit(0); }
	printf("%d\n", (int)child);
	fflush(stdout);
	signal(SIGTERM, on_term);
	while (!stop) { sleep(1); }
	waitpid(child, NULL, 0);
	return 0;
}
ZOMBIE_SRC
if command -v cc >/dev/null 2>&1 && cc -o "$ZOMBIE_MAKER" "$SB/cstub/zombie-maker.c" >/dev/null 2>&1; then
	ZOMBIE_MAKER_OK=1
fi

for tool in osascript nc; do
	cat > "$SB/bin/$tool" <<SHIM_REFUSE || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM: must never be reached. Records the call (run-long trace) and refuses.
printf '$tool:unexpected-call\n' >> "\$LABTEST_REFUSED_TRACE"
exit 97
SHIM_REFUSE
done
chmod +x "$SB"/bin/* || exit 1
for shim in "$SB"/bin/* "$PINS"/*/xfreerdp; do
	if ! bash -n "$shim"; then printf 'shim does not parse: %s\n' "$shim"; exit 1; fi
done
# The load-bearing safety assertion: with the sandbox PATH in force, each shimmed name MUST
# resolve to the shim -- otherwise a case would run the maintainer's real xfreerdp against
# the placeholder address. Checked before any case runs; a miss aborts the whole suite.
for tool in xfreerdp osascript nc; do
	resolved="$(PATH="$SB/bin:$PATH" command -v "$tool" || true)"
	if [ "$resolved" != "$SB/bin/$tool" ]; then
		printf 'ABORT: %s resolves to %s, not the shim\n' "$tool" "${resolved:-<nothing>}"
		exit 1
	fi
done

# Positive controls (review r2 I2 / r3 B2): prove both run-long recorders work by hitting each
# shim once through the same `env -i` the relay gets, then clear. An empty refused trace at the
# end then means "not reached", and an orphan check over the pid ledger has a ledger to read.
env -i LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" PATH="$SB/bin:$PATH" osascript -e 'x' >/dev/null 2>&1
if ! grep -qF 'osascript:unexpected-call' "$LABTEST_REFUSED_TRACE"; then
	printf 'ABORT: the refused-shim trace did not record a deliberate call\n'; exit 1
fi
: > "$LABTEST_REFUSED_TRACE"
env -i LABTEST_TRACE="$LABTEST_TRACE" LABTEST_PID_LEDGER="$LABTEST_PID_LEDGER" LABTEST_XFREERDP_MODE=exit0 PATH="$SB/bin:$PATH" xfreerdp /probe >/dev/null 2>&1
if ! awk -F'\t' '{print $1}' "$LABTEST_PID_LEDGER" | grep -qE '^[0-9]+$'; then
	printf 'ABORT: the pid ledger did not record a deliberate shim run\n'; exit 1
fi
# Gate r1 O3: a shim that stopped recording an identity (always writing an empty second field)
# must fail the suite loudly here, before any case relies on it -- an empty identity can never be
# matched by orphan_scan, which would otherwise silently blind the whole orphan check.
if ! awk -F'\t' '{print $2}' "$LABTEST_PID_LEDGER" | grep -qE '.'; then
	printf 'ABORT: the pid ledger recorded no identity for a deliberate shim run\n'; exit 1
fi
: > "$LABTEST_PID_LEDGER"
: > "$LABTEST_TRACE"

# -- Helpers ---------------------------------------------------------------------------------

# The client pin's two run-environment inputs besides relay-client.env: RELAY_ENV_PIN is passed as
# MACDOWS_XFREERDP (empty = unset, as the relay reads it) and RELAY_PATH_OVERRIDE, when non-empty,
# replaces the sandbox PATH. Both (and RELAY_STDIN) are cleared by `begin` and by `reset_run`.
RELAY_ENV_PIN=''
RELAY_PATH_OVERRIDE=''
# The relay's stdin: /dev/null unless a case names a file (13n).
RELAY_STDIN=''
# A file whose bytes the xfreerdp shim writes to its stdout (relay.log) when dialled (14*); empty =
# none. Passed to the shim as LABTEST_SHIM_EMIT.
RELAY_SHIM_EMIT=''
# LC_ALL for the relay (14g); empty = not passed at all (env -i leaves the relay without one).
RELAY_LOCALE=''
# Clears everything one relay run leaves or reads, except job.env (a case with several runs keeps
# its job and changes only the client inputs between them). `-r`: 13m makes relay-client.env a
# directory; on a symlink `rm -rf` removes the link, never its target.
reset_run() {
	: > "$LABTEST_TRACE"
	: > "$LOG"
	rm -rf "$SBRUNTIME/relay-client.env"
	RELAY_ENV_PIN=''
	RELAY_PATH_OVERRIDE=''
	RELAY_STDIN=''
	RELAY_SHIM_EMIT=''
	RELAY_LOCALE=''
}
begin() { # <case label>
	CASE="$1"
	reset_run
	rm -f "$SBRUNTIME/job.env"
}
assert_has() { # <file> <fixed string>
	if grep -qF -- "$2" "$1"; then return 0; fi
	fail "$CASE: expected [$2] in $(basename "$1")"; note "$(cat "$1")"; return 1
}
assert_lacks() { # <file> <fixed string>
	if ! grep -qF -- "$2" "$1"; then return 0; fi
	fail "$CASE: [$2] must not appear in $(basename "$1")"; note "$(cat "$1")"; return 1
}
assert_eq() { # <actual> <expected> <what>
	if [ "$1" = "$2" ]; then return 0; fi
	fail "$CASE: $3 -- expected [$2], got [$1]"; return 1
}
# Each argv element is its own assertion with its own `fail` (review r2 B1: an `else` that only
# noted meant a missing element made the case vanish instead of failing).
assert_argv_has() { # <argv line> <element>
	if [[ "$1" == *"[$2]"* ]]; then return 0; fi
	fail "$CASE: argv lacks [$2]"; note "argv: $1"; return 1
}
last_line() { tail -n 1 "$LOG" 2>/dev/null; }
done_lines() { grep -c '^DONE exit=' "$LOG" 2>/dev/null || true; }
xfreerdp_calls() { grep -c '^xfreerdp pid=' "$LABTEST_TRACE" 2>/dev/null || true; }
# Every line any xfreerdp shim or stub wrote this case -- dials AND --version probes. A refused
# run must leave none: the client is resolved and probed only once everything else has passed.
trace_lines() { grep -c '' "$LABTEST_TRACE" 2>/dev/null || true; }
xfreerdp_argv() { grep '^xfreerdp pid=' "$LABTEST_TRACE" | head -n 1; }
# Every pid the shim recorded this case; with `exec sleep` that IS the sleeping process.
kill_recorded_shims() {
	sed -n 's/^xfreerdp pid=\([0-9]*\).*/\1/p' "$LABTEST_TRACE" | while IFS= read -r p; do
		kill "$p" 2>/dev/null || true
	done
}

# Locale/TZ-independent process identity: ps -o lstart=,args= under a fixed LC_ALL/TZ so the SAME
# pid renders the SAME string regardless of the CALLER's own locale or timezone (gate r1 I-2 --
# see write_xfreerdp_shim's own comment on the write side of this).
proc_identity() { # <pid>
	local raw
	raw="$(LC_ALL=C TZ=UTC0 ps -o lstart=,args= -p "$1" 2>/dev/null | tr -s '[:space:]' ' ')"
	printf '%s' "$raw" | sed 's/^ *//;s/ *$//'
}

# Scans a pid<TAB>identity ledger (see write_xfreerdp_shim) and kills only the entries that are
# BOTH alive and still identify as the process that was recorded -- a bare pid number is not
# enough: on a long-running suite the OS can hand a recorded pid to an unrelated process before
# this runs, and killing on pid alone would kill a stranger.
#   - a live process whose `ps -o stat=` starts with Z is a zombie -- already exited, awaiting
#     reap -- and is left alone entirely: a signal to it is a no-op, and `kill -0` on a zombie
#     still reports success, so this check runs BEFORE anything else looks at "alive".
#   - a line with no recorded identity (the C stub in 13l logs a bare pid) can never be matched
#     with confidence and is left alone too, counted separately from a genuine mismatch.
#   - otherwise the SAME proc_identity() call decides: a match is killed, anything else is left
#     running (a pid the OS has since reused for something else must never be touched).
# Sets SCAN_LEDGERED / SCAN_LEFTOVER (killed) / SCAN_REUSED (alive, identity mismatch) /
# SCAN_UNKNOWN (alive, no recorded identity) / SCAN_ZOMBIE (already exited) for the caller.
orphan_scan() { # <ledger path>
	SCAN_LEDGERED=0; SCAN_LEFTOVER=0; SCAN_REUSED=0; SCAN_UNKNOWN=0; SCAN_ZOMBIE=0
	local p ident current stat
	while IFS=$'\t' read -r p ident; do
		[ -n "$p" ] || continue
		SCAN_LEDGERED=$((SCAN_LEDGERED + 1))
		if kill -0 "$p" 2>/dev/null; then
			stat="$(LC_ALL=C TZ=UTC0 ps -o stat= -p "$p" 2>/dev/null | tr -d '[:space:]')"
			case "$stat" in
				Z*) SCAN_ZOMBIE=$((SCAN_ZOMBIE + 1)); continue ;;
			esac
			if [ -z "$ident" ]; then
				SCAN_UNKNOWN=$((SCAN_UNKNOWN + 1))
				continue
			fi
			current="$(proc_identity "$p")"
			if [ -n "$current" ] && [ "$current" = "$ident" ]; then
				SCAN_LEFTOVER=$((SCAN_LEFTOVER + 1))
				kill "$p" 2>/dev/null || true
			else
				SCAN_REUSED=$((SCAN_REUSED + 1))
			fi
		fi
	done < <(sort -u "$1")
}

write_job() { # <PROGRAM> [CMDARGS] [TIMEOUT]
	{
		printf 'PROGRAM=%q\n' "$1"
		if [ -n "${2:-}" ]; then printf 'CMDARGS=%q\n' "$2"; fi
		if [ -n "${3:-}" ]; then printf 'TIMEOUT=%q\n' "$3"; fi
	} > "$SBRUNTIME/job.env"
}

write_client_env() { # <MACDOWS_XFREERDP value>
	printf 'MACDOWS_XFREERDP=%q\n' "$1" > "$SBRUNTIME/relay-client.env"
}
sha8_of() { shasum -a 256 < "$1" | cut -c1-8; }

# Verdict of a DIALLING run for the client pin, as reasons (empty = every pin holds): exactly one
# `[relay] client=` line, equal to `client=<version> sha8=<SHA-256 prefix of binary> source=<source>`
# and placed before the program= line; exactly one dial, made by <binary> (its $0 in the trace);
# DONE exit=0. 13a/13b and the M5/M6 mutation proofs share it, so "the mutant turns 13a red" means
# literally this function returning reasons for the mutant.
client_run_reasons() { # <version-token> <source> <binary>
	local r='' n line cl pl want
	want="[relay] client=$1 sha8=$(sha8_of "$3") source=$2"
	n="$(grep -c '^\[relay\] client=' "$LOG" 2>/dev/null || true)"
	[ "$n" = "1" ] || r="$r client-lines=$n;"
	line="$(grep '^\[relay\] client=' "$LOG" 2>/dev/null | head -n 1)"
	[ "$line" = "$want" ] || r="$r client-line=[$line]-expected-[$want];"
	cl="$(grep -n '^\[relay\] client=' "$LOG" 2>/dev/null | head -n 1 | cut -d: -f1)"
	pl="$(grep -n '^\[relay\] program=' "$LOG" 2>/dev/null | head -n 1 | cut -d: -f1)"
	if [ -z "$cl" ] || [ -z "$pl" ] || [ "$cl" -ge "$pl" ]; then r="$r client-line-not-before-program-line;"; fi
	[ "$(xfreerdp_calls)" = "1" ] || r="$r xfreerdp-calls=$(xfreerdp_calls);"
	[[ "$(xfreerdp_argv)" == "xfreerdp pid="*" argv0=$3 ["* ]] || r="$r dial-not-from-the-expected-binary;"
	[ "$(last_line)" = "DONE exit=0" ] || r="$r last-line=[$(last_line)];"
	printf '%s' "$r"
}

# Verdict of a run the client pin must REFUSE, as reasons prefixed with <label>: the CLIENT-INVALID
# line with <reason text>, DONE exit=69, nothing run at all (the trace is empty -- no dial and no
# --version probe of any shim or stub) and no sandbox path in relay.log.
client_refused_reasons() { # <label> <reason text>
	local r=''
	grep -qF "[relay] CLIENT-INVALID -- $2; no connection attempted" "$LOG" || r="$r $1:no-CLIENT-INVALID-line;"
	[ "$(last_line)" = "DONE exit=69" ] || r="$r $1:last-line=[$(last_line)];"
	[ ! -s "$LABTEST_TRACE" ] || r="$r $1:trace=[$(tr '\n' '|' < "$LABTEST_TRACE")];"
	if grep -qF "$SB/" "$LOG"; then r="$r $1:sandbox-path-in-log;"; fi
	printf '%s' "$r"
}

# Runs the relay (or a mutant copy) with the sandbox environment. Everything the relay reads
# comes from HOME/PATH/job.env; TERM_PROGRAM is cleared so the Terminal self-close branch is
# not taken. <boundary-file> empty = MACDOWS_LAB_BOUNDARY_FILE is passed EMPTY, which lib.sh's
# `${MACDOWS_LAB_BOUNDARY_FILE:-…}` treats exactly like unset: the relay resolves the DEFAULT
# path under the sandbox HOME, as it does live. (Passed as a plain variable, not an array --
# `"${arr[@]}"` on an empty array is an unbound-variable error under bash 3.2 + `set -u`, the
# /bin/bash this suite must also run under.) MACDOWS_XFREERDP is passed the same way, from
# RELAY_ENV_PIN, and is EMPTY -- which the relay reads as unset -- unless a 13* case sets it. The
# relay's stdin is /dev/null (or RELAY_STDIN), never the suite's own.
run_relay() { # <relay-path> <boundary-file|""> [xfreerdp-mode]
	env -i \
		HOME="$SBHOME" \
		PATH="${RELAY_PATH_OVERRIDE:-$SB/bin:$PATH}" \
		TERM_PROGRAM= \
		LABTEST_TRACE="$LABTEST_TRACE" \
		LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" \
		LABTEST_PID_LEDGER="$LABTEST_PID_LEDGER" \
		LABTEST_XFREERDP_MODE="${3:-exit0}" \
		LABTEST_SHIM_EMIT="$RELAY_SHIM_EMIT" \
		${RELAY_LOCALE:+"LC_ALL=$RELAY_LOCALE"} \
		MACDOWS_LAB_BOUNDARY_FILE="$2" \
		MACDOWS_XFREERDP="$RELAY_ENV_PIN" \
		bash "$1" >/dev/null 2>&1 < "${RELAY_STDIN:-/dev/null}"
}

# Runs the relay with a watchdog: kills it if it has not exited within <budget> seconds.
# Prints the elapsed seconds; returns 0 if the relay exited by itself. Budgets are chosen
# against the shim's 30s sleep: a relay that does NOT kill its xfreerdp blocks on `wait` for
# the full 30s, so any budget well under 30 separates "killed it" from "waited for it".
run_relay_bounded() { # <relay-path> <boundary-file|""> <xfreerdp-mode> <budget>
	local start end pid waited=0 self_exited=0
	start=$(date +%s)
	env -i \
		HOME="$SBHOME" \
		PATH="${RELAY_PATH_OVERRIDE:-$SB/bin:$PATH}" \
		TERM_PROGRAM= \
		LABTEST_TRACE="$LABTEST_TRACE" \
		LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" \
		LABTEST_PID_LEDGER="$LABTEST_PID_LEDGER" \
		LABTEST_XFREERDP_MODE="$3" \
		LABTEST_SHIM_EMIT="$RELAY_SHIM_EMIT" \
		${RELAY_LOCALE:+"LC_ALL=$RELAY_LOCALE"} \
		MACDOWS_LAB_BOUNDARY_FILE="$2" \
		MACDOWS_XFREERDP="$RELAY_ENV_PIN" \
		bash "$1" >/dev/null 2>&1 < "${RELAY_STDIN:-/dev/null}" &
	pid=$!
	while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$4" ]; do
		sleep 1
		waited=$((waited + 1))
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
	else
		wait "$pid" 2>/dev/null
		self_exited=1
	fi
	end=$(date +%s)
	printf '%s' "$((end - start))"
	[ "$self_exited" -eq 1 ]
}

# ------------------------------------------------------------------------------------------
# Cases
# ------------------------------------------------------------------------------------------

printf 'test-relay-offline.sh -- driving %s\n' "$LAB/relay.command"

# 1. Boundary refused (host outside the allowed segments): no connection attempted, the log
#    names the refusal, the DONE line carries the refusal code, xfreerdp is never invoked.
#    (The gate's own REFUSED line names the target host by lib.sh's design; the relay adds
#    nothing to it.)
begin '1 boundary refused'
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" "$DENY_FILE"
if assert_has "$LOG" 'BOUNDARY-REFUSED' && assert_eq "$(last_line)" 'DONE exit=78' 'last log line' \
	&& assert_eq "$(trace_lines)" '0' 'xfreerdp runs (dials and --version probes)' && assert_lacks "$LOG" 'LABTEST-PLACEHOLDER-SECRET-3f9a'; then
	pass "$CASE: BOUNDARY-REFUSED logged, DONE exit=78, xfreerdp never invoked, no credential in the log"
fi

# 2. Boundary file missing at the DEFAULT location (HOME has no lab-boundary.env): fail-closed,
#    same shape as 1. Exercises the relay's default-path resolution, not an injected path.
begin '2 boundary file missing (default path)'
mv "$ALLOW_FILE" "$ALLOW_FILE.away" || exit 1
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" ""
mv "$ALLOW_FILE.away" "$ALLOW_FILE" || exit 1
if assert_has "$LOG" 'BOUNDARY-REFUSED' && assert_eq "$(last_line)" 'DONE exit=78' 'last log line' \
	&& assert_eq "$(trace_lines)" '0' 'xfreerdp runs (dials and --version probes)'; then
	pass "$CASE: fail-closed refusal through the default boundary path, xfreerdp never invoked"
fi

# 3. Allowed host through the DEFAULT boundary path, xfreerdp exits 0: exactly one invocation,
#    the argv carries the job's program spec, the runtime share and the codec flag; DONE exit=0;
#    the default 25s timeout is what the relay logs.
begin '3 allowed path'
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" "" exit0
argv="$(xfreerdp_argv)"
if assert_eq "$(xfreerdp_calls)" '1' 'xfreerdp invocations' && assert_eq "$(last_line)" 'DONE exit=0' 'last log line' \
	&& assert_argv_has "$argv" '/v:192.0.2.10' && assert_argv_has "$argv" '/u:labtest-placeholder' \
	&& assert_argv_has "$argv" '/app:program:C:\Windows\System32\notepad.exe' \
	&& assert_argv_has "$argv" "/drive:lab,$SBRUNTIME/share" && assert_argv_has "$argv" '/gfx:AVC420' \
	&& assert_has "$LOG" '[relay] program=C:\Windows\System32\notepad.exe timeout=25s'; then
	pass "$CASE: one xfreerdp invocation with /v /u /app:program /drive:lab /gfx:AVC420; DONE exit=0; default timeout 25s logged"
fi

# 4. On the allowed path the relay echoes program and timeout only: the credential, the account
#    and the host address were all in its environment and none may reach relay.log. (The
#    refused path is different by design -- the gate names the host; case 1 covers its
#    credential half.)
begin '4 allowed path log carries no environment values'
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" "" exit0
if assert_lacks "$LOG" 'LABTEST-PLACEHOLDER-SECRET-3f9a' && assert_lacks "$LOG" '192.0.2.10' && assert_lacks "$LOG" 'labtest-placeholder'; then
	pass "$CASE: neither the password, the account nor the host address reaches relay.log"
fi

# 5. Every TRACKED job (jobs/*.env) drives the relay through the shipped path: the /app argument
#    is exactly `program:<PROGRAM>` plus `,cmd:<CMDARGS>` when the job has one, as ONE argv
#    element -- including the `||<alias>` program form six of the eleven jobs use.
begin '5 tracked jobs'
jobs_ok=0; jobs_total=0
for jobfile in "$LAB"/jobs/*.env; do
	# Three job families in jobs/ are not relay jobs: they carry no PROGRAM and never reach
	# xfreerdp, so the /app pin below has nothing to say about them.
	#   etw-*.env         Device Portal ETW capture   (run-scenario.sh etw   -> wdp-etw.command)
	#   smoke-*.env       one window-smoke run        (run-scenario.sh smoke -> smoke-job.command)
	#   checkpoint-*.env  a whole checkpoint          (run-scenario.sh checkpoint -> checkpoint.sh,
	#                     which drives all three of the above, the relay included)
	# test-wdp-etw-offline.sh and test-smoke-job-offline.sh are their suites.
	case "$(basename "$jobfile")" in etw-*.env | smoke-*.env | checkpoint-*.env) continue ;; esac
	jobs_total=$((jobs_total + 1))
	: > "$LABTEST_TRACE"
	cp "$jobfile" "$SBRUNTIME/job.env" || exit 1
	expected="$(
		# shellcheck source=/dev/null
		. "$jobfile" >/dev/null 2>&1
		spec="/app:program:${PROGRAM}"
		if [ -n "${CMDARGS:-}" ]; then spec="${spec},cmd:${CMDARGS}"; fi
		printf '%s' "$spec"
	)"
	run_relay "$SBLAB/relay.command" "" exit0
	argv="$(xfreerdp_argv)"
	if [ "$(xfreerdp_calls)" = "1" ] && [[ "$argv" == *"[$expected]"* ]] && [ "$(last_line)" = "DONE exit=0" ]; then
		jobs_ok=$((jobs_ok + 1))
	else
		jobs_failed="${jobs_failed:-}$(basename "$jobfile") "
		note "$(basename "$jobfile"): expected [$expected] in argv: $argv (last line: $(last_line))"
	fi
done
# One verdict for the case (the tally counts verdicts); the failing jobs are named in it.
if [ "$jobs_total" -ge 7 ] && [ "$jobs_ok" -eq "$jobs_total" ]; then
	pass "$CASE: all $jobs_total tracked jobs/*.env reach xfreerdp with /app:program:<PROGRAM>[,cmd:<CMDARGS>] as one argv element (incl. the ||alias form)"
else
	fail "$CASE: $jobs_ok of $jobs_total tracked jobs produced the expected /app argument (failed: ${jobs_failed:-none}; total<7 means jobs/ shrank)"
fi

# 6. xfreerdp's own failure is not the relay's: the relay still writes DONE exit=0 (its
#    contract is "the run happened"; the job's verdict lives in the share output).
begin '6 xfreerdp exit 1'
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" "" exit1
if assert_eq "$(last_line)" 'DONE exit=0' 'last log line' && assert_has "$LOG" '[relay] xfreerdp exited'; then
	pass "$CASE: a non-zero xfreerdp exit still yields DONE exit=0 with \"xfreerdp exited\" logged"
fi

# 7. TIMEOUT kill: the shim sleeps 30s, the job says TIMEOUT=1 -- the relay must kill it,
#    log the timeout and write DONE well inside the shim's sleep. Budget 15s: the relay's
#    poll is 1s-granular and the observed exit is ~2s, while a relay that failed to kill
#    would sit on `wait` for the full 30s; 8s is the pass bound on the elapsed time.
begin '7 TIMEOUT kill'
write_job 'C:\Windows\System32\notepad.exe' '' 1
elapsed="$(run_relay_bounded "$SBLAB/relay.command" "" sleep 15)"; self_exited=$?
xpid="$(sed -n 's/^xfreerdp pid=\([0-9]*\).*/\1/p' "$LABTEST_TRACE" | head -n 1)"
alive=0
if [ -n "$xpid" ] && kill -0 "$xpid" 2>/dev/null; then alive=1; fi
kill_recorded_shims
# One verdict: collect every reason first, then pass or fail exactly once.
reasons=''
[ "$self_exited" -eq 0 ] || reasons="$reasons relay-did-not-exit-by-itself;"
[ "$elapsed" -le 8 ] || reasons="$reasons elapsed=${elapsed}s>8;"
[ "$alive" -eq 0 ] || reasons="$reasons shim-still-alive;"
grep -qF 'timeout reached -- closing connection' "$LOG" || reasons="$reasons no-timeout-line;"
[ "$(last_line)" = "DONE exit=0" ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: TIMEOUT=1 kills a 30s xfreerdp -- timeout logged, DONE written in ${elapsed}s, the killed pid is gone"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 8. The log is truncated at startup: two consecutive runs leave exactly one DONE line.
begin '8 log truncation'
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" "" exit0
run_relay "$SBLAB/relay.command" "" exit0
if assert_eq "$(done_lines)" '1' 'DONE lines after two runs'; then
	pass "$CASE: relay.log is truncated at startup (exactly one DONE line after two runs)"
fi

# 9. job.env missing: the relay must still report -- a DONE line with a distinct sysexits code
#    (66 EX_NOINPUT) and a named reason -- rather than die on `set -u` and leave the caller to
#    its own timeout.
begin '9 job.env missing'
run_relay "$SBLAB/relay.command" "" exit0
if assert_has "$LOG" 'JOB-ENV-MISSING' && assert_eq "$(last_line)" 'DONE exit=66' 'last log line' && assert_lacks "$LOG" "$SB/" \
	&& assert_eq "$(trace_lines)" '0' 'xfreerdp runs (dials and --version probes)'; then
	pass "$CASE: JOB-ENV-MISSING logged (repo-relative, no absolute path), DONE exit=66, xfreerdp never invoked"
fi

# 10. job.env present but without PROGRAM: same contract, its own reason and code (65 EX_DATAERR).
begin '10 job.env without PROGRAM'
printf 'TIMEOUT=5\n' > "$SBRUNTIME/job.env"
run_relay "$SBLAB/relay.command" "" exit0
if assert_has "$LOG" 'JOB-ENV-INVALID' && assert_eq "$(last_line)" 'DONE exit=65' 'last log line' \
	&& assert_eq "$(trace_lines)" '0' 'xfreerdp runs (dials and --version probes)'; then
	pass "$CASE: JOB-ENV-INVALID logged, DONE exit=65, xfreerdp never invoked"
fi

# 10b. job.env cannot bypass the boundary gate: a job.env that redefines
#      crdp_assert_lab_boundary must still be refused, because the relay sources job.env only
#      AFTER the gate has passed (review r2 B2 -- the first draft of the job.env guard sourced it
#      before the gate and this exact file walked straight through).
begin '10b job.env cannot redefine the gate'
printf 'crdp_assert_lab_boundary() { return 0; }\nPROGRAM=%q\n' 'C:\Windows\System32\notepad.exe' > "$SBRUNTIME/job.env"
run_relay "$SBLAB/relay.command" "$DENY_FILE" exit0
if assert_has "$LOG" 'BOUNDARY-REFUSED' && assert_eq "$(last_line)" 'DONE exit=78' 'last log line' \
	&& assert_eq "$(trace_lines)" '0' 'xfreerdp runs (dials and --version probes)'; then
	pass "$CASE: a job.env redefining crdp_assert_lab_boundary is still refused (job.env is sourced after the gate)"
fi

# 10d. TIMEOUT that is not a positive integer: refused as JOB-ENV-INVALID (65) -- before this the
#      poll loop's `-lt` failed, the connection was torn down at once and the run still reported
#      DONE exit=0 (review r4 I1).
begin '10d job.env TIMEOUT not a positive integer'
write_job 'C:\Windows\System32\notepad.exe' '' 'abc'
run_relay "$SBLAB/relay.command" "" exit0
if assert_has "$LOG" 'JOB-ENV-INVALID' && assert_has "$LOG" 'TIMEOUT is not a positive integer' \
	&& assert_eq "$(last_line)" 'DONE exit=65' 'last log line' && assert_eq "$(trace_lines)" '0' 'xfreerdp runs (dials and --version probes)'; then
	pass "$CASE: JOB-ENV-INVALID (TIMEOUT) logged, DONE exit=65, xfreerdp never invoked"
fi

# 10e. A hand-edited CRLF job.env must not ship a bare CR into the argv nor into the TIMEOUT check:
#      every value's trailing CR is stripped, so `/app:program:<PROGRAM>` is exact, `timeout=5s` is
#      accepted (a `5\r` used to fail the positive-integer check, review r6 I1) and DONE exit=0.
begin '10e CRLF job.env'
printf 'PROGRAM=%q\r\nCMDARGS=%q\r\nTIMEOUT=5\r\n' 'C:\Windows\System32\notepad.exe' '-NoProfile' > "$SBRUNTIME/job.env"
run_relay "$SBLAB/relay.command" "" exit0
argv="$(xfreerdp_argv)"
# One verdict: collect reasons first.
reasons=''
[ "$(xfreerdp_calls)" = "1" ] || reasons="$reasons xfreerdp-calls=$(xfreerdp_calls);"
[ "$(last_line)" = "DONE exit=0" ] || reasons="$reasons last-line=[$(last_line)];"
[[ "$argv" == *'[/app:program:C:\Windows\System32\notepad.exe,cmd:-NoProfile]'* ]] || reasons="$reasons app-arg-not-exact;"
grep -qF 'timeout=5s' "$LOG" || reasons="$reasons timeout-not-5s;"
grep -q "$(printf '\r')" "$LABTEST_TRACE" && reasons="$reasons bare-CR-in-argv;"
if [ -z "$reasons" ]; then
	pass "$CASE: trailing CRs are stripped from PROGRAM/CMDARGS/TIMEOUT; no CR reaches the argv; timeout=5s accepted"
else
	fail "$CASE:$reasons"; note "argv: $argv"
fi

# 10f. A value that spans lines (a CMDARGS with an embedded newline) is refused as JOB-ENV-INVALID
#      instead of being silently truncated and mis-diagnosed as a TIMEOUT problem.
begin '10f multi-line job.env value'
printf 'PROGRAM=%q\nCMDARGS=$'"'"'a\\nb'"'"'\nTIMEOUT=5\n' 'C:\Windows\System32\notepad.exe' > "$SBRUNTIME/job.env"
run_relay "$SBLAB/relay.command" "" exit0
if assert_has "$LOG" 'spans more than one line' && assert_eq "$(last_line)" 'DONE exit=65' 'last log line' \
	&& assert_eq "$(trace_lines)" '0' 'xfreerdp runs (dials and --version probes)'; then
	pass "$CASE: a multi-line CMDARGS is refused as JOB-ENV-INVALID (65), xfreerdp never invoked"
fi

# 10c. job.env cannot redirect the connection either: overriding WIN_HOST/WIN_USER/WIN_PASS/SHARE
#      (and the gate function) in job.env must change nothing about the argv -- the relay reads
#      job.env in a subshell and takes only PROGRAM/CMDARGS/TIMEOUT out (review r3 B1: with a plain
#      `source`, the gate approved one host and xfreerdp dialled another).
begin '10c job.env cannot redirect the connection'
{
	printf 'PROGRAM=%q\n' 'C:\Windows\System32\notepad.exe'
	printf 'WIN_HOST=198.51.100.7\nWIN_USER=intruder\nWIN_PASS=stolen\nSHARE=/etc\n'
	printf 'crdp_assert_lab_boundary() { return 0; }\n'
} > "$SBRUNTIME/job.env"
run_relay "$SBLAB/relay.command" "" exit0
argv="$(xfreerdp_argv)"
if assert_eq "$(xfreerdp_calls)" '1' 'xfreerdp invocations' \
	&& assert_argv_has "$argv" '/v:192.0.2.10' && assert_argv_has "$argv" '/u:labtest-placeholder' \
	&& assert_argv_has "$argv" "/drive:lab,$SBRUNTIME/share" && assert_lacks "$LABTEST_TRACE" '198.51.100.7' \
	&& assert_lacks "$LABTEST_TRACE" '/etc]' && assert_argv_has "$argv" '/app:program:C:\Windows\System32\notepad.exe'; then
	pass "$CASE: WIN_HOST/WIN_USER/WIN_PASS/SHARE overrides in job.env never reach the argv (subshell read, four keys only)"
fi

# ------------------------------------------------------------------------------------------
# Mutation proofs: the pins above must FAIL against a relay with the guard removed.
# ------------------------------------------------------------------------------------------

# 12. XFREERDP_EXTRA (T6-prime RA3, 2026-09-07): a job may add xfreerdp switches from a closed
#     allowlist -- /scale:<100|140|180>, /scale-desktop:<100-500>, /scale-device:<100|140|180>,
#     /dynamic-resolution -- so a job can join the session as a client declaring a non-100 %
#     scale. Anything else is refused as JOB-ENV-INVALID (65) before any connection: the key
#     must not become a second way to redirect the connection (/v:, /u:, /p:, /drive:) or to
#     smuggle arbitrary switches. Tokens are separate argv elements placed before the /app spec.
begin '12a XFREERDP_EXTRA allowed tokens (tracked job)'
cp "$LAB/jobs/other-client-scale180.env" "$SBRUNTIME/job.env" || exit 1
run_relay "$SBLAB/relay.command" "" exit0
argv="$(xfreerdp_argv)"
if assert_eq "$(xfreerdp_calls)" "1" "xfreerdp invocations" && assert_argv_has "$argv" '/scale:180' && assert_argv_has "$argv" '/dynamic-resolution' \
	&& assert_argv_has "$argv" '/app:program:C:\Windows\System32\winver.exe' \
	&& [[ "${argv%%\[/app:program:*}" == *'[/scale:180]'* ]] && assert_eq "$(last_line)" "DONE exit=0" "last line"; then
	pass "$CASE: /scale:180 and /dynamic-resolution reach xfreerdp as their own argv elements, before the /app spec; DONE exit=0"
fi

begin '12b XFREERDP_EXTRA cannot redirect the connection'
printf 'PROGRAM=%q\nXFREERDP_EXTRA=%q\nTIMEOUT=5\n' 'C:\Windows\System32\notepad.exe' '/scale:180 /v:198.51.100.7' > "$SBRUNTIME/job.env"
run_relay "$SBLAB/relay.command" "" exit0
if assert_eq "$(trace_lines)" "0" "xfreerdp runs (dials and --version probes)" && assert_has "$LOG" 'JOB-ENV-INVALID' \
	&& assert_eq "$(last_line)" "DONE exit=65" "last line" && assert_lacks "$LABTEST_TRACE" '198.51.100.7'; then
	pass "$CASE: a /v: token in XFREERDP_EXTRA is refused as JOB-ENV-INVALID (65); xfreerdp never runs"
fi

begin '12c XFREERDP_EXTRA value outside the allowlist'
printf 'PROGRAM=%q\nXFREERDP_EXTRA=%q\nTIMEOUT=5\n' 'C:\Windows\System32\notepad.exe' '/scale:150' > "$SBRUNTIME/job.env"
run_relay "$SBLAB/relay.command" "" exit0
if assert_eq "$(trace_lines)" "0" "xfreerdp runs (dials and --version probes)" && assert_has "$LOG" 'JOB-ENV-INVALID' \
	&& assert_eq "$(last_line)" "DONE exit=65" "last line"; then
	pass "$CASE: /scale:150 (not one of 100|140|180) is refused as JOB-ENV-INVALID (65)"
fi

# 12d is a regression pin, not a must-red (it passed against the pre-change relay too, gate r1 m-1):
# it guards the other tracked jobs' argv against a future default value or stray token.
begin '12d XFREERDP_EXTRA absent leaves the argv unchanged'
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" "" exit0
argv="$(xfreerdp_argv)"
if assert_eq "$(xfreerdp_calls)" "1" "xfreerdp invocations" && assert_lacks "$LABTEST_TRACE" '/scale' && assert_lacks "$LABTEST_TRACE" '/dynamic-resolution' \
	&& assert_argv_has "$argv" '/app:program:C:\Windows\System32\notepad.exe' && assert_eq "$(last_line)" "DONE exit=0" "last line"; then
	pass "$CASE: without XFREERDP_EXTRA no extra switch appears (regression pin)"
fi

begin '12e CRLF XFREERDP_EXTRA'
printf 'PROGRAM=%q\r\nXFREERDP_EXTRA=%q\r\nTIMEOUT=5\r\n' 'C:\Windows\System32\notepad.exe' '/scale:140' > "$SBRUNTIME/job.env"
run_relay "$SBLAB/relay.command" "" exit0
argv="$(xfreerdp_argv)"
if assert_eq "$(xfreerdp_calls)" "1" "xfreerdp invocations" && assert_argv_has "$argv" '/scale:140' && assert_lacks "$LABTEST_TRACE" "$(printf '\r')" \
	&& assert_eq "$(last_line)" "DONE exit=0" "last line"; then
	pass "$CASE: a trailing CR on XFREERDP_EXTRA is stripped; /scale:140 accepted; no CR reaches the argv"
fi

# 13. CLIENT PIN (2026-09-28). Homebrew's FreeRDP 3.32.0 read every redirected file as empty
#     (upstream issue #13495) while the relay kept dialling whatever xfreerdp PATH found and logged
#     nothing about it. The relay now resolves relay-client.env > environment MACDOWS_XFREERDP >
#     PATH, refuses a bad pin as CLIENT-INVALID (69) before running anything, and logs
#     `[relay] client=<version> sha8=<8 hex> source=<file|env|path>` before its program= line;
#     source= names the level that chose the client (relay-client.env / environment / PATH).
begin '13a client line (PATH)'
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" "" exit0
reasons="$(client_run_reasons 9.9.9 path "$SB/bin/xfreerdp")"
if [ -z "$reasons" ]; then
	pass "$CASE: exactly one [relay] client=9.9.9 sha8=<the PATH shim's SHA-256 prefix> source=path line, before program=; the PATH shim dials"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

begin '13b client pin via relay-client.env'
write_client_env "$PIN_A"
write_job 'C:\Windows\System32\notepad.exe'
run_relay "$SBLAB/relay.command" "" exit0
reasons="$(client_run_reasons 8.8.8 file "$PIN_A")"
if [ -z "$reasons" ]; then
	pass "$CASE: relay-client.env's stub dials (its \$0 in the trace) and is named client=8.8.8 sha8=<its own SHA-256 prefix> source=file"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"; note "trace: $(cat "$LABTEST_TRACE")"
fi

# 13c. A pin that is not an executable absolute path refuses the run and runs NOTHING -- not the
#      pin, not a --version probe, and no fall-back to PATH: a non-executable file; a bare name,
#      with the relay started from a directory that holds an executable stub of that name (so only
#      the absolute-path rule can refuse it -- `-f`/`-x` pass, and bash would run the PATH shim); a
#      directory (which `-x` alone accepts); a value spanning two lines (whose first line is a valid
#      pin). One verdict over the four runs.
begin '13c pin not an executable absolute path'
write_job 'C:\Windows\System32\notepad.exe'
reasons=''
write_client_env "$PIN_NOEXEC"
run_relay "$SBLAB/relay.command" "" exit0
reasons="$reasons$(client_refused_reasons non-executable 'MACDOWS_XFREERDP is not an executable absolute path')"
reset_run; write_client_env 'xfreerdp'
(cd "$PINS/a" && run_relay "$SBLAB/relay.command" "" exit0)
reasons="$reasons$(client_refused_reasons bare-name 'MACDOWS_XFREERDP is not an executable absolute path')"
reset_run; write_client_env "$PIN_DIR"
run_relay "$SBLAB/relay.command" "" exit0
reasons="$reasons$(client_refused_reasons directory 'MACDOWS_XFREERDP is not an executable absolute path')"
reset_run; write_client_env "$(printf '%s\n%s' "$PIN_A" "$PIN_A")"
run_relay "$SBLAB/relay.command" "" exit0
reasons="$reasons$(client_refused_reasons two-lines 'relay-client.env does not yield one single-line MACDOWS_XFREERDP (multi-line value or early exit)')"
if [ -z "$reasons" ]; then
	pass "$CASE: non-executable file, bare name, directory and two-line value each give CLIENT-INVALID + DONE exit=69 with nothing run and no path logged"
else
	fail "$CASE:$reasons"
fi

# 13d. relay-client.env gets the job.env isolation (the shape of 10b + 10c): a file that also
#      redefines the gate and overrides the host, account, password, share and every job key must
#      (i) leave a denied host refused and (ii) on an allowed host change nothing but the client --
#      the argv, the program, the timeout and the extra switches still come from host.env/job.env.
begin '13d relay-client.env cannot redefine the gate or other keys'
write_job 'C:\Windows\System32\notepad.exe'
write_intruder_client_env() {
	{
		printf 'crdp_assert_lab_boundary() { return 0; }\nrelay_extra_tokens_ok() { return 0; }\n'
		printf 'MACDOWS_XFREERDP=%q\n' "$PIN_A"
		printf 'WIN_HOST=198.51.100.7\nWIN_USER=intruder\nWIN_PASS=stolen\nSHARE=/etc\n'
		printf 'PROGRAM=%q\nTIMEOUT=1\nXFREERDP_EXTRA=%q\n' 'C:\intruder.exe' '/v:198.51.100.7'
	} > "$SBRUNTIME/relay-client.env"
}
reasons=''
write_intruder_client_env
run_relay "$SBLAB/relay.command" "$DENY_FILE" exit0
grep -qF 'BOUNDARY-REFUSED' "$LOG" || reasons="$reasons deny:no-BOUNDARY-REFUSED;"
[ "$(last_line)" = "DONE exit=78" ] || reasons="$reasons deny:last-line=[$(last_line)];"
[ ! -s "$LABTEST_TRACE" ] || reasons="$reasons deny:trace-not-empty;"
reset_run; write_intruder_client_env
run_relay "$SBLAB/relay.command" "" exit0
argv="$(xfreerdp_argv)"
reasons="$reasons$(client_run_reasons 8.8.8 file "$PIN_A")"
for want in '/v:192.0.2.10' '/u:labtest-placeholder' "/drive:lab,$SBRUNTIME/share" '/app:program:C:\Windows\System32\notepad.exe'; do
	[[ "$argv" == *"[$want]"* ]] || reasons="$reasons allow:argv-lacks-[$want];"
done
for unwanted in '198.51.100.7' 'intruder' '/etc]' 'stolen'; do
	if grep -qF -- "$unwanted" "$LABTEST_TRACE"; then reasons="$reasons allow:trace-has-[$unwanted];"; fi
done
grep -qF '[relay] program=C:\Windows\System32\notepad.exe timeout=25s extra=<none>' "$LOG" || reasons="$reasons allow:program-line-changed;"
if [ -z "$reasons" ]; then
	pass "$CASE: a denied host stays refused; on an allowed host only the pin is taken -- host, account, share, program, timeout and extra switches in relay-client.env never reach the argv or the log"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"; note "argv: $argv"
fi

# 13e. A CRLF relay-client.env (the shape of 10e): the trailing CR is stripped, the pin is taken and
#      no CR reaches the argv, the trace or relay.log.
begin '13e CRLF relay-client.env'
write_job 'C:\Windows\System32\notepad.exe'
printf 'MACDOWS_XFREERDP=%q\r\n' "$PIN_A" > "$SBRUNTIME/relay-client.env"
run_relay "$SBLAB/relay.command" "" exit0
reasons="$(client_run_reasons 8.8.8 file "$PIN_A")"
if grep -q "$(printf '\r')" "$LABTEST_TRACE"; then reasons="$reasons bare-CR-in-trace;"; fi
if grep -q "$(printf '\r')" "$LOG"; then reasons="$reasons bare-CR-in-log;"; fi
if [ -z "$reasons" ]; then
	pass "$CASE: the trailing CR is stripped; the pinned stub dials and is named source=file; no CR reaches the trace or the log"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 13f. A client whose FIRST --version line carries no x.y.z is named `unknown` (the x.y.z on its
#      second line is not taken) -- and still dials: the line is a record, not a gate.
begin '13f version token unknown'
write_job 'C:\Windows\System32\notepad.exe'
write_client_env "$PIN_NOVERSION"
run_relay "$SBLAB/relay.command" "" exit0
reasons="$(client_run_reasons unknown file "$PIN_NOVERSION")"
if [ -z "$reasons" ]; then
	pass "$CASE: no x.y.z on the first --version line gives client=unknown (the second line's is ignored) with the stub's sha8; the run still dials and ends DONE exit=0"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 13g. The client line never carries a path (a pin may sit under the home directory): in both the
#      pinned and the PATH form the one client= line contains no `/`, and no sandbox path at all
#      reaches relay.log.
begin '13g client line carries no path'
write_job 'C:\Windows\System32\notepad.exe'
reasons=''
for form in pinned path; do
	reset_run
	if [ "$form" = pinned ]; then write_client_env "$PIN_A"; fi
	run_relay "$SBLAB/relay.command" "" exit0
	n="$(grep -c '^\[relay\] client=' "$LOG" || true)"
	[ "$n" = "1" ] || reasons="$reasons $form:client-lines=$n;"
	if grep '^\[relay\] client=' "$LOG" | grep -qF '/'; then reasons="$reasons $form:slash-in-client-line;"; fi
	if grep -qF "$SB/" "$LOG"; then reasons="$reasons $form:sandbox-path-in-log;"; fi
done
if [ -z "$reasons" ]; then
	pass "$CASE: pinned and PATH form each log one client= line without a '/', and no sandbox path reaches relay.log"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 13h. Level 2 of the priority: with no relay-client.env, a non-empty MACDOWS_XFREERDP in the
#      environment pins the client (source=env); an invalid one refuses without falling back to PATH.
begin '13h environment MACDOWS_XFREERDP pin'
write_job 'C:\Windows\System32\notepad.exe'
RELAY_ENV_PIN="$PIN_A"
run_relay "$SBLAB/relay.command" "" exit0
reasons="$(client_run_reasons 8.8.8 env "$PIN_A")"
reset_run; RELAY_ENV_PIN="$PIN_NOEXEC"
run_relay "$SBLAB/relay.command" "" exit0
reasons="$reasons$(client_refused_reasons env-non-executable 'MACDOWS_XFREERDP is not an executable absolute path')"
if [ -z "$reasons" ]; then
	pass "$CASE: an environment pin dials its stub as source=env; a non-executable one gives CLIENT-INVALID (69) and PATH is never consulted"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 13i. Level 1 beats level 2, and a PRESENT relay-client.env is authoritative: with both a file pin
#      and an environment pin the file's stub dials; an empty file refuses the run even though the
#      environment carries a valid pin (to unpin, the file is deleted, not emptied).
begin '13i relay-client.env wins over the environment'
write_job 'C:\Windows\System32\notepad.exe'
write_client_env "$PIN_A"; RELAY_ENV_PIN="$PIN_B"
run_relay "$SBLAB/relay.command" "" exit0
reasons="$(client_run_reasons 8.8.8 file "$PIN_A")"
reset_run; : > "$SBRUNTIME/relay-client.env"; RELAY_ENV_PIN="$PIN_B"
run_relay "$SBLAB/relay.command" "" exit0
reasons="$reasons$(client_refused_reasons empty-file 'relay-client.env exists but sets no MACDOWS_XFREERDP')"
if [ -z "$reasons" ]; then
	pass "$CASE: the file pin (8.8.8, source=file) dials over the environment pin (7.7.7); an empty relay-client.env refuses (69) instead of handing over the environment's pin"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 13j. Level 3 with nothing to find: no pin and no xfreerdp anywhere on PATH refuses as CLIENT-INVALID
#      (69) -- before the pin, bash's "command not found" still ended DONE exit=0. The reduced PATH is
#      the suite's own PATH minus the shim directory, minus every directory holding anything named
#      xfreerdp, minus relative entries; the case runs only after a fresh bash under that PATH has
#      been shown to resolve no xfreerdp, so no real client can be reached.
begin '13j no xfreerdp on PATH'
write_job 'C:\Windows\System32\notepad.exe'
nox_path=''
set -f
old_ifs="$IFS"; IFS=:
for d in $PATH; do
	case "$d" in /*) ;; *) continue ;; esac
	[ "$d" = "$SB/bin" ] && continue
	[ -e "$d/xfreerdp" ] && continue
	nox_path="${nox_path:+$nox_path:}$d"
done
IFS="$old_ifs"
set +f
leak="$(env -i PATH="$nox_path" "$BASH" -c 'command -v xfreerdp' 2>/dev/null || true)"
if [ -n "$leak" ] || [ -z "$nox_path" ]; then
	fail "$CASE: not run -- the reduced PATH still resolves an xfreerdp or is empty"
else
	RELAY_PATH_OVERRIDE="$nox_path"
	run_relay "$SBLAB/relay.command" "" exit0
	reasons="$(client_refused_reasons no-path-client 'no executable xfreerdp on PATH')"
	if [ -z "$reasons" ]; then
		pass "$CASE: with nothing on PATH the relay refuses as CLIENT-INVALID (69) and dials nothing"
	else
		fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
	fi
fi

# 13k. A client that cannot answer --version is refused, never dialled (gate r1 I-1): a pin whose
#      libraries stopped loading after a Homebrew upgrade dies in dyld (SIGABRT), an interpreter
#      that is gone fails the exec, a missing loader exits 127. Before the probe's status counted,
#      each of these was logged client=unknown and dialled, ending DONE exit=0 with nothing done on
#      the host. Each must give CLIENT-INVALID + DONE exit=69, no dial and no path in relay.log.
begin '13k client that fails its --version probe'
write_job 'C:\Windows\System32\notepad.exe'
reasons=''
for spec in "exit127:$PIN_V127" "sigabrt:$PIN_ABORT" "bad-interpreter:$PIN_BADINTERP"; do
	reset_run; write_client_env "${spec#*:}"
	run_relay "$SBLAB/relay.command" "" exit0
	reasons="$reasons$(client_refused_reasons "${spec%%:*}" 'client version probe failed')"
done
if [ -z "$reasons" ]; then
	pass "$CASE: --version exiting 127, dying of SIGABRT or hitting a missing interpreter each give CLIENT-INVALID (probe failed) + DONE exit=69, with no dial and no path logged"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 13l. The client's argv[0] is `xfreerdp`, never the pin path (gate r1 I-2): FreeRDP echoes argv[0]
#      into relay.log in its usage and error banners, and the pin may sit under the home directory.
#      A #! script never sees its argv[0], so the behavioural half uses the compiled stub and runs
#      only when `cc` built it; the source-shape half always runs. The verdict lives in
#      argv0_reasons so M8 can reuse it.
# Shape half: exactly one statement runs the client with /v:, and it is the `exec -a xfreerdp` form.
# Behavioural half: the pinned and the PATH form each dial with argv[0] exactly `xfreerdp`, the
# stub's argv[0] banner reaches relay.log (so the no-path check is not vacuous) and no sandbox path
# does; an execute-only client (unreadable, so no digest) is logged sha8=unknown and still dials.
argv0_reasons() { # <relay-path>
	local r='' n_all n_exec form want
	# shellcheck disable=SC2016  # the single quotes are deliberate: the literal source text
	n_all="$(grep -cF '"$XFREERDP_BIN" "/v:${WIN_HOST}"' "$1" || true)"
	# shellcheck disable=SC2016  # as above
	n_exec="$(grep -cF '( exec -a xfreerdp "$XFREERDP_BIN" "/v:${WIN_HOST}"' "$1" || true)"
	if [ "$n_all" != "1" ] || [ "$n_exec" != "1" ]; then r="$r shape:dial-statements=$n_all,exec-a-form=$n_exec;"; fi
	if [ "$CSTUB_OK" -ne 1 ]; then printf '%s' "$r"; return 0; fi
	for form in pinned path exec-only; do
		reset_run
		case "$form" in
		pinned) write_client_env "$CSTUB_BIN"; want="client=5.5.5 sha8=$(sha8_of "$CSTUB_BIN") source=file" ;;
		path) RELAY_PATH_OVERRIDE="$CSTUB_DIR/bin:$SB/bin:$PATH"; want="client=5.5.5 sha8=$(sha8_of "$CSTUB_BIN") source=path" ;;
		exec-only)
			if [ -r "$CSTUB_EXEC_ONLY" ]; then continue; fi
			write_client_env "$CSTUB_EXEC_ONLY"; want='client=5.5.5 sha8=unknown source=file' ;;
		esac
		run_relay "$1" "" exit0
		[ "$(grep '^\[relay\] client=' "$LOG" | head -n 1)" = "[relay] $want" ] || r="$r $form:client-line-not-[$want];"
		[ "$(xfreerdp_calls)" = "1" ] || r="$r $form:xfreerdp-calls=$(xfreerdp_calls);"
		[[ "$(xfreerdp_argv)" == "xfreerdp pid="*" argv0=xfreerdp ["* ]] || r="$r $form:argv0-is-not-xfreerdp;"
		grep -qF 'xfreerdp - offline stub banner' "$LOG" || r="$r $form:no-banner-in-log;"
		if grep -qF "$SB/" "$LOG"; then r="$r $form:sandbox-path-in-log;"; fi
		[ "$(last_line)" = "DONE exit=0" ] || r="$r $form:last-line=[$(last_line)];"
	done
	printf '%s' "$r"
}
begin '13l dial argv[0] is xfreerdp, never the pin path'
write_job 'C:\Windows\System32\notepad.exe'
reasons="$(argv0_reasons "$SBLAB/relay.command")"
if [ "$CSTUB_OK" -ne 1 ]; then
	note "no working cc: the compiled-stub half did not run, the source-shape half did"
elif [ -r "$CSTUB_EXEC_ONLY" ]; then
	note "a mode-0111 file is still readable here (root?): the execute-only form did not run"
fi
if [ -z "$reasons" ] && [ "$CSTUB_OK" -ne 1 ]; then
	pass "$CASE: the one dial statement is the exec -a xfreerdp form (source-shape half only: no working cc)"
elif [ -z "$reasons" ]; then
	pass "$CASE: the one dial statement is the exec -a xfreerdp form; the compiled stub sees argv[0]=xfreerdp in pinned and PATH form, its argv[0] banner carries no path into relay.log, and an unreadable client logs sha8=unknown"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 13m. A PRESENT relay-client.env that is not a readable regular file refuses -- a dangling
#      symlink (which `-e` alone calls absent), a directory, an unreadable file -- and so does one
#      that exits before its value can be read. The environment carries a valid pin all along, so a
#      fall-through to level 2 (or 3) would dial and show up in the trace.
begin '13m relay-client.env that is not a readable regular file'
write_job 'C:\Windows\System32\notepad.exe'
reasons=''
for form in dangling-symlink directory unreadable exits-early; do
	reset_run; RELAY_ENV_PIN="$PIN_B"
	case "$form" in
	dangling-symlink) ln -s "$SB/no-such-relay-client.env" "$SBRUNTIME/relay-client.env" ;;
	directory) mkdir "$SBRUNTIME/relay-client.env" ;;
	unreadable)
		write_client_env "$PIN_A"; chmod 000 "$SBRUNTIME/relay-client.env"
		if [ -r "$SBRUNTIME/relay-client.env" ]; then
			note "a mode-000 file is still readable here (root?): the unreadable form did not run"
			continue
		fi ;;
	exits-early) printf 'MACDOWS_XFREERDP=%q\nexit 0\n' "$PIN_A" > "$SBRUNTIME/relay-client.env" ;;
	esac
	run_relay "$SBLAB/relay.command" "" exit0
	if [ "$form" = exits-early ]; then
		reasons="$reasons$(client_refused_reasons "$form" 'relay-client.env does not yield one single-line MACDOWS_XFREERDP (multi-line value or early exit)')"
	else
		reasons="$reasons$(client_refused_reasons "$form" 'relay-client.env is not a readable regular file')"
	fi
done
reset_run
if [ -z "$reasons" ]; then
	pass "$CASE: a dangling symlink, a directory, an unreadable file and a file that exits early each refuse (69) with nothing run -- never a fall-through to the environment pin"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 13n. Probe hygiene. (i) A noisy client -- it writes its path to stderr, reads whatever stdin it
#      is given, and answers in FreeRDP's print_version_ex form `version [<its path>] 4.4.4 (4.4.4)`
#      from a directory named xfreerdp-1.1.1 -- is logged client=4.4.4: not the path's 1.1.1, one
#      token although the revision repeats it, no path in relay.log, and it never saw the stdin
#      the relay was given. (ii) A digest tool that answers no digest gives sha8=unknown.
begin '13n version probe hygiene'
write_job 'C:\Windows\System32\notepad.exe'
write_client_env "$PIN_NOISY"; RELAY_STDIN="$SB/stdin-data.txt"
run_relay "$SBLAB/relay.command" "" exit0
reasons="$(client_run_reasons 4.4.4 file "$PIN_NOISY")"
if grep -qF 'version stdin=' "$LABTEST_TRACE"; then reasons="$reasons noisy:probe-read-the-relay-stdin;"; fi
if grep -qF "$SB/" "$LOG"; then reasons="$reasons noisy:sandbox-path-in-log;"; fi
grep -qF 'version argv0=' "$LABTEST_TRACE" || reasons="$reasons noisy:probe-did-not-run;"
reset_run; write_client_env "$PIN_A"; RELAY_PATH_OVERRIDE="$SB/badsha:$SB/bin:$PATH"
run_relay "$SBLAB/relay.command" "" exit0
[ "$(grep '^\[relay\] client=' "$LOG" | head -n 1)" = '[relay] client=8.8.8 sha8=unknown source=file' ] || reasons="$reasons badsha:client-line=[$(grep '^\[relay\] client=' "$LOG" | head -n 1)];"
[[ "$(xfreerdp_argv)" == "xfreerdp pid="*" argv0=$PIN_A ["* ]] || reasons="$reasons badsha:dial-not-from-the-pin;"
if [ -z "$reasons" ]; then
	pass "$CASE: a print_version_ex answer under an xfreerdp-1.1.1 directory is logged client=4.4.4 (one token), the probe's stderr and the relay's stdin stay away from it, and a non-digest answer gives sha8=unknown"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 14. LOGON-INFO MASK (2026-10-02; relay.command header). FreeRDP logs `Logon Info V2 [<domain>\<user>
#     [<n>]]` on every logon, which put the lab host's computer name and the lab account into
#     relay.log and from there into evidence directories and the docs archives. A dialling run now
#     rewrites relay.log once after xfreerdp has gone, in place (same inode), masking only the
#     `<domain>\<user>` segment of `Logon Info V1 [` / `Logon Info V2 [` lines, and logs
#     `[relay] masked logon-info lines=<n>` between `[relay] xfreerdp exited` and DONE. The fixtures
#     stand in for FreeRDP's own output (the shim writes them to relay.log, see RELAY_SHIM_EMIT);
#     EXAMPLE-HOST / exampleuser are placeholders, never a real host or account.
MASK_FIX_LOGON="$SB/fixture-logon.txt"
MASK_FIX_MASKED="$SB/fixture-logon-masked.txt"
MASK_FIX_PLAIN="$SB/fixture-plain.txt"
write_logon_fixture() { # <path> <domain\user segment>
	{
		printf '%s\n' '[12:00:00:001] [100:200] [INFO][com.freerdp.core.connection] - connection established'
		printf '%s\n' "[12:00:01:500] [100:200] [INFO][com.freerdp.client.common] - [client_common_save_session_info]: Logon Info V2 [$2 [7]]"
		printf '%s\n' "[12:00:01:501] [100:200] [INFO][com.freerdp.client.common] - [client_common_save_session_info]: Logon Info V1 [$2]"
		printf '%s\n' '[12:00:01:502] [100:200] [INFO][com.freerdp.client.common] - [client_common_save_session_info]: Logon Extended Info [cookie: TRUE, LogonId: 7, errorInfo: FALSE, notifyType: 0, notifyData: 0]'
		printf '%s\n' '[12:00:09:900] [100:200] [ERROR][com.freerdp.core] - ERRINFO_LOGOFF_BY_USER (0x0000000C)'
	} > "$1"
}
write_logon_fixture "$MASK_FIX_LOGON" 'EXAMPLE-HOST\exampleuser' || exit 1
write_logon_fixture "$MASK_FIX_MASKED" '<host>\<lab-user>' || exit 1
# No line the mask may touch, but every shape that sits next to one: an unknown version, a missing
# space before `[`, lower case, a backslash path, printf directives, a tab, a CR, trailing blanks
# and a multi-byte UTF-8 character.
{
	printf '%s\n' 'Logon Info V3 [EXAMPLE-HOST\exampleuser [7]]'
	printf '%s\n' 'Logon Info V2[EXAMPLE-HOST\exampleuser]'
	printf '%s\n' 'logon info v2 [EXAMPLE-HOST\exampleuser [7]]'
	printf '%s\n' 'Logon Extended Info [cookie: TRUE, LogonId: 7]'
	printf '%s\n' 'C:\Windows\System32\logoff.exe 100% %s %d \\ \n end'
	printf 'tab\there carriage-return\r\n'
	printf '%s\n' 'trailing blanks   '
	printf 'caf\303\251\n'
} > "$MASK_FIX_PLAIN" || exit 1
# awk stand-ins for 14e, PATH-first only for that case. They defer to the awk the suite itself
# resolves for every call except the relay's mask filter (recognised by RELAY_MASK_COUNT in its
# environment): one fails it, one "succeeds" without reporting a line count.
REAL_AWK="$(command -v awk)"
mkdir -p "$SB/awk-fail" "$SB/awk-nocount" || exit 1
for variant in fail nocount; do
	# shellcheck disable=SC2016  # shim source text: "$2" belongs to the shim, not to this shell
	if [ "$variant" = fail ]; then mask_action='exit 2'; else mask_action='cat "$2"; exit 0'; fi
	{
		printf '#!/usr/bin/env bash\n'
		printf '# OFFLINE TEST SHIM (14e): the relay mask filter -> %s; any other awk call is the real one.\n' "$variant"
		# The relay calls the filter as `awk '<program>' relay.log`, so "$2" is the log.
		# shellcheck disable=SC2016  # shim source text, expanded by the shim
		printf 'if [ -n "${RELAY_MASK_COUNT:-}" ]; then %s; fi\n' "$mask_action"
		printf 'exec %q "$@"\n' "$REAL_AWK"
	} > "$SB/awk-$variant/awk" && chmod +x "$SB/awk-$variant/awk" || exit 1
	bash -n "$SB/awk-$variant/awk" || exit 1
done
# `ls -i` on one known path: the portable inode read (stat's flags differ between BSD and GNU).
# shellcheck disable=SC2012
inode_of() { ls -i "$1" 2>/dev/null | sed 's/^ *//; s/ .*//'; }
# relay.log up to and including the first `[relay] program=` line, then <fixture>, then the given
# lines -- the whole log byte for byte. The head is taken from the log itself (it carries the
# boundary gate's line and the shim's sha8) but must end in the client line and the program line,
# or the expectation is not built at all.
expected_log() { # <out> <fixture> <line>...
	local out="$1" fixture="$2" pl
	shift 2
	pl="$(grep -n '^\[relay\] program=' "$LOG" | head -n 1 | cut -d: -f1)"
	[ -n "$pl" ] && [ "$pl" -ge 2 ] || return 1
	sed -n "$((pl - 1))p" "$LOG" | grep -q '^\[relay\] client=' || return 1
	{ head -n "$pl" "$LOG"; cat "$fixture"; printf '%s\n' "$@"; } > "$out"
}
mask_leftovers() { find "$SBRUNTIME" -maxdepth 1 -name '.relay-mask*' | grep -c '' || true; }

# 14a. Masking on the normal exit path: both logon lines become `<host>\<lab-user>` (V2 keeps its
#      ` [7]]`), the Extended Info line and every other byte stay, the placeholders appear nowhere,
#      `masked logon-info lines=2` sits between `xfreerdp exited` and DONE, no temp file is left.
#      Red when the call to relay_mask_logon_info goes (M9), when the awk filter stops replacing the
#      segment, or when the `masked logon-info` echo goes.
mask_a_reasons() { # <relay-path>
	local r=''
	write_job 'C:\Windows\System32\notepad.exe'
	RELAY_SHIM_EMIT="$MASK_FIX_LOGON"
	run_relay "$1" "" exit0
	if expected_log "$SB/expected-14a.txt" "$MASK_FIX_MASKED" '[relay] xfreerdp exited' '[relay] masked logon-info lines=2' 'DONE exit=0'; then
		cmp -s "$SB/expected-14a.txt" "$LOG" || r="$r log-differs-from-expected;"
	else
		r="$r head-lines-not-client-and-program;"
	fi
	[ "$(grep -c 'EXAMPLE-HOST' "$LOG")" = 0 ] || r="$r EXAMPLE-HOST-in-log;"
	[ "$(grep -c 'exampleuser' "$LOG")" = 0 ] || r="$r exampleuser-in-log;"
	[ "$(grep -c '^\[relay\] masked logon-info' "$LOG")" = 1 ] || r="$r masked-lines=$(grep -c '^\[relay\] masked logon-info' "$LOG");"
	[ "$(mask_leftovers)" = 0 ] || r="$r temp-files-left;"
	printf '%s' "$r"
}
begin '14a logon-info masked on exit'
reasons="$(mask_a_reasons "$SBLAB/relay.command")"
if [ -z "$reasons" ]; then
	pass "$CASE: V2/V1 logon segments masked to <host>\\<lab-user> (V2 keeps [7]]), Extended Info and every other byte untouched, lines=2 between exited and DONE"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 14b. Same mask on the TIMEOUT-kill path: the shim writes the fixture, then sleeps until killed.
#      The fixture region is compared byte for byte and the last four lines are the timeout line,
#      exited, lines=2 and DONE in that order. Red when the mask step stops running for dialling
#      runs (the `RELAY_DIALLED=1` line deleted) or moves before the TIMEOUT kill.
begin '14b logon-info masked on the TIMEOUT path'
write_job 'C:\Windows\System32\notepad.exe' '' 2
RELAY_SHIM_EMIT="$MASK_FIX_LOGON"
run_relay_bounded "$SBLAB/relay.command" "" sleep 15 >/dev/null; self_exited=$?
kill_recorded_shims
reasons=''
[ "$self_exited" -eq 0 ] || reasons="$reasons relay-did-not-exit-by-itself;"
sed -n '/^\[relay\] program=/,/^\[relay\] timeout reached/p' "$LOG" | sed '1d;$d' > "$SB/region-14b.txt"
cmp -s "$SB/region-14b.txt" "$MASK_FIX_MASKED" || reasons="$reasons fixture-region-differs;"
printf '%s\n' '[relay] timeout reached -- closing connection' '[relay] xfreerdp exited' '[relay] masked logon-info lines=2' 'DONE exit=0' > "$SB/tail-14b.txt"
tail -n 4 "$LOG" | cmp -s - "$SB/tail-14b.txt" || reasons="$reasons tail-not-timeout-exited-masked-done;"
[ "$(grep -c 'EXAMPLE-HOST\|exampleuser' "$LOG")" = 0 ] || reasons="$reasons placeholder-in-log;"
if [ -z "$reasons" ]; then
	pass "$CASE: a killed client's logon lines are masked too; timeout, exited, lines=2, DONE in order"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 14c. Nothing to mask: `lines=0`, and the whole log is byte for byte what the run wrote -- the
#      near-miss shapes (V3, no space, lower case) are not taken for logon lines. With n=0 the relay
#      never writes the log back, so this pins only that: no write-back at n=0, no near-miss match,
#      `lines=0`. Red when the filter widens its match (a regex on `Logon Info`), when n=0 still
#      writes back something else, or when the `lines=` echo goes. Byte fidelity of an actual
#      rewrite is 14g's.
begin '14c nothing to mask leaves every byte'
write_job 'C:\Windows\System32\notepad.exe'
RELAY_SHIM_EMIT="$MASK_FIX_PLAIN"
run_relay "$SBLAB/relay.command" "" exit0
reasons=''
if expected_log "$SB/expected-14c.txt" "$MASK_FIX_PLAIN" '[relay] xfreerdp exited' '[relay] masked logon-info lines=0' 'DONE exit=0'; then
	cmp -s "$SB/expected-14c.txt" "$LOG" || reasons="$reasons log-differs-from-expected;"
else
	reasons="$reasons head-lines-not-client-and-program;"
fi
if [ -z "$reasons" ]; then
	pass "$CASE: no Logon Info V1/V2 line -> lines=0 and relay.log is byte-identical to what the run wrote (near-miss shapes, CR, tab, UTF-8 kept)"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"; diff "$SB/expected-14c.txt" "$LOG" | sed 's/^/        /'
fi

# 14d. relay.log keeps its inode through the rewrite, and a reader that opened it before the run
#      (a `tail -f`, a poll loop) reads the masked log and the DONE line through that same open
#      file. Red when the copy-back becomes a rename (M10: `mv tmp relay.log`) or `sed -i`.
mask_d_reasons() { # <relay-path>
	local r='' before after
	write_job 'C:\Windows\System32\notepad.exe'
	RELAY_SHIM_EMIT="$MASK_FIX_LOGON"
	before="$(inode_of "$LOG")"
	exec 9< "$LOG"
	run_relay "$1" "" exit0
	cat <&9 > "$SB/fd-view-14d.txt"
	exec 9<&-
	after="$(inode_of "$LOG")"
	[ -n "$before" ] && [ "$before" = "$after" ] || r="$r inode-changed=[$before]->[$after];"
	cmp -s "$SB/fd-view-14d.txt" "$LOG" || r="$r open-reader-sees-another-file;"
	grep -qF '<host>\<lab-user>' "$SB/fd-view-14d.txt" || r="$r open-reader-sees-no-mask;"
	[ "$(tail -n 1 "$SB/fd-view-14d.txt")" = 'DONE exit=0' ] || r="$r open-reader-sees-no-DONE;"
	printf '%s' "$r"
}
begin '14d relay.log keeps its inode'
reasons="$(mask_d_reasons "$SBLAB/relay.command")"
if [ -z "$reasons" ]; then
	pass "$CASE: same inode before and after; a reader opened before the run reads the masked log and DONE"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 14e. The mask filter failing (awk exits 2) or answering no line count: `[relay] MASK-FAILED -- <reason>`
#      after `xfreerdp exited`, DONE exit=74 still written as the last line, no `masked logon-info`
#      line, relay.log otherwise as the run wrote it (the names stay -- hence 74), no temp file left
#      and no path in the log. Red when the filter's exit status is ignored, when the count check
#      goes (lines= would print empty), or when a failure skips the DONE echo.
begin '14e mask failure still writes DONE'
reasons=''
for variant in fail nocount; do
	reset_run
	write_job 'C:\Windows\System32\notepad.exe'
	RELAY_SHIM_EMIT="$MASK_FIX_LOGON"; RELAY_PATH_OVERRIDE="$SB/awk-$variant:$SB/bin:$PATH"
	run_relay "$SBLAB/relay.command" "" exit0
	case "$variant" in
	fail) want='[relay] MASK-FAILED -- the mask filter failed; ' ;;
	*) want='[relay] MASK-FAILED -- the mask filter reported no line count; ' ;;
	esac
	if expected_log "$SB/expected-14e.txt" "$MASK_FIX_LOGON" '[relay] xfreerdp exited'; then
		# everything up to and including `xfreerdp exited` is the unmasked run, then two lines
		head -n "$(grep -c '' "$SB/expected-14e.txt")" "$LOG" | cmp -s - "$SB/expected-14e.txt" || reasons="$reasons $variant:log-before-mask-changed;"
	else
		reasons="$reasons $variant:head-lines-not-client-and-program;"
	fi
	[[ "$(tail -n 2 "$LOG" | head -n 1)" == "$want"* ]] || reasons="$reasons $variant:second-last-line=[$(tail -n 2 "$LOG" | head -n 1)];"
	[ "$(last_line)" = 'DONE exit=74' ] || reasons="$reasons $variant:last-line=[$(last_line)];"
	[ "$(done_lines)" = 1 ] || reasons="$reasons $variant:done-lines=$(done_lines);"
	! grep -q '^\[relay\] masked logon-info' "$LOG" || reasons="$reasons $variant:masked-line-present;"
	[ "$(mask_leftovers)" = 0 ] || reasons="$reasons $variant:temp-files-left;"
	! grep -qF "$SB/" "$LOG" || reasons="$reasons $variant:sandbox-path-in-log;"
done
if [ -z "$reasons" ]; then
	pass "$CASE: a failing filter and a filter without a count both give MASK-FAILED after exited, DONE exit=74 last, no masked line, no temp file, no path"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 14f. The two logoff jobs carry TIMEOUT=30 (2026-10-02: 12 s killed two logoffs 10.2 / 10.5 s
#      after logon, before ERRINFO_LOGOFF_BY_USER), exactly one TIMEOUT line each. Red when either
#      file goes back to 12 or gains a second TIMEOUT line.
begin '14f logoff jobs TIMEOUT=30'
reasons=''
for jobfile in "$LAB/jobs/logoff-path.env" "$LAB/jobs/logoff.env"; do
	[ "$(grep -c '^TIMEOUT=' "$jobfile")" = 1 ] || reasons="$reasons $(basename "$jobfile"):timeout-lines=$(grep -c '^TIMEOUT=' "$jobfile");"
	grep -qx 'TIMEOUT=30' "$jobfile" || reasons="$reasons $(basename "$jobfile"):not-TIMEOUT=30;"
done
if [ -z "$reasons" ]; then
	pass "$CASE: jobs/logoff-path.env and jobs/logoff.env both read TIMEOUT=30, one line each"
else
	fail "$CASE:$reasons"
fi

# 14g. Byte fidelity on the REWRITE path (gate r1 I-1). 14c's log has no Logon line, so the relay
#      never writes it back and 14c cannot see what the filter does to bytes; here both logon lines
#      are present and the fixture carries a CR, tabs, printf directives, backslashes, multi-byte
#      UTF-8 and an invalid byte (\377) -- one in the masked V2 line's tail after ` [7]]`, one in
#      another line. The relay runs under a UTF-8 LC_ALL (MASK_UTF8_LOCALE, chosen from `locale -a`),
#      so an awk that honours the locale (gawk) would rewrite the invalid byte if the relay's own
#      LC_ALL=C went. The expectation is built here from the same template with the placeholder
#      segment written in -- never by the relay's awk. Red when LC_ALL=C goes under gawk (mutation
#      H, scratch-verified), when the line is reprinted through printf, or when any byte outside the
#      segment changes. No UTF-8 locale on the machine: the case still runs and compares, with a
#      note that the locale-sensitive half was not exercised.
MASK_FIX_BYTES="$SB/fixture-bytes.txt"
MASK_FIX_BYTES_MASKED="$SB/fixture-bytes-masked.txt"
write_bytes_fixture() { # <path> <domain\user segment>
	{
		printf '%s\n' '[12:00:00:001] [100:200] [INFO][com.freerdp.core.connection] - connection established'
		printf '[12:00:01:500] [100:200] [INFO][com.freerdp.client.common] - [client_common_save_session_info]: Logon Info V2 [%s [7]] tail \377 caf\303\251 %%s %%d\tend\r\n' "$2"
		printf '[12:00:01:501] [100:200] [INFO][com.freerdp.client.common] - [client_common_save_session_info]: Logon Info V1 [%s]\r\n' "$2"
		printf '%s\n' 'C:\Windows\System32\logoff.exe 100% %s %d \\ \n end'
		printf 'tab\there invalid \377 byte caf\303\251 carriage-return\r\n'
		printf '%s\n' '[12:00:09:900] [100:200] [ERROR][com.freerdp.core] - ERRINFO_LOGOFF_BY_USER (0x0000000C)'
	} > "$1"
}
write_bytes_fixture "$MASK_FIX_BYTES" 'EXAMPLE-HOST\exampleuser' || exit 1
write_bytes_fixture "$MASK_FIX_BYTES_MASKED" '<host>\<lab-user>' || exit 1
# `locale -a` spells the same locale differently (macOS en_US.UTF-8 / C.UTF-8, glibc en_US.utf8 /
# C.utf8); the comparison folds case and the hyphen, the name is used as listed.
MASK_UTF8_LOCALE=''
MASK_LOCALES="$(locale -a 2>/dev/null || true)"
for want in en_us.utf8 c.utf8; do
	while IFS= read -r loc; do
		if [ "$(printf '%s' "$loc" | tr '[:upper:]' '[:lower:]' | tr -d '-')" = "$want" ]; then MASK_UTF8_LOCALE="$loc"; break; fi
	done <<EOF_LOCALES
$MASK_LOCALES
EOF_LOCALES
	[ -n "$MASK_UTF8_LOCALE" ] && break
done
begin '14g rewrite keeps every other byte'
write_job 'C:\Windows\System32\notepad.exe'
RELAY_SHIM_EMIT="$MASK_FIX_BYTES"; RELAY_LOCALE="$MASK_UTF8_LOCALE"
run_relay "$SBLAB/relay.command" "" exit0
reasons=''
if expected_log "$SB/expected-14g.txt" "$MASK_FIX_BYTES_MASKED" '[relay] xfreerdp exited' '[relay] masked logon-info lines=2' 'DONE exit=0'; then
	cmp -s "$SB/expected-14g.txt" "$LOG" || reasons="$reasons log-differs-from-expected;"
else
	reasons="$reasons head-lines-not-client-and-program;"
fi
[ "$(grep -c 'EXAMPLE-HOST\|exampleuser' "$LOG")" = 0 ] || reasons="$reasons placeholder-in-log;"
if [ -z "$reasons" ]; then
	pass "$CASE: CR, tab, %s %d, backslashes, UTF-8 and \\377 (in the masked tail and elsewhere) byte-identical after the rewrite, LC_ALL=[${MASK_UTF8_LOCALE:-<none>}]"
	[ -n "$MASK_UTF8_LOCALE" ] || note "no UTF-8 locale in \`locale -a\`: the comparison ran, the locale-sensitive half (mutation H) was not exercised"
else
	fail "$CASE:$reasons"; note "LC_ALL=[${MASK_UTF8_LOCALE:-<none>}]"; cmp "$SB/expected-14g.txt" "$LOG" | sed 's/^/        /'
fi

# 14h. Refused runs are not rewritten (gate r1 I-2; header "Refused runs … are not rewritten"): a
#      boundary refusal (78) and a JOB-ENV-MISSING (66) each leave no `masked logon-info` and no
#      MASK-FAILED line, the refusal line stays second to last right above DONE, and no temp file is
#      created. Red when the mask step runs for every run (M11: `-eq 1` -> `true`).
mask_refused_reasons() { # <relay-path>
	local r='' kind want
	for kind in boundary jobenv; do
		reset_run
		rm -f "$SBRUNTIME/job.env"
		if [ "$kind" = boundary ]; then
			write_job 'C:\Windows\System32\notepad.exe'
			run_relay "$1" "$DENY_FILE" exit0
			want='[relay] BOUNDARY-REFUSED -- target is not a permitted lab host; no connection attempted'
		else
			run_relay "$1" "" exit0
			want='[relay] JOB-ENV-MISSING -- .build/lab-runtime/job.env is not readable; no connection attempted'
		fi
		! grep -q '^\[relay\] masked logon-info' "$LOG" || r="$r $kind:masked-line-present;"
		! grep -q 'MASK-FAILED' "$LOG" || r="$r $kind:MASK-FAILED-present;"
		[ "$(tail -n 2 "$LOG" | head -n 1)" = "$want" ] || r="$r $kind:second-last-line=[$(tail -n 2 "$LOG" | head -n 1)];"
		case "$kind" in
		boundary) [ "$(last_line)" = 'DONE exit=78' ] || r="$r $kind:last-line=[$(last_line)];" ;;
		*) [ "$(last_line)" = 'DONE exit=66' ] || r="$r $kind:last-line=[$(last_line)];" ;;
		esac
		[ "$(mask_leftovers)" = 0 ] || r="$r $kind:temp-files-left;"
	done
	printf '%s' "$r"
}
begin '14h refused runs are not rewritten'
reasons="$(mask_refused_reasons "$SBLAB/relay.command")"
if [ -z "$reasons" ]; then
	pass "$CASE: boundary refusal (78) and JOB-ENV-MISSING (66): no masked / MASK-FAILED line, refusal line right above DONE, no temp file"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 14i. The copy-back itself failing (gate r1 I-3): a PATH-first `cat` writes a few bytes and exits 1
#      when -- and only when -- its argument is the relay's mask temp file under the runtime
#      directory; every other call is the real cat. The run must log `MASK-FAILED -- the masked log
#      could not be written back;`, end with DONE exit=74, carry no `masked logon-info` line, leave
#      no temp file and no path in the log. (The partial bytes have no newline; the relay appends a
#      newline first, so MASK-FAILED still starts its own line -- asserted below -- and so does DONE.)
#      Red when that branch's `return 1` goes (mutation F, scratch-verified: lines=2 and DONE exit=0
#      on a cut log) and when the newline guard goes (14i: MASK-FAILED not at line start).
REAL_CAT="$(command -v cat)"
mkdir -p "$SB/cat-fail" || exit 1
# shellcheck disable=SC2016  # shim source text: "$1" belongs to the shim, not to this shell
{
	printf '#!/usr/bin/env bash\n'
	printf '# OFFLINE TEST SHIM (14i): copy-back of the relay mask temp file -> partial write, exit 1.\n'
	printf 'case "${1:-}" in\n'
	printf '%q/.relay-mask.*) head -c 20 "$1"; exit 1 ;;\n' "$SBRUNTIME"
	printf 'esac\n'
	printf 'exec %q "$@"\n' "$REAL_CAT"
} > "$SB/cat-fail/cat" && chmod +x "$SB/cat-fail/cat" || exit 1
bash -n "$SB/cat-fail/cat" || exit 1
mask_writeback_reasons() { # <relay-path>
	local r=''
	write_job 'C:\Windows\System32\notepad.exe'
	RELAY_SHIM_EMIT="$MASK_FIX_LOGON"; RELAY_PATH_OVERRIDE="$SB/cat-fail:$SB/bin:$PATH"
	run_relay "$1" "" exit0
	[ "$(grep -cF '[relay] MASK-FAILED -- the masked log could not be written back; ' "$LOG")" = 1 ] || r="$r writeback-MASK-FAILED-lines=$(grep -cF '[relay] MASK-FAILED -- the masked log could not be written back; ' "$LOG");"
	[ "$(last_line)" = 'DONE exit=74' ] || r="$r last-line=[$(last_line)];"
	[ "$(done_lines)" = 1 ] || r="$r done-lines=$(done_lines);"
	# The partial copy-back leaves the last data line without a newline: MASK-FAILED must still start
	# its own line (controller fold after gate r1, fold-report deviation 4).
	[ "$(grep -c '^\[relay\] MASK-FAILED -- ' "$LOG")" = 1 ] || r="$r MASK-FAILED-not-at-line-start;"
	! grep -q 'masked logon-info' "$LOG" || r="$r masked-line-present;"
	[ "$(mask_leftovers)" = 0 ] || r="$r temp-files-left;"
	! grep -qF "$SB/" "$LOG" || r="$r sandbox-path-in-log;"
	printf '%s' "$r"
}
begin '14i copy-back failure is MASK-FAILED'
reasons="$(mask_writeback_reasons "$SBLAB/relay.command")"
if [ -z "$reasons" ]; then
	pass "$CASE: a failing copy-back gives MASK-FAILED (could not be written back), DONE exit=74 last, no masked line, no temp file, no path"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# 14j. A matched line whose segment carries no backslash is not a logon (gate r1 m-1): FreeRDP's
#      `Logon Info V2 [<INVALID DATA>]` stays byte for byte and is not counted, next to a real V2
#      line that is masked -- lines=1. Red when the backslash condition goes (the diagnostic line
#      would read `<host>\<lab-user>]` and lines=2).
MASK_FIX_INVALID="$SB/fixture-invalid.txt"
MASK_FIX_INVALID_MASKED="$SB/fixture-invalid-masked.txt"
write_invalid_fixture() { # <path> <domain\user segment>
	{
		printf '%s\n' '[12:00:01:400] [100:200] [INFO][com.freerdp.client.common] - [client_common_save_session_info]: Logon Info V2 [<INVALID DATA>]'
		printf '%s\n' "[12:00:01:500] [100:200] [INFO][com.freerdp.client.common] - [client_common_save_session_info]: Logon Info V2 [$2 [7]]"
	} > "$1"
}
write_invalid_fixture "$MASK_FIX_INVALID" 'EXAMPLE-HOST\exampleuser' || exit 1
write_invalid_fixture "$MASK_FIX_INVALID_MASKED" '<host>\<lab-user>' || exit 1
begin '14j segment without a backslash is left alone'
write_job 'C:\Windows\System32\notepad.exe'
RELAY_SHIM_EMIT="$MASK_FIX_INVALID"
run_relay "$SBLAB/relay.command" "" exit0
reasons=''
if expected_log "$SB/expected-14j.txt" "$MASK_FIX_INVALID_MASKED" '[relay] xfreerdp exited' '[relay] masked logon-info lines=1' 'DONE exit=0'; then
	cmp -s "$SB/expected-14j.txt" "$LOG" || reasons="$reasons log-differs-from-expected;"
else
	reasons="$reasons head-lines-not-client-and-program;"
fi
if [ -z "$reasons" ]; then
	pass "$CASE: Logon Info V2 [<INVALID DATA>] unchanged and uncounted, the real V2 line masked, lines=1"
else
	fail "$CASE:$reasons"; note "log: $(cat "$LOG")"
fi

# M1. Boundary gate bypassed (`if ! crdp_assert_lab_boundary` -> `if false`): the refused
#     scenario must now invoke xfreerdp, i.e. case 1's pin bites.
begin 'M1 gate-bypass mutant'
MUTANT_GATE="$SBLAB/labtest-mutant-gate.command"
# shellcheck disable=SC2016  # the single quotes are deliberate: sed must see the literal `$`
if sed 's/if ! crdp_assert_lab_boundary "\${WIN_HOST:-}"; then/if false; then/' "$SBLAB/relay.command" > "$MUTANT_GATE" \
	&& ! cmp -s "$MUTANT_GATE" "$SBLAB/relay.command" && bash -n "$MUTANT_GATE"; then
	write_job 'C:\Windows\System32\notepad.exe'
	run_relay "$MUTANT_GATE" "$DENY_FILE" exit0
	if [ "$(xfreerdp_calls)" = "1" ] && ! grep -qF 'BOUNDARY-REFUSED' "$LOG"; then
		pass "$CASE: detected -- the refused scenario invokes xfreerdp (case 1 pins the gate)"
	else
		fail "$CASE: NOT detected -- case 1 would pass against a relay without the gate"
	fi
else
	fail "$CASE: could not build the mutant (the guard line moved?)"
fi

# M2. TIMEOUT kill removed (`kill "$XPID"` -> `:`): the mutant still `wait`s for xfreerdp,
#     so with a 30s shim and TIMEOUT=1 it cannot write DONE inside a 4s watchdog (26s of
#     margin against the sleep) -- i.e. case 7 pins the kill.
begin 'M2 kill-removed mutant'
MUTANT_KILL="$SBLAB/labtest-mutant-kill.command"
# shellcheck disable=SC2016  # deliberate literal `$XPID` for sed
if sed 's/^\([[:space:]]*\)kill "\$XPID" 2>\/dev\/null$/\1: # kill removed by mutation/' "$SBLAB/relay.command" > "$MUTANT_KILL" \
	&& ! cmp -s "$MUTANT_KILL" "$SBLAB/relay.command" && bash -n "$MUTANT_KILL"; then
	write_job 'C:\Windows\System32\notepad.exe' '' 1
	elapsed="$(run_relay_bounded "$MUTANT_KILL" "" sleep 4)"; self_exited=$?
	kill_recorded_shims
	if [ "$self_exited" -ne 0 ] && [ "$(done_lines)" = "0" ]; then
		pass "$CASE: detected -- no DONE inside ${elapsed}s (case 7 pins the TIMEOUT kill)"
	else
		fail "$CASE: NOT detected"; note "self_exited=$self_exited elapsed=${elapsed}s DONE lines=$(done_lines)"
	fi
else
	fail "$CASE: could not build the mutant (the kill line moved?)"
fi

# M3. job.env sourced into the relay's own shell again (the three subshell reads replaced by one
#     `source`): case 10c's override scenario must now dial the overridden host -- i.e. 10c pins
#     the isolation.
begin 'M3 plain-source mutant'
MUTANT_SOURCE="$SBLAB/labtest-mutant-source.command"
# The JOB_KEYS subshell line becomes a plain `source` (the `read` block then reads four empty
# lines from the here-doc, so the subsequent `${TIMEOUT:-25}` default, PROGRAM and XFREERDP_EXTRA
# come from the sourced variables -- exactly the pre-isolation behaviour).
if awk '
	/JOB_KEYS="\$\( \. "\$RUNTIME\/job\.env"/ {
		if (!done) { print "        source \"$RUNTIME/job.env\"; JOB_KEYS=\"${PROGRAM:-}"; print "${CMDARGS:-}"; print "${TIMEOUT:-}"; print "${XFREERDP_EXTRA:-}"; print "END-OF-JOB-KEYS\""; done = 1 }
		next
	}
	{ print }
	END { if (!done) exit 3 }
' "$SBLAB/relay.command" > "$MUTANT_SOURCE" && ! cmp -s "$MUTANT_SOURCE" "$SBLAB/relay.command" && bash -n "$MUTANT_SOURCE"; then
	# All three keys present, so the mutant fails for the RIGHT reason (a plain source that then
	# hit `set -u` on an unset key would die before argv and read as "detected" for nothing).
	{
		printf 'PROGRAM=%q\nCMDARGS=\nTIMEOUT=5\n' 'C:\Windows\System32\notepad.exe'
		printf 'WIN_HOST=198.51.100.7\nSHARE=/etc\n'
	} > "$SBRUNTIME/job.env"
	run_relay "$MUTANT_SOURCE" "" exit0
	argv="$(xfreerdp_argv)"
	if [[ "$argv" == *"[/v:198.51.100.7]"* ]] && [[ "$argv" == *"[/drive:lab,/etc]"* ]]; then
		pass "$CASE: detected -- with a plain source the argv dials the job.env host AND mounts its share (case 10c pins the isolation)"
	else
		fail "$CASE: NOT detected"; note "argv: $argv"
	fi
else
	fail "$CASE: could not build the mutant (the subshell read lines moved?)"
fi

# M4. XFREERDP_EXTRA allowlist disabled (`if ! relay_extra_tokens_ok` -> `if false`): case 12b's
#     redirect scenario must now reach xfreerdp with the /v: token -- i.e. 11b pins the allowlist.
begin 'M4 extra-allowlist mutant'
MUTANT_EXTRA="$SBLAB/labtest-mutant-extra.command"
# shellcheck disable=SC2016  # deliberate literal `$XFREERDP_EXTRA` for sed
if sed 's/if ! relay_extra_tokens_ok "\$XFREERDP_EXTRA"; then/if false; then/' "$SBLAB/relay.command" > "$MUTANT_EXTRA" \
	&& ! cmp -s "$MUTANT_EXTRA" "$SBLAB/relay.command" && bash -n "$MUTANT_EXTRA"; then
	printf 'PROGRAM=%q\nXFREERDP_EXTRA=%q\nTIMEOUT=5\n' 'C:\Windows\System32\notepad.exe' '/scale:180 /v:198.51.100.7' > "$SBRUNTIME/job.env"
	run_relay "$MUTANT_EXTRA" "" exit0
	if [ "$(xfreerdp_calls)" = "1" ] && grep -qF '198.51.100.7' "$LABTEST_TRACE"; then
		pass "$CASE: detected -- the redirect token reaches xfreerdp (case 12b pins the allowlist)"
	else
		fail "$CASE: NOT detected -- case 12b would pass against a relay without the allowlist"
	fi
else
	fail "$CASE: could not build the mutant (the allowlist guard line moved?)"
fi

# M5. Client line removed (the `echo "[relay] client=` line deleted): 13a's own verdict --
#     client_run_reasons over the 13a scenario -- must turn red, and for the right reason (the
#     mutant still dials, it only stops naming the client).
begin 'M5 client-line-removed mutant'
MUTANT_CLIENTLINE="$SBLAB/labtest-mutant-clientline.command"
if sed '/^[[:space:]]*echo "\[relay\] client=/d' "$SBLAB/relay.command" > "$MUTANT_CLIENTLINE" \
	&& ! cmp -s "$MUTANT_CLIENTLINE" "$SBLAB/relay.command" && bash -n "$MUTANT_CLIENTLINE"; then
	write_job 'C:\Windows\System32\notepad.exe'
	run_relay "$MUTANT_CLIENTLINE" "" exit0
	reasons="$(client_run_reasons 9.9.9 path "$SB/bin/xfreerdp")"
	if [[ "$reasons" == *' client-lines=0;'* ]] && [ "$(xfreerdp_calls)" = "1" ]; then
		pass "$CASE: detected -- 13a's verdict against the mutant:$reasons"
	else
		fail "$CASE: NOT detected -- 13a would pass against a relay that logs no client line"; note "reasons: [$reasons] calls=$(xfreerdp_calls)"
	fi
else
	fail "$CASE: could not build the mutant (the client line moved?)"
fi

# M6. relay-client.env ignored (its presence test -> `if false`): 13b's own
#     verdict must turn red, because the PATH shim dials instead of the pinned stub.
begin 'M6 pin-ignored mutant'
MUTANT_PIN="$SBLAB/labtest-mutant-pin.command"
# shellcheck disable=SC2016  # deliberate literal `$RUNTIME` for sed
if sed 's/if \[ -e "\$RUNTIME\/relay-client\.env" \] || \[ -L "\$RUNTIME\/relay-client\.env" \]; then/if false; then/' "$SBLAB/relay.command" > "$MUTANT_PIN" \
	&& ! cmp -s "$MUTANT_PIN" "$SBLAB/relay.command" && bash -n "$MUTANT_PIN"; then
	write_client_env "$PIN_A"
	write_job 'C:\Windows\System32\notepad.exe'
	run_relay "$MUTANT_PIN" "" exit0
	reasons="$(client_run_reasons 8.8.8 file "$PIN_A")"
	if [[ "$reasons" == *' dial-not-from-the-expected-binary;'* ]] && [[ "$(xfreerdp_argv)" == *" argv0=$SB/bin/xfreerdp ["* ]]; then
		pass "$CASE: detected -- the PATH shim dials instead of the pin; 13b's verdict against the mutant:$reasons"
	else
		fail "$CASE: NOT detected -- 13b would pass against a relay that ignores relay-client.env"; note "reasons: [$reasons]"
	fi
else
	fail "$CASE: could not build the mutant (the relay-client.env test moved?)"
fi

# M7. --version exit status ignored (`if [ "$ver_rc" -ne 0 ]` -> `if false`): 13k's exit-127 client
#     must now be dialled -- i.e. 13k pins the probe's status.
begin 'M7 probe-status-ignored mutant'
MUTANT_PROBE="$SBLAB/labtest-mutant-probe.command"
# shellcheck disable=SC2016  # deliberate literal `$ver_rc` for sed
if sed 's/if \[ "\$ver_rc" -ne 0 \]; then/if false; then/' "$SBLAB/relay.command" > "$MUTANT_PROBE" \
	&& ! cmp -s "$MUTANT_PROBE" "$SBLAB/relay.command" && bash -n "$MUTANT_PROBE"; then
	write_client_env "$PIN_V127"
	write_job 'C:\Windows\System32\notepad.exe'
	run_relay "$MUTANT_PROBE" "" exit0
	reasons="$(client_refused_reasons exit127 'client version probe failed')"
	if [[ "$reasons" == *'exit127:no-CLIENT-INVALID-line;'* ]] && [ "$(xfreerdp_calls)" = "1" ]; then
		pass "$CASE: detected -- the client that cannot start is dialled; 13k's verdict against the mutant:$reasons"
	else
		fail "$CASE: NOT detected -- 13k would pass against a relay that ignores the probe status"; note "reasons: [$reasons] calls=$(xfreerdp_calls)"
	fi
else
	fail "$CASE: could not build the mutant (the probe status test moved?)"
fi

# M8. argv[0] no longer set (`( exec -a xfreerdp "$XFREERDP_BIN"` -> `( exec "$XFREERDP_BIN"`): 13l's
#     own verdict must turn red -- its shape half always, its compiled-stub half where cc exists.
begin 'M8 argv0-unset mutant'
MUTANT_ARGV0="$SBLAB/labtest-mutant-argv0.command"
# shellcheck disable=SC2016  # deliberate literal `$XFREERDP_BIN` for sed
if sed 's/( exec -a xfreerdp "\$XFREERDP_BIN"/( exec "$XFREERDP_BIN"/' "$SBLAB/relay.command" > "$MUTANT_ARGV0" \
	&& ! cmp -s "$MUTANT_ARGV0" "$SBLAB/relay.command" && bash -n "$MUTANT_ARGV0"; then
	write_job 'C:\Windows\System32\notepad.exe'
	reasons="$(argv0_reasons "$MUTANT_ARGV0")"
	if [[ "$reasons" == *' shape:'* ]] && { [ "$CSTUB_OK" -ne 1 ] || [[ "$reasons" == *'pinned:argv0-is-not-xfreerdp;'* ]]; }; then
		pass "$CASE: detected -- 13l's verdict against the mutant:$reasons"
	else
		fail "$CASE: NOT detected -- 13l would pass against a relay that dials with the pin path as argv[0]"; note "reasons: [$reasons]"
	fi
else
	fail "$CASE: could not build the mutant (the dial statement moved?)"
fi

# M9. Mask call removed (`if relay_mask_logon_info; then` -> `if MASK_LINES=0; then`): the mutant still
#     logs `lines=0` and DONE exit=0 but leaves the names in -- 14a's own verdict must turn red.
begin 'M9 mask-call-removed mutant'
MUTANT_MASK="$SBLAB/labtest-mutant-mask.command"
if sed 's/if relay_mask_logon_info; then/if MASK_LINES=0; then/' "$SBLAB/relay.command" > "$MUTANT_MASK" \
	&& ! cmp -s "$MUTANT_MASK" "$SBLAB/relay.command" && bash -n "$MUTANT_MASK"; then
	reset_run
	reasons="$(mask_a_reasons "$MUTANT_MASK")"
	if [[ "$reasons" == *'EXAMPLE-HOST-in-log;'* ]]; then
		pass "$CASE: detected -- 14a's verdict against the mutant:$reasons"
	else
		fail "$CASE: NOT detected -- 14a would pass against a relay that never masks"; note "reasons: [$reasons]"
	fi
else
	fail "$CASE: could not build the mutant (the mask call moved?)"
fi

# M10. Copy-back by rename (`cat "$RELAY_MASK_TMP" >"$LOG"` -> `mv "$RELAY_MASK_TMP" "$LOG"`): the log is masked
#      but is a new file -- 14d's own verdict must turn red on the inode.
begin 'M10 rename-copy-back mutant'
MUTANT_MV="$SBLAB/labtest-mutant-mv.command"
# shellcheck disable=SC2016  # deliberate literal `$RELAY_MASK_TMP` / `$LOG` for sed
if sed 's/if ! cat "\$RELAY_MASK_TMP" >"\$LOG"; then/if ! mv "$RELAY_MASK_TMP" "$LOG"; then/' "$SBLAB/relay.command" > "$MUTANT_MV" \
	&& ! cmp -s "$MUTANT_MV" "$SBLAB/relay.command" && bash -n "$MUTANT_MV"; then
	reset_run
	reasons="$(mask_d_reasons "$MUTANT_MV")"
	if [[ "$reasons" == *'inode-changed='* ]]; then
		pass "$CASE: detected -- 14d's verdict against the mutant:$reasons"
	else
		fail "$CASE: NOT detected -- 14d would pass against a relay that renames over relay.log"; note "reasons: [$reasons]"
	fi
else
	fail "$CASE: could not build the mutant (the copy-back line moved?)"
fi

# M11. Refused runs rewritten too (`if [ "$RELAY_DIALLED" -eq 1 ]; then` -> `if true; then`, gate r1
#      I-2's mutation I): every refusal now logs `masked logon-info lines=0` above DONE -- 14h's own
#      verdict must turn red.
begin 'M11 mask-on-refusal mutant'
MUTANT_REFUSED="$SBLAB/labtest-mutant-refused.command"
# shellcheck disable=SC2016  # deliberate literal `$RELAY_DIALLED` for sed
if sed 's/^if \[ "\$RELAY_DIALLED" -eq 1 \]; then$/if true; then/' "$SBLAB/relay.command" > "$MUTANT_REFUSED" \
	&& ! cmp -s "$MUTANT_REFUSED" "$SBLAB/relay.command" && bash -n "$MUTANT_REFUSED"; then
	reasons="$(mask_refused_reasons "$MUTANT_REFUSED")"
	if [[ "$reasons" == *'boundary:masked-line-present;'* ]] && [[ "$reasons" == *'jobenv:masked-line-present;'* ]]; then
		pass "$CASE: detected -- 14h's verdict against the mutant:$reasons"
	else
		fail "$CASE: NOT detected -- 14h would pass against a relay that rewrites refused runs"; note "reasons: [$reasons]"
	fi
else
	fail "$CASE: could not build the mutant (the dialled-run guard moved?)"
fi

# 11. Across EVERY case above the refuse shims were never reached: the Terminal self-close
#     branch was not taken and no socket helper was invoked (run-long trace, never reset). This
#     block and 12 sit after the last relay run on purpose, so "every" covers all of them.
begin '11 refuse shims never reached'
if [ ! -s "$LABTEST_REFUSED_TRACE" ]; then
	pass "$CASE: osascript/nc shims recorded no call across the whole run (TERM_PROGRAM cleared; no socket helper invoked)"
else
	fail "$CASE: $(sort "$LABTEST_REFUSED_TRACE" | uniq -c | tr '\n' ';')"
fi

# 12. Tracked-tree census: every run above wrote only under .build/lab-runtime.
begin '12 tracked tree census'
if diff -q "$TRACKED_PRISTINE" <(snapshot_tracked) >/dev/null; then
	pass "$CASE: no case wrote into the tracked lab directory"
else
	fail "$CASE: tracked tree changed"; diff "$TRACKED_PRISTINE" <(snapshot_tracked) | sed 's/^/        /'
fi

# A GENUINE leak, still alive, with the identity write_xfreerdp_shim would itself have recorded
# (proc_identity): the scan must actually kill it and count leftover=1. This is what catches gate
# r1 O2 (identity check disabled -- always answers "no match", so the scan never kills anything):
# without a case that requires a real match to be killed, a scan that never kills anything looks
# identical to one that correctly declines to kill a mismatch. "gone" is polled rather than read
# once, because a killed process sits as a zombie for a moment before it is reaped.
begin 'orphan check kills a pid whose identity still matches'
sleep 30 &
match_pid=$!
disown "$match_pid" 2>/dev/null || true
match_ledger="$SB/pid-ledger-match-proof.txt"
match_ident="$(proc_identity "$match_pid")"
printf '%s\t%s\n' "$match_pid" "$match_ident" > "$match_ledger"
orphan_scan "$match_ledger"
match_ledgered=$SCAN_LEDGERED; match_leftover=$SCAN_LEFTOVER; match_reused=$SCAN_REUSED
gone=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if ! kill -0 "$match_pid" 2>/dev/null; then gone=1; break; fi
	st="$(ps -o stat= -p "$match_pid" 2>/dev/null | tr -d '[:space:]')"
	case "$st" in Z*) gone=1; break ;; esac
	sleep 0.2
done
# Bounded cleanup regardless of verdict: a mutant that disables the kill (gate r1 O2) would
# otherwise leave this a real, unkilled sleep for its whole 30s, and `wait` would block for all of
# it -- this case must fail fast, not hang the suite.
kill -9 "$match_pid" 2>/dev/null || true
wait "$match_pid" 2>/dev/null || true
if [ "$match_ledgered" = "1" ] && [ "$match_leftover" = "1" ] && [ "$match_reused" = "0" ] && [ "$gone" = "1" ]; then
	pass "$CASE: a ledgered pid whose live identity still matches the recorded one is killed and counted leftover=1"
else
	fail "$CASE: ledgered=$match_ledgered leftover=$match_leftover reused=$match_reused gone=$gone"
fi

# A ledgered pid the OS has since reused for an unrelated process must NOT be killed by this
# check, and must not be counted as a leftover either. Proved by INTERCEPTING every real kill
# (non -0) call orphan_scan makes during this run and asserting none targeted this pid, rather
# than trusting a post-hoc `kill -0` read: a pid this suite itself just killed sits as a zombie
# until reaped, and `kill -0` on a zombie still reports success -- a `still_alive` check could not
# tell a live stranger from one already killed and awaiting reap. This is what catches gate r1 O4
# (the reused branch also calls kill) and, together with the counters below, gate r1 O1 (the
# identity check is disabled by always answering "match").
begin 'orphan check ignores a pid whose identity no longer matches'
sleep 30 &
reuse_pid=$!
disown "$reuse_pid" 2>/dev/null || true
reuse_ledger="$SB/pid-ledger-reuse-proof.txt"
printf '%s\t%s\n' "$reuse_pid" 'labtest-mismatched-identity-can-never-equal-a-real-identity' > "$reuse_ledger"
KILL_CALLS_FILE="$SB/kill-calls-reuse-proof.txt"; : > "$KILL_CALLS_FILE"
# shellcheck disable=SC2329,SC2317  # shadows the kill builtin only for this case; called indirectly by orphan_scan
kill() {
	if [ "${1:-}" != '-0' ]; then printf '%s\n' "$*" >> "$KILL_CALLS_FILE"; fi
	command kill "$@"
}
orphan_scan "$reuse_ledger"
unset -f kill
real_kill_hit=0
grep -qF "$reuse_pid" "$KILL_CALLS_FILE" 2>/dev/null && real_kill_hit=1
command kill "$reuse_pid" 2>/dev/null || true
wait "$reuse_pid" 2>/dev/null || true
if [ "$SCAN_LEDGERED" = "1" ] && [ "$SCAN_LEFTOVER" = "0" ] && [ "$SCAN_REUSED" = "1" ] && [ "$real_kill_hit" = "0" ]; then
	pass "$CASE: a ledgered pid whose live identity no longer matches the recorded one is left running (reused=1), never sent a real kill"
else
	fail "$CASE: ledgered=$SCAN_LEDGERED leftover=$SCAN_LEFTOVER reused=$SCAN_REUSED real_kill_hit=$real_kill_hit"
fi

# A ledgered pid that is ALREADY a zombie (exited, awaiting reap) must not be treated as alive:
# ps -o stat= is checked first and a leading Z short-circuits before any identity comparison or
# kill attempt -- a signal to a zombie is a no-op that would only waste a syscall. Proved with a
# REAL zombie made by zombie-maker (see its own comment: this platform's bash reaps a plain
# background subshell too fast to observe from shell alone). Best-effort like CSTUB_OK: without a
# working `cc` the case says so and claims nothing.
begin 'orphan check treats a zombie as already gone'
if [ "$ZOMBIE_MAKER_OK" -ne 1 ]; then
	pass "$CASE: no working cc on this machine to build the zombie-maker helper -- skipped"
else
	zpid_file="$SB/zombie-child-pid.txt"
	: > "$zpid_file"
	"$ZOMBIE_MAKER" > "$zpid_file" &
	maker_pid=$!
	disown "$maker_pid" 2>/dev/null || true
	zpid=''
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		[ -s "$zpid_file" ] && { zpid="$(cat "$zpid_file")"; break; }
		sleep 0.1
	done
	if [ -z "$zpid" ]; then
		fail "$CASE: the zombie-maker helper never reported its child's pid"
	else
		st="$(ps -o stat= -p "$zpid" 2>/dev/null | tr -d '[:space:]')"
		case "$st" in
		Z*)
			zledger="$SB/pid-ledger-zombie-proof.txt"
			printf '%s\t%s\n' "$zpid" 'labtest-zombie-identity-is-irrelevant' > "$zledger"
			orphan_scan "$zledger"
			if [ "$SCAN_LEDGERED" = "1" ] && [ "$SCAN_LEFTOVER" = "0" ] && [ "$SCAN_REUSED" = "0" ] && [ "$SCAN_ZOMBIE" = "1" ]; then
				pass "$CASE: a zombie ledgered pid is counted zombie=1, never leftover or reused, never sent a kill"
			else
				fail "$CASE: ledgered=$SCAN_LEDGERED leftover=$SCAN_LEFTOVER reused=$SCAN_REUSED zombie=$SCAN_ZOMBIE"
			fi
			;;
		*) fail "$CASE: zombie-maker's child (pid $zpid) is not in Z state (stat=[$st]) -- the helper itself did not hold up its end" ;;
		esac
	fi
	kill -TERM "$maker_pid" 2>/dev/null || true
	wait "$maker_pid" 2>/dev/null || true
fi

# The identity read at scan time must use the SAME fixed TZ (UTC0) as the write side regardless of
# what TZ the CALLER happens to have exported -- the exact blind spot gate r1 I-2 measured (a
# maintainer's exported TZ made `ps -o lstart=` disagree with what was recorded, and a real leak
# went uncaught). Gate r2 B-1: writing and reading under the SAME exported TZ is a tautology --
# proc_identity() would still agree with itself even with no pin at all, since both calls would
# then be reading the SAME (wrong) ambient TZ. The write and the read below run under DIFFERENT
# exported TZs (Asia/Tokyo, then America/Los_Angeles -- a difference of several hours, so an
# unpinned `ps -o lstart=` would format a different hour on each side) precisely so that only a
# real TZ=UTC0 pin can make the two sides agree.
begin 'orphan check identity ignores the caller TZ'
old_tz="${TZ-}"; had_tz=1; [ -z "${TZ+x}" ] && had_tz=0
export TZ=Asia/Tokyo
sleep 30 &
tz_pid=$!
disown "$tz_pid" 2>/dev/null || true
tz_ledger="$SB/pid-ledger-tz-proof.txt"
tz_ident="$(proc_identity "$tz_pid")"
printf '%s\t%s\n' "$tz_pid" "$tz_ident" > "$tz_ledger"
export TZ=America/Los_Angeles
orphan_scan "$tz_ledger"
tz_ledgered=$SCAN_LEDGERED; tz_leftover=$SCAN_LEFTOVER; tz_reused=$SCAN_REUSED
if [ "$had_tz" = "1" ]; then export TZ="$old_tz"; else unset TZ; fi
kill "$tz_pid" 2>/dev/null || true; wait "$tz_pid" 2>/dev/null || true
if [ "$tz_ledgered" = "1" ] && [ "$tz_leftover" = "1" ] && [ "$tz_reused" = "0" ]; then
	pass "$CASE: written under TZ=Asia/Tokyo, read under TZ=America/Los_Angeles -- proc_identity()'s fixed TZ=UTC0 still agrees on both sides (leftover=1)"
else
	fail "$CASE: ledgered=$tz_ledgered leftover=$tz_leftover reused=$tz_reused"
fi

# Same as above for LC_ALL -- the other half of gate r1 I-2's repro (a zh_CN Terminal), and the
# same gate r2 B-1 fix: write under a non-C locale, then switch to LC_ALL=C before the read, so
# only a real pin (not a shared ambient locale) can make the two sides agree. Best-effort: only
# runs the behavioural half when a non-C locale is actually installed on this machine (CI images
# often carry only C/C.UTF-8/en_US.UTF-8); LC_ALL=C is hardcoded in proc_identity either way.
begin 'orphan check identity ignores the caller locale'
lc_probe="$(locale -a 2>/dev/null | grep -im1 -E '^(zh_CN|de_DE|ja_JP|fr_FR)\.utf-?8$' || true)"
if [ -z "$lc_probe" ]; then
	pass "$CASE: no non-C locale installed on this machine to probe with -- skipped (LC_ALL=C is hardcoded in proc_identity regardless)"
else
	old_lc_all="${LC_ALL-}"; had_lc_all=1; [ -z "${LC_ALL+x}" ] && had_lc_all=0
	export LC_ALL="$lc_probe"
	sleep 30 &
	lc_pid=$!
	disown "$lc_pid" 2>/dev/null || true
	lc_ledger="$SB/pid-ledger-lc-proof.txt"
	lc_ident="$(proc_identity "$lc_pid")"
	printf '%s\t%s\n' "$lc_pid" "$lc_ident" > "$lc_ledger"
	export LC_ALL=C
	orphan_scan "$lc_ledger"
	lc_ledgered=$SCAN_LEDGERED; lc_leftover=$SCAN_LEFTOVER; lc_reused=$SCAN_REUSED
	if [ "$had_lc_all" = "1" ]; then export LC_ALL="$old_lc_all"; else unset LC_ALL; fi
	kill "$lc_pid" 2>/dev/null || true; wait "$lc_pid" 2>/dev/null || true
	if [ "$lc_ledgered" = "1" ] && [ "$lc_leftover" = "1" ] && [ "$lc_reused" = "0" ]; then
		pass "$CASE: written under LC_ALL=$lc_probe, read under LC_ALL=C -- proc_identity()'s fixed LC_ALL=C still agrees on both sides (leftover=1)"
	else
		fail "$CASE: ledgered=$lc_ledgered leftover=$lc_leftover reused=$lc_reused (locale=$lc_probe)"
	fi
fi

# No sleeping shim recorded by THIS run may outlive the suite (the `exec sleep` shape plus
# kill_recorded_shims). Checked against the pids this run recorded, not a machine-wide pgrep --
# an unrelated `sleep 30` on the maintainer's Mac is not this suite's business -- and only when
# the recorded identity still matches the live process (see orphan_scan): a recorded pid the OS
# has since reused for something else is left alone and counted in reused=, and a pid already a
# zombie is counted in zombie=.
begin 'orphan check'
orphan_scan "$LABTEST_PID_LEDGER"
if [ "$SCAN_LEDGERED" -eq 0 ]; then
	fail "$CASE: the pid ledger is empty -- the recorder stopped working, so this check saw nothing"
elif [ "$SCAN_LEFTOVER" = "0" ]; then
	pass "$CASE: none of the $SCAN_LEDGERED recorded shim pid(s) with a matching identity is still alive (reused=$SCAN_REUSED unknown=$SCAN_UNKNOWN zombie=$SCAN_ZOMBIE)"
else
	fail "$CASE: $SCAN_LEFTOVER of $SCAN_LEDGERED recorded shim pid(s) with a matching identity still alive (reused=$SCAN_REUSED unknown=$SCAN_UNKNOWN zombie=$SCAN_ZOMBIE)"
fi

# Every case must have reported (review r2 B1): a case that neither passed nor failed would
# otherwise vanish from the tally with exit 0.
EXPECTED_CASES=63
if [ $((PASSES + FAILURES)) -ne "$EXPECTED_CASES" ]; then
	fail "case tally: $((PASSES + FAILURES)) cases reported, expected $EXPECTED_CASES -- a case produced no verdict"
fi



printf '\n%d passed, %d failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
