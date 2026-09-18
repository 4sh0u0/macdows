#!/usr/bin/env bash
# Offline test suite for Scripts/lab/wdp-etw.command -- the Terminal.app launcher that captures a
# realtime ETW session from the test host's Windows Device Portal. The wrapper is the only thing
# in this repo that ever holds the host's portal credential in a file, so its guards are the ones
# that must not be allowed to rot: the fail-closed boundary gate BEFORE any credential exists, the
# etw-job.env contract, the "an existing certificate pin is never overwritten" rule (and its one
# sanctioned exception, PIN_TRUST_ROTATION=1, which ARCHIVES a stale pin beside itself rather than
# overwriting it -- owner ruling 2026-09-16), the credential file's lifecycle (0600, removed on
# every exit path) and the log mask that keeps etw.log paste-safe. None of that is covered by
# test-relay-offline.sh -- the relay and the wrapper share only their idioms, not a line of code.
#
# Safe in CI, by construction rather than by promise:
#   1. `osascript`, `open`, `openssl` and `mktemp` are PATH-shimmed for every case, and the suite
#      ASSERTS before the first case that PATH resolves each of them to the shim. `date` is
#      shimmed PER CASE instead, from its own directory ($SB/bin-date, prepended to PATH through
#      RUN_ETW_PATH only by the cases that need it): it answers the rotation archive's stamp
#      format with a FIXED stamp, so an archive's name is a known value a case can pre-create or
#      assert on, and a frozen clock reaches only the cases that asked for one -- the default
#      sandbox PATH resolves the REAL date, and the pre-flight asserts both halves. The openssl
#      shim opens no
#      socket; it records its argv and answers `x509` with a fixed fingerprint line. The mktemp
#      shim records its argv and then execs the real binary, which is what turns "no credential
#      file survives the run" into the stronger "no credential file was ever created".
#      (The one place the REAL openssl runs is case 23's python suite: test_wdp_etw.make_cert
#      builds a throw-away certificate for its loopback fake portal. It opens no socket either.)
#   2. `python3` is deliberately NOT shimmed -- Scripts/lib.sh's boundary gate evaluates the
#      segments with the REAL python3, and a shim there would replace the thing under test. The
#      capture client is stubbed at its own path instead: the sandbox's Scripts/lab/wdp_etw.py is
#      written by this suite and records the WDP_* environment, the NAMES of its whole environment
#      (so "what did the wrapper let through" is answerable without printing a value), the
#      credential file's mode and contents and its argv, then exits with LABTEST_CLIENT_RC. With
#      LABTEST_CLIENT_STDERR=1 it also prints a traceback-like line naming its own module path and
#      a refusal quoting the credential file, which is what case 18 masks. It opens no socket.
#   3. HOME is redirected into the sandbox. Its host.env carries an RFC 5737 documentation
#      address and placeholder account strings (never a real host, never a real credential), and
#      the placeholder password is greppable because one case asserts it never reaches the log.
#      Four cases swap that file for a variant -- an IPv6 documentation address, a DNS name, the
#      `export WIN_PASS=...` style -- and each restores it before the next case begins.
#   4. wdp-etw.command is copied into a sandbox tree at the same depth as the real one AND under
#      the sandbox HOME, exactly as the real checkout sits on the lab Mac. Its own
#      `$LAB_DIR/../..` derivation therefore lands REPO_ROOT (and with it .build/lab-runtime/wdp,
#      etw-job.env and etw.log) inside the sandbox, and every path the wrapper logs is a path
#      under $HOME -- which is the value the log mask's <HOME> rule exists for. The real runtime
#      is never touched.
#   5. TMPDIR is redirected into the sandbox, so the credential file the wrapper mktemps is
#      created, counted and (on every passing path) found gone inside $SB.
#   6. TERM_PROGRAM is cleared, so the Terminal self-close branch is never taken; the osascript
#      shim exits 97 and records into a trace that is NOT reset between cases, so the "never
#      reached" assertion at the end covers the whole run.
#
# Each case starts with `begin`, which resets the per-case trace, the sandbox log, the job
# instance, the rotations record and the PATH override, so no case depends on what the previous
# one left behind. Nine mutation proofs
# (M1 gate bypassed, M2 credential removal disabled, M3 log mask disabled, M4 masking pipeline
# reverted to block buffering, M5 line grammar removed, M6 the PIN_TRUST_ROTATION gate removed,
# M7 the rotation's no-clobber archive link weakened to `ln -f`, M8 the "did this run rotate?"
# half of the disagreement line removed, M9 the rotations record appended-to -> truncated)
# copy the wrapper with one guard removed and require the case that claims to pin it to FAIL
# against the mutant. A pin that would also pass against the broken code pins nothing.
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

SB="$(mktemp -d "${TMPDIR:-/tmp}/macdows-etw-offline.XXXXXX")" || exit 1
# Normalised, because the wrapper derives its own paths with `cd … && pwd` and this suite compares
# them as strings: a TMPDIR ending in `/` (macOS's does) would otherwise leave a `//` in $SB that
# the wrapper's environment does not carry, and a case would fail on a path spelling.
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

SBHOME="$SB/home"
# The sandbox checkout lives UNDER the sandbox HOME, exactly as the real one does on the lab Mac.
# That is not decoration: the client's module path is then a path under $HOME, and a client
# traceback -- stderr is piped into the wrapper's log too -- prints it. On the real machine that
# path carries the maintainer's local account name, which is why the mask has a <HOME> rule and
# why case 18 can measure it.
SBROOT="$SBHOME/checkout"
SBLAB="$SBROOT/Scripts/lab"
SBRUNTIME="$SBROOT/.build/lab-runtime"
SBWDP="$SBRUNTIME/wdp"
SBTMP="$SB/tmp"
LOG="$SBRUNTIME/etw.log"
JOB="$SBRUNTIME/etw-job.env"
PINFILE="$SBWDP/portal-cert-sha256.txt"
# The wrapper's durable rotation record. Reset by `begin` like the log and the job instance: it is
# append-only WITHIN a run by design, so a case that counts its lines must start from nothing, and
# a case must not be able to pass on lines an earlier case appended.
ROTLOG="$SBWDP/portal-cert-rotations.log"
# The credential file's template. The wrapper mktemps it under TMPDIR, which this suite redirects
# into the sandbox, so "how many credential files exist right now" is an exact question here.
CREDGLOB="$SBTMP/macdows-etw-cred."
# Per-case trace of client/openssl invocations (reset by `begin`) and a run-long trace of the
# shims that must never be reached (never reset).
export LABTEST_TRACE="$SB/trace.txt"
export LABTEST_REFUSED_TRACE="$SB/refused-trace.txt"
: > "$LABTEST_REFUSED_TRACE"

