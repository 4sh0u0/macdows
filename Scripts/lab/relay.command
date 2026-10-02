#!/usr/bin/env bash
# lab relay -- one-shot RemoteApp run against the owner's own test host (authorized e2e
# lab; same posture as W7's acceptance relay). Reads NO credentials itself beyond
# sourcing the owner's untracked host.env. Launched via Terminal.app (local-network TCC
# holder); `open -a Terminal` does not pass environment variables through, so ALL job
# parameters come from job.env (the client pin is not a job parameter -- see CLIENT PIN).
#
# THIS FILE IS TRACKED (Scripts/lab, since 2026-09-01) and therefore world-readable: it
# must never gain a host address, account name or credential. Everything host-specific is
# read at run time from the owner's untracked ~/.config/macdows/host.env, and everything
# this run produces -- job.env, relay.log and the redirected drive itself -- lives under
# .build/lab-runtime/, which git ignores. See run-matrix.sh's header for the full split.
#
# LIVE-HOST BOUNDARY GATE (owner rule 2026-08-31): before xfreerdp is invoked,
# crdp_assert_lab_boundary (Scripts/lib.sh) must confirm WIN_HOST is inside the owner's
# own lab segments. Fail-closed -- a refusal writes BOUNDARY-REFUSED plus a non-zero DONE
# line to relay.log and no connection is attempted. The window still self-closes; the
# verdict lives in the log, which is what callers poll.
#
# CLIENT PIN (2026-09-28): on 2026-09-24 Homebrew silently upgraded xfreerdp to FreeRDP 3.32.0,
# whose drive redirection regressed (upstream FreeRDP issue #13495: drive_file_read passes the
# wrong object to GetFileSize, so every redirected file reads as size 0). Host-side jobs that
# read their payload from \\tsclient\lab then ran on empty input and still ended DONE exit=0,
# and nothing in relay.log said which client had dialled. So the client is now pinnable and
# fingerprinted. After job.env has been validated, the binary that dials is resolved as:
#   1. .build/lab-runtime/relay-client.env (untracked; one line MACDOWS_XFREERDP='<abs path>').
#      When the file is PRESENT -- a dangling symlink, a directory or an unreadable file counts as
#      present -- it is authoritative: it must be a readable regular file, it is read like job.env
#      (executed once in a subshell, only that one key comes back out, a trailing CR is stripped),
#      and a missing, empty, multi-line, relative or non-executable value refuses the run -- it
#      never falls through to 2 or 3. To unpin, delete the file.
#   2. MACDOWS_XFREERDP from the environment, when non-empty (same validation). `open -a Terminal`
#      does not pass the caller's environment through, so this level reaches a launched relay
#      only via what the Terminal login shell itself exports (shell start-up files, `launchctl
#      setenv`) -- or when the relay is run by hand from a shell.
#   3. xfreerdp from PATH (the behaviour before this pin); nothing found refuses the run.
# The resolved client must then answer `--version` with exit status 0: a pin whose libraries no
# longer load (dyld failure, abort) or whose interpreter is gone is refused here instead of
# dialling and ending DONE exit=0 with nothing done on the host. The probe runs with stdin and
# stderr on /dev/null, and it has no timeout: a client that hangs on --version stalls the relay
# before its DONE line, and the caller's own WAIT_* timeout is the backstop. A refusal writes
# CLIENT-INVALID plus DONE exit=69 (EX_UNAVAILABLE) and dials nothing. The pin is deliberately
# NOT a job.env key: it describes the machine the relay runs on, not the job -- every job of a
# batch must dial through the same binary, and jobs/*.env are tracked while the pin is a
# machine-local path that may sit under the home directory. Every dialling run logs
#   [relay] client=<x.y.z|unknown> sha8=<first 8 hex of the binary's SHA-256|unknown> source=<file|env|path>
# before its program= line (source= names the level that chose the client: file = 1, env = 2,
# path = 3). The version is the first x.y.z
# after "version " on the first --version line, skipping a leading [argv0] (FreeRDP's
# print_version_ex form puts the binary's path, whose directory may itself carry a version,
# there); `unknown` when there is none. sha8 fingerprints the executable only: the drive code
# lives in libfreerdp-client, loaded through @rpath, which the version token reflects (that
# library prints it) and sha8 does not. Neither this line nor anything else the relay writes
# carries the pin path, and the client is started as `exec -a xfreerdp`, so its argv[0] -- which
# FreeRDP echoes into relay.log in its usage and error banners -- is `xfreerdp`, as before the pin.
#
# LOGON-INFO MASK (2026-10-02): on every successful logon FreeRDP's client_common_save_session_info
# logs `Logon Info V2 [<domain>\<user> [<session id>]]` (V1 for the older PDU), i.e. the host's
# computer name and the lab account, and relay.log is copied into evidence directories and from
# there into the docs archives. So once xfreerdp has exited (by itself or by the TIMEOUT kill) and
# before the DONE line, a dialling run rewrites relay.log once: on every line carrying
# `Logon Info V1 [` or `Logon Info V2 [`, the text after that `[` up to the first ` [` or `]` (the
# `<domain>\<user>` segment; the rest of the line when neither follows) becomes `<host>\<lab-user>`
# -- but only when that segment carries a backslash: a segment without one (FreeRDP's
# `<INVALID DATA>` when the PDU carried no logon info) is left as it was and is not counted, so a
# diagnostic line never passes for a logon.
# Every other byte stays as it was -- line order, the `[relay]` lines, timestamps, the ` [<n>]]`
# tail and the `Logon Info V[12]` / ERRINFO_* tokens the preregistered greps key on. The rewrite
# goes through a temp file under .build/lab-runtime and back with `cat tmp >relay.log`, never `mv`
# or `sed -i`, so the log keeps its inode for anyone reading it with `tail -f` or a poll loop; it
# runs after xfreerdp has gone, so nothing is inserted between the client and the log ($! stays
# the client's pid). It is skipped when no line matched. The run then logs
#   [relay] masked logon-info lines=<n>
# after `[relay] xfreerdp exited` (n may be 0; the line names no host or account). If the rewrite
# fails, the run logs `[relay] MASK-FAILED -- <reason>; …` instead (on a line of its own, even after a copy-back that stopped mid-line) and still writes DONE, with
# exit=74 (EX_IOERR) -- the log may then carry the names, and the caller must not archive it as is.
# Refused runs (78 / 66 / 65 / 69) dial nothing and are not rewritten. Lines xfreerdp wrote while
# it was still running were unmasked until then; only a reader that waits for DONE sees the mask.
# A reader following relay.log as a stream sees more than that: `cat tmp >relay.log` truncates
# before it writes, so `tail -f` / `tail -F` report "file truncated" and replay the whole file
# (the Logon Info and ERRINFO_* lines a second time) when the masked log is shorter than what they
# had read, and may miss the truncation and print misaligned fragments when it is not. Readers
# therefore judge a run by its DONE line and the log as it stands then, never by counting lines off
# a tail stream. The two temp files are named in RELAY_MASK_TMP / RELAY_MASK_COUNT, not in function
# locals, so the EXIT trap (HUP / INT / TERM exit through it) removes them when the relay dies
# mid-rewrite -- relay.log may then be cut short and carry no DONE line, and the caller's own wait
# ceiling ends the step.
#
# job.env keys:
#   PROGRAM   Windows path of the RemoteApp program to run
#   CMDARGS   command-line arguments (optional; must contain no commas -- xfreerdp's
#             /app sub-parser splits on commas, so put complex logic in a .ps1 under
#             share/ and pass "-NoProfile -ExecutionPolicy Bypass -File \\tsclient\lab\X.ps1".
#             \\tsclient\lab resolves to the RUNTIME share, into which run-scenario.sh
#             stages the tracked share/*.ps1 before every relay job -- not to the tracked
#             directory. Staging is in run-scenario.sh and NOT in run-matrix.sh on purpose:
#             the hand-launched lanes never go through run-matrix.sh. See stage_share.)
#   TIMEOUT   seconds before the connection is closed (default 25)
set -u
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
RUNTIME="$REPO_ROOT/.build/lab-runtime"
SHARE="$RUNTIME/share"
mkdir -p "$SHARE"
LOG="$RUNTIME/relay.log"
: > "$LOG"
RELAY_RC=0
# 1 once xfreerdp has been started (LOGON-INFO MASK in the header applies to dialling runs only).
RELAY_DIALLED=0
# LOGON-INFO MASK temp files (header): script-level so the EXIT trap can remove them when the relay
# dies mid-rewrite -- bash 3.2 has no function-local trap. Empty = none.
RELAY_MASK_TMP=''
RELAY_MASK_COUNT=''
# shellcheck disable=SC2329,SC2317  # invoked by the EXIT trap below
relay_mask_cleanup() {
    if [ -n "$RELAY_MASK_TMP" ]; then rm -f "$RELAY_MASK_TMP"; fi
    if [ -n "$RELAY_MASK_COUNT" ]; then rm -f "$RELAY_MASK_COUNT"; fi
    RELAY_MASK_TMP=''; RELAY_MASK_COUNT=''
}
trap relay_mask_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# XFREERDP_EXTRA (job.env, optional; T6-prime RA3 "other client", 2026-09-07): extra xfreerdp
# switches from a CLOSED allowlist -- the scale declarations and /dynamic-resolution -- so a job
# can join the retained session as a client that declares a non-100 % scale. Every token must
# match one shape exactly; anything else (a /v:, /u:, /p:, /drive:, a path, a shell character)
# refuses the whole job as JOB-ENV-INVALID before any connection. The shapes admit no space,
# quote, glob or comma, so the validated value can be word-split into argv safely.
relay_extra_tokens_ok() { # <XFREERDP_EXTRA value>
    # The split happens with globbing off (and restored afterwards -- bash 3.2 has no
    # function-local `set -f`), so a value such as `/*` is judged as the literal text it is,
    # never as whatever the filesystem happens to expand it to (relay-extra gate r1 m-3).
    local tok restore_glob=''
    case $- in *f*) ;; *) restore_glob='set +f' ;; esac
    set -f
    for tok in $1; do
        if ! printf '%s' "$tok" | grep -qE '^/(scale:(100|140|180)|scale-desktop:(1[0-9][0-9]|[2-4][0-9][0-9]|500)|scale-device:(100|140|180)|dynamic-resolution)$'; then
            $restore_glob
            return 1
        fi
    done
    $restore_glob
    return 0
}

