#!/usr/bin/env bash
# test-build-ffmpeg-prefix.sh: offline pins for Scripts/build-ffmpeg.sh's prefix-freshness
# verdict (`--check-prefix DIR`), the check its idempotent skip is gated on.
#
# Why this exists (2026-09-05): the 3.31.1 pin flipped the LGPL FFmpeg build to
# --enable-swscale, but build-ffmpeg.sh's skip test was a plain `-f` on the version stamp
# `.ffmpeg-<version>.stamp`. A prefix built before the flip carries the same version and
# therefore the same stamp, so the script skipped, build-freerdp.sh then died on the
# missing libswscale, and the window-smoke launcher failed its build step within seconds
# ("launcher/existence check != freshness", docs STATUS 工程注意). The skip now also requires
# every component the build promises to be present; this suite pins that verdict on synthetic
# prefix directories -- no download, no compiler, no network, no shared .build/ state.
#
# Runs on the reduced tool set Tier 1's ubuntu runner has: `--check-prefix` is answered before
# build-ffmpeg.sh requires jq/strings/otool/perl, so this suite must not need them either.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_FFMPEG="$SCRIPT_DIR/build-ffmpeg.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ffmpeg-prefix-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() {
    # check <name> <expected-exit> <expected-stdout-substring> <dir>
    local name="$1" want_rc="$2" want_out="$3" dir="$4" out rc
    set +e
    out="$("$BUILD_FFMPEG" --check-prefix "$dir" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq "$want_rc" ] && [[ "$out" == *"$want_out"* ]]; then
        echo "PASS $name (rc=$rc)"
        pass=$((pass + 1))
    else
        echo "FAIL $name: want rc=$want_rc containing '$want_out'; got rc=$rc:"
        printf '  %s\n' "$out"
        fail=$((fail + 1))
    fi
}

# The versioned dylib names FFmpeg's `make install` produces (the exact minor numbers do not
# matter to the verdict -- it globs lib<component>.*.dylib, like the staging guard does).
make_prefix() {
    # make_prefix <dir> <stamp:yes|no> <components...>
    local dir="$1" stamp="$2"; shift 2
    mkdir -p "$dir/lib"
    local comp
    for comp in "$@"; do
        : >"$dir/lib/lib${comp}.9.dylib"
        : >"$dir/lib/lib${comp}.dylib"
    done
    if [ "$stamp" = yes ]; then
        : >"$dir/.ffmpeg-9.0.1.stamp"
    fi
}

# 1. Nothing installed: absent, distinct from incomplete (a first build vs a stale one).
check "absent prefix" 2 "absent" "$TMP/absent"

# 2. The full promised set with its stamp: complete -- the only verdict that may skip.
make_prefix "$TMP/complete" yes avcodec avutil swresample swscale
check "complete prefix skips" 0 "complete" "$TMP/complete"

# 3. The 2026-09-05 failure shape: a pre-swscale prefix whose stamp says the right version.
make_prefix "$TMP/pre-swscale" yes avcodec avutil swresample
check "stamped but missing libswscale" 1 "missing libswscale" "$TMP/pre-swscale"

# 4. Any other missing component is reported by name, not just swscale.
make_prefix "$TMP/no-avutil" yes avcodec swresample swscale
check "stamped but missing libavutil" 1 "missing libavutil" "$TMP/no-avutil"

# 5. All libraries but no stamp: an interrupted promotion (the stamp is written last) --
#    must rebuild, and must say why.
make_prefix "$TMP/unstamped" no avcodec avutil swresample swscale
check "unstamped prefix rebuilds" 1 "no version stamp" "$TMP/unstamped"

# 6. A stamp for a different FFmpeg version is not this version's stamp.
make_prefix "$TMP/other-version" no avcodec avutil swresample swscale
: >"$TMP/other-version/.ffmpeg-8.0.0.stamp"
check "foreign version stamp rebuilds" 1 "no version stamp" "$TMP/other-version"

echo "== build-ffmpeg prefix freshness: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
