# Macdows host-agent (feasibility prototype)

A small HTTP agent that runs **inside the user's Windows RDP session** and answers three
questions the RDP/RAIL wire cannot. This is Phase 2 work item **W7**: a prototype whose only
job is to prove the three capabilities are reachable from a standard, non-admin user account.
It is not a product, it is not installed, and it is not meant to be left running.

## What it proves

| # | Capability | Route |
|---|------------|-------|
| 1 | Enumerate published RemoteApps (`TSAppAllowList`) and extract each icon as a PNG | `GET /v1/apps` |
| 2 | **Proxied launch**: start a program that is *not* published as a RemoteApp | `POST /v1/launch` |
| 3 | Resolve the executable that opens a given extension (`.pdf`) for this user | `GET /v1/assoc?ext=.pdf` |

Capability 2 is the differentiator. RAIL can only start what the host has published. The agent
can start anything the operator put in **its own** allowlist file, which is how Macdows could
eventually offer "open this file on the remote host with its default app" without asking an
administrator to publish a new RemoteApp for every program.

## Trust model

* **Loopback only by default.** Binds `127.0.0.1`, so it is reachable only from inside the RDP
  session. See the LAN deviation warning below.
* **Bearer token per launch.** 32 bytes from the platform CSPRNG, hex-encoded, printed once at
  startup and written to `%LOCALAPPDATA%\Macdows\host-agent\token`. Every request must carry
  `Authorization: Bearer <token>`; the comparison is constant-time. Authentication happens
  *before* routing, so an unauthenticated caller cannot even discover which routes exist —
  every such request gets `401` with a `{}` body and no hint.
* **No arbitrary execution, ever.** `POST /v1/launch` accepts an allowlist **id** and nothing
  else. Any `path`, `command`, or `args` in the request body is ignored. The agent resolves the
  program from its own config file and starts it with `Start-Process` — no shell, no `cmd /c`.
  Shells and script hosts (`cmd`, `powershell`, `pwsh`, `wscript`, `cscript`, `mshta`,
  `rundll32`, `regsvr32`, ...) are refused at allowlist-load time even if the operator lists
  them, because allowing one would turn the fixed allowlist back into arbitrary execution.
* **Read-only against the system.** No registry writes, no service install, no autostart, no
  UAC elevation, no code signing, no file transfer, no UI. The agent only reads registry keys
  and starts allowlisted programs.
* **Bounded input.** 64 KiB maximum request, 5 s per-connection read/write timeout, `GET`/`POST`
  only, no `Transfer-Encoding`, no duplicate headers.
* **Nothing sensitive is logged.** The token is printed exactly once at startup and never
  again; request bodies are never logged. `-Verbose` logs only `METHOD path -> status`.

### Why a raw `TcpListener` instead of `HttpListener`

The agent must run as a **standard, non-admin user**. `System.Net.HttpListener` on an arbitrary
prefix requires a URL ACL reservation (`netsh http add urlacl`), which needs administrator
rights — a dependency this prototype exists to avoid. The everyone-reserved
`http://+:80/Temporary_Listen_Addresses/<guid>/` prefix would work without admin, but it puts
the agent on shared port 80 alongside whatever else answers there and forces a GUID path
prefix into every client URL.

So the agent uses `System.Net.Sockets.TcpListener` on `127.0.0.1` with a deliberately minimal
HTTP/1.1 parser: request line, a handful of headers, `Content-Length`, no chunked encoding,
no keep-alive. Everything it does not understand is rejected with `400`. Zero admin
dependencies, and the accepted surface is small enough to read in one sitting.

## Requirements

* Windows PowerShell **5.1** (the shipped `powershell.exe`). PowerShell 7 is *not* required on
  the host. The script is 5.1 / .NET Framework 4.8 compatible.
* A standard user account inside the RDP session. No administrator rights.

## Running it on the host

```powershell
# from the folder holding the script
copy allowlist.sample.json allowlist.json
powershell -ExecutionPolicy Bypass -File .\MacdowsHostAgent.ps1
```

It prints its version, the allowlist load result, the token, and the listening address:

```
macdows-host-agent 0.1.0 (feasibility prototype - not for production)
allowlist: 5 usable entr(y/ies) from .\allowlist.json
token: <64 hex characters>
token file: C:\Users\<user>\AppData\Local\Macdows\host-agent\token
listening on http://127.0.0.1:47615/  (Ctrl+C to stop)
```

Parameters:

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-Port` | `47615` | |
| `-BindAddress` | `127.0.0.1` | Anything else prints a loud warning (see below) |
| `-AllowlistPath` | `allowlist.json` beside the script | Missing file is a warning, not an error: the agent starts with an empty allowlist |
| `-TokenPath` | `%LOCALAPPDATA%\Macdows\host-agent\token` | |
| `-Once` | off | Serve one connection and exit; used by the tests |
| `-NoServe` | off | Define the functions but do not listen; used when dot-sourcing from tests |
| `-Verbose` | off | Logs `METHOD path -> status` per request |

### The allowlist

`allowlist.sample.json` lists a few stock programs that are normally *not* published as
RemoteApps, which is what makes them useful for demonstrating capability 2:

```json
{ "entries": [ { "id": "charmap", "name": "Character Map",
                 "path": "%SystemRoot%\\System32\\charmap.exe", "args": [] } ] }
