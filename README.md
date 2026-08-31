# Macdows

**Remote Windows application windows as native macOS windows, over RDP.**

Macdows maps each application window of a remote Windows host to a native macOS
`NSWindow` — the experience of Parallels' "Coherence" mode, but talking RDP to a real
remote machine instead of a local VM. It's built on FreeRDP's RAIL/RemoteApp channel
(`MS-RDPERP`) with a from-scratch Cocoa seamless-window backend — FreeRDP has never
shipped one before; the only RAIL backend it ships is X11.

> **Not affiliated with or endorsed by Microsoft, Apple, or Parallels.** "Coherence" is
> a Parallels feature name, "Windows" is a Microsoft trademark, and "Mac"/macOS are
> Apple trademarks. Macdows is an independent open-source project with no connection to
> any of those companies.

## Status

**Pre-alpha.** Phase 1 (native MVP: multi-window mapping + input) is complete, verified
on real hardware:

- Multi-app single session — several distinct remote application windows rendering
  concurrently in one RAIL session (the product's core claim)
- 20-cycle connect/disconnect soak, clean under a normal build, ASan, and TSan alike
- push→present latency, p95 ≈ 5ms

Phase 2 (seamless-experience core) is next: focus synchronization, Z-order sync, and
real H264 decode via a dynamically-linked ffmpeg + VideoToolbox hardware decode path.

### Architecture, in brief

FreeRDP 3.30 is vendored as a pinned git submodule plus an external, upstream-linked
patch queue — upstream source and license headers are never modified in place. A small
C event queue (`crdpq`) bridges FreeRDP's RAIL and window callbacks, which fire on
FreeRDP's own protocol threads, onto an ordered queue the Swift/AppKit side drains on
the main thread — no `NSWindow` is ever touched off-main. A from-scratch Cocoa
seamless-window backend then maps each RAIL window to a native `NSWindow`, presenting
pixel content via the `MS-RDPEGFX` surface-to-window binding path.

## Non-goals (v1)

- Multi-user / multi-session hosts
- RDP Wrapper, or anything beyond the single-session `TSAppAllowList` path Win11
  Pro/Enterprise permits
- Printing, drive redirection
- Enterprise gateways or public-internet-exposure hardening

(v1 *does* include basic audio redirection via `rdpsnd` — day-to-day usability without
sound was judged worth the small increment, given FreeRDP already provides it.)

## Requirements

- **Apple Silicon Mac** (arm64) running **macOS 14 (Sonoma) or later**
- **Xcode** plus [XcodeGen](https://github.com/yonaskolb/XcodeGen) (installed
  automatically by the bootstrap script below if missing)
- A **Windows 11 Pro/Enterprise host you own**, with RDP enabled and a RemoteApp
  published (`TSAppAllowList` / `fAllowUnlistedRemotePrograms`)

RemoteApp publishing on Windows client SKUs relies on a documented-but-not-officially-
supported registry mechanism. You are responsible for your own Windows licensing
compliance; multi-user commercial deployment requires Windows Server RDS with
appropriate CALs — that scenario is explicitly out of scope for this project.

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
documented anywhere in this repository. Launch it via `Scripts/run-window-smoke.command`.

## Legal

- Licensed under **Apache-2.0** — see [`LICENSE`](LICENSE).
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

- Commit style: `<type>: <summary>` (`feat` / `fix` / `docs` / `chore` / `refactor` /
  `test` / `build` / `merge`); commit messages and code comments are in English.
- No tracked file may ever contain real Windows host IPs/hostnames, RDP credentials,
  private-network addresses, or personal data — those live only in untracked local
  files. Any RAIL protocol capture sample must be sanitized before being committed.
- The full contributor/agent working rules live in `AGENTS.md`, which is
  maintainer-local (untracked); this section is the tracked summary of the rules
  that bind every contribution.
