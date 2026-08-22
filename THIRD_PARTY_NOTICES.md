# Third-Party Notices

Macdows bundles the following third-party components. This file is enforced by
`Scripts/gen-notices.sh`, which reverse-derives the actually-packaged component list from
`otool -L` on the built app bundle plus the FreeRDP build manifest, and fails the build if
anything linked isn't documented here (adr/0001 NOTICE obligation 2, adr/0006 §5).

Generated inventory metadata (hashes, purls, patch pedigree) lives in
`sbom/macdows.cdx.json` (CycloneDX 1.6), regenerated
at release time by the same script.

---

## FreeRDP

- **Version**: 3.30.0 (tag `3.30.0`, commit `6b107f0aadbabc47941c5a5b893b88c01792af6d`) —
  synced with `deps/freerdp.lock`'s `.tag`; `Scripts/gen-notices.sh` reads that field and
  dies if this file doesn't mention it, so the two can't silently drift apart.
- **Upstream**: https://github.com/FreeRDP/FreeRDP
- **SPDX identifier**: Apache-2.0
- **License text**: `ThirdParty/FreeRDP/LICENSE` (vendored verbatim, upstream copyright
  headers untouched — see `ThirdParty/patches/README.md`)
- **Modified**: No local patches as of Phase 1. If `ThirdParty/patches/*.patch` becomes
  non-empty, the applied patch list is auto-populated into
  `sbom/macdows.cdx.json`'s `pedigree.patches` for the FreeRDP component; the
  human-readable summary belongs here once patches actually land.
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
- **License text**: https://github.com/openssl/openssl/blob/openssl-3.5.7/LICENSE.txt
  (not vendored into this repository — self-built from a pinned, checksum-verified
  tarball by `Scripts/build-openssl.sh`; the license text is fetched alongside the
  source tarball at build time and not tracked here as a separate file in Phase 1)
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

## zlib

- **Version**: system-provided (macOS `/usr/lib/libz.dylib`)
- **SPDX identifier**: Zlib
- **License text**: part of the macOS base system; not vendored or redistributed by
  this project
- **Modified**: No.
- **How it's packaged**: **not packaged.** Dynamically linked from the OS at
  `/usr/lib/libz.dylib` on every target Mac; nothing zlib-related is bundled or
  distributed by Macdows. Listed here for completeness per adr/0006 §5's Phase 1
  entry list, and because `Scripts/gen-notices.sh` detects the link and expects a
  matching (informational-only) entry.
