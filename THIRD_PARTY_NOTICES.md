# Third-Party Notices

Macdows bundles the following third-party components. This file is enforced by
`Scripts/gen-notices.sh`, which reverse-derives the actually-packaged component list from
`otool -L` on the built app bundle plus the FreeRDP build manifest, and fails the build if
anything linked isn't documented here (adr/0001 NOTICE obligation 2, adr/0006 §5).

Generated inventory metadata (hashes, purls, patch pedigree) lives in
`sbom/macdows.cdx.json` (CycloneDX 1.6), regenerated
at release time by the same script.

> **The release gate is manual, not automated.** Nothing in CI runs it today — a Tier 2 CI
> pipeline is still an open owner decision — so before any artifact leaves this machine,
> both of these must be run by hand against the built `.app` and both must exit 0:
>
> ```sh
> Scripts/gen-notices.sh      <path-to-.app>   # licences, notices, SBOM
> Scripts/sign-and-verify.sh --release <path-to-.app>   # signing + release-only checks
> ```
>
> **`--release` is required, and it is not optional book-keeping.** It is what turns the
> `com.apple.security.get-task-allow` check into a hard failure; without it the script stays
> lenient so the ordinary Debug loop keeps working. The flag has to be stated explicitly
> because a macOS bundle carries no trustworthy build-configuration marker — a Debug and a
> Release `Macdows.app` have byte-identical `Info.plist`s — and guessing from the path would
> silently downgrade the check for a Release artifact that merely happens to sit under a
> directory named `Debug`.
>
> Notarization, unlike the entitlement check, is still gated on the artifact's *path*: an
> app under a directory named `Debug` is treated as a local-iteration build and is not
> submitted automatically. If your staging layout puts a real release artifact on such a
> path, re-run with `SIGN_AND_VERIFY_FORCE_NOTARIZE=1` (the script warns when `--release`
> and a `Debug` path are combined). That heuristic is kept deliberately: a wrongly skipped
> notarization is self-announcing, whereas a wrongly downgraded entitlement check is not.
>
> Treat a release without both commands green as unreleased. Everything below is only as
> accurate as the last time somebody ran them.

**These obligations ship with the application, not just with this repository.** A built
`Macdows.app` carries, in `Contents/Resources/`:

- `THIRD_PARTY_NOTICES.md` — this file
- `LGPL_RELINK.md` — the LGPL-2.1 §6 procedure for replacing the bundled FFmpeg
- `licenses/` — the verbatim licence text of every packaged component
  (see [`ThirdParty/licenses/`](ThirdParty/licenses/) for the tracked originals and their
  provenance)

`Scripts/gen-notices.sh` fails the release if any of them is missing from the bundle or has
drifted from the tracked copy, so a recipient who receives only the `.app` still gets
everything the licences require.

---

## FreeRDP

- **Version**: 3.30.0 (tag `3.30.0`, commit `6b107f0aadbabc47941c5a5b893b88c01792af6d`) —
  synced with `deps/freerdp.lock`'s `.tag`; `Scripts/gen-notices.sh` reads that field and
  dies if this file doesn't mention it, so the two can't silently drift apart.
- **Upstream**: https://github.com/FreeRDP/FreeRDP
- **SPDX identifier**: Apache-2.0
- **License text**: `ThirdParty/FreeRDP/LICENSE` (vendored verbatim, upstream copyright
  headers untouched — see `ThirdParty/patches/README.md`). Shipped with the app as
  `Contents/Resources/licenses/LICENSE-FreeRDP-Apache-2.0.txt`, a byte-identical copy
  tracked at `ThirdParty/licenses/LICENSE-FreeRDP-Apache-2.0.txt`.
