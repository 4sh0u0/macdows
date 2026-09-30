# rail-stim

A parameterless RAIL stimulus fixture for the `rail-probe` measurement lane.

`stim-window.c` builds to a tiny native Win32 GUI `.exe` that `rail-probe` launches on a
lab host as a RemoteApp. It creates one top-level window — so the server emits a RAIL
window-create order the instant it appears, and that order landing in the probe's JSONL is
the stimulus taking effect — holds the window visible for a fixed interval, then closes
itself and exits `0`. It writes nothing to disk, the registry, or the task scheduler.

It is a measurement fixture, **not** a wrapper around another program: it deliberately
does not shell out to anything else, because a child process or a second window would
defeat its clean-exit guarantee.

The exhaustive, requirement-by-requirement rationale lives in the header comment of
[`stim-window.c`](stim-window.c). This file is the operator's short version.

## Why it exists

`rail-probe` sends exactly one RAIL `ClientExecute` per launch: the program field holds a
path, the argument field is empty, and the exec flags are `0` (ADR-0021 §5 S1; the primary
`--app` goes out through FreeRDP's `client_rail_server_start_cmd`, which populates only
`FreeRDP_RemoteApplicationProgram`). So the launched artifact has to do its whole job with
**no arguments**. `winver`/`notepad` satisfy "no arguments" but leave a window open that
has to be closed; `stim-window` is the well-behaved alternative that produces a clean
create/destroy pair and cleans up after itself.

## Build

Either toolchain produces a no-argument GUI `stim-window.exe`.

**Cross-compile on the Mac** (keeps a compiler off the host):

```sh
brew install mingw-w64
x86_64-w64-mingw32-gcc -O2 -mwindows -Wall -Wextra \
    -o stim-window.exe stim-window.c -luser32 -lgdi32
```

`-mwindows` selects the GUI subsystem (no console window). The source uses the ANSI `*A`
Win32 APIs and `WinMain`, so no `-municode` (mingw) or `/DUNICODE` (MSVC) is needed and the
two toolchains produce the same behavior.

**On the host with the MSVC Build Tools:**

```bat
cl /O2 stim-window.c /link /SUBSYSTEM:WINDOWS user32.lib gdi32.lib
```

## Place

Install and launch it from a path that satisfies the controller-side red-line rules (the
path string reaches print-plan, B-0 and the docs archive): **not** under `\Users\`, **no**
whitespace, **not** IP-shaped, and containing a backslash. Recommended:

```
C:\Lab\stim-window.exe
```

Provision `C:\Lab` once, as the owner/admin — the lab account cannot create a directory at
the drive root — and let it inherit the default `C:\` ACL so the lab account gets Read &
Execute. That one-time placement is setup, not runtime state: the fixture itself mutates
no persistent host state when it runs.

## Wire into rail-probe

Point the probe's primary app (or the second leg) at the installed path:

```
--app C:\Lab\stim-window.exe
# or, to exercise the delayed second ClientExecute:
--second-exec C:\Lab\stim-window.exe
```

Run rail-probe only through `Scripts/probe.sh` (the boundary gate), never the binary
directly.

## Verify

- **Launch succeeded:** read the probe's `exec-result` for this program. `0` is
  `RAIL_EXEC_S_OK`; any non-zero is the server's own error code (e.g. `FILE_NOT_FOUND` for
  a bad path, which is how a mistyped install path shows up).
- **Stimulus fired and cleaned up:** the JSONL carries a RAIL window-create order for the
  `MacdowsRailStim` window shortly after launch, and a matching destroy order when the
  self-close timer fires. No window from this fixture should survive into a later snapshot.

## Knobs

Both are compile-time — the RAIL launch carries no arguments, so anything adjustable is a
`#define`, not a runtime flag.

| Define | Default | Meaning |
| --- | --- | --- |
| `STIM_VISIBLE_MS` | `8000` | How long the window stays up before it self-closes. The probe records the create and destroy orders regardless of this value; it only sets the steady-state dwell. Safe ceiling: the window closes at `connect + second-delay + STIM_VISIBLE_MS/1000`, which must stay below the 420 s session end (with the default 30 s delay, keep it under ~300 s; staying `<= delay + 300 s` also keeps the destroy order inside the witness window). |
| `STIM_X` / `STIM_Y` / `STIM_W` / `STIM_H` | `120 / 120 / 480 / 320` | Deterministic outer-window rectangle (frame included), fixed rather than `CW_USEDEFAULT` so every run presents the same geometry to the measurement. |

The window style is `WS_OVERLAPPEDWINDOW` (the thick-frame, "notepad-shaped" case). A lane
that needs the dialog-shaped border instead changes that one style in `stim-window.c`.
