# Replacing the bundled FFmpeg libraries (LGPL-2.1 §6)

Macdows dynamically links three **FFmpeg** libraries for H.264/AVC decoding, and ships them
inside the application bundle:

| File in `Macdows.app/Contents/Frameworks/` | Component      |
| ------------------------------------------ | -------------- |
| `libavcodec.63.dylib`                       | libavcodec     |
| `libavutil.61.dylib`                        | libavutil      |
| `libswresample.7.dylib`                     | libswresample  |

FFmpeg is licensed under the **LGPL-2.1-or-later** (this build passes `--disable-gpl
--disable-nonfree --disable-version3`; see `THIRD_PARTY_NOTICES.md`). Section 6 of the
LGPL-2.1 requires that you be able to modify the library and relink the application against
your modified version. **This document is how you do that.** Everything below is
copy-pasteable and works offline once the tarball is downloaded.

Macdows itself is Apache-2.0 and its own source is in this repository; nothing here
restricts what you may do with your replacement FFmpeg.

---

## What makes this possible

The three libraries are ordinary shared libraries loaded at runtime by
`libfreerdp3.3.dylib`, whose load commands reference them purely by
`@rpath/libavcodec.63.dylib` and friends — no static linking, no absolute paths, no symbol
inlining across the boundary. Replacing the files in `Contents/Frameworks/` *is* the
relink; you do not need to rebuild Macdows or FreeRDP, and you do not need this
repository's toolchain.

The only real constraint is the **soname**: your build must produce libraries whose install
names still match `@rpath/libavcodec.63.dylib`, `@rpath/libavutil.61.dylib` and
`@rpath/libswresample.7.dylib`. Building the same major versions with
`--install-name-dir=@rpath` (step 2) does that automatically.

---

## Prerequisites

- macOS on Apple Silicon (`arm64`), matching what Macdows ships.
- Xcode command line tools: `xcode-select --install`.
- No other dependency. The configure line below deliberately builds nothing that needs an
  external library, and needs no assembler beyond clang's (there is no `nasm` requirement
  on `arm64`).

---

## Step 1 — Obtain the exact corresponding source

Macdows ships FFmpeg **9.0.1**. That exact release:

```sh
mkdir -p ~/ffmpeg-relink && cd ~/ffmpeg-relink

curl -fLO https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz

# Verify you got the same bytes this project pinned (deps/freerdp.lock .ffmpeg.sha256):
echo "cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635  ffmpeg-9.0.1.tar.xz" \
  | shasum -a 256 --check

tar -xJf ffmpeg-9.0.1.tar.xz
cd ffmpeg-9.0.1
```

The upstream release index (including the GPG signature
`ffmpeg-9.0.1.tar.xz.asc`) is at <https://ffmpeg.org/releases/>. Upstream git for the same
release is <https://git.ffmpeg.org/ffmpeg.git>, tag `n9.0.1`.

> If you are reading a copy of this file that is older than the app you are patching, take
> the version and checksum from the shipped app instead — `deps/freerdp.lock`'s `.ffmpeg`
> block, or directly out of the binary:
> `strings -a Macdows.app/Contents/Frameworks/libavutil.61.dylib | grep -m1 -- --prefix`
> prints the full configure line the shipped libraries were built with.

## Step 2 — Make your modifications

Edit the source however you like. For example, to prove to yourself that the swap actually
took effect, you can change the version banner:

```sh
# purely illustrative: makes av_version_info() report a suffix you can recognise
printf '%s' "9.0.1-my-build" > VERSION
```

## Step 3 — Build a replacement

These are the exact flags Macdows' own build uses (`Scripts/build-ffmpeg.sh`,
`FFMPEG_CONFIGURE_FLAGS`; mirrored in `deps/freerdp.lock` `.ffmpeg.configure_flags`).
Reproducing them gives you drop-in-compatible libraries. You may of course change them —
just keep `--enable-shared`, `--install-name-dir=@rpath`, and the same major versions.

<!-- BEGIN ffmpeg-configure-flags -->

```sh
./configure \
  --prefix="$HOME/ffmpeg-relink/out" \
  --disable-gpl \
  --disable-nonfree \
  --disable-version3 \
  --enable-shared \
  --disable-static \
  --install-name-dir=@rpath \
  --disable-everything \
  --disable-programs \
  --disable-doc \
  --disable-avdevice \
  --disable-avformat \
  --disable-avfilter \
  --enable-swscale \
  --enable-decoder=h264 \
  --enable-parser=h264 \
  --enable-videotoolbox \
  --enable-hwaccel=h264_videotoolbox \
  --disable-autodetect \
  --enable-pthreads \
  --disable-network \
  --disable-openssl \
  --disable-iconv \
  --disable-zlib \
  --disable-bzlib \
  --disable-lzma \
  --arch=arm64 \
  --extra-cflags=-mmacosx-version-min=14.0 \
  --extra-ldflags=-mmacosx-version-min=14.0
```

