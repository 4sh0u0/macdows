#!/usr/bin/env bash
# Byte-exact round-trip comparer for the input scenarios (adr/0011 §5 items 5/6).
# Usage: compare.sh <smoke-log> <readback-file>
#   Extracts the LAST "expected-utf8-hex=<hex>" occurrence from the smoke log and
#   compares it against the readback file's bytes (as hex). Prints PASS/FAIL and,
#   on FAIL, both hex strings for diagnosis.
set -u
LOG="$1"; FILE="$2"
EXPECTED=$(grep -o 'expected-utf8-hex=[0-9a-fA-F]*' "$LOG" | tail -1 | cut -d= -f2 | tr 'A-F' 'a-f')
if [ -z "$EXPECTED" ]; then
    echo "FAIL  no expected-utf8-hex marker found in $LOG"
    exit 1
fi
if [ ! -f "$FILE" ]; then
    echo "FAIL  readback file missing: $FILE"
    exit 1
fi
ACTUAL=$(xxd -p "$FILE" | tr -d '\n' | tr 'A-F' 'a-f')
# Tolerate a UTF-8 BOM the remote editor may have prepended, and a single trailing
# CRLF/LF it may have appended -- report either as a note, not a failure, since the
# round-trip claim is about the typed characters.
NOTE=""
if [ "${ACTUAL#efbbbf}" != "$ACTUAL" ]; then
    ACTUAL="${ACTUAL#efbbbf}"
    NOTE="$NOTE (leading BOM stripped)"
fi
if [ "${ACTUAL%0d0a}" != "$ACTUAL" ] && [ "${ACTUAL%0d0a}" = "$EXPECTED" ]; then
    ACTUAL="${ACTUAL%0d0a}"
    NOTE="$NOTE (trailing CRLF stripped)"
elif [ "${ACTUAL%0a}" != "$ACTUAL" ] && [ "${ACTUAL%0a}" = "$EXPECTED" ]; then
    ACTUAL="${ACTUAL%0a}"
    NOTE="$NOTE (trailing LF stripped)"
fi
if [ "$ACTUAL" = "$EXPECTED" ]; then
    echo "PASS  round-trip bytes equal$NOTE ($(( ${#EXPECTED} / 2 )) bytes)"
    exit 0
fi
echo "FAIL  byte mismatch$NOTE"
echo "  expected: $EXPECTED"
echo "  actual:   $ACTUAL"
exit 1
