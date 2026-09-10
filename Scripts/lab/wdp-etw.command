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
# goes through etw_sink, which rewrites the four classes of value that can reach it: $HOME to
# <HOME> (the client's stderr is piped into the log, and a Python traceback names this checkout's
# path, which on the lab Mac carries the local account name), the host address to <WIN_HOST>, the
# account to <WIN_USER> and -- belt and braces -- the password to <WIN_PASS>. The password is not
# supposed to reach any output at all: it goes from host.env into the 0600 credential file and
# nowhere else, and this rule is what makes that true rather than merely intended. host.env's OWN
# output is deliberately not routed into the log: the mask is built from host.env, so nothing read
# before it could be masked.
#
# THE JOB FILE IS A TABLE OF VALUES OR IT DOES NOT RUN. Its line SHAPES are checked as TEXT before
# a single byte of it is executed: blank, a comment, or an assignment of a SINGLE WORD to one of
# the four keys below, and nothing else. The VALUE half of that rule is not decoration -- to the
# shell, `TAG=a b` is an assignment PREFIXED to the command `b`, so a wrapper that whitelisted only
# key NAMES would still run programs out of a job file. Measured on the sibling wrapper, not
# theorised: an early draft of smoke-job.command hung FOREVER on `DISPLAY_LOOKS_LIKE=1280 x 720`,
# because /opt/X11/bin/x exists on the lab Mac and reads stdin -- no DONE line at all, and every
# orchestrator polling for one waited out its full timeout. A value carrying a space or a `;` (the
# shipped PROVIDERS list carries both) must therefore be QUOTED, which is also the condition for it
# to survive being read at all.
#
# etw-job.env keys (all single-line; the file is read once, in a subshell -- see below):
#   TAG         capture name, ^[A-Za-z0-9_-]{1,32}$; names etw-<TAG>.jsonl and etw-<TAG>.log
#   DURATION    capture seconds, positive integer (default 60)
#   PROVIDERS   <guid>:<level>[;<guid>:<level>...], level 0-5 -- passed to the client verbatim
#   PIN_RECORD  0|1 (default 0); 1 records the certificate pin ONCE if none exists yet
#
# DONE exit=<rc> is the run's whole verdict (the window's own status is meaningless -- see the
# bottom of this file). The wrapper's own codes and the client's share one space:
#   0   the capture completed
#   64  the CLIENT refused its own configuration (a missing or malformed WDP_* value, a credential
#       file others can read) or could not create/write WDP_OUT: `OUT-UNWRITABLE <class>
#       errno=<n>`. WDP_OUT is opened only after the WebSocket is up -- deliberately, so a refused
#       pin cannot leave a file behind -- so this arrives mid-run rather than at startup. 64 is the
#       client's alone: nothing this wrapper decides is answered with it, so a 64 in a scrollback
#       always means the run got as far as starting the client
#   65  etw-job.env is not a table of values     JOB-ENV-INVALID   (EX_DATAERR). One code for the
#       whole class, because "this file is not a job file" is one answer however it fails: a LINE
#       that is not blank, a comment or an assignment (caught as TEXT, so nothing in the file ran at
#       all), or a VALUE that failed its own shape check after the subshell read it. Which of the
#       two it was is the line immediately above DONE -- the line-grammar refusal names a line
#       NUMBER, the value refusals name a key. smoke-job.command answers 65 for exactly the same
#       question, so an orchestrator's scrollback reads the same way whichever wrapper printed it
#   66  etw-job.env is not readable             JOB-ENV-MISSING
#   69  the connection or the TLS handshake failed
#   76  the portal refused the WebSocket upgrade
#   78  the target is outside the lab segments  BOUNDARY-REFUSED
#   79  no usable pin here (PIN-MISSING, PIN-INVALID) or a mismatch at the client
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
# What a SHA-256 fingerprint looks like, in ONE place: `openssl x509 -fingerprint`'s colon-separated
# form or bare hex. The recorder checks it before writing the pin file and the reader checks it
# again before using one -- same rule both ways, so a pin file can never be trusted on a shape the
# recorder would have refused to produce.
PIN_RE='^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$|^[0-9A-Fa-f]{64}$'
# THE LINE GRAMMAR (see the header). Three kinds of line are admitted and nothing else: blank, a
# comment, or an assignment to one of the four keys whose VALUE is a single shell word. A bare
# value may hold only characters that cannot start a word or a redirection; anything else -- a
# space, a `;`, a backslash, non-ASCII -- must be QUOTED. Single quotes admit anything but a single
# quote; double quotes exclude the three characters that would still expand inside them. A trailing
# `\"` can still continue a double-quoted value onto the next line; that is the one shape this
# grammar cannot see, and it is what the sentinel further down is for.
# Assembled from pieces because the alternatives contain both kinds of quote. The SAME grammar is
# spelled out in smoke-job.command and checkpoint.sh: three copies, deliberately, because each file
# must run standalone (two are opened by Terminal.app), and Scripts/lib.sh is where they belong
# once one place can be sourced by all three. Registered as an open m rather than done here.
ETW_JOB_KEYS_RE='TAG|DURATION|PROVIDERS|PIN_RECORD'
ETW_SQ="'"
ETW_VALUE_BARE='[A-Za-z0-9._:,%@=+/-]*'
ETW_VALUE_DQ='"[^"$`]*"'
ETW_JOB_LINE_RE="^[[:space:]]*(#.*)?\$|^(export )?(${ETW_JOB_KEYS_RE})=(${ETW_VALUE_BARE}|${ETW_SQ}[^${ETW_SQ}]*${ETW_SQ}|${ETW_VALUE_DQ})\$"
ETW_RC=0
CRED=''
BAD_LINE=''
HOME_RE=''
HOST_RE=''
USER_RE=''
PASS_RE=''
TAG=''
TAG_OK=0

