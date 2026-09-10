#!/usr/bin/env bash
# lab window-smoke JOB WRAPPER -- one checkpoint run of Scripts/run-window-smoke.command, driven
# from a job file instead of from a hand-baked runtime script. Launched via Terminal.app (which
# holds the local-network TCC grant) by `run-scenario.sh smoke <job>`; `open -a Terminal` passes
# no environment through, so ALL parameters come from smoke-job.env.
#
# WHY THIS FILE EXISTS. The W3 2x checkpoint of 2026-09-09 ran from four untracked
# .build/lab-runtime/c2p-run<n>.command files, each a hand-written copy of the same five lines
# with one knob changed: two refuse-to-run preflight gates (the checkout must carry the knob
# symbol the run turns; the display must be the looks-like geometry the run's arithmetic assumes),
# a WINDOW_SMOKE_LOG under the batch's evidence directory, the knobs themselves, and a `DONE
# exit=` the orchestrator polls. Copies drift -- one of them silently loses a gate and the run it
# produces looks exactly like the runs that had it. This wrapper is that shape, once, tracked, with
# the job file carrying only VALUES.
#
# THIS FILE IS TRACKED (Scripts/lab) and therefore world-readable: it must never gain a host
# address, an account name, a credential or a maintainer path. Everything host-specific is read at
# run time from the owner's untracked ~/.config/macdows/host.env, every path is derived from
# BASH_SOURCE, and everything a run produces lives under .build/ (lab-runtime/ and evidence/),
# which git ignores.
#
# LIVE-HOST BOUNDARY GATE (owner rule 2026-08-31): before ANYTHING else -- before the job file is
# read, before system_profiler is asked about the display, before a single knob is resolved --
# crdp_assert_lab_boundary (Scripts/lib.sh) must confirm WIN_HOST is inside the owner's own lab
# segments. Fail-closed: a refusal writes BOUNDARY-REFUSED plus DONE exit=78 and stops. The gate is
# FIRST rather than merely "before the connection" for the same reason as wdp-etw.command's: a run
# aimed outside the lab must not cause any of this wrapper's side effects (an evidence directory,
# an xcodebuild, a Terminal window that looks like a lab run) to exist at all.
#
# HOST.ENV. This wrapper sources host.env, which run-window-smoke.command deliberately does not
# (it greps WIN_HOST out textually). It needs the three values for the LOG MASK below, and for
# nothing else: they are stripped from the launcher's environment with `env -u` before it starts,
# so the child sees exactly what it sees when a human launches it by hand -- it re-reads host.env
# itself, through MacdowsCore's EnvFile, and this wrapper never hands it a credential.
#
# LOG MASK. smoke.log is the artefact a human pastes into a report, so every line written to it
# goes through smoke_sink, which rewrites the same four classes of value wdp-etw.command's mask
# does: $HOME to <HOME> (this checkout lives under the maintainer's home directory and the child's
# stdout names it), the host address to <WIN_HOST>, the account to <WIN_USER> and -- belt and
# braces -- the password to <WIN_PASS>. The EVIDENCE log the run itself writes
# (.build/evidence/<BATCH>/window-smoke-<TAG>.log) is deliberately NOT masked: it is the raw
# artefact the records read through their own masking readers, and it never leaves .build/.
#
# smoke-job.env keys (all single-line; the file's line SHAPES are checked before it is read, and it
# is then read once, in a subshell -- see below). Every key maps to at most one WINDOW_SMOKE_*
# variable, and NOTHING else is exported to the child:
#   TAG              run name, ^[A-Za-z0-9._-]{1,32}$; names smoke-<TAG>.log and
#                    window-smoke-<TAG>.log
#   BATCH            evidence directory name, same shape; .build/evidence/<BATCH>/
#   DISPLAY_LOOKS_LIKE  <w>x<h>, or empty for "do not check". Non-empty: `system_profiler
#                    SPDisplaysDataType` must report `UI Looks like: <w> x <h>`, else the run is
#                    REFUSED. This is the 2x checkpoint's own preflight -- a run whose remote-pixel
#                    arithmetic assumes an exact 2x display is unjudgeable on any other display
#   ADVERTISED_SCALE D (default) | none | DD | <desktop>[,<device>] -- see smoke_scale_ok
#   MOVE MAXIMIZE TRAY TRAY_CLICK   0|1, each mapping to the WINDOW_SMOKE_<name> scenario switch
#   EXTRA_APPS       ^[A-Za-z0-9;_-]*$ -- WINDOW_SMOKE_EXTRA_APPS
#   MOVE_TARGET      window-title substring/alternation for the move leg, at most 255 characters
#                    (free text otherwise, so only the two shell-active characters are refused; it
#                    carries CJK by design)
#   APP APP_ARGS     the Windows program and its arguments (ASCII path/argument characters only)
#   REQUIRE_SYMBOL   ^[A-Za-z0-9_]{1,64}$ or empty; non-empty: Tools/window-smoke/main.swift must
#                    contain it, else the run is REFUSED. The c2p-run<n> preflight: a knob this run
#                    turns must EXIST in the checkout being built, or the run measures the default
#                    and says nothing about the knob
#
# DONE exit=<rc> is the run's whole verdict (the window's own status is meaningless -- see the
# bottom of this file). The wrapper's own codes and the launcher's share one space, as
# wdp-etw.command's do with its client's -- and this wrapper answers with the SAME three codes
# wdp-etw.command uses for the same three questions, because a reader of an orchestrator's
# scrollback should not have to remember which wrapper printed which line:
#   0   the run happened (window-smoke's own verdict is in the evidence log)
#   65  the JOB FILE is not a table of values     JOB-ENV-INVALID   (EX_DATAERR). A line that is
#       not blank, a comment or an assignment; a key outside the whitelist; a value outside its
#       shape. Wrong everywhere and forever: no machine, no checkout and no re-run changes it, and
#       nothing was built or connected
#   66  smoke-job.env is not readable             JOB-ENV-MISSING   (EX_NOINPUT)
#   75  THIS MACHINE, RIGHT NOW, is not the environment the job describes (EX_TEMPFAIL). Two
#       preflights answer it, because they are one kind of answer -- "change the environment, then
#       run the identical job file again":
#         REFUSED: display …                     the display is not the looks-like geometry the
#                                                run's remote-pixel arithmetic assumes; plug the
#                                                display in and the same job runs
#         REFUSED: the checkout does not carry …  REQUIRE_SYMBOL is absent from main.swift; check
#                                                out a tree that carries the knob and the same job
#                                                runs
#       Which one it was is the line immediately above DONE. Neither is 65: there is nothing wrong
#       with the job file, and a reader who saw JOB-ENV-INVALID's code would go and edit a correct
#       one
#   78  BOUNDARY-REFUSED -- the target is outside the lab segments (EX_CONFIG). The one code this
#       wrapper shares with the launcher and with every other gate in the repo, deliberately: the
#       boundary refusal means the same thing wherever it comes from
#   anything else: run-window-smoke.command's own DONE code, passed through (1 build/run failure,
#   2 missing credentials, 3 declared-desktop knob, 4 advertised-scale knob, 78 its own gate).
#   This wrapper deliberately spends NO code in 1-4. The untracked c2p-run<n>.command wrappers
#   refused with 3, which is ALSO the launcher's declared-desktop refusal, so `DONE exit=3` meant
#   one of two unrelated things depending on which line above it you happened to read. It now means
#   exactly one, and test-smoke-job-offline.sh case 23 is what keeps that true.
set -u
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
RUNTIME="$REPO_ROOT/.build/lab-runtime"
mkdir -p "$RUNTIME"
# The FIXED log, truncated first (relay.command and wdp-etw.command do the same): if anything below
# dies before the verdict is written -- a host.env that exits, a missing lib.sh -- the caller must
# find an empty log and time out, never last run's DONE exit=0. The per-TAG copy is made at the
# very end, once, from this file: the gate runs before TAG is known, so a refusal has to have
# somewhere to speak, and TAG is only trusted after it has passed its own shape check.
LOG="$RUNTIME/smoke.log"
: > "$LOG"
JOB="$RUNTIME/smoke-job.env"
SMOKE_RC=0
HOME_RE=''
HOST_RE=''
USER_RE=''
PASS_RE=''
TAG=''
TAG_OK=0

