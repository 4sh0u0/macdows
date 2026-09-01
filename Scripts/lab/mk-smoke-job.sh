#!/usr/bin/env bash
# Generates .build/lab-runtime/smoke-job.command with the given KEY=VALUE env pairs baked in
# (open -a Terminal passes no environment through -- W7 lesson), which then execs the
# repo's standard Terminal-relay launcher Scripts/run-window-smoke.command.
# Usage: mk-smoke-job.sh KEY=VALUE [KEY=VALUE ...]
#
# The generated file is a RUNTIME ARTEFACT and must stay under .build/ (ignored): the values
# baked into it are the caller's own -- absolute maintainer paths and, on the tray lane, a host
# account name. It is regenerated on every smoke run, so nothing is lost by not tracking it.
set -eu
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LAB_DIR/../.." && pwd)"
RUNTIME="$REPO_ROOT/.build/lab-runtime"
mkdir -p "$RUNTIME"
JOB="$RUNTIME/smoke-job.command"
{
    echo '#!/usr/bin/env bash'
    for kv in "$@"; do
        printf 'export %q\n' "$kv"
    done
    printf 'exec %q\n' "$REPO_ROOT/Scripts/run-window-smoke.command"
} > "$JOB"
chmod +x "$JOB"
echo "$JOB"
