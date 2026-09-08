#!/usr/bin/env bash
# lab Device Portal ETW capture -- one realtime ETW subscription against the owner's own test
# host's Windows Device Portal (authorized e2e lab; same posture as the relay). Launched via
# Terminal.app, which holds the local-network TCC grant; `open -a Terminal` does not pass
# environment variables through, so ALL parameters come from etw-job.env.
#
# THIS FILE IS TRACKED (Scripts/lab) and therefore world-readable: it must never gain a host
# address, an account name, a credential or a maintainer path. Everything host-specific is read
# at run time from the owner's untracked ~/.config/macdows/host.env, every path is derived from
# BASH_SOURCE, and everything a run produces -- the job instance, etw.log, the certificate pin
# and the capture itself -- lives under .build/lab-runtime/, which git ignores.
#
# LIVE-HOST BOUNDARY GATE (owner rule 2026-08-31): before ANYTHING else, crdp_assert_lab_boundary
# (Scripts/lib.sh) must confirm WIN_HOST is inside the owner's own lab segments. Fail-closed -- a
# refusal writes BOUNDARY-REFUSED plus DONE exit=78 and stops. The gate is deliberately the FIRST
# step rather than merely "before the connection": this wrapper is the one script in the repo that
# writes the portal password into a file, and a run aimed at a host outside the boundary must not
# cause that file to exist at all.
#
# CERTIFICATE PIN. The portal serves a self-signed certificate, so the client trusts the pinned
# SHA-256 of its leaf and nothing else. No pin, no capture (PIN-MISSING, exit 79) -- an unpinned
# run would have to fall back to "trust whatever answers", which is precisely the failure mode the
# pin exists to prevent. A pin that is already on disk is NEVER overwritten, whatever the job
# says: the one-line way to defeat a pin is to re-record it against the wrong peer.
#
# LOG MASK. etw.log is the artefact a human pastes into a report, so every line written to it
# goes through etw_sink, which rewrites the host address to <WIN_HOST> and the account to
# <WIN_USER>. The password never reaches any output at all -- it goes from host.env into the
# 0600 credential file and nowhere else. host.env's OWN output is deliberately not routed into
# the log: the mask is built from host.env, so nothing read before it could be masked.
#
# etw-job.env keys (all single-line; the file is read once, in a subshell -- see below):
#   TAG         capture name, ^[A-Za-z0-9_-]{1,32}$; names etw-<TAG>.jsonl and etw-<TAG>.log
#   DURATION    capture seconds, positive integer (default 60)
#   PROVIDERS   <guid>:<level>[;<guid>:<level>...], level 0-5 -- passed to the client verbatim
#   PIN_RECORD  0|1 (default 0); 1 records the certificate pin ONCE if none exists yet
set -u
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
RUNTIME="$REPO_ROOT/.build/lab-runtime"
WDP="$RUNTIME/wdp"
mkdir -p "$WDP"
LOG="$RUNTIME/etw.log"
# Truncate the log FIRST (relay.command does the same): if anything below dies before the verdict
# is written -- a host.env that exits, a missing lib.sh -- the caller must find an empty log and
# time out, never last run's DONE exit=0.
: > "$LOG"
PINFILE="$WDP/portal-cert-sha256.txt"
ETW_RC=0
CRED=''
HOST_RE=''
USER_RE=''
TAG=''
TAG_OK=0

# BRE-escapes a value so it can be used as a sed pattern. WIN_HOST is normally an IP literal, and
# its dots would otherwise match any character -- close enough to look right and wrong enough to
# leak a neighbouring address.
etw_re_escape() { # <literal>
    printf '%s' "$1" | sed 's|[][\.*^$/]|\\&|g'
}

# The mask. Both patterns are applied only when they are non-empty: an empty sed pattern (`s//x/`)
# re-uses the LAST regex, which would substitute something arbitrary rather than nothing.
etw_mask() {
    if [ -n "$HOST_RE" ] && [ -n "$USER_RE" ]; then
        sed -e "s/$HOST_RE/<WIN_HOST>/g" -e "s/$USER_RE/<WIN_USER>/g"
    elif [ -n "$HOST_RE" ]; then
        sed -e "s/$HOST_RE/<WIN_HOST>/g"
    elif [ -n "$USER_RE" ]; then
        sed -e "s/$USER_RE/<WIN_USER>/g"
    else
        cat
    fi
}

# The ONE place bytes reach the log -- the wrapper's own lines, the gate's output and the client's
# stdout/stderr all pass through here, so the mask cannot be bypassed by adding a writer.
etw_sink() {
    etw_mask >> "$LOG"
}

etw_log() { # <text...>
    printf '%s\n' "$*" | etw_sink
}

# The credential file's whole lifecycle in one function, called both inline (as soon as the client
# returns) and from the EXIT trap (so an interrupt, a `set -u` death or a closed window cannot
# leave the portal password on disk). Two removal sites and one implementation: two
# implementations would drift, and the one that drifted would be the trap nobody watches.
etw_drop_cred() {
    [ -n "$CRED" ] || return 0
    rm -f "$CRED"
    CRED=''
}
trap etw_drop_cred EXIT