# Resolves the client that will dial (CLIENT PIN in the header) and fingerprints it. On success
# sets XFREERDP_BIN (an absolute path), XFREERDP_SOURCE (file|env|path), CLIENT_VERSION and
# CLIENT_SHA8 and returns 0; on refusal sets CLIENT_REASON (a fixed text -- never the path) and
# returns 1 having run nothing but, at most, the client's own --version probe.
relay_resolve_client() {
    local pin='' pin_source='' client_end='' client_keys cr ver_out ver_rc ver_line
    cr=$(printf '\r')
    XFREERDP_BIN=''; XFREERDP_SOURCE=''; CLIENT_VERSION=''; CLIENT_SHA8=''; CLIENT_REASON=''
    # `-L` too: a dangling symlink is not `-e`, and it must refuse rather than fall through.
    if [ -e "$RUNTIME/relay-client.env" ] || [ -L "$RUNTIME/relay-client.env" ]; then
        if [ ! -f "$RUNTIME/relay-client.env" ] || [ ! -r "$RUNTIME/relay-client.env" ]; then
            CLIENT_REASON="relay-client.env is not a readable regular file"
            return 1
        fi
        # Same isolation as job.env: executed once in a subshell, one key plus a sentinel come
        # back out, so the file cannot redefine the gate, a function or any other variable of
        # this shell. MACDOWS_XFREERDP is unset first, so a file that sets nothing refuses the run
        # instead of silently handing over the environment's value.
        # shellcheck source=/dev/null
        client_keys="$( unset MACDOWS_XFREERDP; . "$RUNTIME/relay-client.env" >/dev/null 2>&1; printf '%s\n%s\n' "${MACDOWS_XFREERDP:-}" 'END-OF-CLIENT-KEYS' )"
        { IFS= read -r pin; IFS= read -r client_end; } <<EOF_CLIENT_KEYS
$client_keys
EOF_CLIENT_KEYS
        pin="${pin%"$cr"}"; client_end="${client_end%"$cr"}"
        if [ "$client_end" != "END-OF-CLIENT-KEYS" ]; then
            CLIENT_REASON="relay-client.env does not yield one single-line MACDOWS_XFREERDP (multi-line value or early exit)"
            return 1
        elif [ -z "$pin" ]; then
            CLIENT_REASON="relay-client.env exists but sets no MACDOWS_XFREERDP"
            return 1
        fi
        pin_source='file'
    else
        pin="${MACDOWS_XFREERDP:-}"
        pin_source='env'
    fi
    if [ -n "$pin" ]; then
        XFREERDP_BIN="$pin"
        XFREERDP_SOURCE="$pin_source"
    else
        XFREERDP_BIN="$(command -v xfreerdp 2>/dev/null)"
        XFREERDP_SOURCE='path'
    fi
    # Absolute, a regular file (a directory is -x too) and executable. `command -v` answers a bare
    # name for a function or alias, which the absolute-path test turns away as well.
    case "$XFREERDP_BIN" in
        /*) ;;
        *) XFREERDP_BIN='' ;;
    esac
    if [ -z "$XFREERDP_BIN" ] || [ ! -f "$XFREERDP_BIN" ] || [ ! -x "$XFREERDP_BIN" ]; then
        if [ "$XFREERDP_SOURCE" != "path" ]; then
            CLIENT_REASON="MACDOWS_XFREERDP is not an executable absolute path"
        else
            CLIENT_REASON="no executable xfreerdp on PATH"
        fi
        return 1
    fi
    # The probe must exit 0 (CLIENT PIN in the header). Its stderr goes to /dev/null so a loader or
    # interpreter error naming the binary's path never reaches relay.log; its stdin is /dev/null
    # so it can never consume or wait on the relay's own stdin.
    ver_out="$("$XFREERDP_BIN" --version 2>/dev/null </dev/null)"; ver_rc=$?
    if [ "$ver_rc" -ne 0 ]; then
        CLIENT_REASON="client version probe failed"
        return 1
    fi
    # First line only; drop everything up to "version " and a leading "[argv0] ", then take the
    # first x.y.z -- the trailing (<revision>) may repeat it, hence the final head.
    ver_line="$(printf '%s\n' "$ver_out" | head -n 1)"
    case "$ver_line" in *'version '*) ver_line="${ver_line#*version }" ;; esac
    case "$ver_line" in '['*) ver_line="${ver_line#*] }" ;; esac
    CLIENT_VERSION="$(printf '%s\n' "$ver_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
    [ -n "$CLIENT_VERSION" ] || CLIENT_VERSION=unknown
    # Read through the path as resolved: shasum follows a symlink (Homebrew's bin/ entry), so the
    # digest is that of the real binary, the same as hashing its `readlink -f` target. stderr is
    # redirected BEFORE the input, so an unreadable (execute-only) binary's redirection error --
    # which names the path -- goes to /dev/null too; the shape check then records `unknown`.
    CLIENT_SHA8="$(shasum -a 256 2>/dev/null <"$XFREERDP_BIN" | cut -c1-8)"
    printf '%s' "$CLIENT_SHA8" | grep -qE '^[0-9a-f]{8}$' || CLIENT_SHA8=unknown
    return 0
}

# LOGON-INFO MASK (header). Rewrites $LOG in place; on success sets MASK_LINES (the number of
# lines masked, 0 included) and returns 0, on failure sets MASK_REASON (a fixed text, never a path)
# and returns 1 having left $LOG as it was -- or, when the final copy-back itself failed, as far as
# that copy got. LC_ALL=C makes every awk count bytes; index()/substr() only (no regex, no sub()
# replacement string, no -v), so BSD awk, gawk and mawk produce the same bytes. $LOG always ends
# with the relay's own `[relay] xfreerdp exited` line here, so awk's newline per record reproduces
# the file's newlines exactly. A matched line whose segment carries no backslash is printed as read
# and not counted (header). The temp files live in RELAY_MASK_TMP / RELAY_MASK_COUNT for the EXIT
# trap and are removed through relay_mask_cleanup on every return.
relay_mask_logon_info() {
    MASK_LINES=''; MASK_REASON=''
    RELAY_MASK_TMP="$(mktemp "$RUNTIME/.relay-mask.XXXXXX" 2>/dev/null)" || { RELAY_MASK_TMP=''; MASK_REASON="no temp file"; return 1; }
    RELAY_MASK_COUNT="$(mktemp "$RUNTIME/.relay-mask-count.XXXXXX" 2>/dev/null)" || { RELAY_MASK_COUNT=''; relay_mask_cleanup; MASK_REASON="no temp file"; return 1; }
    if ! LC_ALL=C RELAY_MASK_COUNT="$RELAY_MASK_COUNT" awk '
        BEGIN { n = 0; bs = "\\"; masked = "<host>" bs "<lab-user>" }
        {
            line = $0
            p = index(line, "Logon Info V1 [")
            q = index(line, "Logon Info V2 [")
            if (q > 0 && (p == 0 || q < p)) p = q
            if (p > 0) {
                s = p + 15
                rest = substr(line, s)
                e = index(rest, " [")
                b = index(rest, "]")
                if (b > 0 && (e == 0 || b < e)) e = b
                seg = rest
                tail = ""
                if (e > 0) { seg = substr(rest, 1, e - 1); tail = substr(rest, e) }
                if (index(seg, bs) > 0) {
                    line = substr(line, 1, s - 1) masked tail
                    n++
                }
            }
            print line
        }
        END { print n > ENVIRON["RELAY_MASK_COUNT"] }
    ' "$LOG" >"$RELAY_MASK_TMP" 2>/dev/null; then
        relay_mask_cleanup; MASK_REASON="the mask filter failed"; return 1
    fi
    MASK_LINES="$(head -n 1 "$RELAY_MASK_COUNT" 2>/dev/null)"
    case "$MASK_LINES" in
        '' | *[!0-9]*) relay_mask_cleanup; MASK_LINES=''; MASK_REASON="the mask filter reported no line count"; return 1 ;;
    esac
    if [ "$MASK_LINES" -gt 0 ]; then
        # Same inode (header): truncate-and-write through the existing name, never a rename.
        if ! cat "$RELAY_MASK_TMP" >"$LOG"; then
            relay_mask_cleanup; MASK_REASON="the masked log could not be written back"; return 1
        fi
    fi
    relay_mask_cleanup
    return 0
}

{
    # shellcheck source=/dev/null
    source "$HOME/.config/macdows/host.env"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/Scripts/lib.sh"
    # lib.sh turns on -e/pipefail for its sourcer; this relay deliberately runs with
    # neither (it kills and reaps xfreerdp by hand, and those calls are allowed to fail).
    set +e +o pipefail
    # The boundary gate runs FIRST and judges host.env alone. job.env is a per-run file under
    # .build/ and is never sourced into THIS shell: it is executed once, in a subshell, and only
    # its three keys (PROGRAM, CMDARGS, TIMEOUT) come back out. That isolates what job.env can
    # WRITE (its variables, functions, traps and `exit` die with the subshell), not what it can
    # READ (the subshell inherits this environment) -- sourcing it here let it redefine
    # crdp_assert_lab_boundary (review relay-offline r2 B2) and, once that was closed by
    # ordering, overwrite WIN_HOST/WIN_USER/WIN_PASS/SHARE after the gate had passed -- the gate
    # approving one host and xfreerdp dialling another (r3 B1). test-relay-offline.sh pins
    # both (cases 10b/10c). Each key is then validated: a missing or PROGRAM-less job used to
    # trip `set -u` on "${PROGRAM}" and kill this shell BEFORE the DONE line, so the caller
    # (run-matrix.sh's run_relay_job) could only give up on its own WAIT_* timeout, and a
    # non-numeric TIMEOUT made the poll loop's `-lt` fail so the connection was torn down at
    # once yet reported DONE exit=0 (r4 I1). The contract is "every run writes DONE" -- the
    # job.env refusals keep it, each with a named reason and a sysexits code the caller can
    # tell apart (66 EX_NOINPUT / 65 EX_DATAERR; 78 EX_CONFIG stays the boundary's; 69
    # EX_UNAVAILABLE is the client pin's CLIENT-INVALID, see CLIENT PIN in the header; 74
    # EX_IOERR is a dialling run's MASK-FAILED, see LOGON-INFO MASK in the header).
    if ! crdp_assert_lab_boundary "${WIN_HOST:-}"; then
        echo "[relay] BOUNDARY-REFUSED -- target is not a permitted lab host; no connection attempted"
        RELAY_RC=78
    elif [ ! -r "$RUNTIME/job.env" ]; then
        # The repo-relative spelling: $RUNTIME is an absolute path that may sit under the home
        # directory, and nothing the relay logs names one.
        echo "[relay] JOB-ENV-MISSING -- .build/lab-runtime/job.env is not readable; no connection attempted"
        RELAY_RC=66
    else
        # One subshell, four lines out plus a sentinel (the keys are single-line by contract;
        # `read -r` keeps CMDARGS' backslashes). job.env therefore runs exactly once. A value
        # carrying a newline would shift the following lines, so the fourth read must land on
        # the sentinel or the job is refused as multi-line. job.env is normally copied from
        # jobs/*.env by run-scenario.sh (LF), but a hand-edited CRLF file leaves a trailing CR on
        # each value; it is stripped, not shipped to xfreerdp's argv or fed to the TIMEOUT check
        # (review relay-offline r5 minors, r6 I1).
        # shellcheck source=/dev/null
        JOB_KEYS="$( . "$RUNTIME/job.env" >/dev/null 2>&1; printf '%s\n%s\n%s\n%s\n%s\n' "${PROGRAM:-}" "${CMDARGS:-}" "${TIMEOUT:-}" "${XFREERDP_EXTRA:-}" 'END-OF-JOB-KEYS' )"
        PROGRAM=""; CMDARGS=""; TIMEOUT=""; XFREERDP_EXTRA=""; JOB_KEYS_END=""
        { IFS= read -r PROGRAM; IFS= read -r CMDARGS; IFS= read -r TIMEOUT; IFS= read -r XFREERDP_EXTRA; IFS= read -r JOB_KEYS_END; } <<EOF_JOB_KEYS
$JOB_KEYS
EOF_JOB_KEYS
        CR=$(printf '\r')
        PROGRAM="${PROGRAM%"$CR"}"; CMDARGS="${CMDARGS%"$CR"}"; TIMEOUT="${TIMEOUT%"$CR"}"; XFREERDP_EXTRA="${XFREERDP_EXTRA%"$CR"}"; JOB_KEYS_END="${JOB_KEYS_END%"$CR"}"
        TIMEOUT="${TIMEOUT:-25}"
        if [ "$JOB_KEYS_END" != "END-OF-JOB-KEYS" ]; then
            echo "[relay] JOB-ENV-INVALID -- a job.env value spans more than one line; no connection attempted"
            RELAY_RC=65
        elif [ -z "$PROGRAM" ]; then
            echo "[relay] JOB-ENV-INVALID -- job.env sets no PROGRAM; no connection attempted"
            RELAY_RC=65
        elif ! printf '%s' "$TIMEOUT" | grep -qE '^[1-9][0-9]*$'; then
            echo "[relay] JOB-ENV-INVALID -- job.env TIMEOUT is not a positive integer; no connection attempted"
            RELAY_RC=65
        elif ! relay_extra_tokens_ok "$XFREERDP_EXTRA"; then
            echo "[relay] JOB-ENV-INVALID -- job.env XFREERDP_EXTRA carries a switch outside the allowlist (/scale:<100|140|180>, /scale-desktop:<100-500>, /scale-device:<100|140|180>, /dynamic-resolution); no connection attempted"
            RELAY_RC=65
        elif ! relay_resolve_client; then
            echo "[relay] CLIENT-INVALID -- ${CLIENT_REASON}; no connection attempted"
            RELAY_RC=69
        else
            echo "[relay] client=${CLIENT_VERSION} sha8=${CLIENT_SHA8} source=${XFREERDP_SOURCE}"
            APP_SPEC="/app:program:${PROGRAM}"
            if [ -n "${CMDARGS:-}" ]; then
                APP_SPEC="${APP_SPEC},cmd:${CMDARGS}"
            fi
            echo "[relay] program=${PROGRAM} timeout=${TIMEOUT}s extra=${XFREERDP_EXTRA:-<none>}"
            # XFREERDP_EXTRA is word-split on purpose: every token has passed relay_extra_tokens_ok,
            # whose shapes contain no whitespace, quote, glob or comma, so splitting yields exactly
            # the validated tokens (or nothing) as separate argv elements. `set -f` around the split
            # is defence in depth (relay-extra gate r1 m-3): even a token that somehow carried a glob
            # character could not expand against the filesystem. The relay uses no positional
            # parameters of its own, so `set --` is free to hold the tokens.
            set -f
            # shellcheck disable=SC2086
            set -- $XFREERDP_EXTRA
            set +f
            RELAY_DIALLED=1
            # `exec -a xfreerdp` keeps argv[0] what it was before the pin (CLIENT PIN in the header)
            # instead of the pin's absolute path. The subshell execs the client, so $! is the
            # client's own pid and the TIMEOUT kill below still reaches it.
            ( exec -a xfreerdp "$XFREERDP_BIN" "/v:${WIN_HOST}" "/u:${WIN_USER}" "/p:${WIN_PASS}" /cert:ignore \
                "$@" "$APP_SPEC" "/drive:lab,${SHARE}" /gfx:AVC420 ) &
            XPID=$!
            SECS=0
            while kill -0 "$XPID" 2>/dev/null && [ "$SECS" -lt "$TIMEOUT" ]; do
                sleep 1
                SECS=$((SECS + 1))
            done
            if kill -0 "$XPID" 2>/dev/null; then
                echo "[relay] timeout reached -- closing connection"
                kill "$XPID" 2>/dev/null
                wait "$XPID" 2>/dev/null
            fi
            echo "[relay] xfreerdp exited"
        fi
    fi
} >>"$LOG" 2>&1
# LOGON-INFO MASK (header): after `[relay] xfreerdp exited`, before DONE, dialling runs only.
if [ "$RELAY_DIALLED" -eq 1 ]; then
    if relay_mask_logon_info; then
        echo "[relay] masked logon-info lines=${MASK_LINES}" >>"$LOG"
    else
        # A copy-back that failed half-way (suite 14i) can leave a partial last line with no newline;
        # start the MASK-FAILED line on a line of its own so `^\[relay\] MASK-FAILED` readers never
        # miss it ($(tail -c 1) is empty exactly when the last byte is a newline).
        if [ -s "$LOG" ] && [ -n "$(tail -c 1 "$LOG")" ]; then echo >>"$LOG"; fi
        echo "[relay] MASK-FAILED -- ${MASK_REASON}; this log may still carry the host and account names, do not archive it as is" >>"$LOG"
        RELAY_RC=74
    fi
fi
echo "DONE exit=$RELAY_RC" >>"$LOG"
# self-close this Terminal window (same mechanism as Scripts/run-window-smoke.command)
if [ -n "${TERM_PROGRAM:-}" ] && [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
    TTY_NAME=$(tty)
    osascript -e 'tell application "Terminal" to close (every window whose tty is "'"$TTY_NAME"'")' >/dev/null 2>&1 &
fi