```

Rules enforced at load time — a rejected entry is reported and skipped, it never takes the
whole file down:

* `id` matches `^[A-Za-z0-9._-]{1,64}$` and is unique
* `%SystemRoot%` / `%windir%` are resolved; any other `%TOKEN%` left unresolved is rejected
* the path must be absolute (drive, UNC, or POSIX), must not contain a `..` segment, and must
  point at a file that exists
* the target must be a program — only `.exe` and `.com` are accepted. PowerShell 5.1's
  `Start-Process` uses `ShellExecute`, so an entry pointing at a `.docx` or an `.hta` would
  launch that file type's *registered handler* rather than a program of its own; the basename
  deny-list cannot see that, and this check is what makes "only ever a fixed list of programs"
  actually hold
* shells and script hosts are refused
* `args`, if present, must be an array of strings

Paths are not required to live under `%SystemRoot%`; the *sample* deliberately only uses
programs that do.

### Prototype-only deviation: binding a LAN address

The Mac-side acceptance run in this repo talks to the host over the LAN, which means binding
something other than loopback:

```powershell
powershell -ExecutionPolicy Bypass -File .\MacdowsHostAgent.ps1 -BindAddress 0.0.0.0
```

**This is a lab-only deviation and the agent prints a loud warning when you do it.** Anyone who
can reach that address and obtain the token can list your applications and start allowlisted
programs in your session. There is no TLS: the token crosses the network in clear text.
Do not leave the agent running after the probe, and treat the token as burned afterwards
(restarting the agent mints a new one). In the real design this traffic would ride an RDP
virtual channel, not a TCP socket — that is exactly what W7 is meant to inform.

**Windows Firewall will block the inbound connection**, and the agent cannot do anything about
that: creating an inbound rule requires administrator rights, which this prototype deliberately
does not have. Expect the first LAN probe to time out (`HTTP 000`). Options, in order of
preference:

1. **Use `probe.ps1` instead** (see below). It runs inside the Windows session against
   `127.0.0.1`, so nothing inbound is needed and the agent keeps its loopback bind. This is the
   recommended path and matches the production posture.
2. Tunnel the port over an existing connection (for example SSH port forwarding) and keep the
   agent bound to `127.0.0.1`.
3. Have an administrator add a one-time inbound rule for the port. This trades away the
   "no admin rights anywhere" property, so prefer 1 or 2 for the feasibility run and delete the
   rule afterwards.

## The two probes

There are two acceptance runners, one per side. They check the same three capabilities and
print the same `PASS`/`FAIL` shape; pick by where you can actually reach the agent from.

| | `probe.sh` (Mac) | `probe.ps1` (Windows, **recommended**) |
|---|---|---|
| Runs on | macOS | inside the Windows RDP session |
| Talks to | `http://<host>:<port>` over the LAN | `http://127.0.0.1:<port>` |
| Needs an inbound firewall rule | **yes** (admin) | no |
| Agent bind | LAN (prototype-only deviation) | loopback (production posture) |
| Needs | `curl`, `python3` | Windows PowerShell 5.1 only |
| Results reach the Mac via | directly | `-OutDir` on a redirected drive |

`probe.ps1` is the one to use for the real feasibility run: it needs no deviation from the
loopback bind and no administrator anywhere.

## Running the Windows-side probe (`probe.ps1`)

```powershell
powershell -ExecutionPolicy Bypass -File .\probe.ps1 -OutDir C:\Temp\macdows-probe
```

In the lab, run it as a RemoteApp with the script and the output directory both on redirected
drives, so the results land on the Mac without any inbound connection:

```
powershell.exe -File \\tsclient\macdows\probe.ps1 -OutDir \\tsclient\lab\out
```

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-OutDir` | *(required)* | May be a redirected drive |
| `-Port` | `47615` | |
| `-TokenPath` | `%LOCALAPPDATA%\Macdows\host-agent\token` | Where the agent wrote its token |
| `-LaunchId` | first `agentAllowlist` entry with `inTsAllowList == false` | |
| `-NoRun` | off | Define the functions but do not probe; used when dot-sourcing from tests |

It writes `health.json`, `apps.json`, `assoc.json`, `launch.json`, `icon-0.png` and `result.txt`
to `-OutDir`, prints one `PASS`/`FAIL` line per capability (`apps+icon`, `launch`, `assoc`) to
both stdout and `result.txt`, and exits non-zero if any of them failed. Health is reported as an
informational line rather than a fourth capability — if the agent is unreachable, all three
capability lines fail anyway.

It **always** finishes by writing a `DONE` marker file into `-OutDir`, even when a check fails
or the run throws. That marker (`probe finished <UTC timestamp> failures=<n>`) is what lets the
Mac side distinguish "finished and failed" from "still running or died", which matters when the
only channel back is a redirected drive.

The token is read from the token file and used only as a request header. It is never printed,
never written to any output file, and never logged — there is a test asserting exactly that.

## Running the Mac-side probe (`probe.sh`)

`probe.sh` is the LAN-side equivalent. It uses only `curl` and `python3`, and takes
everything it needs as arguments — no host, port, or token is baked into any file here.

```sh
./probe.sh <host> <port> <token> [launch-id] [out-dir]
```

* `<token>` is the value the agent printed at startup
* `[launch-id]` defaults to the first `agentAllowlist` entry whose `inTsAllowList` is `false`,
  i.e. a program that is provably not reachable through RAIL
* `[out-dir]` defaults to `./probe-out` and receives `health.json`, `apps.json`, `assoc.json`,
  `launch.json`, and `icon-0.png`

It prints one `PASS`/`FAIL` line per capability and exits non-zero if any of them failed. The
bearer token is passed to curl through a private config file so it does not show up in `ps`.

```
PASS  health         GET /v1/health
PASS  apps + icons   GET /v1/apps
PASS  association    GET /v1/assoc?ext=.pdf
PASS  proxied launch POST /v1/launch (id=charmap)
```

The apps check decodes the first non-null icon and asserts the bytes really start with the PNG
magic number, so a base64 field that is not actually an image cannot pass.

## Tests

```sh
pwsh -NoProfile -File ./MacdowsHostAgent.Tests.ps1
```

Runs on macOS under PowerShell 7 and on the host under Windows PowerShell 5.1. **Pester is not
required** — the file carries a ~40-line assertion harness and exits non-zero on any failure.
77 tests covering:

* **The agent** — HTTP head parsing and body framing, size limits, route dispatch and status
  codes, constant-time token comparison, allowlist validation, extension validation, and the
  `/v1/health` JSON shape with every Windows-only call stubbed.
* **`probe.ps1`'s pure parts** — result-line formatting, the PNG magic check, default
  launch-id selection and icon selection over a parsed `/v1/apps` object (including the
  one-element-array-collapsed-to-an-object shape that PowerShell 5.1 can emit).
* **End to end** — three runs that start a real agent on `127.0.0.1` with `-Once` and drive it
  with `curl`, plus three that run `probe.ps1` as a separate process against a live stub agent
  and assert the artifacts, the `DONE` marker, the exit code, and that the token never leaks
  into any output file. The stub agent is the real server loop and HTTP stack with only the
  Windows-only providers replaced, which is what lets `probe.ps1`'s PASS path be proven on macOS.

Every Windows-only call (registry, `System.Drawing`, `Shlwapi!AssocQueryString`,
`Start-Process`) is reached through a provider scriptblock on the request context, so the
dispatch tests stub them on macOS and the same code path runs unmodified on the host.

## Known limitations

* **Prototype transport.** Plain HTTP over TCP, no TLS. Safe because it is loopback-only by
  default; not safe over a LAN (see the warning above).
* **Single-threaded.** One connection at a time, `Connection: close`, no keep-alive. A client
  that connects and then goes silent occupies the agent until the 5 s read timeout expires, and
  one that trickles bytes is cut off by the 15 s absolute per-connection deadline (`408`) — the
  socket timeout alone cannot do that, because every byte received resets it.
* **`Ctrl+C` only.** No service, no autostart, no graceful shutdown endpoint — all deliberate
  non-goals for W7.
* **Icons are whatever the shell gives us.** `ExtractIconEx` (or `ExtractAssociatedIcon`)
  returns a 32×32 icon; there is no high-DPI or 256×256 path yet. Any failure yields
  `"iconPng": null` rather than failing the listing.
* **`tsAllowListDisabled` can be `null`** when the `TSAppAllowList` key or the
  `fDisabledAllowList` value does not exist, which is the normal state on a client SKU that has
  never published a RemoteApp. `published` is then an empty array — expected, not an error.
* **The association lookup answers for the account the agent runs as**, since `AssocQueryString`
  consults `HKCU`. Running it as a different user gives a different answer.
* **`AssocQueryString` does not always answer for a modern handler.** On a Windows 11 25H2 host
  where `.pdf` resolves to Microsoft Edge, it returned `ASSOCSTR_FRIENDLYAPPNAME` but nothing
  for `ASSOCSTR_EXECUTABLE` or `ASSOCSTR_COMMAND`. `EXECUTABLE`/`COMMAND` are verb-sensitive, so
  the agent now passes `open` as the verb and tries a short ladder of `ASSOCF_*` flags; whenever
  neither a program nor a command comes back, it falls through to the registry
  (`HKCU\...\FileExts\<ext>\UserChoice` → `HKCR\<ProgId>\shell\open\command`) and reports
  `"source": "registry"`. A `friendlyName` on its own no longer counts as an answer.
* **Dot-sourcing pollutes the caller's scope.** `. .\MacdowsHostAgent.ps1 -NoServe` sets the
  script's parameter variables (`$Port`, `$BindAddress`, `$AllowlistPath`, `$TokenPath`,
  `$Once`) in your scope, as dot-sourcing always does. Do not name your own variables after
  them in a script that dot-sources the agent.
* **No packaging.** Deliberate non-goal. Copy the three files to the host and run them.
