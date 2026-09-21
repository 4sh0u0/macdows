# Phase 0.5 callback-layer capture samples (2026-09-21, 2x / HiDPI)

This directory is the in-force replay baseline (adr/0018 §1 U-7, §5.2 addendum five item 4):
the default for `Packages/MacdowsCore`'s `ReplayTests`, for `Tools/replay-diff`'s
self-diff fixture, and for `Scripts/upgrade-gate.sh`'s `--baseline`. The 1x directory
`../phase05-rail-events-2026-08-19/` is kept unchanged and stays replayable by passing it
explicitly (`SAMPLES_DIR=` / `--baseline`).

| File | Scenario |
|---|---|
| s1-baseline.jsonl | HiDef default on, winver, 25s (Enhanced RemoteApp: MapSurfaceToWindow actually issued) |
| s2-nohidef.jsonl | `--no-hidef` (legacy standard path, HandshakeEx flags 126 vs 127) |
| s3-multiapp.jsonl | Second ClientExecute on the same connection (winver→regedit @+8s, both S_OK) |
| s4-badpath.jsonl | Nonexistent program path (execResult=5 / rawResult=2 error semantics) |
| s5a.jsonl / s5b.jsonl | Disconnect→reconnect (server re-sends the full window list, incl. CachedIcon) |

Capture environment: libfreerdp 3.31.1 (submodule `63b948ca5cb94307fd5444ee6e73927a41ccdab4`),
RelWithDebInfo arm64, `WITH_FFMPEG=ON` / `WITH_VIDEOTOOLBOX=ON` (H264 decode available —
the 1x baseline was a clean build without H264), no local patches, prefix config hash
`a0ce4c8203b0ca2f`; client tree at macdows `f774615` (the batch log's own first line,
which is the tree rail-probe was built from); probe: rail-probe (callback-layer
JSONL, each line carries a monotonic-millisecond `t_ms` and thread `tid`); server: zh-CN
Windows 11, single-session TSAppAllowList path. The RAIL `ServerHandshakeEx` build number
is `0` in all six files (the server leaves that field zero), so no server build string is
derivable from these samples themselves — the recording's matrix env row carries it.
The rebaseline lane that switched the in-tree default to this directory branched from main
`a366832`, which is a later commit than the recording tree: `a366832` is where these files
landed, `f774615` is where they came from.

Recording form: one unattended batch on 2026-09-21, 10:49–10:51 JST, every leg run with
`--desktop 2560x1440 --scale 200` — i.e. `DesktopWidth=2560`, `DesktopHeight=1440`,
`DesktopScaleFactor=200`, `DeviceScaleFactor=100` in the pre-connect plan, and
`GfxResetGraphics` reporting 2560x1440. Per leg (each one its own probe invocation):

| File | Arguments beyond `--desktop 2560x1440 --scale 200` |
|---|---|
| s1-baseline.jsonl | `--app 'C:\Windows\System32\winver.exe' --duration 25` |
| s2-nohidef.jsonl | `--app 'C:\Windows\System32\winver.exe' --duration 25 --no-hidef` |
| s3-multiapp.jsonl | `--app 'C:\Windows\System32\winver.exe' --duration 30 --second-exec 'C:\Windows\regedit.exe' --second-delay 8` |
| s4-badpath.jsonl | `--app 'C:\NoSuchDir\nope.exe' --duration 15` |
| s5a.jsonl | `--app 'C:\Windows\System32\winver.exe' --duration 15` |
| s5b.jsonl | `--app 'C:\Windows\System32\winver.exe' --duration 15` (a second, independent invocation after s5a — that is the disconnect→reconnect) |

The host session was logged off once before the first leg and once after the last, never
between legs. Two consequences are visible in the data and are session state, not probe
behaviour: s1 is the batch's first connection (its surfaceIds start at 1 and it is the only
leg whose GFX-only "RemoteApp Marker Window" gets a `WindowCreate`), and the Registry
Editor window launched by s3 is still open in s4/s5a/s5b.

