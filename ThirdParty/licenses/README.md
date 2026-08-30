# Vendored third-party license texts

These are the verbatim licence texts for every third-party component Macdows packages.
They are **tracked in the repository and copied into the built application bundle** at
`Macdows.app/Contents/Resources/licenses/`, alongside `THIRD_PARTY_NOTICES.md` and
`LGPL_RELINK.md` — so the licence obligations travel with the artifact rather than only
with the source repository. A user who receives only the `.app` still has everything the
licences require them to have.

`Scripts/gen-notices.sh` fails the release gate if any file listed below is missing from
the bundle, or if a bundled copy has drifted from the tracked copy (it compares SHA-256).
`App/project.yml`'s Copy Files build phase is what puts them there.

| File | Component | Provenance (byte-identical copy of, except zlib — a verbatim extract, see its row) |
| --- | --- | --- |
| `LICENSE-FFmpeg-LGPL-2.1.txt` | FFmpeg | `COPYING.LGPLv2.1` from the pinned, checksum-verified `ffmpeg-9.0.1.tar.xz` |
| `LICENSE-FreeRDP-Apache-2.0.txt` | FreeRDP (incl. WinPR) | `ThirdParty/FreeRDP/LICENSE` at the pinned submodule commit |
| `LICENSE-OpenSSL-Apache-2.0.txt` | OpenSSL | `LICENSE.txt` from the pinned, checksum-verified `openssl-3.5.7.tar.gz` |
| `LICENSE-zlib.txt` | zlib | the licence notice at the top of the macOS SDK's own `zlib.h` |

Notes:

- **FFmpeg is the one with a real obligation attached.** It is LGPL-2.1-or-later and is
  redistributed as three dynamic libraries inside the bundle, so §6's "let the user
  substitute their own build" right applies. `LGPL_RELINK.md` — also shipped in
  `Contents/Resources/` — is the runnable procedure that satisfies it.
- **zlib is *not* redistributed.** Macdows links `/usr/lib/libz.dylib` from the operating
  system; no zlib code is bundled. Its notice is included for completeness (and because
  `THIRD_PARTY_NOTICES.md` lists it), not because a redistribution obligation exists. It
  was extracted from the SDK header of the exact library the app links rather than
  retyped, so it is authentic rather than approximate.
- **OpenSSL is statically linked** into `libfreerdp3`, so it has no dylib of its own in the
  bundle — but it is still redistributed as compiled code, hence its licence text is here.
- These files are **copies, not the authority**. The authority is upstream, at the pinned
  version recorded in `deps/freerdp.lock`. Re-copy them from the corresponding pinned
  source whenever a component is bumped; `Scripts/gen-notices.sh` will fail the release if
  the version in `deps/freerdp.lock` stops matching what `THIRD_PARTY_NOTICES.md` claims.
