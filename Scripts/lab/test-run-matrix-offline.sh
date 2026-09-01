#!/usr/bin/env bash
# test-run-matrix-offline.sh -- offline guard test for run-matrix.sh.
#
#   ./test-run-matrix-offline.sh [--keep]
#
# Drives the REAL run-matrix.sh (and the real run-scenario.sh, the real jobs/*.env, the real
# share/*.ps1 that its staging step copies, and the real Scripts/lib.sh boundary gate) through
# every verdict it can produce, in a throwaway sandbox, in a few seconds. The WAIT_* knobs at
# the top of run-matrix.sh exist for exactly this: the code path under test is the shipping
# one, not a paraphrase of it in a test.
#
# OFFLINE BY CONSTRUCTION -- this is the property that matters, so it is enforced three ways
# rather than promised in a comment:
#   1. `open` is PATH-shimmed. It never launches Terminal.app and never executes the .command
#      files; it writes the artefacts a real relay/probe run would have left behind. That is
#      the whole seam -- `open -a Terminal <x>.command` is the single point where this harness
#      crosses from the Mac side to a live connection, in run-matrix.sh (probe.command) and in
#      run-scenario.sh (relay.command) alike. Nothing test-only had to be added to either file.
#   2. relay.command and probe.command are deliberately NOT copied into the sandbox. Even a bug
#      in the shim cannot execute a relay that is not there.
#   3. `xfreerdp`, `nc` and `osascript` are PATH-shimmed to refuse loudly (exit 97). If a future
#      change ever does reach for a live connection from here, the test fails; it does not dial.
#      `pgrep` is shimmed to "nothing running" so the real machine's process table cannot decide
#      this test's timing.
# HOME is redirected too, so the owner's real ~/.config/macdows/host.env and lab-boundary.env
# are never read and the real target address never enters this process. The sandbox host.env
# carries an RFC 5737 documentation address and no credentials at all.
#
# Everything is written under a mktemp sandbox: the real .build/evidence/tsallowlist-matrix.log,
# the real .build/lab-runtime/relay.log and the real runtime share/*-out.txt are never touched.
# --keep leaves the sandbox (with each case's captured output) in place for inspection.
#
# SANDBOX LAYOUT mirrors the real one exactly, because run-matrix.sh derives both halves of it
# from its own location and nothing may be overridden (that is the point -- an override knob
# would be a way for the shipping script and the test to disagree):
#   <sb>/root/Scripts/lab/          the tracked scripts under test, copied in fresh
#   <sb>/root/.build/lab-runtime/   the artefacts a run produces, created by the code under test
#
# Three of the cases are MUTATION PROOFS: they delete one guard from a sandbox COPY of
# run-matrix.sh and require the case that claims to pin it to fail. A pin that would also pass
# against the broken code pins nothing, and two of this suite's cases were exactly that until
# review measured it. See mutate_delete_block.
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

SB="$(mktemp -d "${TMPDIR:-/tmp}/macdows-matrix-offline.XXXXXX")" || exit 1
# shellcheck disable=SC2329,SC2317  # invoked by the EXIT trap below (0.11 emits SC2329, older CI shellcheck emits SC2317 for the same indirect-invocation shape)
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
SBSHARE="$SBRUNTIME/share"
export LABTEST_TRACE="$SB/trace.txt"

# Content census of the sandbox's TRACKED tree, used to prove a run writes nothing into it.
# cksum rather than shasum/sha256sum: it is POSIX, present on every runner this suite has to
# work on, and the requirement here is change detection, not a security property. Names are
# included as well as contents, so an added or deleted file is caught too.
#
# Defined up here, before the sandbox is built, because the PRISTINE census has to be taken the
# moment construction finishes -- see TRACKED_PRISTINE below and case 16.
#
# `labtest-mutant-*` is skipped: those are the mutation proofs' own scratch copies, written into
# the sandbox lab dir by THIS FILE (they have to sit at that exact depth, because run-matrix.sh
# derives REPO_ROOT from its own location). The prefix is a namespace no shipping script
# produces or reads, so excluding it cannot mask a write by the code under test -- which is why
# the mutants were renamed off `run-matrix.*.sh` when this census became a whole-suite
# invariant: an exclusion pattern has to be obviously test-owned to be safe.
snapshot_tracked() {
	(
		cd "$SBLAB" || exit 1
		find . -type f ! -name 'labtest-mutant-*' | sort | while IFS= read -r f; do
			printf '%s  %s\n' "$(cksum < "$f")" "$f"
		done
	)
}

# ------------------------------------------------------------------------------------------
# Sandbox
# ------------------------------------------------------------------------------------------

# NB $SBRUNTIME is deliberately NOT pre-created: run-matrix.sh's own staging step has to make
# it, and a sandbox that handed it the directory would hide a regression in exactly the code
# this refactor introduced.
mkdir -p "$SBLAB/jobs" "$SBLAB/share" "$SBROOT/Tools/host-agent" \
	"$SB/bin" "$SB/home/.config/macdows" "$SB/fixtures" || exit 1

