#!/usr/bin/env bash
# Offline test suite for Scripts/lab/wdp-etw.command -- the Terminal.app launcher that captures a
# realtime ETW session from the test host's Windows Device Portal. The wrapper is the only thing
# in this repo that ever holds the host's portal credential in a file, so its guards are the ones
# that must not be allowed to rot: the fail-closed boundary gate BEFORE any credential exists, the
# etw-job.env contract, the "an existing certificate pin is never overwritten" rule, the credential
# file's lifecycle (0600, removed on every exit path) and the log mask that keeps etw.log
# paste-safe. None of that is covered by test-relay-offline.sh -- the relay and the wrapper share
# only their idioms, not a line of code.
#
# Safe in CI, by construction rather than by promise:
#   1. `osascript`, `open` and `openssl` are PATH-shimmed, and the suite ASSERTS before the first
#      case that PATH resolves each of them to the shim. The openssl shim opens no socket; it
#      records its argv and answers `x509` with a fixed fingerprint line.
#   2. `python3` is deliberately NOT shimmed -- Scripts/lib.sh's boundary gate evaluates the
#      segments with the REAL python3, and a shim there would replace the thing under test. The
#      capture client is stubbed at its own path instead: the sandbox's Scripts/lab/wdp_etw.py is
#      written by this suite and records the WDP_* environment, the credential file's mode and
#      contents and its argv, then exits with LABTEST_CLIENT_RC. It opens no socket either.
#   3. HOME is redirected into the sandbox. Its host.env carries an RFC 5737 documentation
#      address and placeholder account strings (never a real host, never a real credential), and
#      the placeholder password is greppable because one case asserts it never reaches the log.
#   4. wdp-etw.command is copied into a sandbox tree at the same depth as the real one, so its own
#      `$LAB_DIR/../..` derivation lands REPO_ROOT (and therefore .build/lab-runtime/wdp,
#      etw-job.env and etw.log) inside the sandbox. The real runtime is never touched.
#   5. TMPDIR is redirected into the sandbox, so the credential file the wrapper mktemps is
#      created, counted and (on every passing path) found gone inside $SB.
#   6. TERM_PROGRAM is cleared, so the Terminal self-close branch is never taken; the osascript
#      shim exits 97 and records into a trace that is NOT reset between cases, so the "never
#      reached" assertion at the end covers the whole run.
#
# Each case starts with `begin`, which resets the per-case trace, the sandbox log and the job
# instance, so no case depends on what the previous one left behind. Three mutation proofs
# (M1 gate bypassed, M2 credential removal disabled, M3 log mask disabled) copy the wrapper with
# one guard removed and require the case that claims to pin it to FAIL against the mutant. A pin
# that would also pass against the broken code pins nothing.
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

SBROOT="$SB/root"
SBLAB="$SBROOT/Scripts/lab"
SBRUNTIME="$SBROOT/.build/lab-runtime"
SBWDP="$SBRUNTIME/wdp"
SBHOME="$SB/home"
SBTMP="$SB/tmp"
LOG="$SBRUNTIME/etw.log"
JOB="$SBRUNTIME/etw-job.env"
PINFILE="$SBWDP/portal-cert-sha256.txt"
# The credential file's template. The wrapper mktemps it under TMPDIR, which this suite redirects
# into the sandbox, so "how many credential files exist right now" is an exact question here.
CREDGLOB="$SBTMP/macdows-etw-cred."
# Per-case trace of client/openssl invocations (reset by `begin`) and a run-long trace of the
# shims that must never be reached (never reset).
export LABTEST_TRACE="$SB/trace.txt"
export LABTEST_REFUSED_TRACE="$SB/refused-trace.txt"
: > "$LABTEST_REFUSED_TRACE"