# BRE-escapes a value so it can be used as a sed pattern. WIN_HOST is normally an IP literal, and
# its dots would otherwise match any character -- close enough to look right and wrong enough to
# leak a neighbouring address.
etw_re_escape() { # <literal>
    printf '%s' "$1" | sed 's|[][\.*^$/]|\\&|g'
}

# The mask. Four classes of value can reach etw.log, and each contributes one rule:
#   $HOME     -> <HOME>       a client traceback prints the module's own path, and the checkout
#                             lives under the maintainer's home directory
#   WIN_HOST  -> <WIN_HOST>   the target address, which the gate's REFUSED line quotes by design
#   WIN_USER  -> <WIN_USER>   the portal account
#   WIN_PASS  -> <WIN_PASS>   belt and braces: nothing echoes it today, and after this nothing can
# $HOME goes FIRST, so that a host or account value occurring inside a path is not rewritten out
# from under the path rule, leaving a half-redacted path behind. A rule joins the script only when
# its value is non-empty: an empty sed pattern (`s//x/`) re-uses the LAST regex, which would
# substitute something arbitrary rather than nothing -- and when no rule survives that test the
# sink is a plain `cat`. Over-masking is the safe direction: a pathologically short WIN_PASS would
# rewrite unrelated text, which costs a reader a puzzled moment; under-masking costs a credential.
# Per line, never a single persistent `sed`: sed's own stdout is fully buffered once it is not a
# tty (true of both GNU and BSD sed), so a long-running client's early lines -- WS-OPEN chief
# among them -- would sit in that buffer until the client exits and closes the pipe. That is
# exactly what the 2026-09-09 checkpoint hit: the orchestrator could only treat the JSONL file's
# appearance as "the socket is open" because etw.log stayed empty until the whole run ended. A
# `sed` started fresh for each line has nothing left to buffer past its own exit, and `read -r`
# never consumes past the newline it is waiting for, so this cannot act on a line before the
# client has written the whole thing. The client's stdout is a handful of control lines per run
# (WS-OPEN, WS-EOF/WS-CLOSE, SUMMARY), never one per ETW event, so a process per line costs
# nothing that matters. Kept as ONE physical line on purpose: the M4 mutation proof reverts it to
# the old persistent-`sed`/`cat` pipe with a single-line swap, the same idiom M1-M3 use.
# Two differences from the old pipe, both harmless: a trailing line with no newline gets one
# appended here (`printf '%s\n'` always adds it), which is intentional -- it is what keeps
# `DONE exit=$ETW_RC` as the log's own last line rather than glued onto a half-written client
# line. A NUL byte inside a line is dropped by `read -r` (a bash string cannot hold one), which
# only concatenates the text on either side of it into one line -- a mask pattern can therefore
# only match MORE of the line than before, never less.
etw_mask_pipe() { local script="$1" line; while IFS= read -r line || [ -n "$line" ]; do if [ -n "$script" ]; then printf "%s\n" "$line" | sed -e "$script"; else printf "%s\n" "$line"; fi; done; }

