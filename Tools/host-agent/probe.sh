#!/usr/bin/env bash
#
# probe.sh - Mac-side acceptance run for the Macdows host-agent prototype (W7).
#
# Exercises the three capabilities the agent exists to prove:
#   1. enumerate published RemoteApps, with icons as base64 PNG
#   2. proxy-launch a program that is NOT published as a RemoteApp
#   3. resolve the .pdf file association
#
# Usage:
#   ./probe.sh <host> <port> <token> [launch-id] [out-dir]
#
#   <host>       address of the Windows host running MacdowsHostAgent.ps1
#   <port>       agent port (the agent's default is 47615)
#   <token>      the token the agent printed at startup
#   [launch-id]  allowlist id to launch; default: the first agentAllowlist entry
#                whose inTsAllowList is false
#   [out-dir]    where apps.json and icon-0.png are written; default ./probe-out
#
# Requires only curl and python3. Nothing is hard-coded: no host, no port, no token.
#
set -u

usage() {
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then usage; fi
case "${1:-}" in -h|--help|'') usage ;; esac

HOST="$1"
PORT="$2"
TOKEN="$3"
LAUNCH_ID="${4:-}"
OUT_DIR="${5:-./probe-out}"
TIMEOUT=20
BASE="http://${HOST}:${PORT}"

for tool in curl python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "probe.sh: required tool not found: $tool" >&2
        exit 2
    fi
done

mkdir -p "$OUT_DIR" || exit 2

# Keep the bearer token out of curl's argv (and therefore out of `ps`) by passing it
# through a private config file.
umask 077
CURL_CFG="$(mktemp "${TMPDIR:-/tmp}/macdows-probe.XXXXXX")"
cleanup() { rm -f "$CURL_CFG"; }
trap cleanup EXIT INT TERM
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$CURL_CFG"

FAILED=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }
info() { printf '      %s\n' "$*"; }

# --noproxy '*' is not optional: curl otherwise honours http_proxy / ALL_PROXY / .curlrc from
# the environment, which would send the Authorization: Bearer header to that proxy in clear
# text and then fail the run in a way that looks like an agent fault. probe.ps1 does the
# equivalent with $client.Proxy = $null.
http_get() {   # <path> <outfile> -> prints HTTP status code
    curl --silent --show-error --noproxy '*' --config "$CURL_CFG" --max-time "$TIMEOUT" \
         --output "$2" --write-out '%{http_code}' "${BASE}$1" 2>/dev/null
}

http_post_json() {  # <path> <outfile> <json> -> prints HTTP status code
    curl --silent --show-error --noproxy '*' --config "$CURL_CFG" --max-time "$TIMEOUT" \
         --header 'Content-Type: application/json' --data "$3" \
         --output "$2" --write-out '%{http_code}' "${BASE}$1" 2>/dev/null
}

echo "probing ${BASE} ..."
echo

# ---------------------------------------------------------------------------------------------
# 0. health
# ---------------------------------------------------------------------------------------------
HEALTH_JSON="${OUT_DIR}/health.json"
CODE="$(http_get /v1/health "$HEALTH_JSON")"
if [ "$CODE" = "200" ] && python3 - "$HEALTH_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("agent") == "macdows-host-agent", "unexpected agent field: %r" % d.get("agent")
print("      agent=%s version=%s user=%s session=%s tsAllowListDisabled=%s bind=%s" % (
    d.get("agent"), d.get("version"), d.get("user"), d.get("sessionId"),
    d.get("tsAllowListDisabled"), d.get("bind")))
PY
then
    pass "health         GET /v1/health"
else
    fail "health         GET /v1/health (HTTP $CODE)"
fi

# ---------------------------------------------------------------------------------------------
# 1. published RemoteApps + icons
# ---------------------------------------------------------------------------------------------
APPS_JSON="${OUT_DIR}/apps.json"
ICON_PNG="${OUT_DIR}/icon-0.png"
rm -f "$ICON_PNG"
CODE="$(http_get /v1/apps "$APPS_JSON")"
if [ "$CODE" = "200" ] && python3 - "$APPS_JSON" "$ICON_PNG" <<'PY'
import base64, json, sys

