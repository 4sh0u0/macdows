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

**No patches** against FreeRDP 3.31.1 (`63b948ca5cb94307fd5444ee6e73927a41ccdab4`). The queue
is empty on purpose: the one patch this project ever carried was absorbed upstream and retired
on the 3.31.1 pin bump (2026-09-02).

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