# shellcheck source=/dev/null
source "$HOME/.config/macdows/host.env"
# shellcheck source=/dev/null
source "$REPO_ROOT/Scripts/lib.sh"
# lib.sh turns on -e/pipefail for its sourcer; this wrapper runs with neither. -e because every
# refusal below is an expected outcome that must still reach the DONE line, and pipefail because
# the client's exit code is read from PIPESTATUS, not from the mask it is piped into.
set +e +o pipefail
HOST_RE="$(etw_re_escape "${WIN_HOST:-}")"
USER_RE="$(etw_re_escape "${WIN_USER:-}")"

# The gate judges host.env alone and runs before the job file is even looked at. Its output is
# captured rather than piped so that its exit status stays readable in THIS shell (a pipe would
# hand back the mask's status) -- and so that its REFUSED line, which names the target by lib.sh's
# design, reaches the log masked like everything else.
GATE_OUT=""
GATE_RC=0
GATE_OUT="$(crdp_assert_lab_boundary "${WIN_HOST:-}" 2>&1)" || GATE_RC=$?
etw_log "$GATE_OUT"
etw_log "[etw] target=${WIN_HOST:-} account=${WIN_USER:-} -- both values masked here, so this log is safe to paste"

if [ "$GATE_RC" -ne 0 ]; then
    etw_log "[etw] BOUNDARY-REFUSED -- target is not a permitted lab host; no capture attempted and no credential file created"
    ETW_RC=78
elif [ ! -r "$RUNTIME/etw-job.env" ]; then
    etw_log "[etw] JOB-ENV-MISSING -- $RUNTIME/etw-job.env is not readable; no capture attempted"
    ETW_RC=66
else
    # One subshell, four keys out plus a sentinel (the keys are single-line by contract). The job
    # instance is a per-run file under .build/ and is never sourced into THIS shell: it is executed
    # once, in a subshell, and only its four keys come back out. That isolates what the job can
    # WRITE -- its variables, functions, traps and `exit` die with the subshell -- so it can
    # neither redefine crdp_assert_lab_boundary (the gate has already run, and the function it ran
    # is still lib.sh's) nor overwrite WIN_HOST/WIN_USER/WIN_PASS/PINFILE after the gate approved
    # them, which would have the gate judging one host and the client dialling another. The
    # sentinel catches a value that spans lines: without it a stray newline shifts every following
    # key and the run proceeds with keys that are silently wrong. A hand-edited CRLF file leaves a
    # trailing CR on each value; it is stripped rather than shipped into a file name, a regex or
    # the client's environment.
    # shellcheck source=/dev/null
    JOB_KEYS="$( . "$RUNTIME/etw-job.env" >/dev/null 2>&1; printf '%s\n%s\n%s\n%s\n%s\n' "${TAG:-}" "${DURATION:-}" "${PROVIDERS:-}" "${PIN_RECORD:-}" 'END-OF-JOB-KEYS' )"
    TAG=""; DURATION=""; PROVIDERS=""; PIN_RECORD=""; JOB_KEYS_END=""
    { IFS= read -r TAG; IFS= read -r DURATION; IFS= read -r PROVIDERS; IFS= read -r PIN_RECORD; IFS= read -r JOB_KEYS_END; } <<EOF_JOB_KEYS