# THE LINE GRAMMAR. A job file is a table of values or it does not run, and this is the whole
# statement of what "a table of values" means. Three kinds of line are admitted and nothing else:
# blank, a comment, or an assignment to one of the fourteen keys whose VALUE is a single shell
# word. The key list is repeated by hand in the subshell read further down; case 4's pin and the M2
# mutation proof are what keep the two honest.
#
# THE VALUE HALF IS NOT DECORATION. `KEY=` plus a whitelisted key name is not enough: to the shell,
# `DISPLAY_LOOKS_LIKE=1280 x 720` is an assignment PREFIXED to the command `x 720`, so a job file
# with one unquoted space in it runs a program. Measured, not theorised -- an early draft of this
# file hung forever on exactly that line, because /opt/X11/bin/x exists on the lab Mac and reads
# stdin. Hence: a bare value may hold only characters that cannot start a word or a redirection,
# and anything else -- a space, a separator, a backslash, non-ASCII -- must be QUOTED, which is
# also what makes it survive being read at all (`APP=C:\Windows` unquoted loses its backslashes).
# Single quotes admit anything but a single quote; double quotes exclude the three characters that
# would still expand inside them. A trailing `\"` can still continue a double-quoted value onto the
# next line; that is the one shape this grammar cannot see, and it is what the sentinel below is
# for. Assembled from pieces because the alternatives contain both kinds of quote.
SMOKE_JOB_KEYS_RE='TAG|BATCH|DISPLAY_LOOKS_LIKE|ADVERTISED_SCALE|MOVE|MAXIMIZE|TRAY|TRAY_CLICK|EDGE_PROFILE|EXTRA_APPS|MOVE_TARGET|APP|APP_ARGS|REQUIRE_SYMBOL'
SMOKE_SQ="'"
SMOKE_VALUE_BARE='[A-Za-z0-9._:,%@=+/-]*'
SMOKE_VALUE_DQ='"[^"$`]*"'
SMOKE_JOB_LINE_RE="^[[:space:]]*(#.*)?\$|^(export )?(${SMOKE_JOB_KEYS_RE})=(${SMOKE_VALUE_BARE}|${SMOKE_SQ}[^${SMOKE_SQ}]*${SMOKE_SQ}|${SMOKE_VALUE_DQ})\$"