<!-- END ffmpeg-configure-flags -->

```sh
make -j"$(sysctl -n hw.ncpu)"
make install
```

Notes on two flags that are easy to get wrong:

- `--enable-parser=h264` is **required**. `--disable-everything` also disables parsers, and
  FreeRDP calls `av_parser_init(AV_CODEC_ID_H264)` and treats a `NULL` result as a fatal
  error, so a build without it fails to start decoding.
- `--enable-pthreads` is **required alongside** `--disable-autodetect`, because
  `--disable-autodetect` switches off the thread libraries too and the
  `h264_videotoolbox` hwaccel depends on pthreads. Without it the build still succeeds but
  hardware decoding is silently dropped.

Check what you produced:

```sh
ls -l "$HOME/ffmpeg-relink/out/lib/"
otool -D "$HOME/ffmpeg-relink/out/lib/libavcodec.63.dylib"   # -> @rpath/libavcodec.63.dylib
```

## Step 4 — Swap the libraries into the app

Work on a copy first if you want to keep the original around.

```sh
APP=/Applications/Macdows.app          # adjust to wherever your copy lives
OUT="$HOME/ffmpeg-relink/out/lib"

# Keep a backup of the originals.
mkdir -p ~/ffmpeg-relink/backup
cp -p "$APP/Contents/Frameworks/libavcodec.63.dylib" \
      "$APP/Contents/Frameworks/libavutil.61.dylib" \
      "$APP/Contents/Frameworks/libswresample.7.dylib" \
      ~/ffmpeg-relink/backup/

# Install your build. `cp -L` matters: the files in the prefix are symlinks to
# libavcodec.63.1.101.dylib etc., and the bundle needs real files at the soname name.
cp -L "$OUT/libavcodec.63.dylib"    "$APP/Contents/Frameworks/libavcodec.63.dylib"
cp -L "$OUT/libavutil.61.dylib"     "$APP/Contents/Frameworks/libavutil.61.dylib"
cp -L "$OUT/libswresample.7.dylib"  "$APP/Contents/Frameworks/libswresample.7.dylib"
```

## Step 5 — Re-sign

Replacing files inside a signed bundle invalidates its signature, and macOS refuses to
launch it until it is signed again.

**What necessarily changes, and why.** The signature that ships on Macdows is a Developer ID
signature over the exact bytes of every file in the bundle. You have just changed some of
those bytes, so that signature cannot survive — there is no flag, entitlement, or ordering
that preserves it. Your replacement is signed by *you*. Concretely:

- **The signing identity changes** from `Developer ID Application: … (XTCC8DPHBX)` to your
  own — an ad-hoc identity (`-`, no certificate and no Apple account) if you have nothing
  else. The bundle's Team ID goes away with it.
- **The resource seal is recomputed.** `Contents/_CodeSignature/CodeResources` records a
  hash of every file, so it must be re-sealed; that happens automatically when you sign the
  bundle (the last command below).
- **Library validation has to be relaxed** — see the box after the commands. This is
  unavoidable when replacing a library in a hardened-runtime app with one you signed
  yourself, and it is the one protection you genuinely give up.

Everything else — the hardened runtime, and any entitlements the app shipped with — is
preserved by the recipe below, and is *not* preserved by a plain `codesign --force --sign -`.

```sh
APP=/Applications/Macdows.app          # the same $APP as step 4

# --- 5a. Carry over whatever entitlements the shipped app had, and add the one that
#         makes a self-signed library loadable (see the box below).
# `--entitlements :FILE` (with the colon) writes a real, re-signable plist. Without the
# colon codesign prints a human-readable dump that is NOT valid signing input.
ENT="$(mktemp -t macdows-relink).plist"
if ! codesign -d --entitlements ":$ENT" "$APP" 2>/dev/null || [ ! -s "$ENT" ]; then
  # The shipped app may legitimately have no entitlements at all; start from an empty dict.
  cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
fi
plutil -convert xml1 "$ENT"
/usr/libexec/PlistBuddy -c \
  "Add :com.apple.security.cs.disable-library-validation bool true" "$ENT" 2>/dev/null || true

# --- 5b. Sign inside-out: every embedded library first, then the bundle.
#         --options runtime keeps the hardened runtime on. Sign ALL the dylibs, not only
#         the three you replaced: the others still carry the original Developer ID
#         signature, and a bundle signed by you cannot load libraries signed by someone
#         else.
find "$APP" -name '*.dylib' -print0 | while IFS= read -r -d '' dylib; do
  codesign --force --options runtime --sign - "$dylib"
done

codesign --force --options runtime --entitlements "$ENT" --sign - "$APP"
rm -f "$ENT"

# --- 5c. Verify.
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d -v "$APP" 2>&1 | grep -E 'CodeDirectory|TeamIdentifier'
```