# The files under test, copied fresh on every run so the sandbox cannot drift from the
# originals. NB probe.command / relay.command are NOT among them, on purpose (see header).
cp "$LAB/run-matrix.sh" "$SBLAB/run-matrix.sh" || exit 1
cp "$LAB/run-scenario.sh" "$SBLAB/run-scenario.sh" || exit 1
cp "$LAB"/jobs/*.env "$SBLAB/jobs/" || exit 1
cp "$REPO_ROOT/Scripts/lib.sh" "$SBROOT/Scripts/lib.sh" || exit 1
printf 'offline test placeholder\n' > "$SBROOT/Tools/host-agent/placeholder.txt"

# The real host-side scripts, ALL of them including the *.Tests.ps1 -- so that the staging
# step's exclusion of the test suites is measured against the real directory rather than
# against a sandbox that never contained them. They are only ever copied here: nothing in this
# sandbox runs PowerShell, and the host they are written for does not exist.
cp "$LAB"/share/*.ps1 "$SBLAB/share/" || exit 1

# The tracked tree exactly as construction left it, captured ONCE, before any case has run.
# Case 16 diffs the post-run census against THIS, not against a census taken inside case 16
# itself: a same-case before/after is blind to any write that happens identically on every run,
# because the "before" already contains it. Measured in review -- a mutation that wrote job.env
# into the tracked lab dir on every single case left that weaker form green. This makes the
# "a run writes nothing into the tracked tree" claim an invariant over the WHOLE suite.
TRACKED_PRISTINE="$SB/tracked-pristine.txt"
snapshot_tracked > "$TRACKED_PRISTINE" || exit 1

# -- PATH shims ------------------------------------------------------------------------------

cat > "$SB/bin/open" <<'SHIM_OPEN'
#!/usr/bin/env bash
# OFFLINE TEST SHIM for open(1). Terminal.app is never launched and the .command files are
# never executed; this writes the artefacts a real relay/probe would have left behind, so the
# caller's own polling, parsing and verdict logic runs for real against realistic inputs.
set -u
target=''
for a in "$@"; do
	case "$a" in
	*.command) target="$a" ;;
	esac
done
if [ -z "$target" ]; then
	printf 'open-shim:unexpected-argv\n' >> "$LABTEST_TRACE"
	exit 0
fi
# The .command files live in the TRACKED script home; every artefact a real run would leave
# behind lands in the IGNORED runtime dir. Both are derived here the same way the real
# probe.command and relay.command derive them -- from the script's own location -- so a future
# change to that derivation breaks this shim loudly instead of quietly writing somewhere the
# caller is not watching.
lab="$(cd "$(dirname "$target")" && pwd)"
runtime="$(cd "$lab/../.." && pwd)/.build/lab-runtime"
mkdir -p "$runtime/share"
case "$(basename "$target")" in
probe.command)
	printf 'probe\n' >> "$LABTEST_TRACE"
	printf '%s\n' "${LABTEST_PROBE:-REACHABLE}" > "$runtime/probe-result.txt"
	;;
relay.command)
	# Which job this is, decided the way a human would: by reading the job.env that
	# run-scenario.sh just copied into place. That keeps jobs/*.env on the tested path --
	# rename a job file and run-scenario.sh's cp fails, exactly as it would live.
	job='unknown'
	if grep -c 'tsallowlist-probe\.ps1' "$runtime/job.env" >/dev/null 2>&1; then
		job='regprobe'
	elif grep -c 'tsallowlist-matrix-verify\.ps1' "$runtime/job.env" >/dev/null 2>&1; then
		job='verify'
	elif grep -c 'charmap' "$runtime/job.env" >/dev/null 2>&1; then
		job='negative'
	elif grep -c 'logoff' "$runtime/job.env" >/dev/null 2>&1; then
		job='logoff'
	fi
	printf 'relay:%s\n' "$job" >> "$LABTEST_TRACE"
	# relay.command truncates its log at startup; mirror that or a previous job's DONE
	# line would still be sitting there when the caller starts polling.
	: > "$runtime/relay.log"
	printf '[relay] OFFLINE SHIM job=%s -- no xfreerdp started, no packet sent\n' "$job" \
		>> "$runtime/relay.log"
	rc=0
	case "$job" in
	regprobe)
		rc="${LABTEST_RC_REGPROBE:-0}"
		if [ -n "${LABTEST_OUT_REGPROBE:-}" ]; then
			cp "$LABTEST_OUT_REGPROBE" "$runtime/share/tsallowlist-probe-out.txt"
		fi
		;;
	verify)
		rc="${LABTEST_RC_VERIFY:-0}"
		if [ -n "${LABTEST_OUT_VERIFY:-}" ]; then
			cp "$LABTEST_OUT_VERIFY" "$runtime/share/tsallowlist-matrix-out.txt"
		fi
		;;
	negative)
		rc="${LABTEST_RC_NEGATIVE:-0}"
		if [ "${LABTEST_RAIL_REFUSED:-1}" = "1" ]; then
			printf '[relay] RAIL exec error: execResult=RAIL_EXEC_E_NOT_IN_ALLOWLIST\n' \
				>> "$runtime/relay.log"
		fi
		;;
	logoff)
		rc="${LABTEST_RC_LOGOFF:-0}"
		;;
	esac
	# LABTEST_NO_DONE=1 models a relay that never reported: the window is open, nothing comes
	# back, the caller has to time out on its own. LABTEST_NO_DONE_JOB=<job> does the same for
	# one job only -- that is the only way to reach "everything worked except the logoff",
	# which is the state main()'s verdict downgrade exists for.
	silent=0
	if [ "${LABTEST_NO_DONE:-0}" = "1" ]; then silent=1; fi
	if [ "${LABTEST_NO_DONE_JOB:-}" = "$job" ]; then silent=1; fi
	if [ "$silent" -eq 0 ]; then
		printf 'DONE exit=%s\n' "$rc" >> "$runtime/relay.log"
	fi
	;;
esac
exit 0
SHIM_OPEN

cat > "$SB/bin/pgrep" <<'SHIM_PGREP'
#!/usr/bin/env bash
# OFFLINE TEST SHIM: "no such process" by default. The sandbox never starts xfreerdp, and an
# unrelated xfreerdp on the maintainer's Mac must not be allowed to stall or fail this test --
# hence a fixed answer rather than the real process table. LABTEST_PGREP_BUSY=0 flips it to
# "one is running", which is the only way to reach the one-relay-at-a-time refusal.
exit "${LABTEST_PGREP_BUSY:-1}"
SHIM_PGREP

cat > "$SB/bin/xfreerdp" <<'SHIM_XFREERDP'
#!/usr/bin/env bash
# OFFLINE TEST SHIM. run-matrix.sh records the client build in its transcript; that one
# read-only call is answered here. Anything else is a bug in the test and is refused.
if [ "${1:-}" = "--version" ]; then
	printf 'xfreerdp OFFLINE TEST SHIM (never connects)\n'
	exit 0
fi
printf 'xfreerdp shim REFUSED -- the offline test must never invoke xfreerdp: %s\n' "$*" >&2
exit 97
SHIM_XFREERDP

for refuse in nc osascript; do
	cat > "$SB/bin/$refuse" <<SHIM_REFUSE
#!/usr/bin/env bash
# OFFLINE TEST SHIM: belt and braces. Nothing in this test should reach $refuse -- the
# .command files that use it are not even present in the sandbox. If this ever fires, the
# seam moved and the test must be fixed before it is trusted again.
printf '$refuse shim REFUSED -- offline test: %s\n' "\$*" >&2
exit 97
SHIM_REFUSE
done

chmod +x "$SB/bin/"* || exit 1

# The shim bodies live in quoted heredocs, so shellcheck cannot see them. Parse them here
# instead -- a typo in a shim would otherwise surface as a baffling case failure.
for shim in "$SB/bin/"*; do
	if ! bash -n "$shim"; then
		printf 'FATAL: generated shim does not parse: %s\n' "$shim"
		exit 1
	fi
done

# -- fixtures ----------------------------------------------------------------------------------
# CRLF throughout, because that is what the host side really writes: both producers go through
# [IO.File]::WriteAllLines, which joins on Environment.NewLine. The CR is the entire point of
# cases 7 and 8. No host-identifying content: these are shapes, not captures.

FIX_REG_ENFORCED="$SB/fixtures/regprobe-enforced.txt"
FIX_REG_UNENFORCED="$SB/fixtures/regprobe-unenforced.txt"
FIX_VERIFY_PASS="$SB/fixtures/verify-pass.txt"
FIX_VERIFY_FAIL="$SB/fixtures/verify-fail.txt"
FIX_VERIFY_PRECOND="$SB/fixtures/verify-precondition.txt"

write_regprobe_fixture() { # <path> <fDisabledAllowList value>
	{
		printf 'PSVersion: 5.1.26200.9999\r\n'
		printf 'IsInRole(Administrator): False\r\n'
		printf 'TSAppAllowList\\fDisabledAllowList = %s\r\n' "$2"
		printf 'TSAppAllowList\\fHasCertificate = <absent>\r\n'
		printf 'Applications: 4 key(s)\r\n'
		printf '  [winver]\r\n'
		printf '    Name = winver\r\n'
		printf 'HKLM TSAppAllowList writable by this token: False\r\n'
	} > "$1"
}
write_verify_fixture() { # <path> <RESULT word>
	{
		printf 'macdows TS allow-list matrix verify (offline fixture)\r\n'
		printf '  published: 4  matched: 4  mismatched: 0\r\n'
		printf 'RESULT: %s\r\n' "$2"
	} > "$1"
}

write_regprobe_fixture "$FIX_REG_ENFORCED" 0
write_regprobe_fixture "$FIX_REG_UNENFORCED" 1
write_verify_fixture "$FIX_VERIFY_PASS" PASS
write_verify_fixture "$FIX_VERIFY_FAIL" FAIL
write_verify_fixture "$FIX_VERIFY_PRECOND" PRECONDITION

# -- sandbox HOME ---------------------------------------------------------------------------
# 192.0.2.0/24 and 198.51.100.0/24 are RFC 5737 documentation ranges: they are not routable,
# not anybody's host, and not the owner's segment. The real segments are never read here.

home_reset() { rm -f "$SB/home/.config/macdows/host.env" "$SB/home/.config/macdows/lab-boundary.env"; }
home_hostenv() { printf "WIN_HOST='%s'\n" "$1" > "$SB/home/.config/macdows/host.env"; }
home_boundary() { printf "MACDOWS_LAB_ALLOWED_NETS='192.0.2.0/24'\n" > "$SB/home/.config/macdows/lab-boundary.env"; }
home_ok() { home_reset; home_hostenv '192.0.2.10'; home_boundary; }

# ------------------------------------------------------------------------------------------
# Harness
# ------------------------------------------------------------------------------------------

OUT=''
RC=0

reset_stubs() {
	export LABTEST_PROBE='REACHABLE'
	export LABTEST_OUT_REGPROBE="$FIX_REG_ENFORCED"
	export LABTEST_OUT_VERIFY="$FIX_VERIFY_PASS"
	export LABTEST_RC_REGPROBE=0
	export LABTEST_RC_VERIFY=0
	export LABTEST_RC_NEGATIVE=0
	export LABTEST_RC_LOGOFF=0
	export LABTEST_RAIL_REFUSED=1
	export LABTEST_NO_DONE=0
	export LABTEST_NO_DONE_JOB=''
	export LABTEST_PGREP_BUSY=1
}

begin() { # <slug> <description>
	CASE="$1"
	printf -- '--- case %s: %s\n' "$1" "$2"
	reset_stubs
	home_ok
}

run_sandbox() { # [script]
	local script="${1:-$SBLAB/run-matrix.sh}"
	# The whole runtime tree, not a list of files: it is regenerated from the tracked tree by
	# the staging step under test, so wiping it is both the cheapest reset and a per-case
	# assertion that staging really does put everything back.
	rm -rf "$SBRUNTIME"
	: > "$LABTEST_TRACE"
	OUT="$SB/out-$CASE.txt"
	# Every WAIT_* is driven down to the smallest value that still exercises the real loop
	# (the polls sleep 2, so 2 is one full iteration). SETTLE_SECONDS=0 removes the only
	# other wall-clock cost. This is what those knobs were put there for.
	HOME="$SB/home" \
		PATH="$SB/bin:$PATH" \
		WAIT_REGPROBE=2 WAIT_VERIFY=2 WAIT_NEGATIVE=2 WAIT_LOGOFF=2 \
		WAIT_RELAY_QUIET=2 WAIT_OUTFILE=2 WAIT_PROBE=2 SETTLE_SECONDS=0 \
		bash "$script" > "$OUT" 2>&1
	RC=$?
}

# grep -c ... >/dev/null, never grep -q: same reason run-matrix.sh gives -- -q exits at the
# first match and the SIGPIPE that follows inverts a pipefail pipeline's status.
assert_rc() { # <expected>
	if [ "$RC" -eq "$1" ]; then
		pass "$CASE: exit $RC"
	else
		fail "$CASE: exit $RC, expected $1"
		note "output: $OUT"
	fi
}
assert_has() { # <fixed string> [label]
	if grep -cF -- "$1" "$OUT" >/dev/null 2>&1; then
		pass "$CASE: says '${2:-$1}'"
	else
		fail "$CASE: expected '${2:-$1}' in the transcript"
	fi
}
assert_lacks() { # <fixed string>
	if grep -cF -- "$1" "$OUT" >/dev/null 2>&1; then
		fail "$CASE: transcript must NOT contain '$1'"
	else
		pass "$CASE: no '$1'"
	fi
}
assert_re() { # <BRE> <label>
	if grep -c -- "$1" "$OUT" >/dev/null 2>&1; then
		pass "$CASE: $2"
	else
		fail "$CASE: $2 -- no line matching /$1/"
	fi
}
assert_trace_empty() {
	if [ -s "$LABTEST_TRACE" ]; then
		fail "$CASE: nothing should have been launched, but was: $(tr '\n' ' ' < "$LABTEST_TRACE")"
	else
		pass "$CASE: nothing launched -- no probe, no relay"
	fi
}
assert_launched() { # <trace token>
	if grep -cFx -- "$1" "$LABTEST_TRACE" >/dev/null 2>&1; then
		pass "$CASE: launched $1"
	else
		fail "$CASE: expected $1 to be launched; trace was: $(tr '\n' ' ' < "$LABTEST_TRACE")"
	fi
}
assert_not_launched() { # <trace token>
	if grep -cFx -- "$1" "$LABTEST_TRACE" >/dev/null 2>&1; then
		fail "$CASE: $1 must NOT have been launched"
	else
		pass "$CASE: $1 not launched"
	fi
}

# Mutation support. A pin that would also pass against the broken code pins nothing, so every
# guard this suite claims to protect is proved by deleting it from a COPY (never the original --
# nothing in this file writes outside the sandbox) and requiring the suite to notice.
#
# Deletes one `if … fi` block: the block whose opening line contains <marker>, through the next
# line that is nothing but `fi`. Fails loudly rather than silently if the marker moved, if the
# result stopped parsing, or if <must-vanish> survived -- all three mean this test needs
# updating, not that the code under test is fine.
mutate_delete_block() { # <src> <dst> <marker> <must-vanish>
	if ! awk -v marker="$3" '
		{
			if (!skip && index($0, marker) > 0) { skip = 1; removed++ }
			if (skip) {
				if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) { skip = 0 }
				next
			}
			print
		}
		END { if (removed != 1) { exit 3 } }
	' "$1" > "$2"; then
		note "mutation: [$3] not found exactly once in $(basename "$1")"
		return 1
	fi
	if ! bash -n "$2"; then
		note 'mutation: the mutated copy no longer parses -- the block boundaries moved'
		return 1
	fi
	if grep -cF -- "$4" "$2" >/dev/null 2>&1; then
		note "mutation: [$4] survived the deletion -- the wrong block was removed"
		return 1
	fi
	return 0
}

# ------------------------------------------------------------------------------------------
# Cases
# ------------------------------------------------------------------------------------------

printf 'test-run-matrix-offline.sh -- driving %s\n' "$LAB/run-matrix.sh"
printf 'sandbox: %s\n\n' "$SB"

# -- 1. the boundary gate, with no boundary file at all ---------------------------------------
# Fail-closed is the red line this whole harness rests on: no boundary file means the gate
# cannot prove the target is the owner's own machine, so nothing may be launched.
begin gate-nofile 'lab-boundary.env missing -> exit 3, nothing launched'
home_reset
home_hostenv '192.0.2.10'
run_sandbox
assert_rc 3
assert_has '[gate] boundary: FAIL'
assert_trace_empty

# -- 2. a target outside the allowed segments --------------------------------------------------
begin gate-outside 'target outside the allowed segments -> exit 3, nothing launched'
home_reset
home_hostenv '198.51.100.7'
home_boundary
run_sandbox
assert_rc 3
assert_has '[gate] boundary: FAIL'
assert_trace_empty

# -- 3. no host.env at all -----------------------------------------------------------------------
begin gate-nohostenv 'host.env missing -> exit 3, nothing launched'
home_reset
home_boundary
run_sandbox
assert_rc 3
assert_has 'host.env is missing or unreadable'
assert_trace_empty

# -- 4. host not reachable --------------------------------------------------------------------
begin unreachable 'probe says UNREACHABLE -> exit 4, no relay'
export LABTEST_PROBE='UNREACHABLE'
run_sandbox
assert_rc 4
assert_has 'host is not reachable'
assert_launched 'probe'
assert_not_launched 'relay:regprobe'

# -- 5. the precondition path -------------------------------------------------------------------
begin precondition 'fDisabledAllowList=1 (CRLF) -> exit 2, owner instructions, no verify'
export LABTEST_OUT_REGPROBE="$FIX_REG_UNENFORCED"
run_sandbox
assert_rc 2
assert_has 'MATRIX: PRECONDITION'
assert_has 'OWNER ACTION REQUIRED'
assert_re '\[probe\] fDisabledAllowList = 1$' 'the parsed value carries no stray CR'
assert_launched 'relay:regprobe'
assert_not_launched 'relay:verify'

# -- 6. the happy path ----------------------------------------------------------------------------
begin pass 'enforced + verify PASS + negative control refused -> exit 0'
run_sandbox
assert_rc 0
assert_has 'MATRIX: PASS'
assert_has 'negative control: PASS'
assert_has '[state] host session: logged off'
assert_launched 'relay:verify'
assert_launched 'relay:negative'

# -- 7. the CRLF regression pin ---------------------------------------------------------------
# THE bug from 2026-09-01: the probe writes 'fDisabledAllowList = 0\r', the CR survived into
# the comparison, '0\r' != '0', and an enforced host scored PRECONDITION -- i.e. the matrix
# reported "nothing to measure yet" about a host that was fully enforced. The earlier runs read
# '1\r' and were right by accident. Pinned two ways: the exit code must not be 2, and the
# parsed value must reach the transcript with nothing after the 0 (the $ anchor is the assay --
# a surviving CR sits between the 0 and the newline and breaks the match).
# The verify result is FAIL here on purpose, so that "not PRECONDITION" cannot be satisfied by
# accidentally landing on the PASS path instead.
begin crlf-pin 'enforced + CRLF must NOT score PRECONDITION (regression pin)'
export LABTEST_OUT_VERIFY="$FIX_VERIFY_FAIL"
run_sandbox
assert_rc 1
assert_lacks 'MATRIX: PRECONDITION'
assert_re '\[probe\] fDisabledAllowList = 0$' 'the parsed value carries no stray CR'
assert_has 'MATRIX: FAIL'

# -- 8. does the pin actually bite? ---------------------------------------------------------------
# A regression pin that would also pass against the broken code pins nothing. Remove the one
# line that strips the CR from a copy of the script and re-run case 7's inputs: the old bug must
# come back (exit 2, PRECONDITION). If the strip cannot be found, that is a hard failure and the
# string below needs updating -- silently skipping would leave a test that only looks like one.
begin crlf-mutant 'the pin fails against a copy with the CR strip removed'
MUTANT="$SBLAB/labtest-mutant-crlf-unfixed.sh"
# shellcheck disable=SC2016  # $path is literal here: this is the source line to match, not code
STRIP_LINE='tr -d '"'"'\r'"'"' < "$path"'
grep -vF -- "$STRIP_LINE" "$SBLAB/run-matrix.sh" > "$MUTANT"
REMOVED=$(($(wc -l < "$SBLAB/run-matrix.sh") - $(wc -l < "$MUTANT")))
if [ "$REMOVED" -ne 1 ]; then
	fail "$CASE: expected to remove exactly 1 line matching [$STRIP_LINE], removed $REMOVED"
	note 'the CRLF strip in wait_for_file was reworded -- update STRIP_LINE in this test'
else
	pass "$CASE: mutated a copy by removing the CR strip"
	export LABTEST_OUT_VERIFY="$FIX_VERIFY_FAIL"
	run_sandbox "$MUTANT"
	if [ "$RC" -eq 2 ]; then
		pass "$CASE: without the strip the bug returns (exit 2) -- case 7 is a real pin"
	else
		fail "$CASE: without the strip the run exited $RC, expected 2; case 7 proves nothing"
	fi
fi

# -- 9. the relay refused the target mid-run -------------------------------------------------------
# relay.command writes DONE exit=78 when its own boundary gate refuses, without contacting the
# host. Matching a bare 'DONE exit=' once scored that as a completed step.
begin relay-78 'relay reports DONE exit=78 -> exit 1, refusal named'
export LABTEST_RC_REGPROBE=78
run_sandbox
assert_rc 1
assert_has "relay job 'regprobe' FAILED"
assert_has "exit=78 is relay.command's own boundary refusal"

# -- 10. the relay never reported at all --------------------------------------------------------
# Both the job and the logoff time out, so the host is left logged in and main() has to say so.
begin no-done 'no DONE line -> exit 1 and HOST SESSION: STILL LOGGED IN'
export LABTEST_NO_DONE=1
run_sandbox
assert_rc 1
assert_has "TIMEOUT: relay job 'regprobe' produced no DONE line"
assert_has 'HOST SESSION: STILL LOGGED IN'

# -- 11. the dead-man switch fired mid-run --------------------------------------------------------
# The registry probe saw enforced, the verify job saw unenforced: something restored the host in
# between (-ArmRestoreIn does exactly that). Nothing under test failed, so this is PRECONDITION,
# not FAIL.
begin verify-precondition 'verify reports PRECONDITION inside the enforced branch -> exit 2'
export LABTEST_OUT_VERIFY="$FIX_VERIFY_PRECOND"
run_sandbox
assert_rc 2
assert_has 'the host reports PRECONDITION inside the enforced branch'
assert_has 'MATRIX: PRECONDITION'
assert_not_launched 'relay:negative'

# -- 12. main()'s verdict downgrade ------------------------------------------------------------
# Everything under test passes, but the logoff never reports, so the host is left logged in. A
# verdict that reads "nothing to do here" must never sit next to that line: main() downgrades
# 0 and 2 to 1, and prints the original verdict rather than losing it. This is the ONLY way to
# reach that code -- case 10 leaves the host logged in too, but via a run that already returns
# 1, so the downgrade never executes there (measured in review; case 10 alone does not pin it).
begin downgrade 'a PASS run whose logoff never reports -> exit 0 downgraded to 1'
export LABTEST_NO_DONE_JOB=logoff
run_sandbox
assert_rc 1
assert_has 'MATRIX: PASS'
assert_has 'HOST SESSION: STILL LOGGED IN'
assert_has 'downgrading exit 0 to 1'

# -- 13. does case 12 bite? --------------------------------------------------------------------
begin downgrade-mutant 'case 12 fails against a copy with the downgrade removed'
MUTANT_DG="$SBLAB/labtest-mutant-no-downgrade.sh"
# shellcheck disable=SC2016  # $rc is literal: this is the source line to match, not code
if mutate_delete_block "$SBLAB/run-matrix.sh" "$MUTANT_DG" \
	'[ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]' 'downgrading exit'; then
	pass "$CASE: mutated a copy by removing main()'s verdict downgrade"
	export LABTEST_NO_DONE_JOB=logoff
	run_sandbox "$MUTANT_DG"
	if [ "$RC" -eq 0 ]; then
		pass "$CASE: without it the run reports success over a logged-in host -- case 12 is a real pin"
	else
		fail "$CASE: without the downgrade the run exited $RC, expected 0; case 12 proves nothing"
	fi
else
	fail "$CASE: could not remove main()'s verdict downgrade -- update the marker in this test"
fi

# -- 14. one relay connection at a time ----------------------------------------------------------
# A hard lab rule, and itself a fix: the check used to live in do_logoff, where every caller
# ignored its return and walked straight past it. It now sits at the single choke point every
# job passes through. The suite has to notice if it ever leaves again.
begin relay-busy 'an xfreerdp is already running -> every job refused, nothing launched'
export LABTEST_PGREP_BUSY=0
run_sandbox
assert_rc 1
assert_has "REFUSED to start job 'regprobe'"
assert_has 'one relay connection at a time is a hard rule'
assert_not_launched 'relay:regprobe'
assert_not_launched 'relay:logoff'

# -- 15. does case 14 bite? ------------------------------------------------------------------------
begin busy-mutant 'case 14 fails against a copy with the one-relay refusal removed'
MUTANT_BUSY="$SBLAB/labtest-mutant-no-relay-guard.sh"
# shellcheck disable=SC2016  # $WAIT_RELAY_QUIET is literal: the source line to match, not code
if mutate_delete_block "$SBLAB/run-matrix.sh" "$MUTANT_BUSY" \
	'! wait_for_relay_quiet "$WAIT_RELAY_QUIET"' 'REFUSED to start job'; then
	pass "$CASE: mutated a copy by removing the one-relay-at-a-time refusal"
	export LABTEST_PGREP_BUSY=0
	run_sandbox "$MUTANT_BUSY"
	if [ "$RC" -eq 0 ]; then
		pass "$CASE: without it a relay is started on top of a live one -- case 14 is a real pin"
		assert_launched 'relay:regprobe'
	else
		fail "$CASE: without the refusal the run exited $RC, expected 0; case 14 proves nothing"
	fi
else
	fail "$CASE: could not remove the one-relay-at-a-time refusal -- update the marker in this test"
fi

# -- 16. the promotion split: tracked scripts in, runtime artefacts out ----------------------
# New on 2026-09-01, when this harness moved from the ignored .build/lab into the tracked
# Scripts/lab. The redirected drive is now a DIFFERENT directory from the tracked share/, and
# two properties have to hold or the first live run fails in a way none of the cases above
# would catch:
#   * every host-side script actually arrives in the runtime share (the host can only run what
#     staging put there -- a missing file shows up on the host as a job that does nothing and
#     reports nothing, which is far harder to read than a refusal on the Mac);
#   * a run writes NOTHING into the tracked tree. That is the property that keeps a
#     host-written artefact off a tracked path, and so out of a commit.
# The *.Tests.ps1 exclusion is measured against the real directory: the sandbox copy of
# share/ contains them (see the sandbox setup), so their absence downstream is staging's doing.
begin stage-split 'staging fills the runtime share and leaves the tracked tree untouched'
run_sandbox
snapshot_tracked > "$SB/tracked-after.txt"
assert_rc 0
assert_has '[stage] host-side scripts staged into the runtime share'

STAGE_MISSING=''
for f in "$SBLAB"/share/*.ps1; do
	sbase="$(basename "$f")"
	case "$sbase" in *.Tests.ps1) continue ;; esac
	[ -f "$SBSHARE/$sbase" ] || STAGE_MISSING="$STAGE_MISSING $sbase"
done
if [ -z "$STAGE_MISSING" ]; then
	pass "$CASE: every host-side script reached the runtime share"
else
	fail "$CASE: not staged:$STAGE_MISSING"
fi

STAGE_LEAKED=''
for f in "$SBSHARE"/*.Tests.ps1; do
	[ -f "$f" ] && STAGE_LEAKED="$STAGE_LEAKED $(basename "$f")"
done
if [ -z "$STAGE_LEAKED" ]; then
	pass "$CASE: no *.Tests.ps1 on the redirected drive"
else
	fail "$CASE: test suites staged onto the redirected drive:$STAGE_LEAKED"
fi

if [ -f "$SBSHARE/host-agent/placeholder.txt" ]; then
	pass "$CASE: host-agent refreshed from Tools/host-agent into the runtime share"
else
	fail "$CASE: host-agent was not refreshed into the runtime share"
fi

# Against the PRISTINE census taken at construction, so this covers every case that has run so
# far, not just this one. See TRACKED_PRISTINE.
if diff "$TRACKED_PRISTINE" "$SB/tracked-after.txt" > "$SB/tracked-diff.txt" 2>&1; then
	pass "$CASE: the tracked tree is byte-identical to its pristine state after the whole suite"
else
	fail "$CASE: the tracked tree was modified by a run"
	note "diff: $SB/tracked-diff.txt"
fi

# -- 17. a hand-launched lane stages the share on its own ------------------------------------
# run-matrix.sh drives four of the seven jobs in jobs/. The other three -- stage, readback,
# host-agent-tests -- are launched by hand, straight through run-scenario.sh, and were the
# reason staging ended up in that script rather than in run-matrix.sh: staged from run-matrix
# alone, a hand-launched lane would run against whatever the last matrix run left in the share,
# which on a fresh clone is an empty directory. Driven here WITHOUT run-matrix.sh, because that
# is the whole point -- going through run-matrix would pass either way.
begin scenario-standalone 'run-scenario.sh alone fills the runtime share (hand-launched lanes)'
rm -rf "$SBRUNTIME"
: > "$LABTEST_TRACE"
OUT="$SB/out-$CASE.txt"
HOME="$SB/home" PATH="$SB/bin:$PATH" bash "$SBLAB/run-scenario.sh" relay logoff > "$OUT" 2>&1
RC=$?
assert_rc 0
assert_has '[stage] host-side scripts staged into the runtime share'
assert_launched 'relay:logoff'
if [ -f "$SBSHARE/stage.ps1" ] && [ -f "$SBSHARE/readback.ps1" ] &&
	[ -f "$SBSHARE/host-agent/placeholder.txt" ]; then
	pass "$CASE: the host-side scripts and the host-agent reached the share without run-matrix.sh"
else
	fail "$CASE: a hand-launched lane left the redirected drive unstaged"
fi
if [ -f "$SBRUNTIME/job.env" ]; then
	pass "$CASE: the job instance was written to the runtime dir, not the tracked tree"
else
	fail "$CASE: no runtime job.env"
fi
if [ -f "$SBLAB/job.env" ]; then
	fail "$CASE: job.env was written into the TRACKED script home"
else
	pass "$CASE: nothing written into the tracked script home"
fi

# -- 18. staging prunes the share it owns -------------------------------------------------------
# `cp -f` overwrites but never removes, so before the prune landed, a host-side script renamed or
# deleted in git kept a stale copy on the redirected drive indefinitely -- and the
# "no *.Tests.ps1 on the drive" property of case 16 held only for a FRESH runtime dir, because
# every other case starts from `rm -rf "$SBRUNTIME"` and so can never see a survivor.
#
# This case is the one that starts from a DIRTY share. It also pins the prune's scope: host-written
# artefacts must survive it, or a run would delete the report the previous job just produced.
begin stage-prune 'staging prunes stale .ps1 from a dirty share and spares host artefacts'
rm -rf "$SBRUNTIME"
mkdir -p "$SBSHARE"
printf 'stale -- deleted from git long ago\n' > "$SBSHARE/gone-from-git.ps1"
printf 'stale -- must never survive on the drive\n' > "$SBSHARE/Set-TsAllowListMatrix.Tests.ps1"
printf 'RESULT: PASS\n' > "$SBSHARE/tsallowlist-probe-out.txt"
printf 'ok\n' > "$SBSHARE/readback.done"
: > "$LABTEST_TRACE"
OUT="$SB/out-$CASE.txt"
HOME="$SB/home" PATH="$SB/bin:$PATH" bash "$SBLAB/run-scenario.sh" relay logoff > "$OUT" 2>&1
RC=$?
assert_rc 0
if [ -f "$SBSHARE/gone-from-git.ps1" ]; then
	fail "$CASE: a .ps1 with no counterpart in the tracked tree survived staging"
else
	pass "$CASE: the orphaned .ps1 was pruned"
fi
if [ -f "$SBSHARE/Set-TsAllowListMatrix.Tests.ps1" ]; then
	fail "$CASE: a pre-existing *.Tests.ps1 survived staging onto the redirected drive"
else
	pass "$CASE: a pre-existing *.Tests.ps1 was pruned, not merely never copied"
fi
if [ -f "$SBSHARE/tsallowlist-probe-out.txt" ] && [ -f "$SBSHARE/readback.done" ]; then
	pass "$CASE: host-written artefacts survived the prune"
else
	fail "$CASE: the prune deleted host-written artefacts -- its scope is too wide"
fi
if [ -f "$SBSHARE/tsallowlist-probe.ps1" ]; then
	pass "$CASE: the share was re-filled from the tracked tree after the prune"
else
	fail "$CASE: the prune ran but staging did not re-fill the share"
fi

# ------------------------------------------------------------------------------------------

printf '\n'
printf -- '---------------------------------------------------------------------\n'
if [ "$FAILURES" -eq 0 ]; then
	printf 'OFFLINE GUARD TEST: PASS -- %s assertions, 18 cases (15 pins + 3 mutation proofs)\n' "$PASSES"
	exit 0
fi
printf 'OFFLINE GUARD TEST: FAIL -- %s failed, %s passed\n' "$FAILURES" "$PASSES"
exit 1
