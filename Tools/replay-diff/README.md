# replay-diff

Semantic diff of two `rail-probe` JSONL captures. The comparison half of the W2 upgrade
gate; the driver is `Scripts/upgrade-gate.sh`.

```sh
swift test  --package-path Tools/replay-diff          # the suite
swift build --package-path Tools/replay-diff          # the binary
Scripts/upgrade-gate.sh                               # the gate, end to end, offline
```

Direct use, once built:

```sh
"$(swift build --package-path Tools/replay-diff --show-bin-path)/replay-diff" \
    samples/phase05-rail-events-2026-08-19 /path/to/re-record
```

Both arguments are either two `.jsonl` files or two directories of them (paired by base
name). `--help` documents every option; `--legend` prints the difference-class vocabulary
and the built-in known-difference table.

## What "semantic" buys

A byte diff of two captures of the same server behaviour is 100% noise: every `t_ms`,
every `tid`, and every kernel handle differs by construction. This tool ignores the timing
and thread fields outright, and compares session-scoped handles
(`windowId`/`ownerWindowId`/`activeWindowId`/`windowIdMarker`, `surfaceId`, `notifyIconId`)
as per-side first-appearance ordinals — so "the window ids changed" is silence while "this
surface now maps to a different window" is a finding. Events are matched per event type and
identity tuple, which tolerates cross-channel reordering exactly rather than approximately.

## Order: two tolerances, because there are three producer threads

Residual movement is checked twice. Every one of the six frozen phase05 captures has
**three** concurrent producer lanes, each on exactly one thread, and the lane is fully
determined by the `ev` name:

| lane | `ev` names | tids per capture |
|---|---|---|
| `main` (RAIL) | `PreConnect`, `WindowCreate`, `WindowUpdate`, `WindowIcon`, `MonitoredDesktop`, `NotifyIcon*`, `SecondExec*`, `DurationElapsed`, … | 1 |
| `gfx` (RDPGFX DVC) | `Gfx*` | 1 |
| `server` (RAIL-server callbacks) | `Server*` | 1 |
| `ambiguous` | `ChannelConnected`, `ChannelDisconnected` — the only two names ever observed on more than one thread — plus any event `MacdowsCore` does not model | 2 |

- **Within a lane**: `--lane-order-tolerance`, default **0**. A lane is one thread, so its
  event order is that thread's own callback order — causal. Any movement inside it is a real
  difference. This is what catches a causal inversion such as `WindowIcon` and
  `MonitoredDesktop` appearing before the `WindowCreate` they reference.
- **Across lanes**: `--order-tolerance`, default **2**. Interleaving between three concurrent
  producers near a given instant is genuine run-to-run noise.

Ranks, not indices, so that a long move reads as one finding about the event that moved
rather than one per event it passed — but note that property comes from the tolerance being
≥ 1, not from rank comparison itself. **It does not hold within a lane at the default
tolerance of 0**, where the bystanders fire too: one adjacent same-lane swap → 2 findings,
one 2-position same-lane move → 3. That is the price of catching causal inversions; reading N
same-lane order findings, look for one move, not N.

`ambiguous`-lane events are exempt from the within-lane check and governed by
`--order-tolerance` alone. The lane→thread census is *verified* against the frozen captures
by `LaneOrderTests`, not merely asserted.

What stops the partition rotting is **not** that census — U7 freezes the captures, so an
event a future probe adds can never appear in its input. It is that the `main` lane is an
explicit allow-list with no fall-through: a modelled `ev` name that is neither `Gfx*` nor
`Server*` nor listed resolves to `ambiguous` and is exempt from the within-lane check until
someone measures its thread and adds it in a reviewed edit. `LaneAllowListTests` pins that in
both directions. Today the list is exactly the 17 names measured on the main thread in the
frozen captures — `WindowDelete` and friends are modelled but occur zero times there, so they
are deliberately absent.