Sanitization: the six files were scanned before being committed with the Tier 1 red-line
patterns (`.github/scan-patterns.txt`) plus the lab account name, host-name fragments and
host address forms — zero matches in every file. Every distinct `title`, `exeOrFile` and
`program` literal was then reviewed by hand (7 distinct titles, 3 distinct program paths):
all are Windows system strings — an empty title, the shell desktop-container title, the
RDP tray helper title, a RemoteApp marker-window title, the zh-CN Text Input Experience
overlay title, winver's zh-CN About-dialog title, the zh-CN Registry Editor title — plus
the three `C:\Windows\...`-class program paths the probe itself passed in. No IPs,
hostnames, user names, credentials or certificate fingerprints appear in any file.

Purpose: replay-assertion baseline for the window-order/surface-binding handlers, and
input to the FreeRDP upgrade regression gate. The frozen-session feature pins in
`ReplayTests` (exact window counts, exact windowId sets, exact binding counts,
locale-dependent title literals) are pinned to this capture's own composition; two pins
whose statement shape only held for the 1x session are kept alive against the retired
directory there (`legacy1xFinalWindowCount`, `legacy1xPhantomSurfacesStayPending`), as is
the 1x focus-signal composition (`legacy1xFocusSignalTrace`).

Verification: `ReplayTests` is **not run by Tier 1 CI** — `.github/workflows/` never
invokes `swift test`, `Scripts/replay.sh` or `Scripts/upgrade-gate.sh`, so every red or
green that depends on this directory is visible only in a local run. `Scripts/replay.sh`
(no arguments) is that run.

Fingerprint coverage: `ReplayTests.frozenBaselineSHA256` pins the six `.jsonl` files only.
**This README is not fingerprint-protected** — editing it turns nothing red, so a claim
made here is held up by review alone. The retired 1x directory has its own per-file pins
(`ReplayTests.legacy1xBaselineSHA256`) guarded unconditionally by
`legacy1xSamplesFingerprintIntact`.

Diff against the retired 1x baseline (registration only, no interpretation — these are two
different capture sessions, so differences are expected). `replay-diff
samples/phase05-rail-events-2026-08-19 samples/phase05-rail-events-2026-09-21-2x` reports
1576 differences / 1468 regressions / 108 expected-local, verdict FAIL, made up of:
`fieldValueChanged` 731, of which the size-shaped fields are `ServerMinMaxInfo.*` (6x92),
`WindowCreate.windowWidth/Height` 84, `windowOffsetX/Y` 20, `GfxResetGraphics.width/height`
22 and `GfxMapSurfaceToWindow.mapped*` 18, and the non-size ones are
`WindowCreate.fieldFlags` 11, `WindowCreate.styleEx` 8, `WindowUpdate.fieldFlags` 4,
`WindowUpdate.title` 4, `ChannelDisconnected.name` 7 and `ChannelConnected.name` 1;
`eventCountChanged` 443 (`GfxMapSurfaceToWindow` 130, `NotifyIconCreate` 67 +
`NotifyIconUpdate` 45 + `NotifyIconDelete` 21, `WindowCreate` 75, `ServerMinMaxInfo` 63,
`MonitoredDesktop` 19, `WindowUpdate` 12, `ServerZOrderSync` 8, `GfxResetGraphics` 1,
`ChannelConnected` 1, `ChannelDisconnected` 1); `eventOrderChanged` 288;
`eventTypeOnlyOnOneSide` 6 findings (`WindowIcon` baseline-side only, two findings of two
occurrences each; `WindowCachedIcon` three findings, two baseline-side and one
candidate-side; `LogonErrorInfo` candidate-side only, one occurrence);
`knownLocalDifference` 108 = six captures x the 18 declared appended probe keys
(`resizeMargin*`, `clientOffset*`, `windowClientDelta*` on WindowCreate and WindowUpdate).
Diffing this directory against itself is clean (verdict PASS, zero differences).