# Every WINDOW_SMOKE_* variable this wrapper owns. The child is started with ALL of them removed
# from the environment and only the ones the job selected put back: a knob inherited from whatever
# shell opened Terminal would otherwise turn a run silently, and "ADVERTISED_SCALE=D means the knob
# is UNSET" is a statement about the child's environment that only holds if this list is complete.
SMOKE_MANAGED_VARS='WINDOW_SMOKE_LOG WINDOW_SMOKE_ADVERTISED_SCALE WINDOW_SMOKE_MOVE WINDOW_SMOKE_MAXIMIZE WINDOW_SMOKE_TRAY WINDOW_SMOKE_TRAY_CLICK WINDOW_SMOKE_EDGE_PROFILE WINDOW_SMOKE_EXTRA_APPS WINDOW_SMOKE_MOVE_TARGET WINDOW_SMOKE_APP WINDOW_SMOKE_APP_ARGS'

# BRE-escapes a value so it can be used as a sed pattern. WIN_HOST is normally an IP literal, and
# its dots would otherwise match any character -- close enough to look right and wrong enough to
# leak a neighbouring address. (Same helper as wdp-etw.command's; the two wrappers share the mask's
# rules, not its code, because each must run standalone under `open -a Terminal`.)
smoke_re_escape() { # <literal>
    printf '%s' "$1" | sed 's|[][\.*^$/]|\\&|g'
}

# Per line, never a single persistent `sed` -- the same rule, and for the same measured reason, as
# wdp-etw.command's etw_mask_pipe: sed's stdout is fully buffered once it is not a tty, so a
# `... | sed | >> log` pipe holds the child's early lines until the child exits and the pipe
# closes. That matters more here than there: this wrapper's child is an xcodebuild followed by a
# multi-minute live run, and a human (or an orchestrator) polling smoke.log for progress would see
# an empty file for the whole run. A `sed` started fresh per line has nothing left to buffer past
# its own exit, and `read -r` never consumes past the newline it is waiting for. Kept as ONE
# physical line on purpose, so a mutation proof can revert it with a single-line swap.
smoke_mask_pipe() { local script="$1" line; while IFS= read -r line || [ -n "$line" ]; do if [ -n "$script" ]; then printf "%s\n" "$line" | sed -e "$script"; else printf "%s\n" "$line"; fi; done; }

# The mask. $HOME goes FIRST, so that a host or account value occurring inside a path is not
# rewritten out from under the path rule, leaving a half-redacted path behind. A rule joins the
# script only when its value is non-empty: an empty sed pattern (`s//x/`) re-uses the LAST regex,
# which would substitute something arbitrary rather than nothing.
smoke_mask() {
    local script=''
    if [ -n "$HOME_RE" ]; then script="${script}s/$HOME_RE/<HOME>/g;"; fi
    if [ -n "$HOST_RE" ]; then script="${script}s/$HOST_RE/<WIN_HOST>/g;"; fi
    if [ -n "$USER_RE" ]; then script="${script}s/$USER_RE/<WIN_USER>/g;"; fi
    if [ -n "$PASS_RE" ]; then script="${script}s/$PASS_RE/<WIN_PASS>/g;"; fi
    smoke_mask_pipe "$script"
}

# The ONE place bytes reach smoke.log -- this wrapper's own lines, the gate's output and the
# launcher's stdout/stderr all pass through here, so the mask cannot be bypassed by adding a writer.
smoke_sink() {
    smoke_mask >> "$LOG"
}

smoke_log() { # <text...>
    printf '%s\n' "$*" | smoke_sink
}

