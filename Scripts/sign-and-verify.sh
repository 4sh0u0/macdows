#!/usr/bin/env bash
# sign-and-verify.sh: codesign an app bundle (hardened runtime, inside-out: embedded
# dylibs first, then the bundle itself), verify the signature, check for unexpected
# dylib loads, then attempt notarization if credentials for it are available.
#
# Default signing identity is the "Developer ID Application" certificate — override with
# --identity or $CRDP_SIGN_IDENTITY for local Apple Development builds.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd codesign
require_cmd otool
require_cmd xcrun
require_cmd plutil
require_cmd /usr/libexec/PlistBuddy

NOTARY_PROFILE="macdows"

usage() {
	cat <<EOF
Usage: $(basename "$0") [--identity "<signing identity>"] [--offline] [--release] <path-to-.app>

Env:
  CRDP_SIGN_IDENTITY   codesign identity, same effect as --identity (--identity wins if
                        both are given). Default: "Developer ID Application: Haru Hazawa (XTCC8DPHBX)"

--offline   sign with --timestamp=none instead of requesting an Apple trusted timestamp,
            and skip the notarization step (which requires network access anyway). Use
            for local iteration without network access; the default (online) is what
            ships.

--release   declare that this bundle is a distributable artifact, and enforce the checks
            that only make sense for one. Currently: the app must NOT carry the
            com.apple.security.get-task-allow entitlement (arbitrary debugger attachment
            -> live RDP credentials and session keys readable by any local process); with
            --release that is a hard failure instead of a note.
            THIS IS THE MODE THE RELEASE CHECKLIST USES. Run it against every artifact you
            intend to ship. Without the flag the script stays lenient, so the ordinary
            local Debug loop is unaffected.
            Deliberately an explicit declaration rather than something inferred from the
            bundle: macOS app bundles carry no trustworthy build-configuration marker
            (a Debug and a Release Macdows.app have byte-identical Info.plists, verified),
            and inferring it from the path — as an earlier version did, with
            [[ \$APP_PATH == */Debug/* ]] — silently downgrades the check for a genuine
            Release artifact that merely happens to sit under a directory named Debug.

Notarization is automatic, not opt-in: this script probes
'xcrun notarytool history --keychain-profile $NOTARY_PROFILE' after signing. If that
keychain profile exists (and --offline wasn't given), it notarizes and staples; if not,
it prints one-time setup instructions and skips (exit 0 either way — a missing profile
is not a failure). Exceptions: an app path under a /Debug/ products directory skips
automatic notarization (local-iteration artifacts; set SIGN_AND_VERIFY_FORCE_NOTARIZE=1
to override), and stapling only happens on an explicit 'status: Accepted' from the
notary service — an Invalid submission is a hard failure, never stapled over.
EOF
}

IDENTITY_OVERRIDE=""
OFFLINE=0
RELEASE=0
APP_PATH=""
while [ $# -gt 0 ]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--release)
		RELEASE=1
		shift
		;;
	--identity)
		[ $# -ge 2 ] || die "--identity requires a value"
		IDENTITY_OVERRIDE="$2"
		shift 2
		;;
	--identity=*)
		IDENTITY_OVERRIDE="${1#--identity=}"
		shift
		;;
	--offline)
		OFFLINE=1
		shift
		;;
	*)
		if [ -z "$APP_PATH" ]; then
			APP_PATH="$1"
			shift
		else
			die "unexpected argument: $1"
		fi
		;;
	esac
done

if [ -z "$APP_PATH" ]; then
	usage
	die "missing <path-to-.app>"
fi
[ -d "$APP_PATH" ] || die "not a directory: $APP_PATH"
APP_PATH="$(cd "$APP_PATH" && pwd)"

IDENTITY="${IDENTITY_OVERRIDE:-${CRDP_SIGN_IDENTITY:-Developer ID Application: Haru Hazawa (XTCC8DPHBX)}}"
log "Signing identity: $IDENTITY"

if [ "$OFFLINE" -eq 1 ]; then
	TIMESTAMP_FLAG="--timestamp=none"
	log "Offline mode: signing with --timestamp=none, notarization will be skipped"
else
	TIMESTAMP_FLAG="--timestamp"
fi

INFO_PLIST="$APP_PATH/Contents/Info"
EXEC_NAME="$(defaults read "$INFO_PLIST" CFBundleExecutable 2>/dev/null || true)"
[ -n "$EXEC_NAME" ] || die "could not read CFBundleExecutable from $INFO_PLIST.plist"

# --- Unified cleanup: notarize's zip tmpdir always goes; the DYLD-check tmpdir is kept
# around (with a pointer printed) if we're exiting non-zero, so its log/copy can be
# inspected — deleting diagnostic evidence on the exact path a failure message points at
# defeats the point of printing that path.
NOTARIZE_TMP_DIR=""
CHECK_DIR=""
cleanup_on_exit() {
	local status=$?
	if [ -n "$NOTARIZE_TMP_DIR" ]; then
		rm -rf "$NOTARIZE_TMP_DIR"
	fi
	if [ -n "$CHECK_DIR" ]; then
		if [ "$status" -ne 0 ]; then
			log "DYLD-load-check artifacts preserved for inspection: $CHECK_DIR"
		else
			rm -rf "$CHECK_DIR"
		fi
	fi
	exit "$status"
}
trap cleanup_on_exit EXIT

# --- 0. Preserve any entitlements already on the bundle (e.g. from Xcode's own build-
# time signing) across our re-sign. Behavior is unchanged when there are none. -------
# `--entitlements -` (no colon) prints a human-readable debug dump ("[Dict] [Key] ...
# [Bool] true"), NOT a valid plist — feeding that back into `--entitlements <file>` at
# sign time fails with "unrecognized blob type" / "invalid length in entitlement blob"
# (found by actually round-tripping this against a real Xcode-built, hardened-runtime
# app, which does carry a default entitlement). The colon-prefixed form
# (`--entitlements :file`) is the one that writes real, re-signable XML — still
# necessary here despite codesign's own deprecation warning on that syntax; there is no
# non-deprecated equivalent that produces valid signing input on this macOS version.
ENTITLEMENTS_FILE="$(mktemp -t macdows-entitlements).plist"
if codesign -d --entitlements ":$ENTITLEMENTS_FILE" "$APP_PATH" >/dev/null 2>&1 && [ -s "$ENTITLEMENTS_FILE" ]; then
	log "Preserving existing entitlements from $APP_PATH ($ENTITLEMENTS_FILE)"
else
	rm -f "$ENTITLEMENTS_FILE"
	ENTITLEMENTS_FILE=""
fi
ENTITLEMENTS_ARGS=()
if [ -n "$ENTITLEMENTS_FILE" ]; then
	ENTITLEMENTS_ARGS=(--entitlements "$ENTITLEMENTS_FILE")
fi

# --- 1. Sign embedded dylibs individually (inside-out order) ------------------------
DYLIB_COUNT=0
while IFS= read -r -d '' dylib; do
	log "codesign (dylib): $dylib"
	codesign --force --options runtime "$TIMESTAMP_FLAG" --sign "$IDENTITY" "$dylib"
	DYLIB_COUNT=$((DYLIB_COUNT + 1))
done < <(find "$APP_PATH" -name '*.dylib' -print0)
log "Signed $DYLIB_COUNT embedded dylib(s)"

# --- 2. Sign any embedded .framework bundles (none expected in Phase 1, handled anyway)
if [ -d "$APP_PATH/Contents/Frameworks" ]; then
	while IFS= read -r -d '' fw; do
		log "codesign (framework): $fw"
		codesign --force --options runtime "$TIMESTAMP_FLAG" --sign "$IDENTITY" "$fw"
	done < <(find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0)
fi

# --- 3. Sign the app bundle itself (with preserved entitlements, if any) -------------
log "codesign (bundle): $APP_PATH"
codesign --force --options runtime "$TIMESTAMP_FLAG" "${ENTITLEMENTS_ARGS[@]}" --sign "$IDENTITY" "$APP_PATH"

# --- 4. Verify ------------------------------------------------------------------------
log "Verifying signature (codesign --verify --deep --strict)"
codesign --verify --deep --strict "$APP_PATH"
log "Signature verification: OK"

# --- 4b. Release artifacts must not ship com.apple.security.get-task-allow -------------
# That entitlement lets any process attach a debugger to the app and read/write its memory,
# which in a shipped build means an attacker on the machine can extract RDP credentials and
# session keys straight out of a running Macdows. Xcode adds it automatically to Debug
# builds, and step 0 above deliberately *preserves* whatever entitlements are already on the
# bundle across the re-sign — so without this check a Debug-configuration artifact that got
# signed for distribution would carry it silently. (Apple's notary service also rejects it,
# but that rejection arrives minutes later, only when notarizing, and never at all for the
# --offline path — so this is the earlier, always-on gate.)
#
# Why here and not in Scripts/gen-notices.sh: this is a *release* property, not a licence
# property, and this script is the release gate. gen-notices.sh is deliberately run against
# Debug bundles as routine verification, so a hard failure there would break the normal
# development loop for a condition that is correct and expected in Debug.
#
# The Debug-vs-release distinction is taken from the explicit --release flag, NOT inferred.
# An earlier version tested [[ "$APP_PATH" == */Debug/* ]], which is unsound in the one
# direction that matters: a genuine Release artifact staged, copied, or archived under any
# directory whose name happens to contain "Debug" would silently downgrade the only check
# standing between a debugger entitlement and a shipped build. There is no trustworthy
# in-bundle alternative either — a Debug and a Release Macdows.app have byte-identical
# Info.plists (verified by diffing them), and the Debug-only Contents/MacOS/*.debug.dylib
# is an artifact of the ENABLE_DEBUG_DYLIB build setting rather than of the configuration,
# so it can be toggled independently and is not a sound signal. Declaring the intent at the
# call site is the only honest option: it fails closed for anyone who says --release, and
# leaves the default lenient so routine local signing is unaffected.
GTA_ENTITLEMENT="com.apple.security.get-task-allow"
GTA_PLIST="$(mktemp -t macdows-gta-check).plist"
HAS_GET_TASK_ALLOW=0
if codesign -d --entitlements ":$GTA_PLIST" "$APP_PATH" >/dev/null 2>&1 && [ -s "$GTA_PLIST" ]; then
	if /usr/libexec/PlistBuddy -c "Print :$GTA_ENTITLEMENT" "$GTA_PLIST" >/dev/null 2>&1; then
		HAS_GET_TASK_ALLOW=1
	fi
fi
rm -f "$GTA_PLIST"

if [ "$HAS_GET_TASK_ALLOW" -eq 1 ]; then
	if [ "$RELEASE" -eq 1 ]; then
		die "$GTA_ENTITLEMENT is present on $APP_PATH, which was signed with --release.
This entitlement permits arbitrary debugger attachment (memory read/write) and must never
ship: for Macdows that means live RDP credentials and session keys are readable by any
local process. Xcode injects it whenever signing looks development-style (including the
ad-hoc default identity) and this script preserves existing entitlements across re-signing.
Build with -configuration Release — App/project.yml sets CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
there specifically to keep it out — or strip the entitlement before signing."
	fi
	log "NOTE: $GTA_ENTITLEMENT is present. Expected for a Debug-configuration build and harmless locally; pass --release to make it a hard failure (the release checklist does)."
else
	log "No $GTA_ENTITLEMENT entitlement on the signed bundle"
fi

# --- 5. DYLD load check, run against a throwaway, separately-entitled copy -----------
# Hardened runtime can suppress DYLD_* environment variables (including
# DYLD_PRINT_LIBRARIES) unless the process carries
# com.apple.security.cs.allow-dyld-environment-variables. Running this check directly
# against the real signed $APP_PATH (as an earlier version of this script did) could
# therefore pass on a silently empty log for a dependency that loads without crashing —
# an independent-review BLOCKER. We never ship that entitlement (it weakens hardened
# runtime); it exists only on this throwaway copy, used for exactly one launch, then
# discarded.
CHECK_DIR="$(mktemp -d -t macdows-dyld-check)"
CHECK_DIR="$(cd "$CHECK_DIR" && pwd -P)" # physical path: dyld reports /private/var/..., not the /var/... symlink
CHECK_APP="$CHECK_DIR/$(basename "$APP_PATH")"
cp -R "$APP_PATH" "$CHECK_APP"

DEBUG_ENTITLEMENTS="$CHECK_DIR/debug-entitlements.plist"
if [ -n "$ENTITLEMENTS_FILE" ]; then
	plutil -convert xml1 -o "$DEBUG_ENTITLEMENTS" "$ENTITLEMENTS_FILE"
else
	cat >"$DEBUG_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
fi
/usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.allow-dyld-environment-variables bool true" "$DEBUG_ENTITLEMENTS"

log "Re-signing a throwaway copy with allow-dyld-environment-variables for the load check"
while IFS= read -r -d '' dylib; do
	codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$dylib"
done < <(find "$CHECK_APP" -name '*.dylib' -print0)
codesign --force --options runtime --timestamp=none --entitlements "$DEBUG_ENTITLEMENTS" --sign "$IDENTITY" "$CHECK_APP"

CHECK_EXEC_PATH="$CHECK_APP/Contents/MacOS/$EXEC_NAME"
[ -x "$CHECK_EXEC_PATH" ] || die "executable not found or not executable: $CHECK_EXEC_PATH"

LOG_FILE="$CHECK_DIR/dyld-print-libraries.log"
log "Launching $CHECK_EXEC_PATH (throwaway debug copy) once with DYLD_PRINT_LIBRARIES=1"
DYLD_PRINT_LIBRARIES=1 "$CHECK_EXEC_PATH" >"$LOG_FILE" 2>&1 &
PID=$!
sleep 2
if kill -0 "$PID" 2>/dev/null; then
	kill "$PID" 2>/dev/null || true
else
	log "WARNING: process was no longer running after 2s (exited or crashed early) — log may be incomplete"
fi
wait "$PID" 2>/dev/null || true

[ -s "$LOG_FILE" ] || die "DYLD_PRINT_LIBRARIES log is empty — the check itself is broken (dyld produced no output at all), not evidence of a clean load: $LOG_FILE"
grep -qF "$CHECK_EXEC_PATH" "$LOG_FILE" \
	|| die "DYLD_PRINT_LIBRARIES log doesn't mention the app's own executable path — dyld tracing did not actually fire as expected (entitlement not effective?): $LOG_FILE"

# Extract every absolute path dyld printed (not just ones ending in .dylib — framework
# binaries like Contents/A/Foo.framework/Versions/A/Foo have no extension at all), then
# whitelist-filter to /usr/lib/, /System/, and inside the check copy's own bundle.
UNEXPECTED="$(grep -oE '/[^[:space:]]+$' "$LOG_FILE" \
	| sort -u \
	| grep -v "^$CHECK_APP/" \
	| grep -vE '^(/usr/lib/|/System/)' || true)"

if [ -n "$UNEXPECTED" ]; then
	log "Unexpected absolute load path(s) (not /System, not /usr/lib, not inside the bundle):"
	printf '%s\n' "$UNEXPECTED" >&2
	die "sign-and-verify.sh: unexpected loads detected — see above (full log: $LOG_FILE)"
fi
log "No unexpected loads detected (DYLD_PRINT_LIBRARIES clean, ${DYLIB_COUNT} dylib(s) checked)"

# --- 6. Notarization (automatic if credentials are stored, otherwise skipped) --------
notarize() {
	local zip_path
	NOTARIZE_TMP_DIR="$(mktemp -d -t macdows-notarize)"
	zip_path="$NOTARIZE_TMP_DIR/$(basename "$APP_PATH" .app).zip"

	log "Zipping for submission: $zip_path"
	ditto -c -k --keepParent "$APP_PATH" "$zip_path"

	log "Submitting to the Apple notary service (keychain profile: $NOTARY_PROFILE, this can take a few minutes)"
	local submit_out
	if ! submit_out="$(xcrun notarytool submit "$zip_path" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee /dev/stderr)"; then
		die "notarytool submit failed — see output above (xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE for the full report)"
	fi

	# notarytool's --wait exit code alone is not a trustworthy Accepted signal — gate the
	# staple on the explicit terminal status, so an Invalid/rejected submission never gets
	# a ticket stapled over it (recorded debt from the W4a review round).
	# grep -c >/dev/null, not grep -q: under `set -o pipefail` a -q early-exits and SIGPIPEs
	# its producer, making the pipeline status 141 instead of grep's answer. Harmless for a
	# short string like this today, but the repo's rule is that no pipeline decides a gate
	# with -q, precisely so nobody has to re-derive "is this one short enough to be safe?".
	if ! printf '%s' "$submit_out" | grep -c 'status: Accepted' >/dev/null; then
		die "notarization did not reach 'Accepted' — NOT stapling. Inspect: xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
	fi

	log "Stapling notarization ticket to $APP_PATH"
	xcrun stapler staple "$APP_PATH"
	log "Notarization complete"
}

if [ "$OFFLINE" -eq 1 ]; then
	log "Offline mode: skipping notarization"
elif [[ "$APP_PATH" == */Debug/* ]] && [ "${SIGN_AND_VERIFY_FORCE_NOTARIZE:-0}" != "1" ]; then
	# Debug builds are local-iteration artifacts; auto-submitting each one to the notary
	# service is pure waste (recorded debt from the W4a review round). Release paths keep
	# the automatic flow; SIGN_AND_VERIFY_FORCE_NOTARIZE=1 overrides deliberately.
	#
	# This one keeps the path heuristic on purpose, unlike the get-task-allow gate above.
	# The two fail in opposite directions: a wrongly-skipped notarization is loud and
	# self-correcting (the artifact simply is not stapled, and Gatekeeper says so on the
	# first machine that runs it), whereas a wrongly-downgraded entitlement check ships a
	# debuggable binary and nothing ever tells you. Tying an automatic submission to the
	# Apple notary service to a flag would also make --release cause network activity as a
	# side effect, which is a surprise this script should not spring.
	if [ "$RELEASE" -eq 1 ]; then
		log "WARNING: --release was given but this path is under a /Debug/ directory, so automatic notarization is still being skipped. If this artifact really is for distribution, re-run with SIGN_AND_VERIFY_FORCE_NOTARIZE=1 (or from a non-Debug path)."
	fi
	log "Debug build path detected — skipping automatic notarization (set SIGN_AND_VERIFY_FORCE_NOTARIZE=1 to override)"
else
	log "Checking for stored notarization credentials (keychain profile: $NOTARY_PROFILE)"
	if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
		notarize
	else
		log "No stored notarization credentials for profile '$NOTARY_PROFILE' — skipping notarization (not a failure)."
		log "To enable it, run once (interactive, needs an app-specific password from appleid.apple.com):"
		log "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id XTCC8DPHBX --password <app-specific-password>"
	fi
fi

log "sign-and-verify.sh: OK"
