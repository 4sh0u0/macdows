# Pre-authored known-difference table files

Files here are **inert until explicitly injected** with `--known-difference-table <file>`.
Nothing in the differ loads them by default, and shipping one is not an owner ruling that
it applies to any particular run — each is an entry whose *precondition* is documented
here, and the decision to inject is made per drill, by the operator, against that drill's
own recorded facts. The injection (and the fact that the precondition held) must be
recorded in the drill record, next to the run's other inputs.

This is the table's conditionality mechanism, by design: `KnownDifferenceEntry` is an
unconditional empirical statement about two recordings, so any condition lives in table
*selection*, not in schema. A condition the machine cannot verify (host state at
recording time is operator-recorded metadata, not derivable from captures) would gain
nothing from a schema field except a new way to be silently wrong.

The CLI takes **one** table file per run (`--known-difference-table` overrides, last flag
wins; the file is merged over the built-in `preSeeded` entries, file wins on collision).
A drill that needs several pre-authored entries concatenates them into a single JSON
array — the loader refuses duplicate `eventName`s, differing names coexist fine.

## window-cached-icon-candidate-cold.json

Excuses `WindowCachedIcon` appearing on the **baseline side only** (type census only).

- **Precondition — candidate half only**: this drill's recorded `host_freshness` states
  the **candidate** was captured on a freshly rebooted host. Freshness unknown or
  unrecorded → do **not** inject; the type-only findings are then exactly the signal the
  gate exists to show.
- **Why not "baseline warm" too**: the baseline half has no independent record — the
  2026-08-19 recording day predates the freshness discipline (`host_freshness: unknown`,
  not backfillable), and "the baseline host was warm" can only be inferred from the very
  cached-icon events this entry excuses. A precondition that demanded it would either be
  permanently unsatisfiable or be satisfied by circular reasoning; the entry therefore
  rests on the candidate-side record plus the frozen captures' own contents, and says so.
- **Direction**: matches the one verified observation (drill C-3, 2026-09-01). The mirror
  situation (cached icons on the candidate side only) has never been observed; if it
  occurs, author a fresh entry with `expectedSide: "candidate"` for that drill and record
  it there — entries are empirical statements about a specific pair of recordings, and
  this directory does not pre-author directions nobody has seen.
- **Boundary**: the `WindowIcon` *count* shift in the same corpus is **not evidence** for
  the cache story (the +2 also appears in s3/s5a, which have no cached-icon events on
  either side) and is deliberately not excused — counts stay visible findings; only the
  cached-variant's whole-type presence is.

The shape of every file here is pinned by `GateDriverPlumbingTests` (loader must accept
it; load-bearing fields must keep their ruled values; entry count is pinned so nothing
rides along), so a schema change that would invalidate a shipped file fails the suite
instead of failing an operator mid-drill.