# ADVERTISED_SCALE's domain, stated once. `D` is the PRODUCT DEFAULT and is expressed by leaving
# WINDOW_SMOKE_ADVERTISED_SCALE unset (main.swift: "unset/empty = unset (product default)"), which
# is exactly what the 2026-09-09 run 2 did with `unset WINDOW_SMOKE_ADVERTISED_SCALE`. The other
# three forms are passed to the child verbatim and re-validated there; the domains repeated here
# (desktop 100...500, device 100/140/180 -- MacdowsCore's ScaleAdvertisement) exist so that a typo
# is refused BEFORE a Terminal window, an xcodebuild and a session happen, not after.
# Deliberately STRICTER than main.swift's parser, which trims surrounding whitespace: a job file is
# a definition, and " DD" in one is a typo, not a value. Strictness here fails closed.
smoke_scale_ok() { # <value>
    local desktop device
    case "$1" in
    D | DD | none) return 0 ;;
    esac
    printf '%s\n' "$1" | grep -qE '^[1-9][0-9]{0,2}(,[0-9]{3})?$' || return 1
    desktop="${1%%,*}"
    device="${1#*,}"
    if [ "$device" = "$1" ]; then device=100; fi
    [ "$desktop" -ge 100 ] && [ "$desktop" -le 500 ] || return 1
    case "$device" in
    100 | 140 | 180) return 0 ;;
    esac
    return 1
}

# APP / APP_ARGS travel into the child's environment, never through a shell, so this allow-list is
# defence in depth rather than quoting: what it actually buys is that a value which could only have
# come from a mistake (a `$(...)`, a pipe, a redirect pasted out of a shell transcript) is refused
# at the definition instead of reaching the host as a program name. ASCII by design -- these are
# Windows system paths and switches. `tr -d` rather than a bracket expression: a backslash inside
# an ERE bracket expression is portable only by POSIX's word, and backslash is the ONE character a
# Windows path cannot do without.
smoke_ascii_arg_ok() { # <value>
    [ "${#1}" -le 255 ] || return 1
    [ -z "$(printf '%s' "$1" | tr -d 'A-Za-z0-9 ._:%()+,@=*?\\/-')" ]
}

