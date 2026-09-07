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
   is a claim, and the patch has to have the **lab-only shape**, a grammar checked
   mechanically over its whole diff body: (1) exactly one new `option(MACDOWS_LAB_<X> "..." OFF)`
   line added in a hunk of a `*.cmake` / `CMakeLists.txt` file -- the knob, and the ONLY line a
   CMake file may gain (a `#` line there is a comment only outside a multi-line quoted or bracket
   argument, which a hunk cannot prove, so none is admitted; the knob's description string
   carries the notice); (2) every other added line is a one-line C comment that is nothing else
   (`/* ... */` alone, `//`) or exactly `#cmakedefine MACDOWS_LAB_<X>` in a `*.in` template --
   no code line is admitted, even one that names the knob; (2a) independently of (2), NO added
   line of any kind in any hunk may contain a backslash or `??` (a line ending in `\` or the
   `??/` trigraph is spliced with the next physical line before comments are recognised and
   would swallow real code); (3) every removed line is a
   `#if`/`#elif` line re-added in the same hunk as the removed text followed by
   ` && !defined(MACDOWS_LAB_<X>)` -- a guard appended, nothing else; (4) text hunks of
   existing files only: every `diff --git` block carries a `---`/`+++` pair naming the same file
   the block names (what `git apply` reads), so bare hunks, mode-only blocks, binary blocks,
   new or deleted files, renames and copies are refused. A bug fix, a behaviour change, an
   extra hunk riding along, a `set(KNOB ...)` override, a runtime `if (KNOB)` or a knob named
   outside `MACDOWS_LAB_*` fails one of the four, which is the point: rule 1 exists to stop this
   directory becoming an undocumented fork, and the exception admits nothing but a guarded,
   default-OFF knob. The shape does not judge comment text or the option's description (inert),
   nor whether the guarded `#if` sites are the right ones -- that is the ADR's and the reviewer's
   job. Such a patch is retired when its experiment closes, not carried.

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

**No patches** against FreeRDP 3.31.1 (`63b948ca5cb94307fd5444ee6e73927a41ccdab4`). The queue is
empty on purpose: both patches this project ever carried are retired -- `0001` absorbed upstream on
the 3.31.1 pin bump (2026-09-02), `0002` retired by design when its lab experiment closed
(2026-09-07). The rules above, including the lab-only exception, stay set with the directory empty.

### Retired

- `0002-rdpgfx-lab-scaledmap-advertise-option.patch` (carried 2026-09-07 under the rule-1 lab-only
  exception, ADR-0016) -- added the CMake option `MACDOWS_LAB_SCALEDMAP_ADVERTISE` (default OFF)
  that omitted `RDPGFX_CAPS_FLAG_SCALEDMAP_DISABLE` from the advertised RDPGFX capability sets, so
  `Tools/rail-probe` could run the D1 contrast (`Scripts/build-freerdp.sh` with
  `CRDP_LAB_SCALEDMAP_ADVERTISE=1`). Retired the same day by owner ruling once the D1 record was
  filed (result: the server sends the scaled map variant only when the flag is not advertised;
  ADR-0016 section 3 row 1, n=2 per side). Not the rule-2 case -- it still applied cleanly at
  retirement -- but the exception's own condition: retired when the experiment closes, not
  carried. The toggle and the optional manifest key remain in `Scripts/build-freerdp.sh` and
  fail closed without the patch (the toggle refuses when the applied tree defines no such
  option). Record in `deps/freerdp.lock` (`retired_patches`).
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