- **Modified**: Yes — one patch, applied at build time from the external patch queue at
  `ThirdParty/patches/` (the vendored checkout itself stays a verbatim copy of the pinned
  tag; `Scripts/build-freerdp.sh` applies the queue before configuring and reverts it
  afterwards). The entry is
  `0001-core-capabilities-apply-input-caps-from-src.patch`: two one-token fixes in
  `libfreerdp/core/capabilities.c`'s `rdp_apply_input_capability_set()`, one a backport of
  upstream PR #13287 (`FreeRDP_UnicodeInput`), the other the same-shape fix for
  `FreeRDP_HasQoeEvent`, which upstream has not yet fixed. The queue is also auto-populated
  into `sbom/macdows.cdx.json`'s `pedigree.patches` for this component, as CycloneDX `patch`
  objects carrying the upstream reference from each patch's header.
  The Apache-2.0 obligations are met, not waived, by that arrangement. §4(b) ("modified files
  carry prominent notices") is discharged by the patch file itself: the modified source is
  never distributed — only the patch is — and its header records what changed, why, its
  upstream status and the condition under which it is dropped. The licence text and every
  upstream copyright header ship unaltered. §4(d) adds nothing here: FreeRDP 3.30.0 has no
  top-level `NOTICE` file, only `LICENSE`. (The one `NOTICE` anywhere in its tree,
  `winpr/libwinpr/sysinfo/cpufeatures/NOTICE`, belongs to a vendored third-party component
  that this configuration does not compile and that this patch does not touch.)
- **Includes**: WinPR (WinPR is part of the FreeRDP repository/release and shares the
  same license and copyright).
- **How it's packaged**: built as dynamic libraries and embedded into the app bundle's
  `Contents/Frameworks`: `libfreerdp3`, `libfreerdp-client3`, `libwinpr3` (adr/0006 §3 —
  dynamic-embed strategy; see that ADR for why static linking was rejected). FreeRDP's
  build also produces `libwinpr-tools3`, but nothing in `App/` links against it, so it is
  **not** embedded — don't list it here as packaged; if a future phase starts linking it,
  `Scripts/gen-notices.sh`'s `otool -L` scan will detect it and this entry needs updating
  first (the script fails the build until it is).

## OpenSSL

- **Version**: 3.5.7 (LTS series) — synced with `deps/freerdp.lock`'s `.openssl.version`;
  see the FreeRDP entry above for how that sync is enforced.
- **Upstream**: https://github.com/openssl/openssl (release
  https://github.com/openssl/openssl/releases/tag/openssl-3.5.7)
- **SPDX identifier**: Apache-2.0
- **License text**: `ThirdParty/licenses/LICENSE-OpenSSL-Apache-2.0.txt` — a byte-identical
  copy of `LICENSE.txt` from the pinned, checksum-verified `openssl-3.5.7.tar.gz`
  (upstream: https://github.com/openssl/openssl/blob/openssl-3.5.7/LICENSE.txt). Shipped
  with the app as `Contents/Resources/licenses/LICENSE-OpenSSL-Apache-2.0.txt`. OpenSSL is
  statically linked rather than shipped as its own dylib, but it is still redistributed as
  compiled code, so its licence travels with the artifact.
- **Modified**: No. Built unmodified with `no-shared darwin64-arm64-cc`.
- **How it's packaged**: built **statically** and linked into `libfreerdp3` — it does
  not appear as its own dylib in the bundle (`Scripts/gen-notices.sh` detects this via
  the FreeRDP build manifest's `OPENSSL_USE_STATIC_LIBS` flag rather than `otool -L`,
  since a static link leaves no separate Mach-O entry to find).
- **Why self-built instead of Homebrew's `openssl@3`**: the lab prototype linked
  Homebrew's OpenSSL by absolute path, which is undistributable and breaks on
  `brew upgrade openssl` — see adr/0006 §3 defect #1. A pinned, checksum-verified,
  statically-linked build is also required to have a meaningful SBOM entry ("whatever
  brew had installed today" is not a reproducible version).

## FFmpeg

- **Version**: 9.0.1 — synced with `deps/freerdp.lock`'s `.ffmpeg.version`; see the FreeRDP
  entry above for how that sync is enforced. (`libavcodec` 63, `libavutil` 61,
  `libswresample` 7.)
- **Upstream**: https://ffmpeg.org — source tarball
  https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz
  (SHA-256 `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`, pinned and
  verified on every build by `Scripts/build-ffmpeg.sh`)
- **SPDX identifier**: LGPL-2.1-or-later
- **License text**: `ThirdParty/licenses/LICENSE-FFmpeg-LGPL-2.1.txt` — a byte-identical
  copy of `COPYING.LGPLv2.1` from the pinned, checksum-verified tarball above. Shipped with
  the app as `Contents/Resources/licenses/LICENSE-FFmpeg-LGPL-2.1.txt`; delivering the
  licence with the binary is itself an LGPL-2.1 §1 obligation, not a courtesy.
- **Modified**: No. Built unmodified from the released tarball; the only project-specific
  input is the configure flag set below.
- **Why the licence claim is checkable, not just asserted**: FFmpeg is
  LGPL-2.1-or-later *only* when built without `--enable-gpl` / `--enable-nonfree` /
  `--enable-version3`. This build passes the explicit negations, and FFmpeg bakes its
  entire configure command line into `libavutil` as a string constant, so the posture can
  be read back out of the shipped binary:

  ```sh
  strings -a Macdows.app/Contents/Frameworks/libavutil.61.dylib | grep -- --disable-gpl
  ```

  `Scripts/build-ffmpeg.sh` runs exactly that check itself and refuses to finish if it
  fails, or if `--enable-gpl`/`--enable-nonfree`/`--enable-version3` appear.
- **Configure flags** (recorded here as the evidence of the non-GPL, decode-only build;
  also in `deps/freerdp.lock` `.ffmpeg.configure_flags`, with
  `Scripts/build-ffmpeg.sh`'s `FFMPEG_CONFIGURE_FLAGS` array as the executable source of
  truth):

  <!-- BEGIN ffmpeg-configure-flags -->

  ```
  --disable-gpl --disable-nonfree --disable-version3
  --enable-shared --disable-static --install-name-dir=@rpath
  --disable-everything --disable-programs --disable-doc
  --disable-avdevice --disable-avformat --disable-avfilter --disable-swscale
  --enable-decoder=h264 --enable-parser=h264
  --enable-videotoolbox --enable-hwaccel=h264_videotoolbox
  --disable-autodetect --enable-pthreads
  --disable-network --disable-openssl --disable-iconv
  --disable-zlib --disable-bzlib --disable-lzma
  --arch=arm64
  --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags=-mmacosx-version-min=14.0
  ```

  <!-- END ffmpeg-configure-flags -->

- **How it's packaged**: built as **dynamic libraries** and embedded into the app bundle's
  `Contents/Frameworks`: `libavcodec.63.dylib`, `libavutil.61.dylib`,
  `libswresample.7.dylib`. Static linking is prohibited here (adr/0007) precisely because
  LGPL-2.1 §6 requires that a user be able to substitute their own build of the library.
  `libswresample` is shipped even though Macdows and FreeRDP call no `swr_*` symbol:
  `libavcodec` carries its own load command on it, so it is a required part of the set.
  Nothing else from FFmpeg is built or shipped — `libavformat`, `libavfilter`,
  `libavdevice` and `libswscale` are not produced at all.
- **How to replace it with your own build**: see **[`LGPL_RELINK.md`](LGPL_RELINK.md)** in
  this repository — step-by-step, runnable instructions for obtaining the exact
  corresponding source, rebuilding it (modified or not), swapping the three dylibs inside
  `Macdows.app`, and re-signing. That document is this project's LGPL-2.1 §6 offer;
  `Scripts/gen-notices.sh` fails the release gate if it is missing or names a different
  version than the one actually shipped.
- **Why self-built instead of Homebrew's `ffmpeg`**: two independent blockers. (1) The
  Homebrew formula is built `--enable-gpl --enable-version3` (and pulls in libx264 and
  libx265), which makes those binaries **GPL-3.0** — redistributing them inside this
  Apache-2.0 application is not permitted, which is what made this a hard prerequisite for
  any external distribution. (2) It links by absolute `/opt/homebrew/...` path, which is
  undistributable and breaks on `brew upgrade ffmpeg` — the same adr/0006 §3 defect #1 that
  the OpenSSL entry above describes. The self-built version additionally narrows what is
  shipped from seven libraries to three.

## zlib

- **Version**: system-provided (macOS `/usr/lib/libz.dylib`)
- **SPDX identifier**: Zlib
- **License text**: `ThirdParty/licenses/LICENSE-zlib.txt`, extracted verbatim from the
  macOS SDK's own `zlib.h` — the header of the very library the app links. Shipped with the
  app as `Contents/Resources/licenses/LICENSE-zlib.txt` for completeness; zlib itself is
  part of the macOS base system and is **not** vendored or redistributed by this project, so
  no redistribution obligation attaches to it.
- **Modified**: No.
- **How it's packaged**: **not packaged.** Dynamically linked from the OS at
  `/usr/lib/libz.dylib` on every target Mac; nothing zlib-related is bundled or
  distributed by Macdows. Listed here for completeness per adr/0006 §5's Phase 1
  entry list, and because `Scripts/gen-notices.sh` detects the link and expects a
  matching (informational-only) entry.