mkdir -p "$SBLAB/jobs" "$SBHOME/.config/macdows" "$SB/bin" "$SB/bin-date" "$SBTMP" || exit 1
cp "$LAB/wdp-etw.command" "$SBLAB/wdp-etw.command" || exit 1
cp "$LAB/run-scenario.sh" "$SBLAB/run-scenario.sh" || exit 1
cp "$LAB"/jobs/*.env "$SBLAB/jobs/" || exit 1
mkdir -p "$SBROOT/Scripts" || exit 1
cp "$REPO_ROOT/Scripts/lib.sh" "$SBROOT/Scripts/lib.sh" || exit 1
# NB $SBRUNTIME is deliberately NOT pre-created: the wrapper's own `mkdir -p` has to make it
# (case 0 pins that explicitly).

# RFC 5737 TEST-NET-1 address and placeholder strings: never a real host, never a real credential.
HOSTENV_FILE="$SBHOME/.config/macdows/host.env"
cat > "$HOSTENV_FILE" <<'HOSTENV' || exit 1
WIN_HOST=192.0.2.10
WIN_USER=labtest-placeholder
WIN_PASS=LABTEST-PLACEHOLDER-SECRET-3f9a
HOSTENV
# The DEFAULT boundary file location (what the wrapper resolves when MACDOWS_LAB_BOUNDARY_FILE is
# unset) allows the placeholder segment; the deny file lives elsewhere and is injected by path.
ALLOW_FILE="$SBHOME/.config/macdows/lab-boundary.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="192.0.2.0/24"\n' > "$ALLOW_FILE" || exit 1
DENY_FILE="$SB/deny-boundary.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="198.51.100.0/24"\n' > "$DENY_FILE" || exit 1

# -- The capture client, stubbed at its own path ----------------------------------------------
# Not a PATH shim of python3 (see the header): the wrapper runs `python3 $LAB_DIR/wdp_etw.py`, so
# replacing that ONE file stubs the client while the boundary gate keeps the real interpreter.
# Everything the wrapper is supposed to hand the client -- and the credential file it is supposed
# to hand it, with the mode it is supposed to have -- is recorded here and nowhere else, which is
# what makes "the client never ran" a checkable statement.
cat > "$SBLAB/wdp_etw.py" <<'STUB_CLIENT' || exit 1
"""OFFLINE TEST STUB for the capture client: records its environment, the credential file's mode
and contents and its argv, then exits with LABTEST_CLIENT_RC. Opens no socket, writes no capture."""
import os
import sys
import time

if os.environ.get("LABTEST_CLIENT_WS_OPEN") == "1":
    # Stand-in for the real client's `say("WS-OPEN")` (wdp_etw.py's `say()` flushes after every
    # line). The `running` sentinel is written FIRST, then WS-OPEN is printed and flushed: the
    # sandbox's wait for "the client is up" (case 26, M4) polls the sentinel, and if the log line
    # could in principle land before the sentinel file does, a fast reader could see WS-OPEN with
    # no sentinel yet on disk and misreport the client as not-yet-running. Writing the sentinel
    # first removes that ordering risk entirely rather than relying on the sentinel path being
    # slower (forking `sed` before it can never be faster than a local file write, but "faster"
    # is not the same guarantee as "always"). This process then stays alive -- the sentinel now on
    # disk -- for up to 5s or until a `release` file appears, whichever comes first. That is the
    # window in which the sandbox checks whether WS-OPEN already reached etw.log even though this
    # process has not exited: a masking pipeline that buffers a whole block before writing would
    # show nothing here (case 26's M4 mutant), one that writes per line would.
    running_file = os.environ.get("LABTEST_RUNNING_FILE", "")
    if running_file:
        with open(running_file, "w") as handle:
            handle.write("running\n")
    print("WS-OPEN", flush=True)
    release_file = os.environ.get("LABTEST_RELEASE_FILE", "")
    deadline = time.time() + 5
    while time.time() < deadline:
        if release_file and os.path.exists(release_file):
            break
        time.sleep(0.05)

lines = ["client-run"]
# The pid of the process that started this client -- which is the WRAPPER's own pid, because the
# capture runs as `env ... python3 wdp_etw.py | etw_sink` and bash forks one child per pipeline
# element. That is what makes "the number the wrapper logged is its own pid" a checkable claim
# (case 17c) rather than "a number of the right shape".
lines.append("client-ppid %d" % os.getppid())
for key in sorted(os.environ):
    if key.startswith("WDP_"):
        lines.append("client-env %s=%s" % (key, os.environ[key]))
cred = os.environ.get("WDP_CRED_FILE", "")
cred_body = ""
if cred and os.path.exists(cred):
    lines.append("client-cred-mode %04o" % (os.stat(cred).st_mode & 0o7777))
    with open(cred) as handle:
        cred_body = handle.read().strip()
    lines.append("client-cred-body %s" % cred_body)
else:
    lines.append("client-cred-absent %s" % cred)
# Names only, never values: what this line answers is "which variables did the wrapper let
# through", and the one it must NOT let through is the portal password.
lines.append("client-env-names " + " ".join(sorted(os.environ)))
lines.append("client-argv " + " ".join("[%s]" % arg for arg in sys.argv))
with open(os.environ["LABTEST_TRACE"], "a") as handle:
    handle.write("\n".join(lines) + "\n")
if os.environ.get("LABTEST_CLIENT_STDERR") == "1":
    # Stand-in for the real client's Python traceback. The wrapper pipes the client's stderr into
    # its log along with stdout, and a traceback names the module's own file -- a path under $HOME
    # on the lab Mac, i.e. the local account name. Written to stderr on purpose: the wrapper's
    # `2>&1` into the masking sink is the thing under test.
    sys.stderr.write("Traceback (most recent call last):\n")
    sys.stderr.write('  File "%s", line 1, in <module>\n' % (os.path.abspath(__file__),))
    sys.stderr.write("RuntimeError: LABTEST stand-in traceback\n")
    # ... and a client that quotes what it read back at the operator. The real client deliberately
    # never echoes the credential file's contents, but the wrapper's mask is what makes "the
    # password cannot reach etw.log" true of ANY client it runs, so the suite exercises it.
    sys.stderr.write("LABTEST stand-in refusal, quoting what it read: %s\n" % (cred_body,))
sys.exit(int(os.environ.get("LABTEST_CLIENT_RC", "0")))
STUB_CLIENT

# Census of the sandbox's TRACKED tree, taken once after construction (the client stub included:
# it stands in for a tracked file and must survive every run byte-identical). A run must write
# nothing here -- only under .build/lab-runtime. The mutation proofs write their copies into this
# directory on purpose (the wrapper derives REPO_ROOT from its own location), hence the exclusion;
# `labtest-mutant-*` is a namespace no shipping script produces or reads.
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

# -- PATH shims -------------------------------------------------------------------------------

# A fixed, obviously synthetic fingerprint: 32 colon-separated hex pairs, the shape `openssl x509
# -fingerprint -sha256` prints. The wrapper's `sed 's/^.*=//'` must reduce the line to exactly
# this, and the client must then receive exactly this in WDP_CERT_SHA256.
FAKE_FP='AA:BB:CC:DD:EE:11:22:33:44:55:66:77:88:99:00:AB:CD:EF:01:23:45:67:89:AB:CD:EF:10:32:54:76:98:BA'
cat > "$SB/bin/openssl" <<SHIM_OPENSSL || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM for openssl(1): records argv and answers the two sub-commands the wrapper's
# pin recorder uses. Opens no socket -- \`s_client\` prints a stand-in certificate block, \`x509\`
# prints the fixed fingerprint line the suite pins.
#
# The trace line is composed FIRST and written with ONE append: the wrapper runs s_client and x509
# as a pipeline, so the two shims are alive at the same time and a printf-per-argument recorder
# interleaved their words into a single unreadable line (measured, not theorised).
set -u
line='openssl'
for a in "\$@"; do line="\$line [\$a]"; done
printf '%s\n' "\$line" >> "\$LABTEST_TRACE"
# Which of host.env's variables reached THIS process. The recorder needs none of them (the host is
# already on its command line) and the password least of all.
leaked=''
if [ -n "\${WIN_HOST+x}" ]; then leaked="\$leaked WIN_HOST"; fi
if [ -n "\${WIN_USER+x}" ]; then leaked="\$leaked WIN_USER"; fi
if [ -n "\${WIN_PASS+x}" ]; then leaked="\$leaked WIN_PASS"; fi
printf 'openssl-hostenv%s\n' "\${leaked:- <none>}" >> "\$LABTEST_TRACE"
# LABTEST_OPENSSL_MODE=silent: the call is recorded (above) but nothing is printed -- what a
# portal that accepts the TCP connection and then says nothing looks like to the wrapper's
# pipeline (an empty fingerprint). Case 16g drives the rotation check into that shape.
# LABTEST_OPENSSL_MODE=stall: s_client never returns on its own (a peer that accepts TCP and
# stalls the handshake); it must be the wrapper's dial bound that ends it. \`exec\`, so the process
# the alarm kills is this one and nothing is left behind. x509 then sees a closed pipe and prints
# nothing, as the real x509 would. Case 16i measures the bound.
if [ "\${LABTEST_OPENSSL_MODE:-}" = silent ]; then exit 0; fi
if [ "\${LABTEST_OPENSSL_MODE:-}" = stall ]; then
    if [ "\${1:-}" = s_client ]; then printf 'openssl-stall\n' >> "\$LABTEST_TRACE"; exec sleep 60; fi
    exit 0
fi
case "\${1:-}" in
s_client) printf 'LABTEST-STAND-IN-CERTIFICATE\n' ;;
x509) printf 'SHA256 Fingerprint=%s\n' '$FAKE_FP' ;;
*) exit 2 ;;
esac
SHIM_OPENSSL
cat > "$SB/bin/open" <<'SHIM_OPEN' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM for open(1): records what run-scenario.sh asked Terminal to launch and
# NEVER executes it. The Terminal hop is exactly the thing that must not happen in CI.
set -u
line='open'
for a in "$@"; do line="$line [$a]"; done
printf '%s\n' "$line" >> "$LABTEST_TRACE"
SHIM_OPEN
cat > "$SB/bin/mktemp" <<'SHIM_MKTEMP' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM for mktemp(1): records argv and then RUNS THE REAL mktemp, so the credential
# file is still created exactly as it would be live. It exists because "no credential file was
# ever created" is a statement about CREATION, and a `find` after the run cannot tell a wrapper
# that never made one from a wrapper that made one before the gate and cleaned it up afterwards.
# The real binary is resolved by absolute path, never through PATH: a PATH lookup from inside a
# PATH shim finds the shim again and recurses until the process table gives up.
set -u
line='mktemp'
for a in "$@"; do line="$line [$a]"; done
printf '%s\n' "$line" >> "$LABTEST_TRACE"
exec /usr/bin/mktemp "$@"
SHIM_MKTEMP
# The rotation archive's UTC stamp, fixed: the wrapper names the archive
# `<pin>.until-$(date -u +%Y%m%dT%H%M%SZ)-rotation`, and with a known stamp a case can assert the
# exact name (16b), pre-create it to force the no-clobber path (16h, M7) or read it back out of
# the rotations record (16m). Every other date format -- the wrapper's own start=/end= lines use
# one -- goes to the real binary by absolute path (a PATH lookup from inside a PATH shim would
# find the shim again).
# This shim lives in a directory of its OWN, which only those cases put on PATH (RUN_ETW_PATH =
# $DATE_PATH). Run-wide it would answer that format for EVERY case, and the next user of the same
# format -- a second wrapper, a future line in this one -- would silently receive a frozen clock
# it never asked for, in cases whose verdict has nothing to do with time.
ROTATION_STAMP='20260916T000000Z'
cat > "$SB/bin-date/date" <<SHIM_DATE || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM for date(1): a fixed stamp for the rotation archive's format, the real date
# for everything else.
set -u
if [ "\$#" -eq 2 ] && [ "\$1" = '-u' ] && [ "\$2" = '+%Y%m%dT%H%M%SZ' ]; then
    printf '%s\n' '$ROTATION_STAMP'
    exit 0
fi
exec /bin/date "\$@"
SHIM_DATE
cat > "$SB/bin/osascript" <<'SHIM_OSA' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM: must never be reached (run-long trace, never reset).
printf 'osascript:unexpected-call\n' >> "$LABTEST_REFUSED_TRACE"
exit 97
SHIM_OSA
cat > "$SB/bin/labtest-stdin-cmd" <<'SHIM_STDIN' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM standing in for the program an UNQUOTED job value would run. `TAG=a b` is an
# assignment prefixed to the command `b`, so this is what `b` looks like in the shape that was
# actually measured on the lab Mac: a command that exists on PATH and reads stdin (there,
# /opt/X11/bin/x). It records that it ran -- the whole point of the line grammar is that this
# never happens -- and then reads one line, which is instant when stdin is closed and up to 30s
# when it is not. Bounded rather than infinite so a suite that ever reaches it cannot be left with
# a process nobody owns.
set -u
printf 'job-line-executed\n' >> "$LABTEST_TRACE"
IFS= read -r -t 30 _labtest_ignored || true
SHIM_STDIN
chmod +x "$SB"/bin/* "$SB"/bin-date/* || exit 1
# The PATH a case prepends when it needs the fixed rotation stamp; everything else resolves as it
# does by default.
DATE_PATH="$SB/bin-date:$SB/bin:$PATH"
for shim in "$SB"/bin/* "$SB"/bin-date/*; do
	if ! bash -n "$shim"; then printf 'shim does not parse: %s\n' "$shim"; exit 1; fi
done
# The load-bearing safety assertion: with the sandbox PATH in force, each shimmed name MUST
# resolve to the shim -- otherwise a case would run the maintainer's real openssl against the
# placeholder address, or open a Terminal window. Checked before any case runs.
for tool in openssl open osascript mktemp; do
	resolved="$(PATH="$SB/bin:$PATH" command -v "$tool" || true)"
	if [ "$resolved" != "$SB/bin/$tool" ]; then
		printf 'ABORT: %s resolves to %s, not the shim\n' "$tool" "${resolved:-<nothing>}"
		exit 1
	fi
done
# The date shim is per case, so BOTH halves are asserted: it resolves when a case prepends its
# directory, and the DEFAULT sandbox PATH resolves the real binary. The second half is the point
# of the arrangement -- without it the shim could drift back to being run-wide unnoticed.
resolved="$(PATH="$DATE_PATH" command -v date || true)"
if [ "$resolved" != "$SB/bin-date/date" ]; then
	printf 'ABORT: date resolves to %s under DATE_PATH, not the shim\n' "${resolved:-<nothing>}"
	exit 1
fi
resolved="$(PATH="$SB/bin:$PATH" command -v date || true)"
if [ "$resolved" = "$SB/bin-date/date" ]; then
	printf 'ABORT: the date shim is on the DEFAULT sandbox PATH -- it must be per case\n'
	exit 1
fi
# python3 must be the REAL one: Scripts/lib.sh's boundary gate evaluates the allowed segments with
# it, so a sandbox without python3 would make every gate refuse and every "refused" case pass for
# the wrong reason.
if ! PATH="$SB/bin:$PATH" command -v python3 >/dev/null 2>&1; then
	printf 'ABORT: python3 is not on PATH -- the boundary gate cannot be evaluated\n'; exit 1
fi
# Positive control for the never-reached trace: hit the refuse shim once, confirm it recorded,
# clear -- so an empty trace at the end means "not reached", not "recorder misconfigured".
env -i LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" PATH="$SB/bin:$PATH" osascript -e 'x' >/dev/null 2>&1
if ! grep -qF 'osascript:unexpected-call' "$LABTEST_REFUSED_TRACE"; then
	printf 'ABORT: the refused-shim trace did not record a deliberate call\n'; exit 1
fi
: > "$LABTEST_REFUSED_TRACE"

# -- Helpers -----------------------------------------------------------------------------------

begin() { # <case label>
	CASE="$1"
	: > "$LABTEST_TRACE"
	RUN_ETW_PATH=''
	rm -f "$LOG" "$JOB" "$PINFILE" "$ROTLOG"
	rm -f "$PINFILE".until-* "$PINFILE".rotating.* 2>/dev/null || true
	rm -f "$CREDGLOB"* 2>/dev/null || true
}
assert_has() { # <file> <fixed string>
	if grep -qF -- "$2" "$1"; then return 0; fi
	fail "$CASE: expected [$2] in $(basename "$1")"; note "$(cat "$1" 2>/dev/null)"; return 1
}
assert_lacks() { # <file> <fixed string>
	if ! grep -qF -- "$2" "$1"; then return 0; fi
	fail "$CASE: [$2] must not appear in $(basename "$1")"; note "$(cat "$1" 2>/dev/null)"; return 1
}
assert_eq() { # <actual> <expected> <what>
	if [ "$1" = "$2" ]; then return 0; fi
	fail "$CASE: $3 -- expected [$2], got [$1]"; return 1
}
last_line() { tail -n 1 "$LOG" 2>/dev/null; }
done_lines() { grep -c '^DONE exit=' "$LOG" 2>/dev/null || true; }
client_calls() { grep -c '^client-run$' "$LABTEST_TRACE" 2>/dev/null || true; }
client_env() { grep -c "^client-env $1\$" "$LABTEST_TRACE" 2>/dev/null || true; }
openssl_calls() { grep -c '^openssl ' "$LABTEST_TRACE" 2>/dev/null || true; }
# How many times the wrapper asked for a temporary file. The credential file is the ONLY thing
# this wrapper mktemps, so on a refusal path this must be 0: not "no credential file survives"
# (an EXIT trap satisfies that even when the password was written to disk before the gate ran)
# but "no credential file was ever created".
mktemp_calls() { grep -c '^mktemp ' "$LABTEST_TRACE" 2>/dev/null || true; }
# How many credential files exist under the sandbox TMPDIR right now. On every path the wrapper
# takes this must be 0 after the run: either it never made one, or it removed the one it made.
cred_files() { find "$SBTMP" -name 'macdows-etw-cred.*' -type f 2>/dev/null | wc -l | tr -d ' '; }
# The rotation archives next to the pin file (`<pin>.until-<UTC stamp>-rotation`): how many, and
# the path of the first. A case that rotates expects exactly one; every other case expects none.
archive_count() { find "$SBWDP" -name 'portal-cert-sha256.txt.until-*' -type f 2>/dev/null | wc -l | tr -d ' '; }
archive_path() { find "$SBWDP" -name 'portal-cert-sha256.txt.until-*' -type f 2>/dev/null | head -n 1; }
# A file's permission bits, portably (macOS stat and GNU stat disagree on every flag; python3 is
# already required by the boundary gate).
file_mode() { python3 -c 'import os, sys; print("%04o" % (os.stat(sys.argv[1]).st_mode & 0o7777))' "$1" 2>/dev/null; }
file_inode() { python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$1" 2>/dev/null; }
# The line number in the trace at which a shim was first invoked -- for ordering claims ("the
# dial precedes the credential file"). Empty when it never was.
trace_first() { grep -n "^$1 " "$LABTEST_TRACE" 2>/dev/null | head -n 1 | cut -d: -f1; }
log_count() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }
# The durable rotation record: how many lines it holds right now, and how many of them are the
# exact line a rotation is supposed to leave. A file that does not exist answers 0 to both.
rotlog_lines() { if [ -f "$ROTLOG" ]; then grep -c '' "$ROTLOG" 2>/dev/null || true; else printf '0\n'; fi; }
rotlog_count() { if [ -f "$ROTLOG" ]; then grep -cF -- "$1" "$ROTLOG" 2>/dev/null || true; else printf '0\n'; fi; }

write_job() { # <TAG> <DURATION> <PROVIDERS> <PIN_RECORD> [PIN_TRUST_ROTATION]  (empty argument = key omitted)
	{
		if [ -n "${1:-}" ]; then printf 'TAG=%s\n' "$1"; fi
		if [ -n "${2:-}" ]; then printf 'DURATION=%s\n' "$2"; fi
		if [ -n "${3:-}" ]; then printf "PROVIDERS='%s'\n" "$3"; fi
		if [ -n "${4:-}" ]; then printf 'PIN_RECORD=%s\n' "$4"; fi
		if [ -n "${5:-}" ]; then printf 'PIN_TRUST_ROTATION=%s\n' "$5"; fi
	} > "$JOB"
}

# The two fingerprints the rotation cases are built from. STALE_FP is a pin that the portal (the
# openssl shim, which always answers FAKE_FP) no longer serves; the *_HEX forms are what the
# wrapper must write and log after a rotation -- the client's own canonical form, 64 lower-case
# hex digits (wdp_etw.py `normalise_pin`), so a rotated pin and a `got=` fingerprint read alike.
STALE_FP='FE:ED:FA:CE:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:01:23:45:67:89:AB:CD:EF:12:34:56:78'
FAKE_HEX="$(printf '%s' "$FAKE_FP" | tr -d ':' | tr '[:upper:]' '[:lower:]')"
STALE_HEX="$(printf '%s' "$STALE_FP" | tr -d ':' | tr '[:upper:]' '[:lower:]')"

# The five public Microsoft provider GUIDs the shipped job uses, at level 5.
GOOD_PROVIDERS='1139c61b-b549-4251-8ed3-27250a1edec8:5;c76baa63-ae81-421c-b425-340b4b24157f:5'

# Runs the wrapper (or a mutant copy) with the sandbox environment. Everything it reads comes from
# HOME/PATH/TMPDIR/etw-job.env; TERM_PROGRAM is cleared so the Terminal self-close branch is not
# taken. <boundary-file> empty = MACDOWS_LAB_BOUNDARY_FILE is passed EMPTY, which lib.sh's
# `${MACDOWS_LAB_BOUNDARY_FILE:-…}` treats exactly like unset: the wrapper resolves the DEFAULT
# path under the sandbox HOME, as it does live. (A plain variable, not an array -- `"${arr[@]}"`
# on an empty array is an unbound-variable error under bash 3.2 + `set -u`.)
# The PATH the NEXT run_etw uses, reset to the sandbox default by `begin` so that an override is
# per case by construction: $DATE_PATH for the cases that need the fixed rotation stamp, a farm
# with no openssl in it for the one case that measures a dial which cannot run at all.
RUN_ETW_PATH=''
run_etw() { # <wrapper-path> <boundary-file|""> [client-rc] [client-stderr 0|1] [ws-open 0|1] [running-file] [release-file]
	env -i \
		HOME="$SBHOME" \
		PATH="${RUN_ETW_PATH:-$SB/bin:$PATH}" \
		TMPDIR="$SBTMP" \
		TERM_PROGRAM= \
		LABTEST_TRACE="$LABTEST_TRACE" \
		LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" \
		LABTEST_CLIENT_RC="${3:-0}" \
		LABTEST_CLIENT_STDERR="${4:-0}" \
		LABTEST_CLIENT_WS_OPEN="${5:-0}" \
		LABTEST_RUNNING_FILE="${6:-}" \
		LABTEST_RELEASE_FILE="${7:-}" \
		LABTEST_OPENSSL_MODE="${LABTEST_OPENSSL_MODE:-}" \
		MACDOWS_LAB_BOUNDARY_FILE="$2" \
		bash "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------------------------------------
# Cases
# ------------------------------------------------------------------------------------------

printf 'test-wdp-etw-offline.sh -- driving %s\n' "$LAB/wdp-etw.command"

# 0. The runtime and wdp directories are the wrapper's own to create: neither may exist before the
#    first run and both must exist after it (the sandbox never pre-creates them).
begin '0 wrapper creates its runtime dirs'
if [ ! -d "$SBRUNTIME" ] && [ ! -d "$SBWDP" ]; then
	run_etw "$SBLAB/wdp-etw.command" "$DENY_FILE"
	if [ -d "$SBWDP" ] && [ -f "$LOG" ]; then
		pass "$CASE: neither .build/lab-runtime nor its wdp/ existed before the first run and the wrapper created both"
	else
		fail "$CASE: runtime dir or log missing after the run"
	fi
else
	fail "$CASE: the sandbox pre-created $SBRUNTIME -- this pin measures nothing"
fi

# 1. Refused by the boundary: the log names the refusal, DONE carries 78, and NOTHING past the
#    gate ran -- no credential file was ever mktemped, the client was never started, openssl was
#    never asked for a pin. The gate is first precisely so that a mistyped host never causes the
#    portal password to be written to disk at all.
begin '1 boundary refused'
write_job smoke 30 "$GOOD_PROVIDERS" 0
run_etw "$SBLAB/wdp-etw.command" "$DENY_FILE"
if assert_has "$LOG" 'BOUNDARY-REFUSED' && assert_eq "$(last_line)" 'DONE exit=78' 'last log line' \
	&& assert_eq "$(client_calls)" '0' 'client invocations' && assert_eq "$(openssl_calls)" '0' 'openssl invocations' \
	&& assert_eq "$(cred_files)" '0' 'credential files under TMPDIR' \
	&& assert_eq "$(mktemp_calls)" '0' 'mktemp calls (no credential file was EVER created)' \
	&& assert_lacks "$LOG" 'LABTEST-PLACEHOLDER-SECRET-3f9a'; then
	pass "$CASE: BOUNDARY-REFUSED logged, DONE exit=78, no client, no openssl, no credential file ever created, no credential in the log"
fi

# 2. Boundary file missing at the DEFAULT location (HOME has no lab-boundary.env): fail-closed,
#    same shape as 1. Exercises the wrapper's default-path resolution, not an injected path.
begin '2 boundary file missing (default path)'
mv "$ALLOW_FILE" "$ALLOW_FILE.away" || exit 1
write_job smoke 30 "$GOOD_PROVIDERS" 0
run_etw "$SBLAB/wdp-etw.command" ""
mv "$ALLOW_FILE.away" "$ALLOW_FILE" || exit 1
if assert_has "$LOG" 'BOUNDARY-REFUSED' && assert_eq "$(last_line)" 'DONE exit=78' 'last log line' \
	&& assert_eq "$(client_calls)" '0' 'client invocations' && assert_eq "$(cred_files)" '0' 'credential files under TMPDIR' \
	&& assert_eq "$(mktemp_calls)" '0' 'mktemp calls (no credential file was EVER created)'; then
	pass "$CASE: fail-closed refusal through the default boundary path, no client, no credential file ever created"
fi

# 3. etw-job.env missing: the wrapper must still report -- a DONE line with a distinct sysexits
#    code (66 EX_NOINPUT) and a named reason -- rather than die on `set -u` and leave the caller
#    to its own timeout.
begin '3 etw-job.env missing'
run_etw "$SBLAB/wdp-etw.command" ""
if assert_has "$LOG" 'JOB-ENV-MISSING' && assert_eq "$(last_line)" 'DONE exit=66' 'last log line' \
	&& assert_eq "$(client_calls)" '0' 'client invocations' && assert_eq "$(cred_files)" '0' 'credential files under TMPDIR' \
	&& assert_eq "$(mktemp_calls)" '0' 'mktemp calls (no credential file was EVER created)'; then
	pass "$CASE: JOB-ENV-MISSING logged, DONE exit=66, no client, no credential file ever created"
fi

# 4-12. Every etw-job.env key is validated before anything host-facing happens, and every
#    violation is the same contract: a named JOB-ENV-INVALID reason, DONE exit=65 (EX_DATAERR),
#    no client, no openssl, no credential file. The keys are not cosmetic -- TAG names files under
#    .build/, DURATION bounds the capture, PROVIDERS is handed to the client verbatim -- so each
#    one gets its own case rather than one representative.
case_invalid() { # <case label> <job-file body> <expected reason fragment> <pass note>
	begin "$1"
	printf '%s' "$2" > "$JOB"
	run_etw "$SBLAB/wdp-etw.command" ""
	if assert_has "$LOG" 'JOB-ENV-INVALID' && assert_has "$LOG" "$3" \
		&& assert_eq "$(last_line)" 'DONE exit=65' 'last log line' \
		&& assert_eq "$(client_calls)" '0' 'client invocations' \
		&& assert_eq "$(openssl_calls)" '0' 'openssl invocations' \
		&& assert_eq "$(cred_files)" '0' 'credential files under TMPDIR' \
		&& assert_eq "$(mktemp_calls)" '0' 'mktemp calls (no credential file was EVER created)'; then
		pass "$CASE: $4 -- JOB-ENV-INVALID, DONE exit=65, no client, no openssl, no credential file ever created"
	fi
}

case_invalid '4 TAG missing' \
	"DURATION=30
PROVIDERS='$GOOD_PROVIDERS'
PIN_RECORD=0
" 'JOB-ENV-INVALID -- TAG' 'a job without a TAG has no name for its capture or its log copy'

case_invalid '5 TAG too long' \
	"TAG=abcdefghijklmnopqrstuvwxyz0123456
PROVIDERS='$GOOD_PROVIDERS'
" 'JOB-ENV-INVALID -- TAG' 'a 33-character TAG is over the 32-character bound'

case_invalid '6 TAG with a space' \
	"TAG='smoke run'
PROVIDERS='$GOOD_PROVIDERS'
" 'JOB-ENV-INVALID -- TAG' 'a TAG with a space would split the file names it composes'

case_invalid '7 DURATION zero' \
	"TAG=smoke
DURATION=0
PROVIDERS='$GOOD_PROVIDERS'
" 'JOB-ENV-INVALID -- DURATION' 'DURATION=0 is not a positive integer'

case_invalid '8 DURATION not a number' \
	"TAG=smoke
DURATION=abc
PROVIDERS='$GOOD_PROVIDERS'
" 'JOB-ENV-INVALID -- DURATION' 'a non-numeric DURATION would reach the client as a malformed float'

case_invalid '9 PROVIDERS malformed GUID' \
	"TAG=smoke
PROVIDERS='1139c61b-b549-4251-8ed3-27250a1edec:5'
" 'JOB-ENV-INVALID -- PROVIDERS' 'a GUID one hex digit short is not a GUID'

case_invalid '10 PROVIDERS level out of range' \
	"TAG=smoke
PROVIDERS='1139c61b-b549-4251-8ed3-27250a1edec8:6'
" 'JOB-ENV-INVALID -- PROVIDERS' 'ETW trace levels stop at 5'

case_invalid '11 PROVIDERS carrying a shell construct' \
	"TAG=smoke
PROVIDERS='1139c61b-b549-4251-8ed3-27250a1edec8:5;\$(id)'
" 'JOB-ENV-INVALID -- PROVIDERS' 'a command substitution in PROVIDERS is refused, not evaluated'

case_invalid '12 PIN_RECORD out of range' \
	"TAG=smoke
PROVIDERS='$GOOD_PROVIDERS'
PIN_RECORD=2
" 'JOB-ENV-INVALID -- PIN_RECORD' 'PIN_RECORD is a 0/1 switch'

case_invalid '12c PIN_TRUST_ROTATION out of range' \
	"TAG=smoke
PROVIDERS='$GOOD_PROVIDERS'
PIN_TRUST_ROTATION=2
" 'JOB-ENV-INVALID -- PIN_TRUST_ROTATION' 'PIN_TRUST_ROTATION is a 0/1 switch'

# 12b. A TAG that tries to climb out of .build/. TAG names two files (etw-<TAG>.jsonl and the log
#      copy), so it is the one job value that becomes a path. The `etw-` prefix already makes
#      traversal impossible on its own -- `etw-../..` is not a directory -- but that is the
#      accident, not the rule; the rule is the character class, and this case is what makes case
#      25's tracked-tree census bite if the character class is ever loosened.
case_invalid '12b TAG with a traversal' \
	"TAG=../../../Scripts/lab/pwned
PROVIDERS='$GOOD_PROVIDERS'
" 'JOB-ENV-INVALID -- TAG' 'a TAG that is a relative path is not a name'

# 13. A value that spans lines shifts every following key, so the run would proceed with keys that
#     silently hold the wrong values (the same failure the relay's sentinel closes). TWO guards
#     catch it and this case measures both, because they catch different FILES: the line grammar
#     refuses a naive continuation (its second line is not an assignment to a permitted key), while
#     a continuation whose second line HAPPENS to look like one gets past the grammar and is caught
#     by the sentinel instead. Both answer 65, and that is deliberate: "this file is not a table of
#     values" is ONE answer to the caller, and which guard reached that answer is a question for the
#     reason line above DONE (the grammar names a line NUMBER, the sentinel says "spans more than
#     one line"), not for the exit code. The code a reader acts on has to be the same for both,
#     because the action is the same -- go and fix the job file. Both halves assert that reason line
#     as well as the code, so the two guards remain distinguishable to a human.
begin '13 multi-line job value'
reasons=''
printf "TAG=smoke\nPROVIDERS='%s\n%s'\n" \
	'1139c61b-b549-4251-8ed3-27250a1edec8:5' 'c76baa63-ae81-421c-b425-340b4b24157f:5' > "$JOB"
run_etw "$SBLAB/wdp-etw.command" ""
grep -qF 'is neither blank, a comment, nor an assignment' "$LOG" || reasons="$reasons grammar-did-not-catch-the-plain-continuation;"
[ "$(last_line)" = 'DONE exit=65' ] || reasons="$reasons grammar-case-last-line=[$(last_line)];"
[ "$(client_calls)" = '0' ] || reasons="$reasons grammar-case-client-ran;"
# The one shape the line grammar cannot see: a trailing `\"` inside a double-quoted value escapes
# the closing quote, so the value runs on to the next line -- and that next line is a COMMENT,
# which the grammar admits. Both lines pass; PROVIDERS still ends up carrying a newline, PIN_RECORD
# ends up holding a comment and the sentinel ends up holding PIN_RECORD's value.
begin "$CASE"
printf 'TAG=smoke\nDURATION=30\nPROVIDERS="a\\"\n# still inside the string"\nPIN_RECORD=0\n' > "$JOB"
run_etw "$SBLAB/wdp-etw.command" ""
grep -qF 'spans more than one line' "$LOG" || reasons="$reasons sentinel-did-not-catch-it[$(last_line)];"
[ "$(last_line)" = 'DONE exit=65' ] || reasons="$reasons sentinel-case-last-line=[$(last_line)];"
[ "$(client_calls)" = '0' ] || reasons="$reasons sentinel-case-client-ran;"
[ "$(mktemp_calls)" = '0' ] || reasons="$reasons credential-file-created;"
if [ -z "$reasons" ]; then
	pass "$CASE: a plain continuation is refused by the line grammar (nothing executed) and a grammar-shaped one by the sentinel; both answer DONE exit=65 and are told apart by their reason lines; no client and no credential file either way"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 13b. THE LINE GRAMMAR. A job file is a table of values or it does not run, and the VALUE half of
#      that rule is what this case measures. To the shell, `TAG=a b` is an assignment PREFIXED to
#      the command `b`, so a wrapper that whitelisted only KEY NAMES would still run programs out
#      of a job file. Measured on the sibling wrapper rather than theorised: an early draft of
#      smoke-job.command hung FOREVER on `DISPLAY_LOOKS_LIKE=1280 x 720`, because /opt/X11/bin/x
#      exists on the lab Mac and reads stdin -- no DONE line at all, and every orchestrator polling
#      for one waited out its full timeout.
#      Two shapes, because they fail differently: `TAG=a b`, whose second word does not exist, and
#      the same shape with a command that DOES exist and reads stdin, which is the form that hung.
#      Both must be refused as TEXT, before a single line of the file is executed -- the witness
#      line is the measurement -- and the wrapper must still reach its DONE line quickly. (M5 pins
#      this.)
begin '13b the line grammar refuses an unquoted value before any line runs'
reasons=''
printf 'TAG=a b\nDURATION=30\nPROVIDERS=%s\nPIN_RECORD=0\n' "'$GOOD_PROVIDERS'" > "$JOB"
run_etw "$SBLAB/wdp-etw.command" ""
grep -qF 'JOB-ENV-INVALID' "$LOG" || reasons="$reasons two-word-value-not-refused;"
[ "$(last_line)" = 'DONE exit=65' ] || reasons="$reasons two-word-last-line=[$(last_line)];"
[ "$(client_calls)" = '0' ] || reasons="$reasons two-word-client-ran;"
[ "$(mktemp_calls)" = '0' ] || reasons="$reasons two-word-credential-file-created;"
# The reason line names the line NUMBER and never the line: an offending value may BE the secret
# that must not be printed. (`grep -qF ' b'` would not do -- the wrapper's own "so this log is safe
# to paste" line contains it.)
grep -qF 'TAG=a b' "$LOG" && reasons="$reasons the-offending-line-was-echoed;"
# jobs/etw-smoke.env is 48 lines of which 40 are comment, so "put a note at the end of this line" is
# the natural next edit -- and the grammar refuses it. The reason has to SAY that, or the reader
# follows the advice about quoting, quotes the comment, and is refused a second time.
grep -qF 'a comment must be on a line of its own' "$LOG" \
	|| reasons="$reasons reason-does-not-name-the-comment-rule;"
# The shape that hung. `begin` again, with the same label: it resets the trace, the log and the job
# instance, so the two halves of this case cannot read each other's evidence.
begin "$CASE"
printf 'TAG=a labtest-stdin-cmd\nDURATION=30\nPROVIDERS=%s\nPIN_RECORD=0\n' "'$GOOD_PROVIDERS'" > "$JOB"
run_etw "$SBLAB/wdp-etw.command" "" &
RUN_PID=$!
waited=0
while kill -0 "$RUN_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do
	sleep 0.1
	waited=$((waited + 1))
done
if kill -0 "$RUN_PID" 2>/dev/null; then
	kill -9 "$RUN_PID" 2>/dev/null
	reasons="$reasons WRAPPER-STILL-RUNNING-AFTER-5s;"
fi
wait "$RUN_PID" 2>/dev/null
grep -q '^job-line-executed$' "$LABTEST_TRACE" && reasons="$reasons THE-JOB-FILE-WAS-EXECUTED;"
grep -qF 'JOB-ENV-INVALID' "$LOG" || reasons="$reasons stdin-command-not-refused;"
[ "$(last_line)" = 'DONE exit=65' ] || reasons="$reasons stdin-command-last-line=[$(last_line)];"
[ "$(client_calls)" = '0' ] || reasons="$reasons stdin-command-client-ran;"
if [ -z "$reasons" ]; then
	pass "$CASE: an unquoted TAG=a b and the same shape naming a command that reads stdin are both refused as text with DONE exit=65, and the reason names the comment rule as well as the quoting one -- nothing in the job file ran, no credential file was created, and the wrapper reported inside 5s"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 14. No certificate pin on disk and PIN_RECORD=0: refused with PIN-MISSING and DONE exit=79
#     (the client's own EX_PIN), before the credential file exists. This is the rule that keeps
#     "the pin is the trust decision" true -- an unpinned run would have to trust whatever answers
#     on port 50443, which is the whole thing the pin is for. The reason line has to name the way
#     out, because the operator hits this exactly once per machine.
begin '14 pin missing, PIN_RECORD=0'
write_job smoke 30 "$GOOD_PROVIDERS" 0
run_etw "$SBLAB/wdp-etw.command" ""
if assert_has "$LOG" 'PIN-MISSING' && assert_has "$LOG" 'PIN_RECORD=1' \
	&& assert_eq "$(last_line)" 'DONE exit=79' 'last log line' \
	&& assert_eq "$(client_calls)" '0' 'client invocations' \
	&& assert_eq "$(openssl_calls)" '0' 'openssl invocations' \
	&& assert_eq "$(cred_files)" '0' 'credential files under TMPDIR' \
	&& assert_eq "$(mktemp_calls)" '0' 'mktemp calls (no credential file was EVER created)' \
	&& [ ! -f "$PINFILE" ]; then
	pass "$CASE: PIN-MISSING logged with the way out, DONE exit=79, no client, no credential file ever created, no pin invented"
fi

# 14b. A pin file that does not hold a SHA-256 fingerprint is refused HERE, by the same regex the
#      recorder applies before writing one. Without that, a hand-edited or half-written pin file is
#      handed to the client as WDP_CERT_SHA256 -- so the wrapper creates the 0600 credential file
#      for a run that can only end at the client's own CERT-PIN-MISSING, one layer away from the
#      file that actually needs fixing. The file is left ALONE: an existing pin is never
#      overwritten, and deciding to delete this one is the operator's call, not the wrapper's.
begin '14b pin file that is not a fingerprint'
mkdir -p "$SBWDP" || exit 1
printf 'not-a-fingerprint\n' > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0
run_etw "$SBLAB/wdp-etw.command" ""
if assert_has "$LOG" 'PIN-INVALID' && assert_eq "$(last_line)" 'DONE exit=79' 'last log line' \
	&& assert_eq "$(client_calls)" '0' 'client invocations' \
	&& assert_eq "$(openssl_calls)" '0' 'openssl invocations' \
	&& assert_eq "$(mktemp_calls)" '0' 'mktemp calls (no credential file was EVER created)' \
	&& assert_eq "$(cred_files)" '0' 'credential files under TMPDIR' \
	&& assert_eq "$(cat "$PINFILE" 2>/dev/null)" 'not-a-fingerprint' 'pin file after the run'; then
	pass "$CASE: PIN-INVALID logged, DONE exit=79, no client, no credential file ever created, the pin file left for the operator"
fi

# 14c. A pin file that EXISTS but holds nothing -- truncated by a full disk, emptied by hand,
#      left behind by a killed writer -- is PIN-INVALID, not "no pin yet". Read as missing it
#      would be handed to the RECORDER, the one path that writes a pin, and a pin could then be
#      replaced by `: > portal-cert-sha256.txt` plus a job with PIN_RECORD=1: the "an existing pin
#      is never overwritten" rule defeated with a redirection. Both shapes the reader can produce
#      are measured -- a zero-byte file and one holding only whitespace, which the wrapper's
#      `tr -d '[:space:]'` reduces to the same empty string. The file is left exactly as it is,
#      because deleting it is the deliberate act the rule asks the operator for.
begin '14c an existing but EMPTY pin file is PIN-INVALID, never a pin to record over'
reasons=''
for shape in empty whitespace; do
	mkdir -p "$SBWDP" || exit 1
	: > "$LABTEST_TRACE"
	rm -f "$LOG"
	if [ "$shape" = empty ]; then : > "$PINFILE"; else printf ' \n\t\n' > "$PINFILE"; fi
	before="$(cksum < "$PINFILE")"
	write_job smoke 30 "$GOOD_PROVIDERS" 1
	run_etw "$SBLAB/wdp-etw.command" ""
	label="shape=$shape"
	grep -qF 'PIN-INVALID' "$LOG" || reasons="$reasons $label no-pin-invalid-line;"
	[ "$(last_line)" = 'DONE exit=79' ] || reasons="$reasons $label last-line=[$(last_line)];"
	[ "$(openssl_calls)" = '0' ] || reasons="$reasons $label openssl-calls=$(openssl_calls);"
	[ "$(client_calls)" = '0' ] || reasons="$reasons $label client-calls=$(client_calls);"
	[ "$(mktemp_calls)" = '0' ] || reasons="$reasons $label mktemp-calls=$(mktemp_calls);"
	[ "$(cksum < "$PINFILE")" = "$before" ] || reasons="$reasons $label pin-file-rewritten;"
	[ "$(log_count 'pin recorded')" = '0' ] || reasons="$reasons $label recorder-ran;"
	[ "$(archive_count)" = '0' ] || reasons="$reasons $label archives=$(archive_count);"
done
if [ -z "$reasons" ]; then
	pass "$CASE: a zero-byte pin file and a whitespace-only one are both PIN-INVALID, DONE exit=79, no dial, no client, no credential file, and the file is left byte-identical for the operator"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 15. Pin missing and PIN_RECORD=1: the wrapper records it ONCE, with the documented openssl
#     pipeline, and only then proceeds. The argv is pinned literally because it is the whole
#     recording. WIN_HOST is an IP literal here, so NO `-servername` is sent: the client omits SNI
#     for a literal (wdp_etw.py `_sni_for`), and a pin recorded under handshake conditions the
#     capture will not repeat is a pin against a certificate the capture may never be shown.
#     openssl is invoked only AFTER the boundary gate approved the host.
begin '15 pin missing, PIN_RECORD=1 records it'
write_job smoke 30 "$GOOD_PROVIDERS" 1
run_etw "$SBLAB/wdp-etw.command" ""
sclient="$(grep '^openssl \[s_client\]' "$LABTEST_TRACE" | head -n 1)"
x509="$(grep '^openssl \[x509\]' "$LABTEST_TRACE" | head -n 1)"
if assert_eq "$sclient" 'openssl [s_client] [-connect] [192.0.2.10:50443]' 's_client argv' \
	&& assert_eq "$x509" 'openssl [x509] [-noout] [-fingerprint] [-sha256]' 'x509 argv' \
	&& assert_eq "$(cat "$PINFILE" 2>/dev/null)" "$FAKE_FP" 'recorded pin file' \
	&& assert_has "$LOG" "pin recorded sha256=$FAKE_FP" \
	&& assert_eq "$(client_calls)" '1' 'client invocations' \
	&& assert_eq "$(client_env "WDP_CERT_SHA256=$FAKE_FP")" '1' 'WDP_CERT_SHA256 handed to the client' \
	&& assert_eq "$(last_line)" 'DONE exit=0' 'last log line'; then
	pass "$CASE: openssl s_client|x509 with the documented argv, the fingerprint written to the pin file and handed to the client, DONE exit=0"
fi

# 15b. The same recorder against an IPv6 lab host -- a shape the owner's boundary file now admits.
#      `-connect` must BRACKET the address: OpenSSL's BIO parser calls an unbracketed `host:port`
#      with colons in it ambiguous and refuses outright, so without brackets an IPv6 host could
#      never record a pin at all and PIN-MISSING would name a way out that does not work. No SNI,
#      for the same reason as case 15.
begin '15b pin recorder for an IPv6 lab host'
cp "$HOSTENV_FILE" "$HOSTENV_FILE.away" || exit 1
cat > "$HOSTENV_FILE" <<'HOSTENV6' || exit 1
WIN_HOST=2001:db8::10
WIN_USER=labtest-placeholder
WIN_PASS=LABTEST-PLACEHOLDER-SECRET-3f9a
HOSTENV6
V6_ALLOW="$SB/allow-v6.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="2001:db8::/32"\n' > "$V6_ALLOW" || exit 1
write_job smoke 30 "$GOOD_PROVIDERS" 1
run_etw "$SBLAB/wdp-etw.command" "$V6_ALLOW"
mv "$HOSTENV_FILE.away" "$HOSTENV_FILE" || exit 1
sclient="$(grep '^openssl \[s_client\]' "$LABTEST_TRACE" | head -n 1)"
if assert_eq "$sclient" 'openssl [s_client] [-connect] [[2001:db8::10]:50443]' 's_client argv' \
	&& assert_eq "$(grep -c -- '\[-servername\]' "$LABTEST_TRACE" 2>/dev/null || true)" '0' 'SNI arguments for an IP literal' \
	&& assert_eq "$(cat "$PINFILE" 2>/dev/null)" "$FAKE_FP" 'recorded pin file' \
	&& assert_eq "$(client_env 'WDP_HOST=2001:db8::10')" '1' 'the client dials the address the pin was recorded against' \
	&& assert_eq "$(last_line)" 'DONE exit=0' 'last log line'; then
	pass "$CASE: the IPv6 literal is bracketed in -connect, no SNI is sent, and the pin is recorded and handed to the client"
fi

# 15c. A DNS name is the other side of the same rule: SNI is exactly what a name-based portal needs
#      to serve the certificate the capture will be shown, so it must still be sent. `localhost`
#      resolves from /etc/hosts (no DNS traffic, no socket -- the openssl shim answers).
begin '15c pin recorder for a DNS name keeps SNI'
cp "$HOSTENV_FILE" "$HOSTENV_FILE.away" || exit 1
cat > "$HOSTENV_FILE" <<'HOSTENVDNS' || exit 1
WIN_HOST=localhost
WIN_USER=labtest-placeholder
WIN_PASS=LABTEST-PLACEHOLDER-SECRET-3f9a
HOSTENVDNS
LOOPBACK_ALLOW="$SB/allow-loopback.env"
printf 'MACDOWS_LAB_ALLOWED_NETS="127.0.0.0/8 ::1/128"\n' > "$LOOPBACK_ALLOW" || exit 1
write_job smoke 30 "$GOOD_PROVIDERS" 1
run_etw "$SBLAB/wdp-etw.command" "$LOOPBACK_ALLOW"
mv "$HOSTENV_FILE.away" "$HOSTENV_FILE" || exit 1
sclient="$(grep '^openssl \[s_client\]' "$LABTEST_TRACE" | head -n 1)"
if assert_eq "$sclient" 'openssl [s_client] [-connect] [localhost:50443] [-servername] [localhost]' 's_client argv' \
	&& assert_eq "$(cat "$PINFILE" 2>/dev/null)" "$FAKE_FP" 'recorded pin file' \
	&& assert_eq "$(last_line)" 'DONE exit=0' 'last log line'; then
	pass "$CASE: a DNS name is dialled unbracketed and WITH -servername, the way the client will dial it"
fi

# 15d. The recorder shares the dial -- and therefore the bound. Before this lane a PIN_RECORD=1
#      run against a portal that accepted TCP and stalled TLS hung with no DONE line; now it ends
#      at PIN-RECORD-FAILED inside the bound, nothing written to the pin file, no client, no
#      credential file. Same window as 16i: at least the bound, well under the shim's 60 s.
begin '15d pin recorder against a stalled portal is cut off by the bound'
write_job smoke 30 "$GOOD_PROVIDERS" 1
SECONDS=0
LABTEST_OPENSSL_MODE=stall run_etw "$SBLAB/wdp-etw.command" ""
elapsed=$SECONDS
reasons=''
grep -q '^openssl-stall$' "$LABTEST_TRACE" || reasons="$reasons the-shim-did-not-stall;"
[ "$elapsed" -ge 10 ] || reasons="$reasons returned-in-${elapsed}s-before-the-bound-could-have-fired;"
# The upper limit is the BOUND plus room for a loaded machine, not merely "less than the shim's
# 60 s sleep": at 45 s a wrapper with a 40 s bound passed this pin too. Measured elapsed here is
# ~16 s, so 25 s keeps the stall mutant caught with margin and now fails a bound that grew.
[ "$elapsed" -lt 25 ] || reasons="$reasons took-${elapsed}s-past-the-15s-bound;"
grep -qF 'PIN-RECORD-FAILED' "$LOG" || reasons="$reasons no-record-failed-line;"
[ "$(last_line)" = 'DONE exit=79' ] || reasons="$reasons last-line=[$(last_line)];"
[ ! -f "$PINFILE" ] || reasons="$reasons pin-file-written=[$(cat "$PINFILE" 2>/dev/null)];"
[ "$(client_calls)" = '0' ] || reasons="$reasons client-calls=$(client_calls);"
[ "$(mktemp_calls)" = '0' ] || reasons="$reasons mktemp-calls=$(mktemp_calls);"
if [ -z "$reasons" ]; then
	pass "$CASE: the stalled recorder dial was cut off after ${elapsed}s (bound 15 s), PIN-RECORD-FAILED then PIN-MISSING, no pin written, no client, no credential file, DONE exit=79"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 15e. The recorder writes its pin the way the rotation does: into a private staging file under
#      `umask 077`, then RENAMED over the pin's name. Two properties, and neither is a hole this
#      closes -- the recorder runs only when no pin file exists, so it never had an inode to write
#      through. What it buys is that the contract holds for EVERY pin this wrapper produces rather
#      than only the rotated ones (64 hex at 0600, from the file's first byte), and that the pin
#      name is only ever REPLACED, so no writer in this file can reach the bytes of a hard-linked
#      archive an earlier rotation left beside it. The scenario is the operator's own re-record:
#      rotate, delete the pin, record again -- and the archive from the first rotation is still
#      there, still holding the old fingerprint, still on its own inode.
begin '15e the recorder stages and renames -- 0600, and an archive sharing the old inode is untouched'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$STALE_FP" > "$PINFILE"
archive="$PINFILE.until-20260101T000000Z-rotation"
ln "$PINFILE" "$archive" || exit 1
archive_inode="$(file_inode "$archive")"
rm -f "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 1
run_etw "$SBLAB/wdp-etw.command" ""
reasons=''
[ "$(cat "$PINFILE" 2>/dev/null)" = "$FAKE_FP" ] || reasons="$reasons recorded-pin=[$(cat "$PINFILE" 2>/dev/null)];"
[ "$(file_mode "$PINFILE")" = '0600' ] || reasons="$reasons recorded-pin-mode=$(file_mode "$PINFILE");"
[ "$(file_inode "$PINFILE")" != "$archive_inode" ] || reasons="$reasons recorded-pin-is-the-archive-inode;"
[ "$(cat "$archive" 2>/dev/null)" = "$STALE_FP" ] || reasons="$reasons archive-body=[$(cat "$archive" 2>/dev/null)];"
[ "$(file_inode "$archive")" = "$archive_inode" ] || reasons="$reasons archive-inode-changed;"
[ -z "$(find "$SBWDP" -name 'portal-cert-sha256.txt.rotating.*' 2>/dev/null)" ] || reasons="$reasons staging-file-left-behind;"
grep -qF "pin recorded sha256=$FAKE_FP" "$LOG" || reasons="$reasons no-recorded-line;"
[ "$(client_env "WDP_CERT_SHA256=$FAKE_FP")" = '1' ] || reasons="$reasons client-pin;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: the recorded pin arrived at mode 0600 on its own inode, the hard-linked archive kept its bytes and its inode, no staging file left, DONE exit=0"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 16. A pin that already exists is NEVER re-recorded, even when the job asks for it: re-recording
#     against the wrong peer is the one-line way to defeat a pin, so PIN_RECORD is ignored (and
#     logged as ignored) rather than honoured. openssl must not even be invoked.
begin '16 existing pin is never overwritten'
mkdir -p "$SBWDP" || exit 1
printf 'FE:ED:FA:CE:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:01:23:45:67:89:AB:CD:EF:12:34:56:78\n' > "$PINFILE"
existing="$(cat "$PINFILE")"
write_job smoke 30 "$GOOD_PROVIDERS" 1
run_etw "$SBLAB/wdp-etw.command" ""
if assert_eq "$(openssl_calls)" '0' 'openssl invocations' \
	&& assert_eq "$(cat "$PINFILE")" "$existing" 'pin file after the run' \
	&& assert_has "$LOG" 'PIN_RECORD=1 ignored' \
	&& assert_eq "$(client_env "WDP_CERT_SHA256=$existing")" '1' 'the existing pin is what the client got' \
	&& assert_eq "$(last_line)" 'DONE exit=0' 'last log line'; then
	pass "$CASE: the existing pin is kept, openssl is never invoked, the job's PIN_RECORD=1 is logged as ignored"
fi

# 16b. PIN_TRUST_ROTATION=1 and the portal's certificate no longer matches the pin on file (owner
#      ruling 2026-09-16 02:26 JST "the portal certificate needs no per-rotation confirmation;
#      trust it by default"): BEFORE any credential file exists the wrapper asks the portal for its
#      fingerprint with the SAME openssl pipeline and argv the recorder uses (case 15 pins that
#      argv, so the rotation is shown the certificate the capture will be shown), ARCHIVES the old
#      pin file beside itself as <pin>.until-<UTC stamp>-rotation -- byte-identical, so a rotation
#      destroys nothing -- writes the served fingerprint as 64 lower-case hex at mode 0600, logs
#      exactly ONE `CERT-PIN-ROTATED old= new=` line carrying both fingerprints in that same form,
#      and continues: the client is started once, with the NEW pin, and the run ends DONE exit=0.
begin '16b PIN_TRUST_ROTATION=1 rotates a stale pin and continues'
# This case asserts the archive's exact NAME, so it -- and only it and its two siblings below --
# puts the fixed-stamp date shim on the wrapper's PATH.
RUN_ETW_PATH="$DATE_PATH"
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$STALE_FP" > "$PINFILE"
old_inode="$(file_inode "$PINFILE")"
write_job smoke 30 "$GOOD_PROVIDERS" 0 1
run_etw "$SBLAB/wdp-etw.command" ""
sclient="$(grep '^openssl \[s_client\]' "$LABTEST_TRACE" | head -n 1)"
archive="$PINFILE.until-$ROTATION_STAMP-rotation"
reasons=''
[ "$(openssl_calls)" = '2' ] || reasons="$reasons openssl-calls=$(openssl_calls);"
[ "$sclient" = 'openssl [s_client] [-connect] [192.0.2.10:50443]' ] || reasons="$reasons s_client-argv=[$sclient];"
[ "$(archive_count)" = '1' ] || reasons="$reasons archives=$(archive_count);"
[ -f "$archive" ] || reasons="$reasons archive-not-named-by-the-stamp=[$(basename "$(archive_path)")];"
[ "$(cat "$archive" 2>/dev/null)" = "$STALE_FP" ] || reasons="$reasons archive-body-not-the-old-pin;"
# The archive IS the old file (same inode: a hard link, not a copy) and the pin is a new one.
[ "$(file_inode "$archive")" = "$old_inode" ] || reasons="$reasons archive-is-not-the-old-inode;"
[ "$(file_inode "$PINFILE")" != "$old_inode" ] || reasons="$reasons pin-file-is-still-the-old-inode;"
# The dial precedes the credential file: the first openssl line in the trace comes before the
# first mktemp line (the credential file is the only thing the wrapper mktemps).
[ -n "$(trace_first openssl)" ] && [ -n "$(trace_first mktemp)" ] && [ "$(trace_first openssl)" -lt "$(trace_first mktemp)" ] || reasons="$reasons dial-not-before-credential-file(openssl@$(trace_first openssl) mktemp@$(trace_first mktemp));"
[ "$(cat "$PINFILE" 2>/dev/null)" = "$FAKE_HEX" ] || reasons="$reasons new-pin=[$(cat "$PINFILE" 2>/dev/null)];"
[ "$(file_mode "$PINFILE")" = '0600' ] || reasons="$reasons new-pin-mode=$(file_mode "$PINFILE");"
grep -qF "[etw] CERT-PIN-ROTATED old=$STALE_HEX new=$FAKE_HEX" "$LOG" || reasons="$reasons no-rotated-line;"
[ "$(log_count 'CERT-PIN-ROTATED')" = '1' ] || reasons="$reasons rotated-lines=$(log_count 'CERT-PIN-ROTATED');"
[ "$(client_calls)" = '1' ] || reasons="$reasons client-calls=$(client_calls);"
[ "$(client_env "WDP_CERT_SHA256=$FAKE_HEX")" = '1' ] || reasons="$reasons client-did-not-get-the-new-pin;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
[ "$(cred_files)" = '0' ] || reasons="$reasons cred-files=$(cred_files);"
[ -z "$(find "$SBWDP" -name 'portal-cert-sha256.txt.rotating.*' 2>/dev/null)" ] || reasons="$reasons staging-file-left-behind;"
grep -qF 'asking the portal for its certificate' "$LOG" || reasons="$reasons no-dial-line;"
if [ -z "$reasons" ]; then
	pass "$CASE: the old pin hard-linked byte-identical to $(basename "$archive") before the credential file existed, the served fingerprint written as 64 lower-case hex at 0600 under a new inode, one CERT-PIN-ROTATED line, the client run once with the new pin, DONE exit=0"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"; note "trace: $(tr '\n' ';' < "$LABTEST_TRACE")"
fi

# 16c. The same stale pin WITHOUT the knob -- omitted, and then an explicit 0 -- is the behaviour
#      the wrapper had before the knob existed, byte for byte: no pre-check dial (openssl is never
#      invoked), the pin file untouched, nothing archived, the client started once with the OLD
#      pin and its own CERT-PIN-MISMATCH verdict (the stub answers 79) reaching DONE exit=79. M6
#      is the proof that this case bites when the knob's gate is removed.
begin '16c a stale pin without the knob still ends at the client with exit 79'
reasons=''
for knob in '' 0; do
	mkdir -p "$SBWDP" || exit 1
	rm -f "$PINFILE" "$PINFILE".until-* 2>/dev/null
	: > "$LABTEST_TRACE"
	printf '%s\n' "$STALE_FP" > "$PINFILE"
	write_job smoke 30 "$GOOD_PROVIDERS" 0 "$knob"
	run_etw "$SBLAB/wdp-etw.command" "" 79
	label="knob=[${knob:-omitted}]"
	[ "$(openssl_calls)" = '0' ] || reasons="$reasons $label openssl-calls=$(openssl_calls);"
	[ "$(archive_count)" = '0' ] || reasons="$reasons $label archives=$(archive_count);"
	[ "$(cat "$PINFILE" 2>/dev/null)" = "$STALE_FP" ] || reasons="$reasons $label pin-file-changed;"
	[ "$(client_calls)" = '1' ] || reasons="$reasons $label client-calls=$(client_calls);"
	[ "$(client_env "WDP_CERT_SHA256=$STALE_FP")" = '1' ] || reasons="$reasons $label client-pin;"
	[ "$(last_line)" = 'DONE exit=79' ] || reasons="$reasons $label last-line=[$(last_line)];"
	[ "$(log_count 'ROTAT')" = '0' ] || reasons="$reasons $label rotation-lines=$(log_count 'ROTAT');"
	[ "$(cred_files)" = '0' ] || reasons="$reasons $label cred-files=$(cred_files);"
done
if [ -z "$reasons" ]; then
	pass "$CASE: with the key omitted and with PIN_TRUST_ROTATION=0 alike -- no dial, pin untouched, no archive, the client run once with the old pin, DONE exit=79, no rotation line"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 16d. PIN_TRUST_ROTATION=1 with a certificate that still matches: the pre-check dials (the shim
#      answers the pinned fingerprint), compares as VALUES -- the file holds openssl's upper-case
#      colon form, the comparison must not be fooled by spelling -- and rotates nothing: no
#      archive, the pin file byte-identical (its spelling included), the client handed the pin
#      exactly as it was on file, and one line saying the certificate matched.
begin '16d PIN_TRUST_ROTATION=1 with a matching certificate rotates nothing'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$FAKE_FP" > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0 1
run_etw "$SBLAB/wdp-etw.command" ""
reasons=''
[ "$(openssl_calls)" = '2' ] || reasons="$reasons openssl-calls=$(openssl_calls);"
[ "$(archive_count)" = '0' ] || reasons="$reasons archives=$(archive_count);"
[ "$(cat "$PINFILE" 2>/dev/null)" = "$FAKE_FP" ] || reasons="$reasons pin-file-changed=[$(cat "$PINFILE" 2>/dev/null)];"
grep -qF 'PIN_TRUST_ROTATION=1 -- the portal certificate matches the pin on file' "$LOG" || reasons="$reasons no-match-line;"
[ "$(log_count 'CERT-PIN-ROTATED')" = '0' ] || reasons="$reasons rotated-lines=$(log_count 'CERT-PIN-ROTATED');"
[ "$(client_calls)" = '1' ] || reasons="$reasons client-calls=$(client_calls);"
[ "$(client_env "WDP_CERT_SHA256=$FAKE_FP")" = '1' ] || reasons="$reasons client-pin;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: the pre-check dialled, the colon-form pin compared equal to the served fingerprint, nothing archived or rewritten, the client got the pin as written, DONE exit=0"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 16e. The knob cannot rescue a pin file the wrapper cannot READ: to the wrapper an unreadable pin
#      file is no pin (PIN-MISSING, exit 79, exactly as case 14), because rotating FROM nothing
#      would be the unpinned run the pin exists to refuse. No dial, no archive, the file left as
#      it was (mode included) for the operator.
begin '16e PIN_TRUST_ROTATION=1 with an unreadable pin file is still PIN-MISSING'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$STALE_FP" > "$PINFILE"
chmod 000 "$PINFILE"
if [ -r "$PINFILE" ]; then
	chmod 600 "$PINFILE"
	fail "$CASE: chmod 000 left the pin file readable (running as root?) -- this pin cannot be measured here"
else
	write_job smoke 30 "$GOOD_PROVIDERS" 0 1
	run_etw "$SBLAB/wdp-etw.command" ""
	mode_after="$(file_mode "$PINFILE")"
	chmod 600 "$PINFILE"
	if assert_has "$LOG" 'PIN-MISSING' && assert_eq "$(last_line)" 'DONE exit=79' 'last log line' \
		&& assert_eq "$(openssl_calls)" '0' 'openssl invocations' \
		&& assert_eq "$(client_calls)" '0' 'client invocations' \
		&& assert_eq "$(mktemp_calls)" '0' 'mktemp calls (no credential file was EVER created)' \
		&& assert_eq "$(archive_count)" '0' 'rotation archives' \
		&& assert_eq "$mode_after" '0000' 'pin file mode after the run' \
		&& assert_eq "$(cat "$PINFILE")" "$STALE_FP" 'pin file body after the run' \
		&& assert_lacks "$LOG" 'ROTAT'; then
		pass "$CASE: PIN-MISSING, DONE exit=79, no dial, no client, no archive, the unreadable file left exactly as it was"
	fi
fi

# 16f. Nor a pin file that does not hold a fingerprint: PIN-INVALID, exit 79, exactly as case 14b.
#      Same reason as 16e -- there is no pin to rotate FROM -- and the same "leave it for the
#      operator" rule: the file is untouched and nothing is archived.
begin '16f PIN_TRUST_ROTATION=1 with a malformed pin file is still PIN-INVALID'
mkdir -p "$SBWDP" || exit 1
printf 'not-a-fingerprint\n' > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0 1
run_etw "$SBLAB/wdp-etw.command" ""
if assert_has "$LOG" 'PIN-INVALID' && assert_eq "$(last_line)" 'DONE exit=79' 'last log line' \
	&& assert_eq "$(openssl_calls)" '0' 'openssl invocations' \
	&& assert_eq "$(client_calls)" '0' 'client invocations' \
	&& assert_eq "$(mktemp_calls)" '0' 'mktemp calls (no credential file was EVER created)' \
	&& assert_eq "$(archive_count)" '0' 'rotation archives' \
	&& assert_eq "$(cat "$PINFILE" 2>/dev/null)" 'not-a-fingerprint' 'pin file after the run' \
	&& assert_lacks "$LOG" 'ROTAT'; then
	pass "$CASE: PIN-INVALID, DONE exit=79, no dial, no client, no archive, the malformed file left for the operator"
fi

# 16g. The pre-check dials and the portal does not answer (the shim records the call and prints
#      nothing, so the pipeline yields an empty fingerprint): the wrapper must not decide on
#      nothing. The pin on file is KEPT -- not archived, not blanked -- one line says the check
#      failed, and the capture proceeds against the old pin so that the client's own verdict is
#      what the run ends with (here the stub answers 79, as the real client would on a mismatch).
begin '16g PIN_TRUST_ROTATION=1 keeps the pin when the portal returns no fingerprint'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$STALE_FP" > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0 1
LABTEST_OPENSSL_MODE=silent run_etw "$SBLAB/wdp-etw.command" "" 79
reasons=''
[ "$(openssl_calls)" = '2' ] || reasons="$reasons openssl-calls=$(openssl_calls);"
[ "$(archive_count)" = '0' ] || reasons="$reasons archives=$(archive_count);"
[ "$(cat "$PINFILE" 2>/dev/null)" = "$STALE_FP" ] || reasons="$reasons pin-file-changed=[$(cat "$PINFILE" 2>/dev/null)];"
# The dial RAN and the portal said nothing, so the refusal must say so: reason=no-answer, never
# the reason that blames this Mac (16n measures the other half).
grep -qF 'PIN-ROTATION-CHECK-FAILED reason=no-answer' "$LOG" || reasons="$reasons no-check-failed-line;"
[ "$(log_count 'CERT-PIN-ROTATED')" = '0' ] || reasons="$reasons rotated-lines=$(log_count 'CERT-PIN-ROTATED');"
[ "$(client_calls)" = '1' ] || reasons="$reasons client-calls=$(client_calls);"
[ "$(client_env "WDP_CERT_SHA256=$STALE_FP")" = '1' ] || reasons="$reasons client-pin;"
[ "$(last_line)" = 'DONE exit=79' ] || reasons="$reasons last-line=[$(last_line)];"
[ "$(cred_files)" = '0' ] || reasons="$reasons cred-files=$(cred_files);"
if [ -z "$reasons" ]; then
	pass "$CASE: the silent dial is logged as PIN-ROTATION-CHECK-FAILED reason=no-answer, the old pin kept and handed to the client, whose 79 is the run's verdict"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 16h. The archive name is already taken (a second rotation inside the same UTC second, or an
#      operator's own file): the wrapper must clobber NOTHING. `ln` refuses an existing target, so
#      the rotation fails closed -- PIN-ROTATION-FAILED, the sentinel in the archive untouched,
#      the OLD pin still the pin (same bytes, same inode), no staging file left -- and the capture
#      proceeds against the old pin, whose mismatch the client then reports (the stub answers 79).
#      This is the case that pins the mechanism: `mv` (which would rename over the sentinel) and
#      `ln -f` (M7) both turn it red, and it is the only coverage the PIN-ROTATION-FAILED branch has.
begin '16h an archive name already taken fails the rotation closed'
# The archive is pre-created under the fixed stamp, so the wrapper must compute the same name.
RUN_ETW_PATH="$DATE_PATH"
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$STALE_FP" > "$PINFILE"
old_inode="$(file_inode "$PINFILE")"
archive="$PINFILE.until-$ROTATION_STAMP-rotation"
printf 'LABTEST-EARLIER-ARCHIVE-SENTINEL\n' > "$archive"
write_job smoke 30 "$GOOD_PROVIDERS" 0 1
run_etw "$SBLAB/wdp-etw.command" "" 79
reasons=''
[ "$(openssl_calls)" = '2' ] || reasons="$reasons openssl-calls=$(openssl_calls);"
[ "$(cat "$archive" 2>/dev/null)" = 'LABTEST-EARLIER-ARCHIVE-SENTINEL' ] || reasons="$reasons earlier-archive-clobbered=[$(cat "$archive" 2>/dev/null)];"
[ "$(archive_count)" = '1' ] || reasons="$reasons archives=$(archive_count);"
[ "$(cat "$PINFILE" 2>/dev/null)" = "$STALE_FP" ] || reasons="$reasons pin-file-changed=[$(cat "$PINFILE" 2>/dev/null)];"
[ "$(file_inode "$PINFILE")" = "$old_inode" ] || reasons="$reasons pin-file-replaced;"
grep -qF 'PIN-ROTATION-FAILED' "$LOG" || reasons="$reasons no-rotation-failed-line;"
[ "$(log_count 'CERT-PIN-ROTATED')" = '0' ] || reasons="$reasons rotated-lines=$(log_count 'CERT-PIN-ROTATED');"
[ -z "$(find "$SBWDP" -name 'portal-cert-sha256.txt.rotating.*' 2>/dev/null)" ] || reasons="$reasons staging-file-left-behind;"
[ "$(client_calls)" = '1' ] || reasons="$reasons client-calls=$(client_calls);"
[ "$(client_env "WDP_CERT_SHA256=$STALE_FP")" = '1' ] || reasons="$reasons client-pin;"
[ "$(last_line)" = 'DONE exit=79' ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: PIN-ROTATION-FAILED, the earlier archive's sentinel intact, the old pin still the pin (same inode), no staging file, the client run once with the old pin, DONE exit=79"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 16i. The dial is BOUNDED. The stalled shim never returns on its own (\`exec sleep 60\`), so the
#      only way the wrapper reaches its DONE line inside this case's budget is the alarm the
#      trampoline armed before it exec'd openssl. Measured as elapsed wall time around the run:
#      well under the shim's 60 s and at least the bound itself (a run that came back sooner did
#      not dial at all -- the trace's openssl-stall line says it did). The outcome is 16g's: no
#      fingerprint, pin kept, the client decides.
begin '16i a dial that stalls is cut off by the bound and the pin is kept'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$STALE_FP" > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0 1
SECONDS=0
LABTEST_OPENSSL_MODE=stall run_etw "$SBLAB/wdp-etw.command" "" 79
elapsed=$SECONDS
reasons=''
grep -q '^openssl-stall$' "$LABTEST_TRACE" || reasons="$reasons the-shim-did-not-stall;"
[ "$elapsed" -ge 10 ] || reasons="$reasons returned-in-${elapsed}s-before-the-bound-could-have-fired;"
# 15 s plus room for a loaded machine (see 15d): 45 s would also admit a 40 s bound.
[ "$elapsed" -lt 25 ] || reasons="$reasons took-${elapsed}s-past-the-15s-bound;"
[ "$(last_line)" = 'DONE exit=79' ] || reasons="$reasons last-line=[$(last_line)];"
# A stalled portal ANSWERED the connection and then said nothing, so the reason is the portal's:
# reason=local-tool here would mean the wrapper blamed this Mac for the host's silence (16n).
grep -qF 'PIN-ROTATION-CHECK-FAILED reason=no-answer' "$LOG" || reasons="$reasons no-check-failed-line;"
[ "$(archive_count)" = '0' ] || reasons="$reasons archives=$(archive_count);"
[ "$(cat "$PINFILE" 2>/dev/null)" = "$STALE_FP" ] || reasons="$reasons pin-file-changed;"
[ "$(client_calls)" = '1' ] || reasons="$reasons client-calls=$(client_calls);"
[ "$(client_env "WDP_CERT_SHA256=$STALE_FP")" = '1' ] || reasons="$reasons client-pin;"
if [ -z "$reasons" ]; then
	pass "$CASE: the stalled dial was cut off after ${elapsed}s (bound 15 s, shim would have slept 60 s), PIN-ROTATION-CHECK-FAILED, the pin kept, DONE exit=79"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 16j. PIN_RECORD=1 and PIN_TRUST_ROTATION=1 together, with a stale pin on file: the rotation runs
#      (the pin exists), the recorder does not (a pin exists -- and after the rotation still
#      does), so the portal is dialled ONCE: openssl_calls is 2, not 4. The recorder's "ignored"
#      line and the rotation's line both appear.
begin '16j PIN_RECORD=1 alongside PIN_TRUST_ROTATION=1 dials once'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$STALE_FP" > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 1 1
run_etw "$SBLAB/wdp-etw.command" ""
reasons=''
[ "$(openssl_calls)" = '2' ] || reasons="$reasons openssl-calls=$(openssl_calls);"
[ "$(log_count 'PIN_RECORD=1 ignored')" = '1' ] || reasons="$reasons ignored-lines=$(log_count 'PIN_RECORD=1 ignored');"
[ "$(log_count 'CERT-PIN-ROTATED')" = '1' ] || reasons="$reasons rotated-lines=$(log_count 'CERT-PIN-ROTATED');"
[ "$(log_count 'recording the portal certificate pin')" = '0' ] || reasons="$reasons recorder-ran;"
[ "$(cat "$PINFILE" 2>/dev/null)" = "$FAKE_HEX" ] || reasons="$reasons new-pin=[$(cat "$PINFILE" 2>/dev/null)];"
[ "$(client_env "WDP_CERT_SHA256=$FAKE_HEX")" = '1' ] || reasons="$reasons client-pin;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: one dial (openssl_calls=2), PIN_RECORD=1 logged as ignored, one CERT-PIN-ROTATED line, the recorder never ran, DONE exit=0"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 16k. The rotation trusts a SEPARATE TLS connection, taken moments before the capture's. The
#      portal regenerates its certificate on every webmanagement start -- the reason the knob
#      exists at all -- so a restart landing BETWEEN the dial and the capture pins certificate A
#      while the capture is shown B: the run still ends at the client's own exit 79, the good pin
#      has already been archived, and the next run rotates again. Nothing is lost, but without a
#      line saying the two disagreed a scrollback reads "the pin rotated and STILL mismatched",
#      i.e. as a broken pin rather than as one certificate change reported twice. Exactly one
#      line, carrying both fingerprints, and everything else about the run is unchanged.
begin '16k a rotation whose capture then meets exit 79 says the two certificates disagreed'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$STALE_FP" > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0 1
run_etw "$SBLAB/wdp-etw.command" "" 79
reasons=''
[ "$(log_count 'CERT-PIN-ROTATED')" = '1' ] || reasons="$reasons rotated-lines=$(log_count 'CERT-PIN-ROTATED');"
grep -qF "[etw] PIN-ROTATED-THEN-MISMATCHED old=$STALE_HEX new=$FAKE_HEX" "$LOG" || reasons="$reasons no-disagreement-line;"
[ "$(log_count 'PIN-ROTATED-THEN-MISMATCHED')" = '1' ] || reasons="$reasons disagreement-lines=$(log_count 'PIN-ROTATED-THEN-MISMATCHED');"
[ "$(last_line)" = 'DONE exit=79' ] || reasons="$reasons last-line=[$(last_line)];"
[ "$(cat "$PINFILE" 2>/dev/null)" = "$FAKE_HEX" ] || reasons="$reasons pin=[$(cat "$PINFILE" 2>/dev/null)];"
[ "$(archive_count)" = '1' ] || reasons="$reasons archives=$(archive_count);"
[ "$(cat "$(archive_path)" 2>/dev/null)" = "$STALE_FP" ] || reasons="$reasons archive-body-not-the-old-pin;"
[ "$(client_calls)" = '1' ] || reasons="$reasons client-calls=$(client_calls);"
[ "$(cred_files)" = '0' ] || reasons="$reasons cred-files=$(cred_files);"
if [ -z "$reasons" ]; then
	pass "$CASE: one CERT-PIN-ROTATED and exactly one PIN-ROTATED-THEN-MISMATCHED naming both fingerprints, the archive intact, the new pin on file, DONE exit=79"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 16l. The other half of the same claim: a run that did NOT rotate must never print that line,
#      however it ends. Both shapes that reach the client's 79 without a rotation are measured --
#      the knob on with a certificate that still matches, and no knob at all with a stale pin --
#      because a line emitted on the exit code alone would turn every ordinary pin mismatch into a
#      report of a certificate change that did not happen. M8 is the proof that this case bites.
begin '16l a run that did not rotate never claims the certificates disagreed'
reasons=''
for leg in matching no-knob; do
	mkdir -p "$SBWDP" || exit 1
	: > "$LABTEST_TRACE"
	rm -f "$LOG" "$PINFILE"
	if [ "$leg" = matching ]; then
		printf '%s\n' "$FAKE_FP" > "$PINFILE"
		write_job smoke 30 "$GOOD_PROVIDERS" 0 1
	else
		printf '%s\n' "$STALE_FP" > "$PINFILE"
		write_job smoke 30 "$GOOD_PROVIDERS" 0
	fi
	run_etw "$SBLAB/wdp-etw.command" "" 79
	[ "$(log_count 'PIN-ROTATED-THEN-MISMATCHED')" = '0' ] || reasons="$reasons leg=$leg disagreement-line-without-a-rotation;"
	[ "$(log_count 'CERT-PIN-ROTATED')" = '0' ] || reasons="$reasons leg=$leg rotated-lines=$(log_count 'CERT-PIN-ROTATED');"
	[ "$(last_line)" = 'DONE exit=79' ] || reasons="$reasons leg=$leg last-line=[$(last_line)];"
	[ "$(client_calls)" = '1' ] || reasons="$reasons leg=$leg client-calls=$(client_calls);"
	[ "$(rotlog_lines)" = '0' ] || reasons="$reasons leg=$leg rotations-record-lines=$(rotlog_lines);"
done
if [ -z "$reasons" ]; then
	pass "$CASE: neither a matching certificate under the knob nor a stale pin without it prints PIN-ROTATED-THEN-MISMATCHED, and neither appends to the rotations record, though both end DONE exit=79"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 16m. What actually RECORDS a rotation. etw.log is truncated by the next run -- including a rerun
#      of the same TAG, whose per-TAG copy is overwritten too -- so outside a checkpoint batch that
#      gathers the log the CERT-PIN-ROTATED line is gone the moment anything runs again. The
#      durable record is the archive file plus one APPENDED line in portal-cert-rotations.log:
#      `<stamp> tag= old= new= archive=`, 0600, never truncated. Two rotations across two runs
#      leave two lines (the archive from the first is removed between them, which is the operator
#      pruning by hand -- the only way that name is ever freed), and a third run that rotates
#      nothing leaves both lines exactly where they were while etw.log starts again from empty.
begin '16m every rotation appends one line to a record no run truncates'
RUN_ETW_PATH="$DATE_PATH"
mkdir -p "$SBWDP" || exit 1
archive="$PINFILE.until-$ROTATION_STAMP-rotation"
expected_rotation="$ROTATION_STAMP tag=smoke old=$STALE_HEX new=$FAKE_HEX archive=$(basename "$archive")"
write_job smoke 30 "$GOOD_PROVIDERS" 0 1
printf '%s\n' "$STALE_FP" > "$PINFILE"
run_etw "$SBLAB/wdp-etw.command" ""
first_rotation_lines="$(rotlog_lines)"
# The operator prunes the first archive by hand and the portal's certificate changes again.
rm -f "$archive"
printf '%s\n' "$STALE_FP" > "$PINFILE"
run_etw "$SBLAB/wdp-etw.command" ""
second_rotation_lines="$(rotlog_lines)"
# A third run, rotating nothing: etw.log is truncated, the record is not.
write_job smoke 30 "$GOOD_PROVIDERS" 0
run_etw "$SBLAB/wdp-etw.command" ""
reasons=''
[ "$first_rotation_lines" = '1' ] || reasons="$reasons after-first-rotation=$first_rotation_lines;"
[ "$second_rotation_lines" = '2' ] || reasons="$reasons after-second-rotation=$second_rotation_lines;"
[ "$(rotlog_lines)" = '2' ] || reasons="$reasons after-a-run-that-rotated-nothing=$(rotlog_lines);"
[ "$(rotlog_count "$expected_rotation")" = '2' ] || reasons="$reasons record-lines-matching-the-grammar=$(rotlog_count "$expected_rotation");"
[ "$(file_mode "$ROTLOG")" = '0600' ] || reasons="$reasons record-mode=$(file_mode "$ROTLOG");"
[ "$(log_count 'CERT-PIN-ROTATED')" = '0' ] || reasons="$reasons third-run-log-still-carries-a-rotation-line;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
[ "$(cat "$PINFILE" 2>/dev/null)" = "$FAKE_HEX" ] || reasons="$reasons pin=[$(cat "$PINFILE" 2>/dev/null)];"
if [ -z "$reasons" ]; then
	pass "$CASE: two rotations left two lines of the documented grammar in a 0600 append-only record, and a third run truncated etw.log without touching them"
else
	fail "$CASE:$reasons"; note "record: $(if [ -f "$ROTLOG" ]; then tr '\n' ';' < "$ROTLOG"; fi)"
fi

# 16n. An empty fingerprint means two different things and the refusal must not assert the wrong
#      one: the portal said nothing (reason=no-answer, 16g and 16i) or the dial could not run on
#      THIS machine at all (reason=local-tool) -- a missing openssl, a python3 the trampoline
#      cannot exec. The first move differs (go and look at the host / go and look at this Mac), so
#      the line names the half the wrapper can actually decide. Measured by running the wrapper on
#      a PATH farm built from the sandbox's own PATH with every `openssl` left out, so the dial
#      genuinely cannot run (the openssl shim records nothing) while everything else -- the other
#      shims, the real python3 the boundary gate needs -- resolves exactly as it does elsewhere.
begin '16n a dial that cannot run here is reason=local-tool, and the pin is kept'
NOSSL_BIN="$SB/bin-no-openssl"
rm -rf "$NOSSL_BIN"
mkdir -p "$NOSSL_BIN" || exit 1
python3 -c '
import os, sys
dest, path, skip = sys.argv[1], sys.argv[2], sys.argv[3]
for directory in path.split(":"):
    if not directory or not os.path.isdir(directory):
        continue
    for name in sorted(os.listdir(directory)):
        if name == skip:
            continue
        link = os.path.join(dest, name)
        if os.path.lexists(link):
            continue
        try:
            os.symlink(os.path.join(directory, name), link)
        except OSError:
            pass
' "$NOSSL_BIN" "$SB/bin:$PATH" openssl || exit 1
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$STALE_FP" > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0 1
RUN_ETW_PATH="$NOSSL_BIN"
run_etw "$SBLAB/wdp-etw.command" "" 79
reasons=''
[ -z "$(PATH="$NOSSL_BIN" command -v openssl || true)" ] || reasons="$reasons openssl-still-on-the-farm-path;"
[ -n "$(PATH="$NOSSL_BIN" command -v python3 || true)" ] || reasons="$reasons python3-missing-from-the-farm-path;"
[ "$(openssl_calls)" = '0' ] || reasons="$reasons openssl-calls=$(openssl_calls);"
grep -qF 'PIN-ROTATION-CHECK-FAILED reason=local-tool' "$LOG" || reasons="$reasons no-local-tool-reason;"
[ "$(log_count 'CERT-PIN-ROTATED')" = '0' ] || reasons="$reasons rotated-lines=$(log_count 'CERT-PIN-ROTATED');"
[ "$(archive_count)" = '0' ] || reasons="$reasons archives=$(archive_count);"
[ "$(cat "$PINFILE" 2>/dev/null)" = "$STALE_FP" ] || reasons="$reasons pin-file-changed=[$(cat "$PINFILE" 2>/dev/null)];"
[ "$(client_calls)" = '1' ] || reasons="$reasons client-calls=$(client_calls);"
[ "$(client_env "WDP_CERT_SHA256=$STALE_FP")" = '1' ] || reasons="$reasons client-pin;"
[ "$(last_line)" = 'DONE exit=79' ] || reasons="$reasons last-line=[$(last_line)];"
[ "$(cred_files)" = '0' ] || reasons="$reasons cred-files=$(cred_files);"
if [ -z "$reasons" ]; then
	pass "$CASE: with no openssl on PATH the dial never ran, the refusal reads reason=local-tool, the pin was kept and handed to the client, DONE exit=79"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 17. The happy path, pinned element by element: this argument list IS the wrapper's contract with
#     the client (which reads its parameters from the environment precisely because argv is
#     world-readable through ps). Also the credential file's whole life: mode 0600 and the exact
#     `user:password` line while the client runs, gone the moment it returns.
begin '17 happy path'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$FAKE_FP" > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0
run_etw "$SBLAB/wdp-etw.command" ""
credpath="$(sed -n 's/^client-env WDP_CRED_FILE=//p' "$LABTEST_TRACE" | head -n 1)"
envcount="$(grep -c '^client-env WDP_' "$LABTEST_TRACE" 2>/dev/null || true)"
reasons=''
[ "$(client_calls)" = '1' ] || reasons="$reasons client-calls=$(client_calls);"
[ "$(client_env 'WDP_HOST=192.0.2.10')" = '1' ] || reasons="$reasons WDP_HOST;"
[ "$(client_env 'WDP_PORT=50443')" = '1' ] || reasons="$reasons WDP_PORT;"
[ "$(client_env "WDP_CERT_SHA256=$FAKE_FP")" = '1' ] || reasons="$reasons WDP_CERT_SHA256;"
[ "$(client_env "WDP_PROVIDERS=$GOOD_PROVIDERS")" = '1' ] || reasons="$reasons WDP_PROVIDERS;"
[ "$(client_env 'WDP_DURATION=30')" = '1' ] || reasons="$reasons WDP_DURATION;"
[ "$(client_env "WDP_OUT=$SBWDP/etw-smoke.jsonl")" = '1' ] || reasons="$reasons WDP_OUT;"
[ "$envcount" = '7' ] || reasons="$reasons env-count=$envcount(expected 7);"
case "$credpath" in "$SBTMP"/macdows-etw-cred.*) ;; *) reasons="$reasons cred-path=[$credpath];" ;; esac
grep -qF 'client-cred-mode 0600' "$LABTEST_TRACE" || reasons="$reasons cred-mode=[$(sed -n 's/^client-cred-mode //p' "$LABTEST_TRACE")];"
grep -qF 'client-cred-body labtest-placeholder:LABTEST-PLACEHOLDER-SECRET-3f9a' "$LABTEST_TRACE" || reasons="$reasons cred-body;"
# -x, not a substring match: the rule the client's whole environment-not-argv design exists for
# is "nothing BUT the module path is ever on the command line" (argv is world-readable through
# `ps`), and an unanchored match is satisfied by any number of extra arguments after it.
grep -qxF "client-argv [$SBLAB/wdp_etw.py]" "$LABTEST_TRACE" || reasons="$reasons client-argv=[$(grep '^client-argv' "$LABTEST_TRACE")];"
[ "$(cred_files)" = '0' ] || reasons="$reasons credential-file-survived-the-run;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
[ -f "$SBWDP/etw-smoke.log" ] || reasons="$reasons no-per-tag-log-copy;"
if [ -z "$reasons" ]; then
	pass "$CASE: the client saw exactly the seven documented WDP_* values, a 0600 credential file holding <user>:<password>, and nothing else; the credential file is gone; DONE exit=0; etw-smoke.log kept"
else
	fail "$CASE:$reasons"; note "trace: $(tr '\n' ';' < "$LABTEST_TRACE")"
fi

# 17b. The same happy path with host.env written in the `export` style, which Scripts/probe.sh:70
#      says exists in the wild. The wrapper's children must not inherit the portal password just
#      because the operator's host.env exports it: argv is world-readable through `ps` and an
#      environment is world-readable through a crash dump, and the credential FILE (0600, removed
#      on every path) is the one channel this design allows. WIN_USER and WIN_HOST go the same way
#      -- neither child needs them, the client takes WDP_HOST and the recorder takes the host on
#      its command line -- while the WDP_* values must still arrive and the credential file must
#      still be written from values the WRAPPER still holds. PIN_RECORD=1 with no pin on file, so
#      both children (the openssl recorder and the client) run in one case.
begin '17b host.env in the export style keeps its values out of the children'
cp "$HOSTENV_FILE" "$HOSTENV_FILE.away" || exit 1
cat > "$HOSTENV_FILE" <<'HOSTENVEXPORT' || exit 1
export WIN_HOST=192.0.2.10
export WIN_USER=labtest-placeholder
export WIN_PASS=LABTEST-PLACEHOLDER-SECRET-3f9a
HOSTENVEXPORT
write_job smoke 30 "$GOOD_PROVIDERS" 1
run_etw "$SBLAB/wdp-etw.command" ""
mv "$HOSTENV_FILE.away" "$HOSTENV_FILE" || exit 1
envnames=" $(sed -n 's/^client-env-names //p' "$LABTEST_TRACE" | head -n 1) "
reasons=''
[ "$(client_calls)" = '1' ] || reasons="$reasons client-calls=$(client_calls);"
for leaked in WIN_PASS WIN_USER WIN_HOST; do
	case "$envnames" in *" $leaked "*) reasons="$reasons $leaked-reached-the-client;" ;; esac
done
for needed in WDP_HOST WDP_CRED_FILE WDP_CERT_SHA256; do
	case "$envnames" in *" $needed "*) ;; *) reasons="$reasons $needed-missing;" ;; esac
done
if grep -q '^openssl-hostenv .*WIN_' "$LABTEST_TRACE"; then
	reasons="$reasons host.env-reached-openssl=[$(grep '^openssl-hostenv' "$LABTEST_TRACE" | head -n 1)];"
fi
[ "$(grep -c '^openssl-hostenv <none>$' "$LABTEST_TRACE" 2>/dev/null || true)" -ge 1 ] || reasons="$reasons no-openssl-environment-recorded;"
grep -qF 'client-cred-body labtest-placeholder:LABTEST-PLACEHOLDER-SECRET-3f9a' "$LABTEST_TRACE" || reasons="$reasons cred-body;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: an exporting host.env reaches neither the pin recorder nor the client; the WDP_* values and the 0600 credential file are unaffected"
else
	fail "$CASE:$reasons"; note "trace: $(tr '\n' ';' < "$LABTEST_TRACE")"
fi

# 17c. THE PID LINE. checkpoint.sh's overlap guard has to answer "is a capture still in flight?"
#      before it launches another one, because two realtime subscriptions against the same portal
#      disable each other's providers and the damage lands in the OTHER run's evidence. The signal
#      it reads is this line: the wrapper writes its OWN pid into etw.log right after the capture's
#      start line and BEFORE it dials, so a guard can `kill -0` it.
#      Pinned three ways, because each answers a different way of getting it wrong: the number is
#      the process that started the client (its ppid -- not merely "a number of the right shape");
#      there is exactly ONE such line (a guard reading the wrong one of several would be watching a
#      process that already exited); and it precedes the client's first output, since a pid written
#      after the dial arrives too late for a guard that must decide before the second capture is
#      launched.
begin '17c the wrapper records its own pid before it dials'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$FAKE_FP" > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0
PID_RELEASE="$SB/pid-release"
# Created BEFORE the run: the stub breaks out of its wait on the first poll, so this case pays for
# the WS-OPEN line without paying for the 5s window case 26 needs.
: > "$PID_RELEASE"
run_etw "$SBLAB/wdp-etw.command" "" 0 0 1 "$SB/pid-running" "$PID_RELEASE"
reasons=''
pid_lines="$(grep -c '^\[etw\] pid=[0-9][0-9]*$' "$LOG" 2>/dev/null || true)"
logged_pid="$(sed -n 's/^\[etw\] pid=\([0-9][0-9]*\)$/\1/p' "$LOG" | head -n 1)"
client_ppid="$(sed -n 's/^client-ppid //p' "$LABTEST_TRACE" | head -n 1)"
tag_line="$(grep -n '^\[etw\] etw capture tag=' "$LOG" | head -n 1 | cut -d: -f1)"
pid_line="$(grep -n '^\[etw\] pid=' "$LOG" | head -n 1 | cut -d: -f1)"
ws_line="$(grep -n '^WS-OPEN$' "$LOG" | head -n 1 | cut -d: -f1)"
[ "$pid_lines" = '1' ] || reasons="$reasons pid-lines=$pid_lines;"
if [ -z "$logged_pid" ] || [ "$logged_pid" != "$client_ppid" ]; then
	reasons="$reasons logged-pid=[$logged_pid]-client-ppid=[$client_ppid];"
fi
if [ -z "$tag_line" ] || [ -z "$pid_line" ] || [ -z "$ws_line" ] \
	|| [ "$tag_line" -ge "$pid_line" ] || [ "$pid_line" -ge "$ws_line" ]; then
	reasons="$reasons order=[tag:$tag_line pid:$pid_line ws-open:$ws_line];"
fi
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: exactly one [etw] pid= line, carrying the pid of the process that started the client, written after the capture's start line and before the client's first output"
else
	fail "$CASE:$reasons"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# 18. etw.log is what a human pastes into a report, so the address, the account and the local
#     account name appear only in their masked form and the password not at all. The masked forms
#     have to BE there: an empty mask would satisfy a "does not contain" assertion on its own.
#     The client runs with LABTEST_CLIENT_STDERR=1, so it prints two lines of the class that
#     reaches the log from the CLIENT rather than from the wrapper's own printf: a traceback naming
#     its own module path (which carries $HOME) and a refusal quoting the credential file it read
#     (which carries the account and the password). Both must arrive masked.
begin '18 log mask'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$FAKE_FP" > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0
run_etw "$SBLAB/wdp-etw.command" "" 0 1
if assert_has "$LOG" '<WIN_HOST>' && assert_has "$LOG" '<WIN_USER>' \
	&& assert_has "$LOG" 'RuntimeError: LABTEST stand-in traceback' \
	&& assert_has "$LOG" '<HOME>' && assert_lacks "$LOG" "$SBHOME" \
	&& assert_has "$LOG" '<WIN_USER>:<WIN_PASS>' \
	&& assert_lacks "$LOG" '192.0.2.10' && assert_lacks "$LOG" 'labtest-placeholder' \
	&& assert_lacks "$LOG" 'LABTEST-PLACEHOLDER-SECRET-3f9a' \
	&& [ -f "$SBWDP/etw-smoke.log" ] && assert_lacks "$SBWDP/etw-smoke.log" '192.0.2.10' \
	&& assert_lacks "$SBWDP/etw-smoke.log" "$SBHOME" \
	&& assert_has "$SBWDP/etw-smoke.log" '<WIN_HOST>'; then
	pass "$CASE: etw.log and its per-TAG copy carry <WIN_HOST>/<WIN_USER>/<HOME> and neither the address, the account, the password nor the home path a client traceback printed"
fi

# 19. A hand-edited CRLF job.env must not ship a bare CR into a file name, into a regex or into the
#     client's environment: every value's trailing CR is stripped, so the job is ACCEPTED and the
#     capture runs with exactly the values the file spells.
begin '19 CRLF job file'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$FAKE_FP" > "$PINFILE"
# ALL FIVE keys, the newest included: its value is checked against ^[01]$, so a CR that survived
# the strip would make `1\r` fail that check and the run would refuse with 65 -- and the pin
# whose CR-stripped value is honoured is the one that decides whether the wrapper dials at all.
printf 'TAG=smoke\r\nDURATION=30\r\nPROVIDERS=%s\r\nPIN_RECORD=0\r\nPIN_TRUST_ROTATION=1\r\n' "'$GOOD_PROVIDERS'" > "$JOB"
run_etw "$SBLAB/wdp-etw.command" ""
reasons=''
[ "$(client_calls)" = '1' ] || reasons="$reasons client-calls=$(client_calls);"
# The fifth key was read as 1: the wrapper dialled (two openssl calls, s_client|x509) and said so.
[ "$(openssl_calls)" = '2' ] || reasons="$reasons openssl-calls=$(openssl_calls);"
grep -qF 'the portal certificate matches the pin on file' "$LOG" || reasons="$reasons fifth-key-not-honoured;"
[ "$(client_env 'WDP_DURATION=30')" = '1' ] || reasons="$reasons WDP_DURATION;"
[ "$(client_env "WDP_PROVIDERS=$GOOD_PROVIDERS")" = '1' ] || reasons="$reasons WDP_PROVIDERS;"
[ "$(client_env "WDP_OUT=$SBWDP/etw-smoke.jsonl")" = '1' ] || reasons="$reasons WDP_OUT;"
grep -q "$(printf '\r')" "$LABTEST_TRACE" && reasons="$reasons bare-CR-reached-the-client;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: trailing CRs are stripped from all five keys -- PIN_TRUST_ROTATION=1 is honoured and dials -- the job is accepted and no CR reaches the client"
else
	fail "$CASE:$reasons"; note "trace: $(tr '\n' ';' < "$LABTEST_TRACE")"
fi

# 19b. A CR in the MIDDLE of a value. The line grammar judges the file with every CR deleted, so
#      `TAG=sm<CR>oke` is admitted as the text `TAG=smoke` -- but the subshell reads the ORIGINAL
#      file, and a strip that took only the TRAILING CR handed back `sm<CR>oke`, which then failed
#      TAG's own shape check. Two guards disagreeing about the same file: the grammar said yes, the
#      shape check said no, and the reason printed was about TAG's character class rather than about
#      a stray CR. Every CR is removed now, and the value the client gets is the value the grammar
#      admitted. checkpoint.sh reads this same file with tr -d '\r' to build the waits an
#      orchestrator runs on, so agreeing with it is not cosmetic: they name the same JSONL.
begin '19b a CR inside a value, not only at the end of the line'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$FAKE_FP" > "$PINFILE"
printf 'TAG=sm\roke\r\nDURATION=30\r\nPROVIDERS=%s\r\nPIN_RECORD=0\r\n' "'$GOOD_PROVIDERS'" > "$JOB"
run_etw "$SBLAB/wdp-etw.command" ""
reasons=''
[ "$(client_calls)" = '1' ] || reasons="$reasons client-calls=$(client_calls);"
[ "$(client_env "WDP_OUT=$SBWDP/etw-smoke.jsonl")" = '1' ] || reasons="$reasons WDP_OUT;"
[ -f "$SBRUNTIME/wdp/etw-smoke.log" ] || reasons="$reasons per-TAG-log-not-named-etw-smoke.log;"
grep -q "$(printf '\r')" "$LABTEST_TRACE" && reasons="$reasons bare-CR-reached-the-client;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: a CR anywhere in TAG is removed, so the grammar and the shape check judge the same value and the capture is named etw-smoke.jsonl"
else
	fail "$CASE:$reasons"; note "trace: $(tr '\n' ';' < "$LABTEST_TRACE" | tr '\r' '?')"
fi

# 20. The client's exit code IS the run's verdict -- unlike the relay, whose xfreerdp exit says
#     nothing about the job. A refusal inside the client (79 = pin mismatch) must reach the DONE
#     line the caller polls, not be flattened to 0.
begin '20 client exit code propagates'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$FAKE_FP" > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0
run_etw "$SBLAB/wdp-etw.command" "" 79
if assert_eq "$(client_calls)" '1' 'client invocations' && assert_eq "$(last_line)" 'DONE exit=79' 'last log line' \
	&& assert_has "$LOG" 'rc=79' && assert_eq "$(cred_files)" '0' 'credential files under TMPDIR'; then
	pass "$CASE: a client exit of 79 reaches DONE exit=79 and the credential file is still removed"
fi

# 21. The log is truncated at startup: a stale DONE line from a previous run must not be what a
#     caller polling for one finds.
begin '21 log truncation'
mkdir -p "$SBWDP" "$SBRUNTIME" || exit 1
printf '[etw] stale run\nDONE exit=0\n' > "$LOG"
printf '%s\n' "$FAKE_FP" > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0
run_etw "$SBLAB/wdp-etw.command" "" 79
if assert_eq "$(done_lines)" '1' 'DONE lines after the run' && assert_lacks "$LOG" 'stale run' \
	&& assert_eq "$(last_line)" 'DONE exit=79' 'last log line'; then
	pass "$CASE: etw.log is truncated at startup -- the stale DONE exit=0 is gone and exactly one DONE line remains"
fi

# 22. run-scenario.sh's etw mode is the only supported way to launch a capture: it copies the
#     TRACKED jobs/etw-<name>.env to the runtime instance, removes the previous etw.log (so a
#     caller polling for DONE cannot read the last run's verdict) and hands the wrapper to
#     Terminal. It stages no share -- no relay is involved, and staging would only widen the
#     redirected drive for a run that never mounts one.
begin '22 run-scenario.sh etw smoke'
printf 'DONE exit=0\n' > "$LOG"
OUT="$SB/out-run-scenario.txt"
(cd "$SBLAB" && env HOME="$SBHOME" PATH="$SB/bin:$PATH" LABTEST_TRACE="$LABTEST_TRACE" \
	LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" bash "$SBLAB/run-scenario.sh" etw smoke) > "$OUT" 2>&1
rc=$?
reasons=''
[ "$rc" -eq 0 ] || reasons="$reasons rc=$rc;"
grep -qF 'etw smoke launched' "$OUT" || reasons="$reasons no-launch-line;"
cmp -s "$SBLAB/jobs/etw-smoke.env" "$JOB" || reasons="$reasons job-instance-differs-from-the-tracked-template;"
[ -f "$LOG" ] && reasons="$reasons stale-etw.log-survived;"
grep -qF "open [-a] [Terminal] [$SBLAB/wdp-etw.command]" "$LABTEST_TRACE" || reasons="$reasons open-argv=[$(grep '^open ' "$LABTEST_TRACE")];"
[ -f "$SBLAB/etw-job.env" ] && reasons="$reasons job-written-into-the-tracked-tree;"
if [ -z "$reasons" ]; then
	pass "$CASE: jobs/etw-smoke.env copied to the runtime etw-job.env, the stale etw.log removed, Terminal asked to open wdp-etw.command and nothing written into the tracked tree"
else
	fail "$CASE:$reasons"; note "$(cat "$OUT")"
fi

# 22b. The TRACKED job template must actually be accepted by the wrapper and reach the client
#      unchanged -- the same property test-relay-offline.sh's case 5 keeps for jobs/*.env. It is a
#      regression pin rather than a must-red (it passed the moment jobs/etw-smoke.env existed):
#      what it guards is a future edit to the template's GUID list, duration or quoting, which
#      would otherwise surface as a refused capture on the lab host and nowhere else.
begin '22b the tracked jobs/etw-smoke.env drives the wrapper'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$FAKE_FP" > "$PINFILE"
cp "$SBLAB/jobs/etw-smoke.env" "$JOB" || exit 1
tracked_providers="$(
	# shellcheck source=/dev/null
	. "$SBLAB/jobs/etw-smoke.env" >/dev/null 2>&1
	printf '%s' "${PROVIDERS:-}"
)"
tracked_count="$(printf '%s\n' "$tracked_providers" | awk -F';' '{print NF}')"
run_etw "$SBLAB/wdp-etw.command" ""
reasons=''
[ "$tracked_count" -ge 5 ] || reasons="$reasons template-lists-only-$tracked_count-providers;"
[ "$(client_calls)" = '1' ] || reasons="$reasons client-calls=$(client_calls);"
[ "$(client_env "WDP_PROVIDERS=$tracked_providers")" = '1' ] || reasons="$reasons providers-not-verbatim;"
[ "$(client_env 'WDP_DURATION=150')" = '1' ] || reasons="$reasons WDP_DURATION;"
[ "$(client_env "WDP_OUT=$SBWDP/etw-smoke.jsonl")" = '1' ] || reasons="$reasons WDP_OUT;"
grep -qF "providers=$tracked_count" "$LOG" || reasons="$reasons provider-count-not-logged;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: the shipped template's $tracked_count providers reach the client verbatim at DURATION=150; DONE exit=0"
else
	fail "$CASE:$reasons"; note "trace: $(tr '\n' ';' < "$LABTEST_TRACE")"
fi

# 23. The wrapper is only half the capture: the client it runs and the summariser that makes a
#     capture safe to quote are Python, and their own unit suites live next to it. Run them from
#     the REAL Scripts/lab (they are pure unit tests; the client's suite talks to a loopback fake
#     portal and nothing else), so this suite is the single command that says whether the whole
#     ETW lane is sound. A missing module is a FAILURE here, never a silent skip -- a skipped
#     suite reads as coverage that is not there.
#     `-B`: no bytecode. A cached .pyc is keyed on the source's mtime and SIZE, so an edit that
#     restores a file to a byte-identical state within the same second leaves the PREVIOUS
#     module's bytecode valid -- measured during this lane's review, where a restored source and
#     a red suite disagreed until Scripts/lab/__pycache__ was removed. Nothing may decide a Tier 1
#     verdict except the sources in the tree.
begin '23 the python unit suites pass'
missing=''
for module in test_wdp_etw.py test_etw_summarize.py; do
	[ -f "$LAB/$module" ] || missing="$missing $module"
done
if [ -n "$missing" ]; then
	fail "$CASE: Scripts/lab is missing:$missing -- the ETW lane's python suites cannot run"
elif (cd "$LAB" && python3 -B -m unittest test_wdp_etw test_etw_summarize) > "$SB/unittest.txt" 2>&1; then
	pass "$CASE: $(tail -n 1 "$SB/unittest.txt") -- test_wdp_etw + test_etw_summarize green"
else
	fail "$CASE: the python unit suites are red"; note "$(tail -n 25 "$SB/unittest.txt")"
fi

# 24. Across EVERY case above the refuse shim was never reached: TERM_PROGRAM was cleared, so the
#     Terminal self-close branch was not taken (run-long trace, never reset).
begin '24 osascript never reached'
if [ ! -s "$LABTEST_REFUSED_TRACE" ]; then
	pass "$CASE: the osascript shim recorded no call across the whole run (TERM_PROGRAM cleared)"
else
	fail "$CASE: $(sort "$LABTEST_REFUSED_TRACE" | uniq -c | tr '\n' ';')"
fi

# 25. Tracked-tree census: every run above wrote only under .build/lab-runtime. The pin file, the
#     capture and the per-TAG log copy all live there by design -- a wrapper that wrote any of them
#     next to itself would be committing a host's certificate fingerprint to git.
begin '25 tracked tree census'
if diff -q "$TRACKED_PRISTINE" <(snapshot_tracked) >/dev/null; then
	pass "$CASE: no case wrote into the tracked lab directory"
else
	fail "$CASE: tracked tree changed"; diff "$TRACKED_PRISTINE" <(snapshot_tracked) | sed 's/^/        /'
fi

# 26. WS-OPEN is the client's first line once the WebSocket is up, and it must reach etw.log WHILE
#     the client is still running -- not only after it exits. The stub writes a `running` sentinel
#     (per m-2, BEFORE it prints WS-OPEN), prints WS-OPEN (flushed, exactly like the real client's
#     `say()`), then blocks on a `release` file for up to 5s so this case can look at the log
#     before the pipe closes. This is the fix for the gap the 2026-09-09 checkpoint hit (record
#     m-2): a masking pipeline that buffers a whole block before writing leaves etw.log empty
#     until the client exits, so an orchestrator can only treat the JSONL file's appearance as
#     "the socket is open".
#     Waiting for the sentinel and polling the log are two SEPARATE bounded waits (record m-1):
#     first up to 5s for the sentinel to appear (this is "has the wrapper even gotten the client
#     running yet", a question about the harness/machine, not about the masking pipeline), and
#     only once that is true, up to 3s of polling etw.log for WS-OPEN. Folding both into one
#     window let a slow-to-start wrapper (nothing to do with the defect this case exists to catch)
#     produce the same `seen=0` a real block-buffering regression would, on a machine too loaded to
#     start the client inside the old single 2s bound.
begin '26 WS-OPEN reaches etw.log before the client exits'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$FAKE_FP" > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0
RUNNING_FILE="$SB/ws-open-running"
RELEASE_FILE="$SB/ws-open-release"
rm -f "$RUNNING_FILE" "$RELEASE_FILE"
env -i \
	HOME="$SBHOME" \
	PATH="$SB/bin:$PATH" \
	TMPDIR="$SBTMP" \
	TERM_PROGRAM= \
	LABTEST_TRACE="$LABTEST_TRACE" \
	LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" \
	LABTEST_CLIENT_RC=0 \
	LABTEST_CLIENT_STDERR=0 \
	LABTEST_CLIENT_WS_OPEN=1 \
	LABTEST_RUNNING_FILE="$RUNNING_FILE" \
	LABTEST_RELEASE_FILE="$RELEASE_FILE" \
	MACDOWS_LAB_BOUNDARY_FILE="" \
	bash "$SBLAB/wdp-etw.command" >/dev/null 2>&1 &
WRAPPER_PID=$!
RUNNING_SEEN=0
SECONDS=0
while [ "$SECONDS" -lt 5 ]; do
	if [ -f "$RUNNING_FILE" ]; then
		RUNNING_SEEN=1
		break
	fi
	if ! kill -0 "$WRAPPER_PID" 2>/dev/null; then
		break
	fi
	sleep 0.1
done
SEEN=0
STILL_RUNNING=0
if [ "$RUNNING_SEEN" -eq 1 ]; then
	SECONDS=0
	while [ "$SECONDS" -lt 3 ]; do
		if grep -qF 'WS-OPEN' "$LOG" 2>/dev/null; then
			SEEN=1
			if [ -f "$RUNNING_FILE" ] && kill -0 "$WRAPPER_PID" 2>/dev/null; then
				STILL_RUNNING=1
			fi
			break
		fi
		sleep 0.1
	done
fi
: > "$RELEASE_FILE"
wait "$WRAPPER_PID"
if [ "$RUNNING_SEEN" -eq 1 ] && [ "$SEEN" -eq 1 ] && [ "$STILL_RUNNING" -eq 1 ] \
	&& assert_eq "$(last_line)" 'DONE exit=0' 'last log line'; then
	pass "$CASE: the running sentinel appeared within 5s and WS-OPEN reached etw.log within 3s of it, while the client stub was still blocked on its release file"
else
	fail "$CASE: running_seen=$RUNNING_SEEN seen=$SEEN still_running=$STILL_RUNNING"; note "log: $(tr '\n' ';' < "$LOG")"
fi

# ------------------------------------------------------------------------------------------
# Mutation proofs: the pins above must FAIL against a wrapper with the guard removed.
# ------------------------------------------------------------------------------------------

# M1. Boundary gate bypassed (the refusal branch's condition -> `if false`): the refused scenario
#     must now walk all the way to the client -- i.e. case 1's pin bites. This is the mutation
#     that matters most here: past the gate the wrapper writes the portal password to disk.
begin 'M1 gate-bypass mutant'
MUTANT_GATE="$SBLAB/labtest-mutant-gate.command"
# shellcheck disable=SC2016  # the single quotes are deliberate: sed must see the literal `$`
if sed 's/if \[ "\$GATE_RC" -ne 0 \]; then/if false; then/' "$SBLAB/wdp-etw.command" > "$MUTANT_GATE" \
	&& ! cmp -s "$MUTANT_GATE" "$SBLAB/wdp-etw.command" && bash -n "$MUTANT_GATE"; then
	mkdir -p "$SBWDP" || exit 1
	printf '%s\n' "$FAKE_FP" > "$PINFILE"
	write_job smoke 30 "$GOOD_PROVIDERS" 0
	run_etw "$MUTANT_GATE" "$DENY_FILE"
	if [ "$(client_calls)" = '1' ] && ! grep -qF 'BOUNDARY-REFUSED' "$LOG"; then
		pass "$CASE: detected -- the refused scenario reaches the client and a credential file is written (case 1 pins the gate)"
	else
		fail "$CASE: NOT detected -- case 1 would pass against a wrapper without the gate"
		note "client calls=$(client_calls) log: $(tr '\n' ';' < "$LOG")"
	fi
else
	fail "$CASE: could not build the mutant (the guard line moved?)"
fi

# M2. Credential removal disabled (the single `rm` inside etw_drop_cred -> `:`, which neuters the
#     inline call AND the EXIT trap, since both go through that one function): the happy path must
#     now leave the portal password sitting in TMPDIR -- i.e. case 17's `cred_files` pin bites.
begin 'M2 credential-removal mutant'
MUTANT_CRED="$SBLAB/labtest-mutant-cred.command"
# shellcheck disable=SC2016  # deliberate literal `$CRED` for sed
if sed 's/^    rm -f "\$CRED"$/    : # credential removal disabled by mutation/' "$SBLAB/wdp-etw.command" > "$MUTANT_CRED" \
	&& ! cmp -s "$MUTANT_CRED" "$SBLAB/wdp-etw.command" && bash -n "$MUTANT_CRED"; then
	mkdir -p "$SBWDP" || exit 1
	printf '%s\n' "$FAKE_FP" > "$PINFILE"
	write_job smoke 30 "$GOOD_PROVIDERS" 0
	run_etw "$MUTANT_CRED" ""
	leaked="$(cred_files)"
	leaked_body="$(cat "$CREDGLOB"* 2>/dev/null)"
	rm -f "$CREDGLOB"* 2>/dev/null || true
	if [ "$leaked" = '1' ] && [ "$leaked_body" = 'labtest-placeholder:LABTEST-PLACEHOLDER-SECRET-3f9a' ]; then
		pass "$CASE: detected -- the credential file survives the run with the password in it (case 17 pins the removal)"
	else
		fail "$CASE: NOT detected"; note "credential files=$leaked"
	fi
else
	fail "$CASE: could not build the mutant (the removal line moved?)"
fi

# M3. Log mask disabled (etw_sink's mask -> `cat`): the happy-path log must now carry the raw host
#     address -- i.e. case 18's pin bites. etw_sink is the only writer, so this one line is the
#     whole mask; a second writer added later would be caught by this proof going green for the
#     wrong reason only if it ALSO masked, which is the point of routing everything through it.
begin 'M3 log-mask mutant'
MUTANT_MASK="$SBLAB/labtest-mutant-mask.command"
# shellcheck disable=SC2016  # deliberate literal `$LOG` for sed
if sed 's/etw_mask >> "\$LOG"/cat >> "$LOG"/' "$SBLAB/wdp-etw.command" > "$MUTANT_MASK" \
	&& ! cmp -s "$MUTANT_MASK" "$SBLAB/wdp-etw.command" && bash -n "$MUTANT_MASK"; then
	mkdir -p "$SBWDP" || exit 1
	printf '%s\n' "$FAKE_FP" > "$PINFILE"
	write_job smoke 30 "$GOOD_PROVIDERS" 0
	run_etw "$MUTANT_MASK" "" 0 1
	if grep -qF '192.0.2.10' "$LOG" && grep -qF 'labtest-placeholder' "$LOG" && grep -qF "$SBHOME" "$LOG"; then
		pass "$CASE: detected -- the raw address, the account and the home path from the client's traceback all reach etw.log (case 18 pins the mask)"
	else
		fail "$CASE: NOT detected -- case 18 would pass against a wrapper with no mask"
		note "log: $(tr '\n' ';' < "$LOG")"
	fi
else
	fail "$CASE: could not build the mutant (etw_sink moved?)"
fi

# M4. The masking pipeline reverted to a single persistent `sed`/`cat` (etw_mask_pipe's old,
#     block-buffered body): case 26's WS-OPEN-while-still-running pin must now go red, because the
#     mutant's sed only flushes once the client's whole pipe closes. Built with python3 -- not sed
#     -- because the line being swapped is itself full of the shell metacharacters (`$`, `"`, `[`,
#     `]`) a sed BRE pattern would have to escape one by one; an exact, single-occurrence literal
#     match is what "the guard line moved" is supposed to catch, and a fragile regex would make
#     that check itself unreliable rather than the thing it is meant to protect.
#     The judgement (record m-1) is the causal claim itself, not a single point-in-time snapshot:
#     WS-OPEN must be ABSENT from etw.log throughout the whole window in which the client is
#     confirmed still running (sentinel present AND `kill -0` succeeds), and PRESENT only once the
#     client has actually exited. A single "not seen within N seconds" check cannot tell a real
#     block-buffering regression apart from a wrapper that is merely slow to start the client on a
#     loaded machine -- both would report "not seen" for an unrelated reason and this proof would
#     go green either way. Polling for absence continuously while the sentinel/kill-0 pair
#     confirms the client is alive removes that ambiguity: the slow-start case still eventually
#     shows the sentinel and then, on correctly line-buffered code, WS-OPEN soon after -- so it
#     would fail this proof's "absent while running" check instead of passing it for the wrong
#     reason.
begin 'M4 line-buffer mutant'
MUTANT_BUFFER="$SBLAB/labtest-mutant-buffer.command"
# shellcheck disable=SC2016  # deliberate literal `$1`/`$line`/`$script`: this is the exact source
# text being matched and replaced, not a shell expansion.
OLD_PIPE_LINE='etw_mask_pipe() { local script="$1" line; while IFS= read -r line || [ -n "$line" ]; do if [ -n "$script" ]; then printf "%s\n" "$line" | sed -e "$script"; else printf "%s\n" "$line"; fi; done; }'
# shellcheck disable=SC2016  # same reason: literal replacement text, not an expansion
NEW_PIPE_LINE='etw_mask_pipe() { local script="$1"; if [ -n "$script" ]; then sed -e "$script"; else cat; fi; }'
if python3 -B -c '
import sys
old, new, src, dst = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit(1)
with open(dst, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
' "$OLD_PIPE_LINE" "$NEW_PIPE_LINE" "$SBLAB/wdp-etw.command" "$MUTANT_BUFFER" \
	&& [ -s "$MUTANT_BUFFER" ] && ! cmp -s "$MUTANT_BUFFER" "$SBLAB/wdp-etw.command" && bash -n "$MUTANT_BUFFER"; then
	mkdir -p "$SBWDP" || exit 1
	printf '%s\n' "$FAKE_FP" > "$PINFILE"
	write_job smoke 30 "$GOOD_PROVIDERS" 0
	M4_RUNNING="$SB/m4-ws-open-running"
	M4_RELEASE="$SB/m4-ws-open-release"
	rm -f "$M4_RUNNING" "$M4_RELEASE"
	env -i \
		HOME="$SBHOME" \
		PATH="$SB/bin:$PATH" \
		TMPDIR="$SBTMP" \
		TERM_PROGRAM= \
		LABTEST_TRACE="$LABTEST_TRACE" \
		LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" \
		LABTEST_CLIENT_RC=0 \
		LABTEST_CLIENT_STDERR=0 \
		LABTEST_CLIENT_WS_OPEN=1 \
		LABTEST_RUNNING_FILE="$M4_RUNNING" \
		LABTEST_RELEASE_FILE="$M4_RELEASE" \
		MACDOWS_LAB_BOUNDARY_FILE="" \
		bash "$MUTANT_BUFFER" >/dev/null 2>&1 &
	M4_PID=$!
	# Bounded 5s wait for the sentinel (same budget as case 26): the mutant only changes the
	# masking pipeline downstream of the client, not the client itself, so the sentinel -- written
	# by the client stub directly to disk -- appears on the same schedule as in case 26.
	M4_RUNNING_SEEN=0
	SECONDS=0
	while [ "$SECONDS" -lt 5 ]; do
		if [ -f "$M4_RUNNING" ]; then
			M4_RUNNING_SEEN=1
			break
		fi
		if ! kill -0 "$M4_PID" 2>/dev/null; then
			break
		fi
		sleep 0.1
	done
	# Poll for the WHOLE 3s window the sentinel is confirmed live, not just once: a single
	# point-in-time check cannot distinguish "genuinely absent throughout" from "we happened to
	# look before it appeared", and the latter would let this proof pass for the wrong reason.
	M4_SEEN_WHILE_RUNNING=0
	if [ "$M4_RUNNING_SEEN" -eq 1 ]; then
		SECONDS=0
		while [ "$SECONDS" -lt 3 ] && [ -f "$M4_RUNNING" ] && kill -0 "$M4_PID" 2>/dev/null; do
			if grep -qF 'WS-OPEN' "$LOG" 2>/dev/null; then
				M4_SEEN_WHILE_RUNNING=1
			fi
			sleep 0.1
		done
	fi
	: > "$M4_RELEASE"
	wait "$M4_PID"
	if [ "$M4_RUNNING_SEEN" -eq 1 ] && [ "$M4_SEEN_WHILE_RUNNING" -eq 0 ] && grep -qF 'WS-OPEN' "$LOG" 2>/dev/null; then
		pass "$CASE: detected -- WS-OPEN never reached etw.log while the client stub was confirmed still running (sentinel present, kill -0 succeeded), only after it exited (case 26 pins the per-line flush)"
	else
		fail "$CASE: NOT detected -- case 26 would pass against the old block-buffered pipe (running_seen=$M4_RUNNING_SEEN seen-while-running=$M4_SEEN_WHILE_RUNNING)"
	fi
else
	fail "$CASE: could not build the mutant (etw_mask_pipe's line moved?)"
fi

# M5. The line grammar removed (its verdict -> the empty string, i.e. "no bad line"): a job file
#     whose unquoted value is an assignment prefixed to a COMMAND must now execute that command --
#     i.e. case 13b's witness pin bites. The `</dev/null` on the source stays, which is why the
#     mutant merely RUNS the command instead of hanging on it: that redirection is defence in depth
#     BEHIND the grammar, and this is the measurement that says so. With the grammar gone it is the
#     only thing between a job file and a wrapper that never writes a DONE line at all.
begin 'M5 line-grammar mutant'
MUTANT_GRAMMAR="$SBLAB/labtest-mutant-grammar.command"
# shellcheck disable=SC2016  # sed must see the literal $BAD_LINE, and the replacement must too
if sed 's|^elif BAD_LINE=.*; \[ -n "$BAD_LINE" \]; then$|elif BAD_LINE=""; [ -n "$BAD_LINE" ]; then|' \
	"$SBLAB/wdp-etw.command" > "$MUTANT_GRAMMAR" \
	&& ! cmp -s "$MUTANT_GRAMMAR" "$SBLAB/wdp-etw.command" && bash -n "$MUTANT_GRAMMAR"; then
	printf 'TAG=a labtest-stdin-cmd\nDURATION=30\nPROVIDERS=%s\nPIN_RECORD=0\n' "'$GOOD_PROVIDERS'" > "$JOB"
	run_etw "$MUTANT_GRAMMAR" "" &
	M5_PID=$!
	waited=0
	while kill -0 "$M5_PID" 2>/dev/null && [ "$waited" -lt 50 ]; do
		sleep 0.1
		waited=$((waited + 1))
	done
	M5_HUNG=0
	if kill -0 "$M5_PID" 2>/dev/null; then
		kill -9 "$M5_PID" 2>/dev/null
		M5_HUNG=1
	fi
	wait "$M5_PID" 2>/dev/null
	if grep -q '^job-line-executed$' "$LABTEST_TRACE" || [ "$M5_HUNG" -eq 1 ]; then
		pass "$CASE: detected -- the job file's own command line ran (executed=$(grep -c '^job-line-executed$' "$LABTEST_TRACE" 2>/dev/null || true) hung=$M5_HUNG), which case 13b refuses"
	else
		fail "$CASE: NOT detected -- case 13b would pass against a wrapper without the line grammar"
		note "log: $(tr '\n' ';' < "$LOG")"
	fi
else
	fail "$CASE: could not build the mutant (the grammar's elif moved?)"
fi

# M6. The PIN_TRUST_ROTATION gate removed (the rotation block's `[ "$PIN_TRUST_ROTATION" = "1" ] &&`
#     deleted, so the pre-check and the rotation run for EVERY job that has a valid pin): case
#     16c's scenario -- a stale pin and no knob -- must now dial and rotate, i.e. 16c's "no
#     openssl call, no archive, pin untouched" pins bite. This is the proof that the knob is what
#     admits the rotation, not merely what names it.
begin 'M6 rotation-gate mutant'
MUTANT_ROTATE="$SBLAB/labtest-mutant-rotate.command"
# shellcheck disable=SC2016  # deliberate literal `$PIN_TRUST_ROTATION` / `$PIN_BAD` for sed
if sed 's/if \[ "\$PIN_TRUST_ROTATION" = "1" \] && \[ "\$PIN_BAD" -eq 0 \]/if [ "$PIN_BAD" -eq 0 ]/' \
	"$SBLAB/wdp-etw.command" > "$MUTANT_ROTATE" \
	&& ! cmp -s "$MUTANT_ROTATE" "$SBLAB/wdp-etw.command" && bash -n "$MUTANT_ROTATE"; then
	mkdir -p "$SBWDP" || exit 1
	printf '%s\n' "$STALE_FP" > "$PINFILE"
	write_job smoke 30 "$GOOD_PROVIDERS" 0
	run_etw "$MUTANT_ROTATE" "" 79
	if [ "$(openssl_calls)" = '2' ] && [ "$(archive_count)" = '1' ] && [ "$(cat "$PINFILE" 2>/dev/null)" = "$FAKE_HEX" ]; then
		pass "$CASE: detected -- without the gate a job with no knob dials, archives and rewrites the pin (case 16c pins the gate)"
	else
		fail "$CASE: NOT detected -- case 16c would pass against a wrapper that rotates without the knob (openssl=$(openssl_calls) archives=$(archive_count))"
		note "log: $(tr '\n' ';' < "$LOG")"
	fi
else
	fail "$CASE: could not build the mutant (the rotation guard line moved?)"
fi

# M7. The no-clobber archive link weakened (`ln` -> `ln -f`): case 16h's pre-created archive must
#     now be overwritten by the old pin and the rotation must go through -- i.e. 16h's "sentinel
#     intact / PIN-ROTATION-FAILED / old pin still the pin" pins bite. (`mv` in that line fails
#     16h the same way, by renaming over the sentinel; one mutant suffices to show the case bites.)
begin 'M7 archive no-clobber mutant'
RUN_ETW_PATH="$DATE_PATH"
MUTANT_LN="$SBLAB/labtest-mutant-ln.command"
# shellcheck disable=SC2016  # deliberate literal `$PINFILE` / `$ARCHIVE` for sed
if sed 's/&& ln "\$PINFILE" "\$ARCHIVE" 2>\/dev\/null/\&\& ln -f "$PINFILE" "$ARCHIVE" 2>\/dev\/null/' \
	"$SBLAB/wdp-etw.command" > "$MUTANT_LN" \
	&& ! cmp -s "$MUTANT_LN" "$SBLAB/wdp-etw.command" && bash -n "$MUTANT_LN"; then
	mkdir -p "$SBWDP" || exit 1
	printf '%s\n' "$STALE_FP" > "$PINFILE"
	archive="$PINFILE.until-$ROTATION_STAMP-rotation"
	printf 'LABTEST-EARLIER-ARCHIVE-SENTINEL\n' > "$archive"
	write_job smoke 30 "$GOOD_PROVIDERS" 0 1
	run_etw "$MUTANT_LN" "" 79
	if [ "$(cat "$archive" 2>/dev/null)" = "$STALE_FP" ] && [ "$(cat "$PINFILE" 2>/dev/null)" = "$FAKE_HEX" ] && grep -qF 'CERT-PIN-ROTATED' "$LOG"; then
		pass "$CASE: detected -- ln -f overwrote the earlier archive's sentinel with the old pin and the rotation went through (case 16h pins the no-clobber link)"
	else
		fail "$CASE: NOT detected -- case 16h would pass against a wrapper that clobbers an existing archive (archive=[$(cat "$archive" 2>/dev/null)] pin=[$(cat "$PINFILE" 2>/dev/null)])"
		note "log: $(tr '\n' ';' < "$LOG")"
	fi
else
	fail "$CASE: could not build the mutant (the ln line moved?)"
fi

# M8. The disagreement line's "did this run rotate?" half removed (its guard reduced to the exit
#     code alone), so ANY capture that ends at the client's 79 claims the dial and the capture were
#     shown different certificates: case 16l's no-rotation legs must go red. Without this half the
#     line would fire on every ordinary pin mismatch -- the exact reading it exists to prevent --
#     and a rotation that really did disagree would be indistinguishable from it.
begin 'M8 disagreement-line mutant'
MUTANT_MISMATCH="$SBLAB/labtest-mutant-mismatch.command"
# shellcheck disable=SC2016  # deliberate literal `$ETW_ROTATED` / `$ETW_RC` for sed
if sed 's/if \[ "\$ETW_ROTATED" -eq 1 \] && \[ "\$ETW_RC" -eq 79 \]/if [ "$ETW_RC" -eq 79 ]/' \
	"$SBLAB/wdp-etw.command" > "$MUTANT_MISMATCH" \
	&& ! cmp -s "$MUTANT_MISMATCH" "$SBLAB/wdp-etw.command" && bash -n "$MUTANT_MISMATCH"; then
	mkdir -p "$SBWDP" || exit 1
	printf '%s\n' "$FAKE_FP" > "$PINFILE"
	write_job smoke 30 "$GOOD_PROVIDERS" 0 1
	run_etw "$MUTANT_MISMATCH" "" 79
	if grep -qF 'PIN-ROTATED-THEN-MISMATCHED' "$LOG" && [ "$(log_count 'CERT-PIN-ROTATED')" = '0' ]; then
		pass "$CASE: detected -- a run that rotated nothing reports the certificates as disagreeing (case 16l pins the rotation half of the guard)"
	else
		fail "$CASE: NOT detected -- case 16l would pass against a wrapper that prints the line on the exit code alone"
		note "log: $(tr '\n' ';' < "$LOG")"
	fi
else
	fail "$CASE: could not build the mutant (the disagreement guard moved?)"
fi

# M9. The rotations record's append weakened to a truncating redirection: case 16m's "two
#     rotations leave two lines" must go red, because each rotation would overwrite the last. The
#     file is the ONLY durable trace of a rotation once etw.log has been truncated, so a record
#     that keeps just the most recent line is not a record -- it is the log line again, one file
#     further away.
begin 'M9 rotations-record truncate mutant'
RUN_ETW_PATH="$DATE_PATH"
MUTANT_ROTLOG="$SBLAB/labtest-mutant-rotlog.command"
# shellcheck disable=SC2016  # deliberate literal `$ROTLOG` for sed
if sed 's/etw_mask >> "\$ROTLOG"/etw_mask > "$ROTLOG"/' \
	"$SBLAB/wdp-etw.command" > "$MUTANT_ROTLOG" \
	&& ! cmp -s "$MUTANT_ROTLOG" "$SBLAB/wdp-etw.command" && bash -n "$MUTANT_ROTLOG"; then
	mkdir -p "$SBWDP" || exit 1
	write_job smoke 30 "$GOOD_PROVIDERS" 0 1
	printf '%s\n' "$STALE_FP" > "$PINFILE"
	run_etw "$MUTANT_ROTLOG" ""
	rm -f "$PINFILE.until-$ROTATION_STAMP-rotation"
	printf '%s\n' "$STALE_FP" > "$PINFILE"
	run_etw "$MUTANT_ROTLOG" ""
	if [ "$(rotlog_lines)" = '1' ]; then
		pass "$CASE: detected -- the second rotation overwrote the first one's line (case 16m pins the append)"
	else
		fail "$CASE: NOT detected -- case 16m would pass against a record that is rewritten rather than appended to (lines=$(rotlog_lines))"
		note "record: $(if [ -f "$ROTLOG" ]; then tr '\n' ';' < "$ROTLOG"; fi)"
	fi
else
	fail "$CASE: could not build the mutant (the rotations record's write moved?)"
fi

# Every case must have reported: a case that neither passed nor failed would otherwise vanish
# from the tally with exit 0. Placed after the LAST case on purpose.
EXPECTED_CASES=62
if [ $((PASSES + FAILURES)) -ne "$EXPECTED_CASES" ]; then
	fail "case tally: $((PASSES + FAILURES)) cases reported, expected $EXPECTED_CASES -- a case produced no verdict"
fi
printf '\n%d passed, %d failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