$JOB_KEYS
EOF_JOB_KEYS
    CR=$(printf '\r')
    TAG="${TAG%"$CR"}"; DURATION="${DURATION%"$CR"}"; PROVIDERS="${PROVIDERS%"$CR"}"; PIN_RECORD="${PIN_RECORD%"$CR"}"; JOB_KEYS_END="${JOB_KEYS_END%"$CR"}"
    DURATION="${DURATION:-60}"
    PIN_RECORD="${PIN_RECORD:-0}"
    # TAG's verdict is computed once, here, and reused by the log-copy step at the very bottom:
    # etw-<TAG>.log may only be written for a TAG that passed this exact rule, and a job that
    # spans lines has no trustworthy TAG at all.
    if [ "$JOB_KEYS_END" = "END-OF-JOB-KEYS" ] && printf '%s' "$TAG" | grep -qE '^[A-Za-z0-9_-]{1,32}$'; then
        TAG_OK=1
    fi
    # 8-4-4-4-12 hex, either case, level 0-5, `;`-separated. Written out rather than composed from
    # a variable so that what the wrapper accepts is readable in one line -- this is the value that
    # is handed to the client, and the shape is also what keeps a shell construct out of it.
    GUID_RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
    if [ "$JOB_KEYS_END" != "END-OF-JOB-KEYS" ]; then
        etw_log "[etw] JOB-ENV-INVALID -- an etw-job.env value spans more than one line; no capture attempted"
        ETW_RC=65
    elif [ "$TAG_OK" -ne 1 ]; then
        etw_log "[etw] JOB-ENV-INVALID -- TAG must match ^[A-Za-z0-9_-]{1,32}\$ (it names etw-<TAG>.jsonl and etw-<TAG>.log); no capture attempted"
        ETW_RC=65
    elif ! printf '%s' "$DURATION" | grep -qE '^[1-9][0-9]*$'; then
        etw_log "[etw] JOB-ENV-INVALID -- DURATION is not a positive integer; no capture attempted"
        ETW_RC=65
    elif ! printf '%s' "$PROVIDERS" | grep -qE "^$GUID_RE:[0-5](;$GUID_RE:[0-5])*\$"; then
        etw_log "[etw] JOB-ENV-INVALID -- PROVIDERS must be <guid>:<level 0-5> entries separated by ';'; no capture attempted"
        ETW_RC=65
    elif ! printf '%s' "$PIN_RECORD" | grep -qE '^[01]$'; then
        etw_log "[etw] JOB-ENV-INVALID -- PIN_RECORD must be 0 or 1; no capture attempted"
        ETW_RC=65
    else
        # Whitespace is stripped rather than trusted: a hand-edited pin file with a trailing CR
        # would otherwise reach the client as a malformed pin and be refused there, one layer away
        # from the file that actually needs fixing.
        PIN=""
        if [ -r "$PINFILE" ]; then
            PIN="$(tr -d '[:space:]' < "$PINFILE")"
        fi
        if [ -n "$PIN" ] && [ "$PIN_RECORD" = "1" ]; then
            etw_log "[etw] PIN_RECORD=1 ignored -- a pin is already on file and is never overwritten"
        fi
        if [ -z "$PIN" ] && [ "$PIN_RECORD" = "1" ]; then
            # The gate has already approved WIN_HOST, so this is the first and only moment the
            # wrapper is allowed to touch the network before the capture itself. The fingerprint of
            # a certificate is a public value: logging it is what lets the operator compare it
            # against what the host shows, which is the only check that makes a
            # trust-on-first-use pin worth anything.
            etw_log "[etw] recording the portal certificate pin (PIN_RECORD=1)"
            FP="$(openssl s_client -connect "$WIN_HOST:50443" -servername "$WIN_HOST" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//' | tr -d '[:space:]')"
            # The shape is checked BEFORE the file is written: a portal that did not answer yields
            # an empty fingerprint, and writing that would create a pin file that can never be
            # recorded again (an existing pin is never overwritten) and refuses every future run.
            if printf '%s' "$FP" | grep -qE '^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$|^[0-9A-Fa-f]{64}$'; then
                printf '%s\n' "$FP" > "$PINFILE"
                PIN="$FP"
                etw_log "[etw] pin recorded sha256=$FP"
            else
                etw_log "[etw] PIN-RECORD-FAILED -- the portal returned no SHA-256 fingerprint; nothing written to the pin file"
            fi
        fi
        if [ -z "$PIN" ]; then
            etw_log "[etw] PIN-MISSING -- record it once with PIN_RECORD=1; no capture attempted"
            ETW_RC=79
        else
            # The credential file exists for the length of the capture and no longer. mktemp gives
            # it a private name under TMPDIR; chmod runs BEFORE the password is written, so there
            # is no window in which the file holds the secret at the default umask; the EXIT trap
            # installed at the top of this script owns every path out of here.
            CRED="$(mktemp "${TMPDIR:-/tmp}/macdows-etw-cred.XXXXXX")"
            chmod 600 "$CRED"
            printf '%s:%s\n' "${WIN_USER:-}" "${WIN_PASS:-}" > "$CRED"
            PROV_COUNT="$(printf '%s\n' "$PROVIDERS" | awk -F';' '{print NF}')"
            etw_log "[etw] etw capture tag=$TAG duration=${DURATION}s providers=$PROV_COUNT start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            # Parameters travel in the environment, never in argv: argv is world-readable through
            # `ps` on this platform, and one of these values is the path of a file holding the
            # portal password. The client's stdout/stderr is piped into the log so the capture's
            # progress is visible live to whoever is polling it -- hence PIPESTATUS rather than $?,
            # which would be the mask's status.
            WDP_HOST="$WIN_HOST" \
                WDP_PORT=50443 \
                WDP_CRED_FILE="$CRED" \
                WDP_CERT_SHA256="$PIN" \
                WDP_PROVIDERS="$PROVIDERS" \
                WDP_DURATION="$DURATION" \
                WDP_OUT="$WDP/etw-$TAG.jsonl" \
                python3 "$LAB_DIR/wdp_etw.py" 2>&1 | etw_sink
            ETW_RC=${PIPESTATUS[0]}
            etw_drop_cred
            etw_log "[etw] end=$(date -u +%Y-%m-%dT%H:%M:%SZ) rc=$ETW_RC"
        fi
    fi
fi

etw_log "DONE exit=$ETW_RC"
if [ "$TAG_OK" -eq 1 ]; then
    cp "$LOG" "$WDP/etw-$TAG.log"
fi
# self-close this Terminal window (same mechanism as relay.command)
if [ -n "${TERM_PROGRAM:-}" ] && [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
    TTY_NAME=$(tty)
    osascript -e 'tell application "Terminal" to close (every window whose tty is "'"$TTY_NAME"'")' >/dev/null 2>&1 &
fi
# Owner rule: the window's own exit status is meaningless (nobody sees it); the real verdict is
# the DONE line, which every caller polls for.
exit 0