etw_mask() {
    local script=''
    if [ -n "$HOME_RE" ]; then script="${script}s/$HOME_RE/<HOME>/g;"; fi
    if [ -n "$HOST_RE" ]; then script="${script}s/$HOST_RE/<WIN_HOST>/g;"; fi
    if [ -n "$USER_RE" ]; then script="${script}s/$USER_RE/<WIN_USER>/g;"; fi
    if [ -n "$PASS_RE" ]; then script="${script}s/$PASS_RE/<WIN_PASS>/g;"; fi
    etw_mask_pipe "$script"
}

# The ONE place bytes reach the log -- the wrapper's own lines, the gate's output and the client's
# stdout/stderr all pass through here, so the mask cannot be bypassed by adding a writer.
etw_sink() {
    etw_mask >> "$LOG"
}

etw_log() { # <text...>
    printf '%s\n' "$*" | etw_sink
}

# The pin recorder's network call in one place: the SNI decision below changes the ARGUMENTS, not
# the pipeline that turns whatever certificate was served into a fingerprint.
#
# `env -u` strips host.env's values from BOTH members of the pipeline -- each is its own process
# and neither needs them (the host is on the command line). It matters because a host.env written
# in the `export WIN_PASS=...` style, which Scripts/probe.sh notes exists in the wild, would
# otherwise hand the portal password to every child this script starts; the 0600 credential file
# is the ONE channel this design allows for it.
etw_record_fp() { # <openssl s_client argument...>
    env -u WIN_PASS -u WIN_USER -u WIN_HOST openssl s_client "$@" </dev/null 2>/dev/null \
        | env -u WIN_PASS -u WIN_USER -u WIN_HOST openssl x509 -noout -fingerprint -sha256 2>/dev/null \
        | sed 's/^.*=//' | tr -d '[:space:]'
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
# HOME is masked alongside host.env's values because this checkout sits under it: the client
# module a traceback names, and every path this wrapper logs, start with it. A HOME of "/" is
# left alone -- rewriting every slash would destroy the log rather than redact it.
if [ -n "${HOME:-}" ] && [ "${HOME:-}" != '/' ]; then
    HOME_RE="$(etw_re_escape "$HOME")"
fi
HOST_RE="$(etw_re_escape "${WIN_HOST:-}")"
USER_RE="$(etw_re_escape "${WIN_USER:-}")"
PASS_RE="$(etw_re_escape "${WIN_PASS:-}")"

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
# The grammar is checked HERE, after the gate and the readability test and before the subshell
# below executes anything: the subshell isolates what a job can WRITE, but it cannot stop a job
# LINE from running, and this shell holds WIN_PASS (host.env is sourced for the log mask), which a
# subshell inherits. The assignment sits in the condition so that the branch it guards stays a
# sibling of the two above it rather than another level of nesting around the whole run.
# CR is stripped first, so a hand-edited CRLF file is judged on its content. The line NUMBER is
# reported and never the line: an offending line may BE the value that must not be printed.
elif BAD_LINE="$(tr -d '\r' < "$RUNTIME/etw-job.env" | grep -nvE "$ETW_JOB_LINE_RE" | head -n 1 | cut -d: -f1)"; [ -n "$BAD_LINE" ]; then
    etw_log "[etw] JOB-ENV-INVALID -- line $BAD_LINE of etw-job.env is neither blank, a comment, nor an assignment of a SINGLE WORD to one of TAG DURATION PROVIDERS PIN_RECORD; a value carrying a space or a ';' must be quoted, or the shell reads what follows it as a command; and a comment must be on a line of its own -- an assignment may not be followed by one, quoted or not. The line itself is not quoted here because it may BE the value that must not be printed. No capture attempted"
    ETW_RC=65
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
    # CR on each value; EVERY one is removed, not just the trailing one, so nothing carrying a CR
    # reaches a file name, a regex or the client's environment. All of them rather than the last,
    # because the grammar above judges the file with every CR already deleted -- `TAG=sm<CR>oke` is
    # admitted as the text `TAG=smoke` -- and a strip that took only the trailing CR would hand the
    # client a value the check never saw. checkpoint.sh's cp_job_value deletes all of them too, and
    # it reads THIS file to build the waits an orchestrator runs on: with anything less here the two
    # would disagree about the name of a file they both build.
    #
    # What the subshell does NOT do is hide THIS shell's variables from the job: it inherits them,
    # so a job line could read WIN_PASS as easily as it reads its own keys. That is deliberate and
    # is relay.command's posture too -- jobs/*.env are tracked files in this repo, i.e. code that
    # is reviewed like any other, and a job that wanted the credential could equally read the
    # host.env this wrapper reads. The isolation above is against a job that CHANGES the run
    # (redirecting the target past an approved gate), not against one that reads it.
    # stdin is closed for the source. The grammar above admits no command, so nothing here can
    # read stdin today -- this is defence in depth BEHIND that grammar, and it is deliberately not
    # pinned by a mutation proof, because with the grammar intact removing it changes nothing
    # observable. What it buys is the failure mode: a job line that reached a program which reads
    # stdin would block this wrapper FOREVER -- no DONE line, and every orchestrator polling for
    # one waits out its full timeout, which is the worst shape a refusal can take.
    # shellcheck source=/dev/null
    JOB_KEYS="$( . "$RUNTIME/etw-job.env" >/dev/null 2>&1 </dev/null; printf '%s\n%s\n%s\n%s\n%s\n' "${TAG:-}" "${DURATION:-}" "${PROVIDERS:-}" "${PIN_RECORD:-}" 'END-OF-JOB-KEYS' )"
    TAG=""; DURATION=""; PROVIDERS=""; PIN_RECORD=""; JOB_KEYS_END=""
    { IFS= read -r TAG; IFS= read -r DURATION; IFS= read -r PROVIDERS; IFS= read -r PIN_RECORD; IFS= read -r JOB_KEYS_END; } <<EOF_JOB_KEYS
$JOB_KEYS
EOF_JOB_KEYS
    CR=$(printf '\r')
    TAG="${TAG//$CR/}"; DURATION="${DURATION//$CR/}"; PROVIDERS="${PROVIDERS//$CR/}"; PIN_RECORD="${PIN_RECORD//$CR/}"; JOB_KEYS_END="${JOB_KEYS_END//$CR/}"
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
        PIN_BAD=0
        if [ -r "$PINFILE" ]; then
            PIN="$(tr -d '[:space:]' < "$PINFILE")"
            # Validated on the way IN with the same regex the recorder applies on the way out. An
            # unchecked pin file -- hand-edited, truncated by a full disk, half-written by a
            # killed recorder -- would otherwise be handed to the client, which means this wrapper
            # would create the 0600 credential file for a run that can only end at the client's
            # own CERT-PIN-MISSING, one layer away from the file that actually needs fixing.
            if [ -n "$PIN" ] && ! printf '%s' "$PIN" | grep -qE "$PIN_RE"; then
                PIN_BAD=1
                PIN=""
            fi
        fi
        if [ -n "$PIN" ] && [ "$PIN_RECORD" = "1" ]; then
            etw_log "[etw] PIN_RECORD=1 ignored -- a pin is already on file and is never overwritten"
        fi
        # PIN_BAD is checked here as well as below: the pin file EXISTS, so recording over it is
        # exactly the "never overwrite a pin" rule -- the operator decides whether that file is
        # junk, and the reason line says so.
        if [ "$PIN_BAD" -eq 0 ] && [ -z "$PIN" ] && [ "$PIN_RECORD" = "1" ]; then
            # The gate has already approved WIN_HOST, so this is the first and only moment the
            # wrapper is allowed to touch the network before the capture itself. The fingerprint of
            # a certificate is a public value: logging it is what lets the operator compare it
            # against what the host shows, which is the only check that makes a
            # trust-on-first-use pin worth anything.
            etw_log "[etw] recording the portal certificate pin (PIN_RECORD=1)"
            # The recorder must be shown the SAME certificate the capture will later be pinned
            # against, so it follows the client's two address rules exactly (wdp_etw.py
            # `_host_header` and `_sni_for`):
            #   * an address containing ':' -- an IPv6 literal -- is BRACKETED in -connect. OpenSSL
            #     calls an unbracketed `host:port` with colons in it ambiguous and refuses before
            #     it dials, so without this an IPv6 lab host (the owner's boundary file admits one)
            #     could never record a pin and PIN-MISSING would name a way out that does not work.
            #   * an IP literal is dialled WITHOUT -servername. SNI carries names only; the client
            #     omits it for a literal, and a portal that answers a name with a different
            #     certificate would leave a pin the capture is never shown.
            # The literal test is the same pair of classes the client's `_sni_for` distinguishes:
            # a dotted quad, or anything containing a colon.
            case "$WIN_HOST" in
                *:*) CONNECT_TO="[$WIN_HOST]:50443" ;;
                *) CONNECT_TO="$WIN_HOST:50443" ;;
            esac
            if printf '%s' "$WIN_HOST" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|:'; then
                FP="$(etw_record_fp -connect "$CONNECT_TO")"
            else
                FP="$(etw_record_fp -connect "$CONNECT_TO" -servername "$WIN_HOST")"
            fi
            # The shape is checked BEFORE the file is written: a portal that did not answer yields
            # an empty fingerprint, and writing that would create a pin file that can never be
            # recorded again (an existing pin is never overwritten) and refuses every future run.
            if printf '%s' "$FP" | grep -qE "$PIN_RE"; then
                printf '%s\n' "$FP" > "$PINFILE"
                PIN="$FP"
                etw_log "[etw] pin recorded sha256=$FP"
            else
                etw_log "[etw] PIN-RECORD-FAILED -- the portal returned no SHA-256 fingerprint; nothing written to the pin file"
            fi
        fi
        if [ "$PIN_BAD" -eq 1 ]; then
            etw_log "[etw] PIN-INVALID -- the pin file does not hold a SHA-256 fingerprint; delete it and re-record with PIN_RECORD=1; no capture attempted"
            ETW_RC=79
        elif [ -z "$PIN" ]; then
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
            # THE PID LINE, written before the dial and after the start line. checkpoint.sh's
            # overlap guard has to answer "is a capture still in flight?" before it launches
            # another one -- two realtime subscriptions against the same portal disable each
            # other's providers, and the damage lands in the OTHER run's evidence. This is the
            # signal it reads: `$$` is THIS wrapper's pid, so a guard can `kill -0` it and know it
            # is watching this checkout's capture rather than a neighbour's process that happens to
            # match a pattern. Before the dial, because a pid published afterwards arrives too late
            # for a guard that must decide before the second capture is launched. It goes through
            # the mask like every other line: a pathologically short WIN_PASS could rewrite the
            # digits, and a reader that then cannot parse a pid falls back to the process table --
            # the fail-safe direction.
            etw_log "[etw] pid=$$"
            # Parameters travel in the environment, never in argv: argv is world-readable through
            # `ps` on this platform, and one of these values is the path of a file holding the
            # portal password. The client's stdout/stderr is piped into the log so the capture's
            # progress is visible live to whoever is polling it -- hence PIPESTATUS rather than $?,
            # which would be the mask's status.
            # `env -u` for the same reason as the pin recorder: with an exporting host.env the
            # client would otherwise inherit the portal password it is being handed a FILE for,
            # and WIN_USER/WIN_HOST besides. WDP_HOST carries the (gate-approved) address the
            # client is meant to dial; nothing else from host.env crosses.
            env -u WIN_PASS -u WIN_USER -u WIN_HOST \
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