def as_list(v):
    # Windows PowerShell 5.1's ConvertTo-Json can collapse a one-element array into a
    # bare object; accept either shape so a host with a single RemoteApp still passes.
    if v is None:
        return []
    return v if isinstance(v, list) else [v]

doc = json.load(open(sys.argv[1]))
published = as_list(doc.get("published"))
allowed = as_list(doc.get("agentAllowlist"))
print("      tsAllowListDisabled=%s  published=%d  agentAllowlist=%d"
      % (doc.get("tsAllowListDisabled"), len(published), len(allowed)))
for a in published:
    print("      published: %-24s %s" % (a.get("name"), a.get("path")))
for a in allowed:
    print("      allowlist: %-24s inTsAllowList=%s  %s"
          % (a.get("id"), a.get("inTsAllowList"), a.get("path")))

# First non-null icon anywhere in the response, published entries first.
blob = None
for a in list(published) + list(allowed):
    if a.get("iconPng"):
        blob = a["iconPng"]
        print("      first icon from: %s" % (a.get("name") or a.get("id")))
        break
assert blob is not None, "no entry carried an iconPng"

raw = base64.b64decode(blob, validate=True)
assert raw[:8] == b"\x89PNG\r\n\x1a\n", "decoded icon is not a PNG (magic=%r)" % raw[:8]
open(sys.argv[2], "wb").write(raw)
print("      wrote %s (%d bytes)" % (sys.argv[2], len(raw)))
PY
then
    pass "apps + icons   GET /v1/apps"
else
    fail "apps + icons   GET /v1/apps (HTTP $CODE)"
fi

# ---------------------------------------------------------------------------------------------
# 2. file association
# ---------------------------------------------------------------------------------------------
ASSOC_JSON="${OUT_DIR}/assoc.json"
CODE="$(http_get '/v1/assoc?ext=.pdf' "$ASSOC_JSON")"
if [ "$CODE" = "200" ] && python3 - "$ASSOC_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("      ext=%s source=%s" % (d.get("ext"), d.get("source")))
print("      executable=%s" % d.get("executable"))
print("      command=%s" % d.get("command"))
print("      friendlyName=%s" % d.get("friendlyName"))
assert d.get("ext") == ".pdf", "wrong ext echoed back"
assert d.get("executable") or d.get("command"), "no executable and no command for .pdf"
PY
then
    pass "association    GET /v1/assoc?ext=.pdf"
else
    fail "association    GET /v1/assoc?ext=.pdf (HTTP $CODE)"
fi

# ---------------------------------------------------------------------------------------------
# 3. proxied launch (a program outside TSAppAllowList)
# ---------------------------------------------------------------------------------------------
if [ -z "$LAUNCH_ID" ] && [ -s "$APPS_JSON" ]; then
    LAUNCH_ID="$(python3 - "$APPS_JSON" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
entries = doc.get("agentAllowlist")
if entries is None:
    entries = []
elif not isinstance(entries, list):
    entries = [entries]
for e in entries:
    if e.get("inTsAllowList") is False and e.get("id"):
        print(e["id"])
        break
PY
)"
fi

if [ -z "$LAUNCH_ID" ]; then
    fail "proxied launch POST /v1/launch (no allowlist entry outside TSAppAllowList; pass one explicitly)"
else
    LAUNCH_JSON="${OUT_DIR}/launch.json"
    PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"id": sys.argv[1]}))' "$LAUNCH_ID")"
    CODE="$(http_post_json /v1/launch "$LAUNCH_JSON" "$PAYLOAD")"
    if [ "$CODE" = "200" ] && python3 - "$LAUNCH_JSON" "$LAUNCH_ID" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("id") == sys.argv[2], "agent launched a different id: %r" % d.get("id")
pid = d.get("pid")
assert isinstance(pid, int) and pid > 0, "no usable pid in the response: %r" % (pid,)
print("      launched id=%s pid=%s path=%s" % (d.get("id"), pid, d.get("path")))
PY
    then
        pass "proxied launch POST /v1/launch (id=$LAUNCH_ID)"
    else
        fail "proxied launch POST /v1/launch (id=$LAUNCH_ID, HTTP $CODE)"
    fi
fi

echo
if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED capability check(s) failed. Artifacts in ${OUT_DIR}"
    exit 1
fi
echo "all capability checks passed. Artifacts in ${OUT_DIR}"
exit 0