That last line should report `flags=0x10002(adhoc,runtime)` — `adhoc` because you signed it,
`runtime` because the hardened runtime survived.

> **Why `disable-library-validation` is required, not optional.**
> The hardened runtime enforces *library validation*: a process may only load libraries
> signed by the same Team ID as its main executable (or Apple platform binaries). Ad-hoc
> signatures carry no Team ID at all, and "no team" does not match "no team" — dyld rejects
> the load with
> `not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs`.
> Measured on this exact bundle:
>
> | How you re-sign | Resulting flags | Launches? |
> | --- | --- | --- |
> | `codesign --force --sign -` (no `--options runtime`) | `0x2(adhoc)` | yes — but the hardened runtime is silently **gone** |
> | `--options runtime`, no entitlements | `0x10002(adhoc,runtime)` | **no** — library validation rejects it |
> | `--options runtime` + `disable-library-validation` | `0x10002(adhoc,runtime)` | **yes** ← the recipe above |
>
> So the real choice is which protection to give up: the whole hardened runtime, or just
> library validation. The recipe keeps the hardened runtime and gives up only library
> validation, which is the smaller loss.
>
> **If you have your own Developer ID certificate**, you do not have to give up anything:
> sign every dylib and the bundle with `--sign "Developer ID Application: …"` instead of
> `-`, drop the `disable-library-validation` line, and library validation passes normally
> because all the code once again shares one Team ID.

Also worth knowing:

- **Gatekeeper quarantine.** An app downloaded from the internet carries a quarantine
  attribute; after re-signing it yourself, clear it with
  `xattr -dr com.apple.quarantine "$APP"`.
- **Notarization does not survive either.** If the copy you started from was notarized, the
  stapled ticket no longer matches. That is expected and does not prevent the app from
  running locally.

## Step 6 — Confirm the swap took effect

```sh
# The app now loads your libraries and nothing from outside the bundle:
otool -L "$APP/Contents/Frameworks/libfreerdp3.3.dylib" | grep libav

# Your build's own configure line, read back out of the shipped binary:
strings -a "$APP/Contents/Frameworks/libavutil.61.dylib" | grep -m1 -- --prefix
```

Then launch the app and connect to a host that negotiates the RDP graphics pipeline with
AVC/H.264. Decoding runs through your libraries.

To undo everything, copy the files back from `~/ffmpeg-relink/backup/` and re-sign, or
simply reinstall Macdows.

---

## If something goes wrong

| Symptom | Cause |
| ------- | ----- |
| `dyld: … not valid for use in process: … have different Team IDs` | The `disable-library-validation` entitlement was not applied, or you signed only some of the dylibs. Re-run step 5 exactly — it signs *every* dylib in the bundle, not just the three you replaced. |
| App won't launch, Console shows a code signature error | Step 5 was skipped, or the bundle itself was not re-signed after the libraries. Sign inside-out: libraries first, then the bundle. |
| `codesign -d -v` shows `flags=0x2(adhoc)` instead of `0x10002(adhoc,runtime)` | `--options runtime` was omitted, so the hardened runtime was dropped. Harmless for local use, but you are running with less protection than the shipped build; re-sign with the flag. |
| `dyld: Library not loaded: @rpath/libavcodec.63.dylib` | The replacement's install name doesn't match. Rebuild with `--install-name-dir=@rpath`, and check with `otool -D`. |
| Connects, but the remote screen stays blank or falls back to a slower codec | The H.264 decoder or parser is missing from your build. Confirm `--enable-decoder=h264` and `--enable-parser=h264`. |
| Video works but CPU usage is high | The VideoToolbox hwaccel was dropped — the usual cause is `--disable-autodetect` without `--enable-pthreads`. |

Upstream FFmpeg build documentation: <https://ffmpeg.org/platform.html#macOS>.
