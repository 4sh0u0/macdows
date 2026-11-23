# Macdows

**Remote Windows application windows as native macOS windows, over RDP.**

Macdows maps each application window of a remote Windows host to a native macOS
`NSWindow` — the experience of Parallels' "Coherence" mode, but talking RDP to a real
remote machine instead of a local VM. It's built on FreeRDP's RAIL/RemoteApp channel
(`MS-RDPERP`) with a from-scratch Cocoa seamless-window backend — FreeRDP has never
shipped one before; the RAIL backends it does ship belong to its other clients (X11,
Windows, Android and, since 3.32.0, SDL3).

> **Not affiliated with or endorsed by Microsoft, Apple, or Parallels.** "Coherence" is
> a Parallels feature name, "Windows" is a Microsoft trademark, and "Mac"/macOS are
> Apple trademarks. Macdows is an independent open-source project with no connection to
> any of those companies.

## Status

**Pre-alpha.** No builds are published: there are no prebuilt binaries and no releases,
and the only way to run Macdows is to build it from source (see [Building](#building))
and allow-list your host (see the first known issue below).

- **Phase 1** (native MVP: multi-window mapping + input) is complete, verified on real
  hardware:
  - Multi-app single session — several distinct remote application windows rendering
    concurrently in one RAIL session (the product's core claim)
  - 20-cycle connect/disconnect soak, clean under a normal build, ASan, and TSan alike
  - push→present latency, p95 ≈ 5ms
- **Phase 2** (seamless-experience core) is complete: focus synchronization, Z-order
  synchronization, window style translation, local move/resize, remote tray icons
  (mirrored as entries in the Macdows menu bar menu, left click only), and Cmd↔Ctrl key
  mapping. An LGPL-only FFmpeg with H264 and VideoToolbox decode is built in and linked
  dynamically, but the client does not negotiate H264 with the host yet.
- **Phase 3** (hardening) is in progress. Delivered so far: HiDPI on a single display,
  automatic reconnect after a dropped connection, an app shell (host list and editor,
  settings, certificate confirmation, and a start panel opened from the Dock icon; the
  Help menu items are placeholders), and input-method and keyboard handling. Audio
  playback is wired up but not yet verified on a real host. Not done yet: clipboard,
  multi-monitor, drag and drop, and systematic compatibility testing.

### Known issues and limitations

- **Connections are limited to an allow-list.** As a development safeguard, Macdows
  refuses to connect unless the host's address falls inside a network listed in
  `~/.config/macdows/lab-boundary.env` (one key, `MACDOWS_LAB_ALLOWED_NETS`, holding a
  space-separated CIDR list); without that file, every connection is refused.
- **No clipboard redirection.** The `cliprdr` channel is not wired up.
- **Audio is playback only and not yet verified on a real host.** The host's sound
  is routed to this Mac through the `rdpsnd` channel; it can be turned off in the
  settings (General > Sound). The microphone is not supported.
- **Single display only.** No per-monitor layout is sent to the host, only a single
  local display has been exercised, and display changes made during a session are not
  sent to the host.
- **Manual host setup.** You publish the RemoteApp yourself through the registry (see
  Requirements); there is no user-facing host setup guide, and `Tools/host-agent` is
  only a feasibility prototype.
- **NLA only.** Connections use Network Level Authentication with NTLM (no Kerberos, no
  Microsoft Entra ID sign-in); hosts that require Standard RDP Security or TLS-only
  security are not supported.
- **Host lock screen, UAC and Ctrl+Alt+Del are not handled.** When the host switches to
  its secure desktop, Macdows does not detect it or tell you, and how the remote windows
  behave then has not been characterized.
- **Few verified host configurations.** No systematic compatibility testing across
  Windows builds and applications has been done, so expect gaps beyond the ones tried
  so far.

### Architecture, in brief

FreeRDP is vendored as a pinned git submodule (the pinned version is recorded in
`deps/freerdp.lock`) plus an external, upstream-linked patch queue. The patches live
outside the submodule: the build applies them to the checkout and reverts them when it
exits, so the checkout is clean at rest. None of the queued patches touches upstream
license headers. A small C event queue (`crdpq`) bridges FreeRDP's RAIL and window
callbacks, which fire on FreeRDP's own protocol threads, onto an ordered queue the
Swift/AppKit side drains on the main thread — no `NSWindow` is ever touched off-main. A
from-scratch Cocoa seamless-window backend then maps each RAIL window to a native
`NSWindow`, presenting pixel content via the `MS-RDPEGFX` surface-to-window binding
path.

## Non-goals (v1)

- Multi-user / multi-session hosts
- RDP Wrapper, or anything beyond a single session on a Windows 11 Pro/Enterprise
  host
- Printing, drive redirection
- Enterprise gateways or public-internet-exposure hardening

(Basic audio redirection via `rdpsnd` is in scope for v1 — day-to-day usability without
sound was judged worth the small increment, given FreeRDP already provides it. Playback
is wired up but not yet verified on a real host, and the microphone is not supported;
see Known issues above.)

## Requirements

- **Apple Silicon Mac** (arm64) running **macOS 14 (Sonoma) or later**
- **Xcode** plus [XcodeGen](https://github.com/yonaskolb/XcodeGen) (installed
  automatically by the bootstrap script below if missing)
- A **Windows 11 Pro/Enterprise host you own**, with RDP enabled and a RemoteApp
  published (`TSAppAllowList` / `fAllowUnlistedRemotePrograms`)

### Windows licensing

The Macdows app is a client only. It contains no Microsoft software, and neither
this project nor its licence grants you any right to use Windows or any other
Microsoft product.

To use Macdows, the Windows host has to be configured to accept RemoteApp
connections, which involves registry or policy settings. There is no user-facing setup
guide or script; you configure the host yourself. As far as we could find, Microsoft
does not document or support this setup on a standalone Windows 11 Pro or Enterprise
PC; Microsoft documents RemoteApp hosting for Windows Server Remote Desktop Services
and for Azure Virtual Desktop. A Windows update may change how these settings behave.

Whether your use of Windows is permitted — including who connects to the host, from
which devices, how many people use it at the same time, and the changes you make to
its configuration — depends on the licence terms for your copy of Windows
(preinstalled, retail, volume and subscription licences can differ; the terms for
preinstalled copies of Windows 11 say they can be reviewed under
Settings > System > About). Read the terms for your copy and, if in doubt, ask
Microsoft or a qualified adviser.

Macdows is designed for one person and one session at a time. If your Windows PC is
seldom or never used in person, check what your licence terms say about in-person use
and how long remote access may continue before relying on such a setup. Multi-user
use, and providing Windows to other people as a service, are out of scope. Nothing in
this repository is legal advice.

## Building

```sh
git clone --recurse-submodules https://github.com/4sh0u0/macdows.git
cd macdows
./Scripts/bootstrap.sh
```

`bootstrap.sh` is the one-command path from a clean checkout to a buildable Xcode
project: it installs the required Homebrew formulas (`cmake`, `ninja`, `xcodegen`,
`jq`, `pkg-config`), initializes the vendored `ThirdParty/FreeRDP` submodule, verifies
it's pinned to the commit recorded in `deps/freerdp.lock`, builds a pinned static
OpenSSL, a pinned LGPL-only FFmpeg and the vendored FreeRDP from source, and runs
`xcodegen generate`. It's idempotent — safe to re-run any time.

FFmpeg is built from source rather than installed from Homebrew on purpose: the Homebrew
formula is a GPL-3.0 build, which cannot be redistributed inside this Apache-2.0
application. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and
[`LGPL_RELINK.md`](LGPL_RELINK.md).

Then build the app:

```sh
xcodebuild -project App/Macdows.xcodeproj -scheme Macdows build
```

Run the pure-Swift package tests (no display, no signing identity required):

```sh
swift test --package-path Packages/MacdowsCore
```

`Scripts/test-queue.sh` runs the same suite under a normal build plus AddressSanitizer
and ThreadSanitizer — this is the matrix Phase 1's soak testing ran clean under.

`Tools/window-smoke` is an end-to-end, real-host verification harness (it drives an
actual `NSApplication` against a live RAIL session) — it's opt-in and needs a Windows
RDP host you control, supplied via `WIN_HOST`/`WIN_USER`/`WIN_PASS` environment
variables or a local, untracked host-credentials file (see
`Tools/window-smoke/main.swift` for the exact mechanism). No real host values are
documented anywhere in this repository. Like the app, it refuses any host outside the
allow-list described under Known issues. Launch it via
`Scripts/run-window-smoke.command`.

## Legal

- Licensed under **Apache-2.0** — see [`LICENSE`](LICENSE).
- The Macdows app contains no Microsoft software, and neither this project nor its
  licence grants any right to use Windows or any other Microsoft product; see
  [Windows licensing](#windows-licensing).
- Vendors **FreeRDP** (Apache-2.0) as a pinned git submodule (`ThirdParty/FreeRDP`,
  unmodified upstream source plus an external, upstream-linked patch queue).
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) documents every third-party
  component actually packaged into the app bundle, and a CycloneDX SBOM is generated
  alongside it at release time by `Scripts/gen-notices.sh`, which fails the build if
  anything linked isn't documented.
- The compliance payload ships **inside the artifact**, not just the repo: the app
  bundle carries `THIRD_PARTY_NOTICES.md`, `LGPL_RELINK.md` and the full licence texts
  (vendored under [`ThirdParty/licenses/`](ThirdParty/licenses/)) in
  `Contents/Resources/`, and `Scripts/gen-notices.sh` fails the release gate if any of
  them is missing or has drifted from the tracked copy.
- Bundles **FFmpeg** (LGPL-2.1-or-later) for H264 decode, self-built from a pinned,
  checksum-verified upstream tarball with `--disable-gpl --disable-nonfree
  --disable-version3` and linked **dynamically only**. Dynamic linking and the
  source-availability obligation under LGPL §6 are a deliberate design constraint, not an
  afterthought: [`LGPL_RELINK.md`](LGPL_RELINK.md) is the runnable, step-by-step
  procedure for replacing the bundled libraries with your own modified build.

## Repository conventions

- Commit style: `<type>(<scope>): <summary>` (`feat` / `fix` / `docs` / `chore` /
  `refactor` / `test` / `build` / `ci` / `merge`), where the scope is optional; commit
  messages and code comments are in English.
- No tracked file may ever contain real Windows host IPs/hostnames, RDP credentials,
  private-network addresses, or personal data — those live only in untracked local
  files. Any RAIL protocol capture sample must be sanitized before being committed.
- The full contributor/agent working rules live in `AGENTS.md`, which is
  maintainer-local (untracked); this section is the tracked summary of the rules
  that bind every contribution.