mkdir -p "$SBLAB/jobs" "$SBHOME/.config/macdows" "$SB/bin" "$SBTMP" || exit 1
cp "$LAB/wdp-etw.command" "$SBLAB/wdp-etw.command" || exit 1
cp "$LAB/run-scenario.sh" "$SBLAB/run-scenario.sh" || exit 1
cp "$LAB"/jobs/*.env "$SBLAB/jobs/" || exit 1
mkdir -p "$SBROOT/Scripts" || exit 1
cp "$REPO_ROOT/Scripts/lib.sh" "$SBROOT/Scripts/lib.sh" || exit 1
# NB $SBRUNTIME is deliberately NOT pre-created: the wrapper's own `mkdir -p` has to make it
# (case 0 pins that explicitly).

# RFC 5737 TEST-NET-1 address and placeholder strings: never a real host, never a real credential.
cat > "$SBHOME/.config/macdows/host.env" <<'HOSTENV' || exit 1
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

lines = ["client-run"]
for key in sorted(os.environ):
    if key.startswith("WDP_"):
        lines.append("client-env %s=%s" % (key, os.environ[key]))
cred = os.environ.get("WDP_CRED_FILE", "")
if cred and os.path.exists(cred):
    lines.append("client-cred-mode %04o" % (os.stat(cred).st_mode & 0o7777))
    with open(cred) as handle:
        lines.append("client-cred-body %s" % handle.read().strip())
else:
    lines.append("client-cred-absent %s" % cred)
lines.append("client-argv " + " ".join("[%s]" % arg for arg in sys.argv))
with open(os.environ["LABTEST_TRACE"], "a") as handle:
    handle.write("\n".join(lines) + "\n")
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
cat > "$SB/bin/osascript" <<'SHIM_OSA' || exit 1
#!/usr/bin/env bash
# OFFLINE TEST SHIM: must never be reached (run-long trace, never reset).
printf 'osascript:unexpected-call\n' >> "$LABTEST_REFUSED_TRACE"
exit 97
SHIM_OSA
chmod +x "$SB"/bin/* || exit 1
for shim in "$SB"/bin/*; do
	if ! bash -n "$shim"; then printf 'shim does not parse: %s\n' "$shim"; exit 1; fi
done
# The load-bearing safety assertion: with the sandbox PATH in force, each shimmed name MUST
# resolve to the shim -- otherwise a case would run the maintainer's real openssl against the
# placeholder address, or open a Terminal window. Checked before any case runs.
for tool in openssl open osascript; do
	resolved="$(PATH="$SB/bin:$PATH" command -v "$tool" || true)"
	if [ "$resolved" != "$SB/bin/$tool" ]; then
		printf 'ABORT: %s resolves to %s, not the shim\n' "$tool" "${resolved:-<nothing>}"
		exit 1
	fi
done
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
	rm -f "$LOG" "$JOB" "$PINFILE"
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
# How many credential files exist under the sandbox TMPDIR right now. On every path the wrapper
# takes this must be 0 after the run: either it never made one, or it removed the one it made.
cred_files() { find "$SBTMP" -name 'macdows-etw-cred.*' -type f 2>/dev/null | wc -l | tr -d ' '; }

write_job() { # <TAG> <DURATION> <PROVIDERS> <PIN_RECORD>  (empty argument = key omitted)
	{
		if [ -n "${1:-}" ]; then printf 'TAG=%s\n' "$1"; fi
		if [ -n "${2:-}" ]; then printf 'DURATION=%s\n' "$2"; fi
		if [ -n "${3:-}" ]; then printf "PROVIDERS='%s'\n" "$3"; fi
		if [ -n "${4:-}" ]; then printf 'PIN_RECORD=%s\n' "$4"; fi
	} > "$JOB"
}

# The five public Microsoft provider GUIDs the shipped job uses, at level 5.
GOOD_PROVIDERS='1139c61b-b549-4251-8ed3-27250a1edec8:5;c76baa63-ae81-421c-b425-340b4b24157f:5'

# Runs the wrapper (or a mutant copy) with the sandbox environment. Everything it reads comes from
# HOME/PATH/TMPDIR/etw-job.env; TERM_PROGRAM is cleared so the Terminal self-close branch is not
# taken. <boundary-file> empty = MACDOWS_LAB_BOUNDARY_FILE is passed EMPTY, which lib.sh's
# `${MACDOWS_LAB_BOUNDARY_FILE:-…}` treats exactly like unset: the wrapper resolves the DEFAULT
# path under the sandbox HOME, as it does live. (A plain variable, not an array -- `"${arr[@]}"`
# on an empty array is an unbound-variable error under bash 3.2 + `set -u`.)
run_etw() { # <wrapper-path> <boundary-file|""> [client-rc]
	env -i \
		HOME="$SBHOME" \
		PATH="$SB/bin:$PATH" \
		TMPDIR="$SBTMP" \
		TERM_PROGRAM= \
		LABTEST_TRACE="$LABTEST_TRACE" \
		LABTEST_REFUSED_TRACE="$LABTEST_REFUSED_TRACE" \
		LABTEST_CLIENT_RC="${3:-0}" \
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
	&& assert_lacks "$LOG" 'LABTEST-PLACEHOLDER-SECRET-3f9a'; then
	pass "$CASE: BOUNDARY-REFUSED logged, DONE exit=78, no client, no openssl, no credential file, no credential in the log"
fi

# 2. Boundary file missing at the DEFAULT location (HOME has no lab-boundary.env): fail-closed,
#    same shape as 1. Exercises the wrapper's default-path resolution, not an injected path.
begin '2 boundary file missing (default path)'
mv "$ALLOW_FILE" "$ALLOW_FILE.away" || exit 1
write_job smoke 30 "$GOOD_PROVIDERS" 0
run_etw "$SBLAB/wdp-etw.command" ""
mv "$ALLOW_FILE.away" "$ALLOW_FILE" || exit 1
if assert_has "$LOG" 'BOUNDARY-REFUSED' && assert_eq "$(last_line)" 'DONE exit=78' 'last log line' \
	&& assert_eq "$(client_calls)" '0' 'client invocations' && assert_eq "$(cred_files)" '0' 'credential files under TMPDIR'; then
	pass "$CASE: fail-closed refusal through the default boundary path, no client, no credential file"
fi

# 3. etw-job.env missing: the wrapper must still report -- a DONE line with a distinct sysexits
#    code (66 EX_NOINPUT) and a named reason -- rather than die on `set -u` and leave the caller
#    to its own timeout.
begin '3 etw-job.env missing'
run_etw "$SBLAB/wdp-etw.command" ""
if assert_has "$LOG" 'JOB-ENV-MISSING' && assert_eq "$(last_line)" 'DONE exit=66' 'last log line' \
	&& assert_eq "$(client_calls)" '0' 'client invocations' && assert_eq "$(cred_files)" '0' 'credential files under TMPDIR'; then
	pass "$CASE: JOB-ENV-MISSING logged, DONE exit=66, no client, no credential file"
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
		&& assert_eq "$(cred_files)" '0' 'credential files under TMPDIR'; then
		pass "$CASE: $4 -- JOB-ENV-INVALID, DONE exit=65, no client, no openssl, no credential file"
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

# 13. A value that spans lines shifts every following key, so the sentinel line is what proves the
#     read stayed aligned. Refused as JOB-ENV-INVALID rather than acted on with keys that silently
#     hold the wrong values (same failure the relay's sentinel closes).
case_invalid '13 multi-line job value' \
	"TAG=smoke
PROVIDERS='1139c61b-b549-4251-8ed3-27250a1edec8:5
c76baa63-ae81-421c-b425-340b4b24157f:5'
" 'spans more than one line' 'a PROVIDERS value with an embedded newline'

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
	&& [ ! -f "$PINFILE" ]; then
	pass "$CASE: PIN-MISSING logged with the way out, DONE exit=79, no client, no credential file, no pin invented"
fi

# 15. Pin missing and PIN_RECORD=1: the wrapper records it ONCE, with the documented openssl
#     pipeline, and only then proceeds. The argv is pinned literally because it is the whole
#     recording: `-servername` is what makes the portal present the certificate the capture will
#     later be pinned against, and it is invoked only AFTER the boundary gate approved the host.
begin '15 pin missing, PIN_RECORD=1 records it'
write_job smoke 30 "$GOOD_PROVIDERS" 1
run_etw "$SBLAB/wdp-etw.command" ""
sclient="$(grep '^openssl \[s_client\]' "$LABTEST_TRACE" | head -n 1)"
x509="$(grep '^openssl \[x509\]' "$LABTEST_TRACE" | head -n 1)"
if assert_eq "$sclient" 'openssl [s_client] [-connect] [192.0.2.10:50443] [-servername] [192.0.2.10]' 's_client argv' \
	&& assert_eq "$x509" 'openssl [x509] [-noout] [-fingerprint] [-sha256]' 'x509 argv' \
	&& assert_eq "$(cat "$PINFILE" 2>/dev/null)" "$FAKE_FP" 'recorded pin file' \
	&& assert_has "$LOG" "pin recorded sha256=$FAKE_FP" \
	&& assert_eq "$(client_calls)" '1' 'client invocations' \
	&& assert_eq "$(client_env "WDP_CERT_SHA256=$FAKE_FP")" '1' 'WDP_CERT_SHA256 handed to the client' \
	&& assert_eq "$(last_line)" 'DONE exit=0' 'last log line'; then
	pass "$CASE: openssl s_client|x509 with the documented argv, the fingerprint written to the pin file and handed to the client, DONE exit=0"
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
grep -qF "client-argv [$SBLAB/wdp_etw.py]" "$LABTEST_TRACE" || reasons="$reasons client-argv=[$(grep '^client-argv' "$LABTEST_TRACE")];"
[ "$(cred_files)" = '0' ] || reasons="$reasons credential-file-survived-the-run;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
[ -f "$SBWDP/etw-smoke.log" ] || reasons="$reasons no-per-tag-log-copy;"
if [ -z "$reasons" ]; then
	pass "$CASE: the client saw exactly the seven documented WDP_* values, a 0600 credential file holding <user>:<password>, and nothing else; the credential file is gone; DONE exit=0; etw-smoke.log kept"
else
	fail "$CASE:$reasons"; note "trace: $(tr '\n' ';' < "$LABTEST_TRACE")"
fi

# 18. etw.log is what a human pastes into a report, so the address and the account appear only in
#     their masked form and the password not at all. The masked forms have to BE there: an empty
#     mask would satisfy a "does not contain" assertion on its own.
begin '18 log mask'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$FAKE_FP" > "$PINFILE"
write_job smoke 30 "$GOOD_PROVIDERS" 0
run_etw "$SBLAB/wdp-etw.command" ""
if assert_has "$LOG" '<WIN_HOST>' && assert_has "$LOG" '<WIN_USER>' \
	&& assert_lacks "$LOG" '192.0.2.10' && assert_lacks "$LOG" 'labtest-placeholder' \
	&& assert_lacks "$LOG" 'LABTEST-PLACEHOLDER-SECRET-3f9a' \
	&& [ -f "$SBWDP/etw-smoke.log" ] && assert_lacks "$SBWDP/etw-smoke.log" '192.0.2.10' \
	&& assert_has "$SBWDP/etw-smoke.log" '<WIN_HOST>'; then
	pass "$CASE: etw.log and its per-TAG copy carry <WIN_HOST>/<WIN_USER> and neither the address, the account nor the password"
fi

# 19. A hand-edited CRLF job.env must not ship a bare CR into a file name, into a regex or into the
#     client's environment: every value's trailing CR is stripped, so the job is ACCEPTED and the
#     capture runs with exactly the values the file spells.
begin '19 CRLF job file'
mkdir -p "$SBWDP" || exit 1
printf '%s\n' "$FAKE_FP" > "$PINFILE"
printf 'TAG=smoke\r\nDURATION=30\r\nPROVIDERS=%s\r\nPIN_RECORD=0\r\n' "'$GOOD_PROVIDERS'" > "$JOB"
run_etw "$SBLAB/wdp-etw.command" ""
reasons=''
[ "$(client_calls)" = '1' ] || reasons="$reasons client-calls=$(client_calls);"
[ "$(client_env 'WDP_DURATION=30')" = '1' ] || reasons="$reasons WDP_DURATION;"
[ "$(client_env "WDP_PROVIDERS=$GOOD_PROVIDERS")" = '1' ] || reasons="$reasons WDP_PROVIDERS;"
[ "$(client_env "WDP_OUT=$SBWDP/etw-smoke.jsonl")" = '1' ] || reasons="$reasons WDP_OUT;"
grep -q "$(printf '\r')" "$LABTEST_TRACE" && reasons="$reasons bare-CR-reached-the-client;"
[ "$(last_line)" = 'DONE exit=0' ] || reasons="$reasons last-line=[$(last_line)];"
if [ -z "$reasons" ]; then
	pass "$CASE: trailing CRs are stripped from TAG/DURATION/PROVIDERS/PIN_RECORD; the job is accepted and no CR reaches the client"
else
	fail "$CASE:$reasons"; note "trace: $(tr '\n' ';' < "$LABTEST_TRACE")"
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
begin '23 the python unit suites pass'
missing=''
for module in test_wdp_etw.py test_etw_summarize.py; do
	[ -f "$LAB/$module" ] || missing="$missing $module"
done
if [ -n "$missing" ]; then
	fail "$CASE: Scripts/lab is missing:$missing -- the ETW lane's python suites cannot run"
elif (cd "$LAB" && python3 -m unittest test_wdp_etw test_etw_summarize) > "$SB/unittest.txt" 2>&1; then
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
	run_etw "$MUTANT_MASK" ""
	if grep -qF '192.0.2.10' "$LOG" && grep -qF 'labtest-placeholder' "$LOG"; then
		pass "$CASE: detected -- the raw address and account reach etw.log (case 18 pins the mask)"
	else
		fail "$CASE: NOT detected -- case 18 would pass against a wrapper with no mask"
		note "log: $(tr '\n' ';' < "$LOG")"
	fi
else
	fail "$CASE: could not build the mutant (etw_sink moved?)"
fi

# Every case must have reported: a case that neither passed nor failed would otherwise vanish
# from the tally with exit 0. Placed after the LAST case on purpose.
EXPECTED_CASES=30
if [ $((PASSES + FAILURES)) -ne "$EXPECTED_CASES" ]; then
	fail "case tally: $((PASSES + FAILURES)) cases reported, expected $EXPECTED_CASES -- a case produced no verdict"
fi
printf '\n%d passed, %d failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