**Residual tolerated class.** What is still not reported is reordering *between* lanes
within `--order-tolerance` positions — a `Gfx*` surface map sliding two places past a
`WindowUpdate`, say. The lifecycle-breaking subset of that (an update/icon/delete for a
window that does not exist yet) is caught not here but by **phase 2** of
`Scripts/upgrade-gate.sh`: `Scripts/replay.sh` runs `ReplayTests.zeroAnomalies`, which
asserts `WindowModel` reports no `Anomaly` over the candidate. **`--skip-replay` removes
that control** — it is not a speed-up, it gives up the differ's backstop.

## Difference classes

| class | severity | meaning |
|---|---|---|
| `fieldValueChanged` | regression | a matched event's field holds a different value |
| `fieldPresenceChanged` | regression | a matched event has a field on one side only |
| `eventCountChanged` | regression | an event type occurs a different number of times, or against different windows/surfaces |
| `eventOrderChanged` | regression | a matched event moved further than the order tolerance allows |
| `eventTypeOnlyOnOneSide` | regression | an entire event type is present on one side only, unexplained |
| `knownLocalDifference` | **expected** | an entire event type is present on one side only, attributable to a known *local difference* between the two recordings (mechanism **not** asserted) |
| `unparsableLine` | regression | a line could not be parsed as a `RailEvent` |

`knownLocalDifference` exists because of M1 finding **F-1** and is pre-seeded with one
entry: `GfxMapSurfaceToScaledWindow`, expected on the *candidate* side, `supersedes`
`GfxMapSurfaceToWindow`, `newFields` `["targetWidth","targetHeight"]`.

### What is claimed, and what is not

No frozen phase05 capture contains the scaled event — verified independently by L4's audit,
and not for want of instrumentation (`rail-probe.c:754-767` has logged the scaled variant,
with `target*`, the whole time). The same host **did** emit it in a 2026-08-21 session. So
its appearance on a post-2026-08-19 capture is an **expected delta against this
pre-flip-era baseline**, and a drill record must not report it as an upstream regression.

**The mechanism is open.** An earlier revision of this file blamed the FFmpeg/AVC capability
flip. The M1 L4 audit — recorded in `deps/freerdp.lock`'s own `CORRECTION` note, appended
2026-09-01 to the "Phase 2 W0(2) AVC caps flip" entry — falsified that twice over: `AVC_DISABLED` is advertised identically
before and after the flip, and the variant was observed **two days before** the flip landed,
on a `WITH_FFMPEG=OFF` build. Assertions are forbidden in **both** directions — not "this is
the AVC flip", and not "this is upstream". The leading open hypothesis is the client's
advertised RDPGFX caps (`SCALEDMAP_DISABLE`, 10.7+), unmeasured because nothing logs the
`CapsAdvertise` PDU. **Resolver: the W2 drill's instrumented re-record.** Until then L11
must record `freerdp_avc`, `freerdp_scaledmap_caps`, `client_tool` and `session_desktop` for
both sides.

`supersedes` survives that falsification because it is not a causal claim: it says the plain
and scaled maps are two variants of one behaviour, which is a fact about the two payload
types (`RailEvent.swift:151-160`).

### `supersedes` pairs for comparison — it does not excuse from it

Only the **presence** of the type is excused. The two one-sided occurrence sets are matched
by identity tuple and field-compared exactly like a same-name pair, reported under a
`OldName→NewName` label. Counts must correspond; unmatched identities are
`eventCountChanged` regressions; every field except the declared `newFields` flows through
the normal field policy. `newFields` are exempt only in the direction that matches the
variant, and are recorded once per field ("present on N matched event(s)"), not once per
event.

Round-2 review measured what the alternative costs. With a name-level excuse, every surface
in all six captures re-mapped at **1×1 instead of 2560×1440** — a total graphics regression —
came out `PASS, exit 0`, with totals byte-identical to an honest flip. Since the baseline is
pre-flip forever, that would have been the *steady state* of every future drill. Now:

| candidate | verdict |
|---|---|
| honest flip (same surface, same window, same geometry) | **PASS** |
| flip + mapped geometry destroyed | **FAIL** (`fieldValueChanged` on `mappedWidth`/`mappedHeight`) |
| flip + surface re-attributed to a different window | **FAIL** (`eventCountChanged` on both identities) |
| flip + fewer scaled maps than plain ones | **FAIL** (`eventCountChanged`) |

### The pairing is conditional in three ways, each with a test

- **Directional.** The scaled event found only on the *baseline* side is not excused.
- **Paired.** A disappearance is only excused when its counterpart is itself present on the
  expected side **in the same comparison**. A lone disappearance stays a regression.
- **Not a co-appearance.** If both types appear on the *same* side, nothing was superseded;
  only the entry's own type is excused.

Add a one-off entry for a drill with `--known-difference-table FILE`, a JSON array of
`{"eventName","expectedSide","supersedes"?,"newFields"?,"cause","reference"}` (both optional;
absent `supersedes` = pure addition). The option is **not repeatable** — the last one given
wins — and a file naming the same event twice is refused. Every entry excuses one event
type's presence, so the built-in table stays minimal and additions are an owner ruling
recorded in the drill. The active table is printed into every report's notes, so a run with a
one-off table is never indistinguishable from a run without one.

## Exit codes

`0` clean (or only explained differences) · `1` unexplained difference · `2` could not run.

## Constraints this tool is built under

- **Offline.** The package has exactly one dependency, a *path* dependency on
  `Packages/MacdowsCore`. There is no `url:` dependency and no `Package.resolved`; argv is
  parsed by hand rather than pulling in swift-argument-parser. `Scripts/upgrade-gate.sh`
  must run on a machine with no network and no live host.
- **One parser.** `MacdowsCore.RailEvent.parseJSONL` decides which lines are valid and
  which event kinds are modelled; this package adds a structural re-read of the same line
  so it can name individual fields (`RailEventKind` is a closed enum with no field
  reflection). The two halves are joined on line number and cannot disagree.
- **Red lines.** Certificate/host fields (`host`, `commonName`, `subject`, `issuer`,
  `fingerprint`) are compared but never printed; a raw capture line is never echoed, not
  even in a parse-failure report. Output from a live re-record is still capture-derived —
  read it before copying anything into a tracked drill record.
- **The baseline stays frozen.** Test fixtures live under `Tests/`, never under `samples/`
  (M1 wave-1 ruling U7): `samples/phase05-rail-events-2026-08-19` is what the gate diffs
  against and must stay byte-identical.

## Known limitation: the ordinal-shift cascade

Canonical ordinals are assigned in first-appearance order, so anything that changes *which*
handle appears first shifts every later ordinal in that namespace — and the blast radius is
much larger than "the two windows trade ordinals". **Measured on a real capture: one extra
`WindowCreate` prepended to `s3-multiapp.jsonl` (145 lines) yields 98 `eventCountChanged`
findings on its own**, and roughly 190 findings in total. Only the 98 is
construction-independent — it falls out of the ordinal shift and is pinned by
`GateDriverPlumbingTests`; the `fieldValueChanged` and `eventOrderChanged` counts depend on
the payload of the injected window, so no exact total is quoted (two differently-shaped
injected lines gave 176–196 across review rounds). The propagation is the point: the `window`
namespace shift reaches every identity bucket that references a window, which is most of the
stream. A live re-record that opens one transient window the baseline did not (a splash
screen, a tooltip, a tray flyout) lands here.

The tool fails **loudly, never silently**, so the verdict is not misleading. But a
three-figure report for one extra window is exactly the false-alarm shape that trains an
operator to ignore a gate, so the report says so itself: whenever the two sides have
different numbers of distinct handles in a namespace, a `CASCADE RISK` note appears at the
top of that capture's section.

**First-line remedy for the operator**: read the `CASCADE RISK` note and the **first**
`eventCountChanged`, and check whether the candidate simply opened one extra window early in
the stream. If so, the rest of the report is one finding wearing a costume.
`--no-canonical-ids` is **not** the remedy here — it makes every handle differ. The real fix
is payload-anchored identity (title-keyed where a title is present), deferred to W2 batch 2.