# The window-close decision, in one function, called from one place (smoke_finish). tty-matched, so
# only this window closes. Owner rule 2026-09-02: the window closes once the log says DONE, on
# SUCCESS AND ON FAILURE -- a wrapper window left open is a window someone has to close by hand,
# and the scrollback is not the evidence (the two logs are).
smoke_close_window() {
    local tty_name
    if [ -n "${TERM_PROGRAM:-}" ] && [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
        tty_name=$(tty)
        osascript -e 'tell application "Terminal" to close (every window whose tty is "'"$tty_name"'")' >/dev/null 2>&1 &
    fi
}

# The per-TAG copy every orchestrator polls. Only for a TAG that passed its own shape check: a job
# that spans lines, or names its run with a path separator, has no trustworthy TAG at all.
smoke_copy_tag_log() {
    if [ "$TAG_OK" -eq 1 ]; then
        cp "$LOG" "$RUNTIME/smoke-$TAG.log"
    fi
}

# ORDER IS LOAD-BEARING, and it is why these three steps live in one function instead of at three
# call sites. Closing the window sends this process a hangup, so ANY work left after the osascript
# may simply not happen; and run-window-smoke.command's own self-close (which would fire on its
# success, on THIS window, because it is our child on our tty) is disarmed by clearing TERM_PROGRAM
# for the child, so this wrapper is the only thing that ever closes it. DONE first, then the copy
# the orchestrator polls, then the close. test-smoke-job-offline.sh's mutation proof M4 swaps the
# first and last lines and requires the ordering pin to go red.
smoke_finish() { # <rc>
    smoke_log "DONE exit=$1"
    smoke_copy_tag_log
    smoke_close_window
}

# shellcheck source=/dev/null
source "$HOME/.config/macdows/host.env"
# shellcheck source=/dev/null
source "$REPO_ROOT/Scripts/lib.sh"
# lib.sh turns on -e/pipefail for its sourcer; this wrapper runs with neither. -e because every
# refusal below is an expected outcome that must still reach the DONE line, and pipefail because
# the launcher's exit code is read from PIPESTATUS, not from the mask it is piped into.
set +e +o pipefail
# HOME is masked alongside host.env's values because this checkout sits under it. A HOME of "/" is
# left alone -- rewriting every slash would destroy the log rather than redact it.
if [ -n "${HOME:-}" ] && [ "${HOME:-}" != '/' ]; then
    HOME_RE="$(smoke_re_escape "$HOME")"
fi
HOST_RE="$(smoke_re_escape "${WIN_HOST:-}")"
USER_RE="$(smoke_re_escape "${WIN_USER:-}")"
PASS_RE="$(smoke_re_escape "${WIN_PASS:-}")"

# The gate judges host.env alone and runs before the job file is even looked at. Its output is
# captured rather than piped so that its exit status stays readable in THIS shell (a pipe would
# hand back the mask's status) -- and so that its REFUSED line, which names the target by lib.sh's
# design, reaches the log masked like everything else.
GATE_OUT=""
GATE_RC=0
GATE_OUT="$(crdp_assert_lab_boundary "${WIN_HOST:-}" 2>&1)" || GATE_RC=$?
smoke_log "$GATE_OUT"
smoke_log "[smoke] target=${WIN_HOST:-} account=${WIN_USER:-} -- both values masked here, so this log is safe to paste"

if [ "$GATE_RC" -ne 0 ]; then
    smoke_log "[smoke] BOUNDARY-REFUSED -- target is not a permitted lab host; nothing was built, nothing was connected"
    SMOKE_RC=78
elif [ ! -r "$JOB" ]; then
    smoke_log "[smoke] JOB-ENV-MISSING -- $JOB is not readable; no run attempted"
    SMOKE_RC=66
else
    # STEP 1: the job file's line SHAPES, checked as TEXT, before a single byte of it is executed.
    # This is the whitelist that matters. The subshell below isolates what a job can WRITE, but it
    # cannot stop a job LINE from running -- and this shell holds WIN_PASS, which a subshell
    # inherits, so a job carrying `printenv WIN_PASS > /tmp/x` would exfiltrate the credential
    # without ever needing a key of its own. Refusing every line that is not blank, a comment, or
    # an assignment to a whitelisted key closes that: the file is a table of values or it does not
    # run. jobs/*.env are tracked, reviewed files, so this is a guard against a mistake and against
    # a runtime instance someone hand-edited -- not a claim about a hostile author with commit
    # access. CR is stripped first so a CRLF file is judged on its content.
    # The line NUMBER is reported, never the line: an offending line may be exactly the secret.
    BAD_LINE="$(tr -d '\r' < "$JOB" | grep -nvE "$SMOKE_JOB_LINE_RE" | head -n 1 | cut -d: -f1)"
    if [ -n "$BAD_LINE" ]; then
        smoke_log "[smoke] JOB-ENV-INVALID -- line $BAD_LINE of smoke-job.env is neither blank, a comment, nor an assignment of a SINGLE WORD to one of the permitted keys (TAG BATCH DISPLAY_LOOKS_LIKE ADVERTISED_SCALE MOVE MAXIMIZE TRAY TRAY_CLICK EDGE_PROFILE EXTRA_APPS MOVE_TARGET APP APP_ARGS REQUIRE_SYMBOL); a value carrying a space, a separator or a backslash must be quoted, or the shell reads what follows it as a command; and a comment must be on a line of its own -- an assignment may not be followed by one, quoted or not. The line itself is not quoted here because it may BE the value that must not be printed. No run attempted"
        SMOKE_RC=65
    else
        # STEP 2: one subshell, fourteen keys out plus a sentinel (the keys are single-line by
        # contract). The job instance is a per-run file under .build/ and is never sourced into
        # THIS shell: it is executed once, in a subshell, and only its keys come back out. That
        # isolates what the job can WRITE -- its variables, functions, traps and `exit` die with
        # the subshell -- so it can neither redefine crdp_assert_lab_boundary (the gate has already
        # run, and the function it ran is still lib.sh's) nor overwrite WIN_HOST/HOME/PATH after
        # the gate approved them. The sentinel catches a value that spans lines: without it a stray
        # newline shifts every following key and the run proceeds with keys that are silently
        # wrong. A hand-edited CRLF file leaves a CR on each value; EVERY one is removed, not just
        # the trailing one, so nothing carrying a CR reaches a file name or the child's environment.
        # All of them rather than the last, for one reason: the grammar above judges the file with
        # every CR already deleted, so `MOVE_TARGET=a<CR>b` is admitted as the text `MOVE_TARGET=ab`
        # -- and a strip that took only the trailing CR would then hand the child a value the check
        # never saw. checkpoint.sh's cp_job_value has always deleted all of them; with anything less
        # here the two would disagree about the name of a file they both build.
        # stdin is closed for the source: the grammar above admits no command, but a guard that
        # depends on another guard being complete is the one that fails quietly. A job line that
        # reached a program which reads stdin would otherwise block this wrapper FOREVER -- no DONE
        # line, and every orchestrator polling for one waits out its full timeout.
        # shellcheck source=/dev/null
        JOB_KEYS="$( . "$JOB" >/dev/null 2>&1 </dev/null; printf '%s\n' "${TAG:-}" "${BATCH:-}" "${DISPLAY_LOOKS_LIKE:-}" "${ADVERTISED_SCALE:-}" "${MOVE:-}" "${MAXIMIZE:-}" "${TRAY:-}" "${TRAY_CLICK:-}" "${EXTRA_APPS:-}" "${MOVE_TARGET:-}" "${APP:-}" "${APP_ARGS:-}" "${REQUIRE_SYMBOL:-}" "${EDGE_PROFILE:-}" 'END-OF-JOB-KEYS' )"
        TAG=""; BATCH=""; DISPLAY_LOOKS_LIKE=""; ADVERTISED_SCALE=""; MOVE=""; MAXIMIZE=""
        TRAY=""; TRAY_CLICK=""; EXTRA_APPS=""; MOVE_TARGET=""; APP=""; APP_ARGS=""
        REQUIRE_SYMBOL=""; EDGE_PROFILE=""; JOB_KEYS_END=""
        {
            IFS= read -r TAG; IFS= read -r BATCH; IFS= read -r DISPLAY_LOOKS_LIKE
            IFS= read -r ADVERTISED_SCALE; IFS= read -r MOVE; IFS= read -r MAXIMIZE
            IFS= read -r TRAY; IFS= read -r TRAY_CLICK; IFS= read -r EXTRA_APPS
            IFS= read -r MOVE_TARGET; IFS= read -r APP; IFS= read -r APP_ARGS
            IFS= read -r REQUIRE_SYMBOL; IFS= read -r EDGE_PROFILE; IFS= read -r JOB_KEYS_END
        } <<EOF_JOB_KEYS
$JOB_KEYS
EOF_JOB_KEYS
        CR=$(printf '\r')
        TAG="${TAG//$CR/}"; BATCH="${BATCH//$CR/}"; DISPLAY_LOOKS_LIKE="${DISPLAY_LOOKS_LIKE//$CR/}"
        ADVERTISED_SCALE="${ADVERTISED_SCALE//$CR/}"; MOVE="${MOVE//$CR/}"; MAXIMIZE="${MAXIMIZE//$CR/}"
        TRAY="${TRAY//$CR/}"; TRAY_CLICK="${TRAY_CLICK//$CR/}"; EXTRA_APPS="${EXTRA_APPS//$CR/}"
        MOVE_TARGET="${MOVE_TARGET//$CR/}"; APP="${APP//$CR/}"; APP_ARGS="${APP_ARGS//$CR/}"
        REQUIRE_SYMBOL="${REQUIRE_SYMBOL//$CR/}"; EDGE_PROFILE="${EDGE_PROFILE//$CR/}"
        JOB_KEYS_END="${JOB_KEYS_END//$CR/}"
        # Defaults. ADVERTISED_SCALE's is D because that is what an ABSENT knob means to the child
        # (product default, ADR-0018 U-1) -- the job file says D to say "do not turn it", and an
        # omitted key says the same thing rather than something subtly different.
        ADVERTISED_SCALE="${ADVERTISED_SCALE:-D}"
        MOVE="${MOVE:-0}"; MAXIMIZE="${MAXIMIZE:-0}"; TRAY="${TRAY:-0}"; TRAY_CLICK="${TRAY_CLICK:-0}"
        # EDGE_PROFILE is the O-A measurement knob (WINDOW_SMOKE_EDGE_PROFILE): opt-in, and its
        # default is OFF for the same reason the child's is -- a run that did not ask to measure
        # must be byte-identical to one built before the diagnostic existed.
        EDGE_PROFILE="${EDGE_PROFILE:-0}"
        # TAG's verdict is computed once, here, and reused by the log-copy step at the very bottom.
        if [ "$JOB_KEYS_END" = "END-OF-JOB-KEYS" ] && printf '%s\n' "$TAG" | grep -qE '^[A-Za-z0-9._-]{1,32}$'; then
            TAG_OK=1
        fi

        # STEP 3: every value's shape, one refusal per key, all before anything host-facing.
        # `printf '%s\n'`, not `printf '%s'`: an empty value printed WITHOUT a newline is zero
        # bytes, and grep on zero bytes sees no lines and therefore matches nothing -- so a rule
        # like `^[A-Za-z0-9;_-]*$`, which exists precisely to ALLOW an empty value, would refuse
        # one. Measured on EXTRA_APPS=, where it turned every default job into JOB-ENV-INVALID.
        # The sentinel above guarantees every value is one line, so the added newline adds no line.
        if [ "$JOB_KEYS_END" != "END-OF-JOB-KEYS" ]; then
            smoke_log "[smoke] JOB-ENV-INVALID -- a smoke-job.env value spans more than one line; no run attempted"
            SMOKE_RC=65
        elif [ "$TAG_OK" -ne 1 ]; then
            smoke_log "[smoke] JOB-ENV-INVALID -- TAG must match ^[A-Za-z0-9._-]{1,32}\$ (it names smoke-<TAG>.log and window-smoke-<TAG>.log); no run attempted"
            SMOKE_RC=65
        elif ! printf '%s\n' "$BATCH" | grep -qE '^[A-Za-z0-9._-]{1,32}$' \
            || [ "$BATCH" = '.' ] || [ "$BATCH" = '..' ]; then
            # `.` and `..` pass the character class and are still not directory NAMES: BATCH is one
            # path component under .build/evidence/, and `..` would put a run's evidence log in
            # .build/ next to the build tree. Excluded by value rather than by making the class
            # unreadable.
            smoke_log "[smoke] JOB-ENV-INVALID -- BATCH must match ^[A-Za-z0-9._-]{1,32}\$ and be a real directory name (not . or ..); it names .build/evidence/<BATCH>/, which is how a run is attributed to a checkpoint; no run attempted"
            SMOKE_RC=65
        elif [ -n "$DISPLAY_LOOKS_LIKE" ] && ! printf '%s\n' "$DISPLAY_LOOKS_LIKE" | grep -qE '^[1-9][0-9]{1,4}x[1-9][0-9]{1,4}$'; then
            smoke_log "[smoke] JOB-ENV-INVALID -- DISPLAY_LOOKS_LIKE must be <w>x<h> (e.g. 1280x720) or empty for no check; no run attempted"
            SMOKE_RC=65
        elif ! smoke_scale_ok "$ADVERTISED_SCALE"; then
            smoke_log "[smoke] JOB-ENV-INVALID -- ADVERTISED_SCALE must be D (product default, knob unset) | none | DD | <desktop>[,<device>] with desktop 100-500 and device 100/140/180; no run attempted"
            SMOKE_RC=65
        elif ! printf '%s\n' "$MOVE$MAXIMIZE$TRAY$TRAY_CLICK" | grep -qE '^[01]{4}$'; then
            smoke_log "[smoke] JOB-ENV-INVALID -- MOVE, MAXIMIZE, TRAY and TRAY_CLICK must each be 0 or 1; no run attempted"
            SMOKE_RC=65
        elif ! printf '%s\n' "$EDGE_PROFILE" | grep -qE '^[01]$'; then
            smoke_log "[smoke] JOB-ENV-INVALID -- EDGE_PROFILE must be 0 or 1 (1 sets WINDOW_SMOKE_EDGE_PROFILE=1, the O-A measurement-only edge/corner profile; absent or 0 leaves the knob unset); no run attempted"
            SMOKE_RC=65
        elif ! printf '%s\n' "$EXTRA_APPS" | grep -qE '^[A-Za-z0-9;_-]*$'; then
            smoke_log "[smoke] JOB-ENV-INVALID -- EXTRA_APPS must match ^[A-Za-z0-9;_-]*\$ (the child splits it on ';'); no run attempted"
            SMOKE_RC=65
        elif [ "${#MOVE_TARGET}" -gt 255 ] || case "$MOVE_TARGET" in *'$'* | *'`'*) true ;; *) false ;; esac then
            # The 255 matches APP/APP_ARGS's bound (smoke_ascii_arg_ok) rather than answering a
            # threat: nothing here is close to E2BIG. What it buys is that every value this wrapper
            # forwards has a stated ceiling, so "how long can a job file's value be" has one answer
            # instead of two, and a window title that ran away is refused at the definition.
            smoke_log "[smoke] JOB-ENV-INVALID -- MOVE_TARGET must be at most 255 characters and must not contain '\$' or a backtick (it is free text otherwise, and carries CJK titles by design); no run attempted"
            SMOKE_RC=65
        elif ! smoke_ascii_arg_ok "$APP" || ! smoke_ascii_arg_ok "$APP_ARGS"; then
            smoke_log "[smoke] JOB-ENV-INVALID -- APP and APP_ARGS must be <=255 Windows path/argument characters (letters, digits, space and . _ : % ( ) + , @ = * ? \\ / -); no run attempted"
            SMOKE_RC=65
        elif [ -n "$REQUIRE_SYMBOL" ] && ! printf '%s\n' "$REQUIRE_SYMBOL" | grep -qE '^[A-Za-z0-9_]{1,64}$'; then
            smoke_log "[smoke] JOB-ENV-INVALID -- REQUIRE_SYMBOL must match ^[A-Za-z0-9_]{1,64}\$ (it is a symbol name grepped for in Tools/window-smoke/main.swift) or be empty; no run attempted"
            SMOKE_RC=65
        # STEP 4: the two preflight gates. Both come from the 2026-09-09 checkpoint's per-run
        # wrappers, and both refuse rather than run: each guards a premise the run's own evidence
        # cannot restate afterwards.
        # They answer with the SAME code, 75, and neither with the 3 those wrappers used (see the
        # code table at the top). They are one kind of refusal: the job file is correct and THIS
        # ENVIRONMENT is not the one it describes -- a display that is not the required geometry, a
        # checkout that does not carry the knob the run is named for. Both are fixed by changing the
        # environment, and afterwards the identical job file runs, which is exactly what EX_TEMPFAIL
        # means. What separates them from 65 is not severity but WHERE the fix goes: 65 sends the
        # reader to the job file, 75 sends them to the machine. The reason line above DONE says which
        # of the two preflights spoke; the code says which drawer to look in. And 3 said neither,
        # which is why it now belongs to the launcher alone.
        elif [ -n "$REQUIRE_SYMBOL" ] && ! grep -qF "$REQUIRE_SYMBOL" "$REPO_ROOT/Tools/window-smoke/main.swift" 2>/dev/null; then
            smoke_log "[smoke] REFUSED: the checkout does not carry $REQUIRE_SYMBOL -- Tools/window-smoke/main.swift is missing it (or missing entirely), so this run would exercise the default and say nothing about the knob it is named for; nothing was built, nothing was connected"
            SMOKE_RC=75
        elif [ -n "$DISPLAY_LOOKS_LIKE" ] && ! system_profiler SPDisplaysDataType 2>/dev/null | grep -qF "UI Looks like: ${DISPLAY_LOOKS_LIKE%x*} x ${DISPLAY_LOOKS_LIKE#*x}"; then
            smoke_log "[smoke] REFUSED: display is not looks-like $DISPLAY_LOOKS_LIKE -- the run's remote-pixel arithmetic assumes that geometry and is unjudgeable on any other; nothing was built, nothing was connected"
            SMOKE_RC=75
        else
            # The evidence log is the run's own artefact and lives under the batch directory, which
            # is this wrapper's to create. It is NOT masked (see the header): the records read it
            # through their own masking readers, and it never leaves .build/.
            WS_LOG="$REPO_ROOT/.build/evidence/$BATCH/window-smoke-$TAG.log"
            mkdir -p "$REPO_ROOT/.build/evidence/$BATCH"
            # Every managed knob is REMOVED first and only the selected ones put back, so the
            # child's environment is a function of the job file alone. WIN_* go too: the child
            # re-reads host.env itself (MacdowsCore's EnvFile), which is exactly what it does when
            # a human launches it, so this wrapper never hands it a credential. TERM_PROGRAM is
            # cleared to DISARM the launcher's own self-close: it fires on ITS success, matched on
            # a tty that is also OURS, and would close this window from under the DONE line.
            CHILD_ENV=(-u WIN_HOST -u WIN_USER -u WIN_PASS)
            for managed in $SMOKE_MANAGED_VARS; do
                CHILD_ENV+=(-u "$managed")
            done
            CHILD_ENV+=(TERM_PROGRAM= "WINDOW_SMOKE_LOG=$WS_LOG")
            # D = the product default = the knob UNSET (main.swift: unset/empty is the product
            # default, ADR-0018 U-1). The other three forms are passed through verbatim.
            if [ "$ADVERTISED_SCALE" != 'D' ]; then
                CHILD_ENV+=("WINDOW_SMOKE_ADVERTISED_SCALE=$ADVERTISED_SCALE")
            fi
            # 0 is expressed by ABSENCE, not by `=0`: main.swift tests each switch for the string
            # "1", so the two are equivalent to the child, and absence is the one a reader of the
            # child's environment cannot misread.
            if [ "$MOVE" = '1' ]; then CHILD_ENV+=('WINDOW_SMOKE_MOVE=1'); fi
            if [ "$MAXIMIZE" = '1' ]; then CHILD_ENV+=('WINDOW_SMOKE_MAXIMIZE=1'); fi
            if [ "$TRAY" = '1' ]; then CHILD_ENV+=('WINDOW_SMOKE_TRAY=1'); fi
            if [ "$TRAY_CLICK" = '1' ]; then CHILD_ENV+=('WINDOW_SMOKE_TRAY_CLICK=1'); fi
            if [ "$EDGE_PROFILE" = '1' ]; then CHILD_ENV+=('WINDOW_SMOKE_EDGE_PROFILE=1'); fi
            if [ -n "$EXTRA_APPS" ]; then CHILD_ENV+=("WINDOW_SMOKE_EXTRA_APPS=$EXTRA_APPS"); fi
            if [ -n "$MOVE_TARGET" ]; then CHILD_ENV+=("WINDOW_SMOKE_MOVE_TARGET=$MOVE_TARGET"); fi
            if [ -n "$APP" ]; then CHILD_ENV+=("WINDOW_SMOKE_APP=$APP"); fi
            if [ -n "$APP_ARGS" ]; then CHILD_ENV+=("WINDOW_SMOKE_APP_ARGS=$APP_ARGS"); fi
            smoke_log "[smoke] run tag=$TAG batch=$BATCH advertised_scale=$ADVERTISED_SCALE move=$MOVE maximize=$MAXIMIZE tray=$TRAY tray_click=$TRAY_CLICK edge_profile=$EDGE_PROFILE extra_apps=${EXTRA_APPS:-<none>} start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            smoke_log "[smoke] evidence log: $WS_LOG"
            # The launcher's stdout/stderr is piped into smoke.log so a human polling this wrapper
            # sees the build and the gate live -- hence PIPESTATUS rather than $?, which would be
            # the mask's status. The launcher's own DONE line is in the EVIDENCE log; this one is
            # the wrapper's, and they carry the same code on every path that reaches the launcher.
            env "${CHILD_ENV[@]}" "$REPO_ROOT/Scripts/run-window-smoke.command" 2>&1 | smoke_sink
            SMOKE_RC=${PIPESTATUS[0]}
            smoke_log "[smoke] end=$(date -u +%Y-%m-%dT%H:%M:%SZ) rc=$SMOKE_RC"
        fi
    fi
fi

smoke_finish "$SMOKE_RC"
# Owner rule: the window's own exit status is meaningless (nobody sees it); the real verdict is the
# DONE line, which every caller polls for.
exit 0
