# ThirdParty/patches/

Patch queue applied on top of the pinned `ThirdParty/FreeRDP` submodule commit.

## Why patches live here instead of in the submodule

The submodule stays a clean, unmodified checkout of the pinned upstream tag/commit. Any
local delta is expressed as a `.patch` file here and applied by `Scripts/build-freerdp.sh`
before configuring the build. This keeps "what did we change" always equal to the
contents of this directory (`git diff` on a submodule pointer bump is a one-line SHA
change, not a haystack of interleaved local edits), and keeps upstream `LICENSE`/`NOTICE`/
copyright headers physically untouched — a structural requirement of the project's
licensing policy (upstream license and copyright text stays verbatim).

Rejected alternatives: `git subtree` (pollutes full history, blows up the history-audit
cost) and a plain source copy (no provenance, conflicts head-on with the version-tracking
policy).

## Rules (enforced, not advisory)

1. **Every `.patch` file's header must cite an upstream issue or PR link.** A patch with
   no upstream record is a review blocker — it is exactly the shape of a privately
   maintained fork accreting undocumented changes. Put the link in a comment at the top
   of the patch file, e.g.:

   ```
   # Upstream: https://github.com/FreeRDP/FreeRDP/issues/12345
   # or: https://github.com/FreeRDP/FreeRDP/pull/12345
   ```

   **Lab-only exception (owner ruling 2026-09-07, ADR-0016 §5 question 2).** A patch that
   introduces a build knob which (a) defaults OFF so the default build is unchanged, (b) is
   only ever enabled for a non-rendering lab tool, and (c) is backed by an *Accepted* ADR,
   may carry this header line instead of an upstream link:

   ```
   # Lab-only: default OFF; ADR: docs/adr/NNNN-<slug>.md
   ```

   The line is matched literally by `crdp_patch_record_ok` in `Scripts/lib.sh` (the one
   implementation `Scripts/build-freerdp.sh`, Tier 1's `Scripts/check-patch-queue.sh` and the
   release SBOM generator `Scripts/gen-notices.sh` all consult; `Scripts/test-patch-queue.sh`
   pins it): "default OFF" and the `docs/adr/` path are mandatory, and the record must be in
   the patch *header* -- the lines before the first real diff line (`diff --git `, `--- a/` or
   `--- /dev/null`) -- so a link that merely appears inside a hunk does not count. The marker
   is a claim, and the patch has to substantiate it mechanically: a hunk of a CMake file
   (`*.cmake` or `CMakeLists.txt`) must ADD an `option(<NAME> "..." OFF)` line whose `<NAME>`
   is not also on a removed line of the same file (a new knob -- not an existing option flipped
   `ON`→`OFF`, not an option line placed in the header or in a non-CMake file). The file a hunk
   targets is the one its `+++` line names -- what `git apply` reads -- and a `diff --git` line
   that disagrees with it is refused outright. The exception does not apply
   to bug fixes or behaviour changes: those still need an upstream record, because the point
   of rule 1 is to stop this directory becoming an undocumented fork. Such a patch is retired
   when its experiment closes, not carried.

2. **`git apply` failure is a hard build failure.** `Scripts/build-freerdp.sh` applies
   every `*.patch` file in this directory with `git apply --check` first; if any patch
   fails to apply cleanly, the build stops. There is no silent skip and no fuzzy-apply
   fallback — a patch that no longer applies means the upstream pin moved out from under
   it and needs a human to look at it (rebase the patch or drop it if upstream absorbed
   the fix).

3. **Upgrade = move the submodule pointer + replay the patch queue + pass the replay
   gate.** Patches are the only form local modification is allowed to take. When bumping
   the pinned FreeRDP tag, re-apply every patch in this directory against the new
   checkout; a patch that stops applying blocks the upgrade until resolved.

4. **Quarterly review.** Patches with an open upstream PR should be checked periodically
   for whether upstream has since merged the fix — if so, drop the local patch on the
   next version bump instead of carrying it forever.

## Current state

**One patch** against FreeRDP 3.31.1 (`63b948ca5cb94307fd5444ee6e73927a41ccdab4`):

- `0002-rdpgfx-lab-scaledmap-advertise-option.patch` (2026-09-07, lab-only exception, ADR-0016)
  -- adds the CMake option `MACDOWS_LAB_SCALEDMAP_ADVERTISE` (default **OFF**) that omits
  `RDPGFX_CAPS_FLAG_SCALEDMAP_DISABLE` from the advertised RDPGFX capability sets. OFF leaves
  every preprocessed line as it was; ON is a protocol-level false advertisement used only by
  `Tools/rail-probe` for the D1 contrast experiment (`Scripts/build-freerdp.sh` with
  `CRDP_LAB_SCALEDMAP_ADVERTISE=1`, a separate config-hash prefix never made `current`). Each
  modified site carries a one-line `Macdows lab patch 0002` notice (Apache-2.0 §4(b));
  `THIRD_PARTY_NOTICES.md`'s FreeRDP entry says "Modified: Yes" and names it. Retire when D1's
  record is filed -- and remove nothing else: `Scripts/build-freerdp.sh` records the option's
  cache value as an OPTIONAL manifest key precisely so retiring this patch is a one-file change.

Before it (2026-09-02 to 2026-09-07) the queue was empty on purpose: the one patch this project
carried before was absorbed upstream and retired on the 3.31.1 pin bump.

### Retired

- `0001-core-capabilities-apply-input-caps-from-src.patch` (carried against 3.30.0) --
  `rdp_apply_input_capability_set()` read two received-capability values out of the
  destination `settings` instead of the parsed server answer `src`. Hunk 1 fixed upstream by
  PR #13287 (commit 21cd3d6), hunk 2 by this project's PR #13313 (commit 7447382); both are in
  the 3.31.1 tag (`libfreerdp/core/capabilities.c:1414` and `:1423` read `src`). `git apply
  --check` against the 3.31.1 tree fails, which is exactly rule 2's "upstream absorbed the
  fix -- drop the patch" case. The retirement record with the verification lives in
  `deps/freerdp.lock` (`retired_patches`).

The rules above predate the first patch on purpose -- the bar was set before anything was
ever added to this directory, and it stays set with the directory empty.
