# Phase 0.5 callback-layer capture samples (2026-08-19)

Capture environment: libfreerdp 3.30.0 (tag, commit 6b107f0aadba), clean build without
H264; server Win11 Pro for Workstations 25H2 (26200.8521), single-session TSAppAllowList
path; probe: rail-probe (callback-layer JSONL, each line carries a monotonic-millisecond
`t_ms` and thread `tid`). Samples were scanned for sensitive fields (no IPs, hostnames,
credentials, or fingerprints).

| File | Scenario |
|---|---|
| s1-baseline.jsonl | HiDef default on, winver, 25s (Enhanced RemoteApp: MapSurfaceToWindow actually issued) |
| s2-nohidef.jsonl | `--no-hidef` (legacy standard path, HandshakeEx flags 126 vs 127) |
| s3-multiapp.jsonl | Second ClientExecute on the same connection (winver→regedit @+8s, both S_OK) |
| s4-badpath.jsonl | Nonexistent program path (execResult=5 / rawResult=2 error semantics) |
| s5a.jsonl / s5b.jsonl | Disconnect→reconnect (server re-sends the full window list, incl. CachedIcon) |

Purpose: replay-assertion baseline for the window-order/surface-binding handlers from
Phase 1 onward; input to the FreeRDP upgrade regression gate.
