#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test suite for server-snapshot.ps1's pure helpers.

.DESCRIPTION
    Runs on macOS under PowerShell 7 (Tier 1 runs it on ubuntu-latest's pwsh) with no external
    dependencies. Self-contained assertion harness, exit code propagated: 0 when every case
    passes, 1 otherwise. Style follows tsallowlist-matrix-verify.Tests.ps1.

    server-snapshot.ps1 is a READ-ONLY host probe: the parts that touch the host (event logs,
    registry, CIM) cannot run here and are not driven here. What IS driven is every decision the
    report depends on -- which log channels count as RDS-related, how keyword hits are counted,
    how the windows_build / host_freshness matrix fields are composed -- as pure functions over
    fixtures, so a wrong verdict line can be caught without spending a live connection.

    Fixture log names are Microsoft's public channel names. No host names, no addresses, nothing
    account-specific appears in this file.

.EXAMPLE
    pwsh -NoProfile -File ./server-snapshot.Tests.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'server-snapshot.ps1') -NoRun

# -------------------------------------------------------------------------------------------
# Assertion harness
# -------------------------------------------------------------------------------------------

$script:TestTotal = 0
$script:TestFailed = 0
$script:TestFailures = New-Object System.Collections.ArrayList

function Test-Case {
    param([string] $Name, [scriptblock] $Body)
    $script:TestTotal++
    try {
        & $Body
        Write-Host "  ok   $Name"
    } catch {
        $script:TestFailed++
        [void]$script:TestFailures.Add("$Name :: $($_.Exception.Message)")
        Write-Host "  FAIL $Name"
        Write-Host "       $($_.Exception.Message)"
    }
}

function Assert-True {
    param($Condition, [string] $Because = 'expected a true condition')
    if (-not $Condition) { throw $Because }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Because = '')
    if ($Expected -ne $Actual) {
        $msg = "expected [$Expected] but got [$Actual]"
        if ($Because) { $msg = "$Because - $msg" }
        throw $msg
    }
}

function New-Section { param([string] $Name) Write-Host ''; Write-Host "== $Name" }

# -------------------------------------------------------------------------------------------
# Pre-registration pins (memo 2026-09-scaledmap-next-step.md sections 3/8, path A)
# -------------------------------------------------------------------------------------------

New-Section 'pre-registered constants'

Test-Case 'the keyword list is the memo''s three (graphics / scal / gfx) plus surface, in that order' {
    $kw = @($script:SnapshotKeywords)
    Assert-Equal 4 $kw.Count 'keyword count'
    Assert-Equal 'graphics' $kw[0]
    Assert-Equal 'scal' $kw[1]
    Assert-Equal 'gfx' $kw[2]
    Assert-Equal 'surface' $kw[3]
}

Test-Case 'the registry key list names the policy hive and the RDP-Tcp winstation, all under HKLM/HKCU' {
    $keys = @($script:SnapshotRegistryKeys)
    Assert-True ($keys.Count -ge 5) "at least five keys, got $($keys.Count)"
    $paths = @($keys | ForEach-Object { $_.Path })
    Assert-True ($paths -contains 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services') 'policy hive present'
    Assert-True ($paths -contains 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp') 'RDP-Tcp winstation present'
    foreach ($p in $paths) {
        Assert-True ($p -match '^HK(LM|CU):\\') "every key is a registry path, got [$p]"
    }
}

Test-Case 'every HKLM key dumps all values; the HKCU Desktop key dumps only its pre-registered DPI/desktop names' {
    foreach ($k in @($script:SnapshotRegistryKeys)) {
        if ($k.Path -like 'HKCU:*') {
            Assert-True (-not $k.AllValues) "HKCU key must not dump every value: $($k.Path)"
            foreach ($n in @('LogPixels', 'Win8DpiScaling', 'DpiScalingVer', 'MaxVirtualDesktopDimension', 'MaxMonitorDimension')) {
                Assert-True (@($k.Names) -contains $n) "HKCU Desktop must pre-register $n"
            }
        } else {
            Assert-True ($k.AllValues) "HKLM key must dump every value: $($k.Path)"
        }
    }
}

# -------------------------------------------------------------------------------------------
# Select-SnapshotLogName
# -------------------------------------------------------------------------------------------

New-Section 'Select-SnapshotLogName'

$fixtureLogs = @(
    'Application',
    'Security',
    'System',
    'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational',
    'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational',
    'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational',
    'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Admin',
    'Microsoft-Windows-RemoteDesktopServices-RemoteFX-Synth3dvsc/Admin',
    'Microsoft-Windows-RemoteApp and Desktop Connections/Admin',
    'Microsoft-Windows-Remote-Desktop-Management-Service/Admin',
    'Microsoft-Windows-Rdp-Graphics-RdpLite/Operational',
    'Microsoft-Windows-Rdp-Graphics-RdpAvenc/Debug',
    'Microsoft-Windows-Wordpad/Admin',
    'Microsoft-Windows-Dwm-Core/Diagnostic',
    'Microsoft-Windows-PowerShell/Operational',
    'Microsoft-Windows-Kernel-Boot/Operational'
)

Test-Case 'keeps every TerminalServices / RemoteDesktop / RemoteFX / RemoteApp / Remote-Desktop channel' {
    $sel = @(Select-SnapshotLogName -Names $fixtureLogs)
    foreach ($want in @(
        'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational',
        'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational',
        'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational',
        'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Admin',
        'Microsoft-Windows-RemoteDesktopServices-RemoteFX-Synth3dvsc/Admin',
        'Microsoft-Windows-RemoteApp and Desktop Connections/Admin',
        'Microsoft-Windows-Remote-Desktop-Management-Service/Admin',
        'Microsoft-Windows-Rdp-Graphics-RdpLite/Operational',
        'Microsoft-Windows-Rdp-Graphics-RdpAvenc/Debug')) {
        Assert-True ($sel -contains $want) "expected [$want] to be selected"
    }
}

Test-Case 'Wordpad is NOT selected: the rdp inside "Wordpad" is not the RDP token (dry run 2 false positive)' {
    $sel = @(Select-SnapshotLogName -Names @('Microsoft-Windows-Wordpad/Admin', 'Microsoft-Windows-Wordpad/Debug', 'x-Wordpad-y'))
    Assert-Equal 0 $sel.Count
}

Test-Case 'the hyphenated RDMS channel is selected by the optional hyphen, not by another token' {
    $name = 'Microsoft-Windows-Remote-Desktop-Management-Service/Admin'
    $sel = @(Select-SnapshotLogName -Names @($name))
    Assert-Equal 1 $sel.Count
    # Pin the claim rather than assert it in a comment (r1): the name matches none of the other
    # alternatives on their own, so Remote-?Desktop is what admitted it.
    Assert-True ($name -notmatch 'TerminalServices|Remote-?App|RemoteFX|Rdms|(^|[-/ ])Rdp([-/ ]|$)|(?-i:Rdp[A-Z])') 'no other alternative matches this name'
}

Test-Case 'the bare tokens RemoteFX, Rdms and RDP select a channel named by them alone' {
    $sel = @(Select-SnapshotLogName -Names @('x-RemoteFX-y', 'x-Rdms-y', 'x-RDP-y', 'x-Remotefax-y'))
    Assert-Equal 3 $sel.Count 'three tokens, and "Remotefax" is not one of them'
    Assert-True ($sel -notcontains 'x-Remotefax-y')
}

Test-Case 'Rdp as a token needs a separator or a CamelCase continuation: RdpCoreTS/RdpLite yes, "xrdpx" and "-rdpfoo-" no' {
    $sel = @(Select-SnapshotLogName -Names @('a-RdpCoreTS/Operational', 'a-RdpLite/Admin', 'xrdpx', 'a-rdpfoo-b'))
    Assert-Equal 2 $sel.Count
    Assert-True ($sel -contains 'a-RdpCoreTS/Operational')
    Assert-True ($sel -contains 'a-RdpLite/Admin')
}

Test-Case 'drops the unrelated channels (Application, Security, System, PowerShell, Kernel-Boot, Dwm)' {
    $sel = @(Select-SnapshotLogName -Names $fixtureLogs)
    foreach ($drop in @('Application', 'Security', 'System',
                        'Microsoft-Windows-PowerShell/Operational',
                        'Microsoft-Windows-Kernel-Boot/Operational',
                        'Microsoft-Windows-Wordpad/Admin',
                        'Microsoft-Windows-Dwm-Core/Diagnostic')) {
        Assert-True ($sel -notcontains $drop) "expected [$drop] to be dropped"
    }
    Assert-Equal 9 $sel.Count 'exactly the nine RDS channels survive'
}

Test-Case 'is case-insensitive and preserves input order' {
    $sel = @(Select-SnapshotLogName -Names @('zzz', 'x-remotedesktopservices-y', 'a-TERMINALSERVICES-b'))
    Assert-Equal 2 $sel.Count
    Assert-Equal 'x-remotedesktopservices-y' $sel[0]
    Assert-Equal 'a-TERMINALSERVICES-b' $sel[1]
}

Test-Case 'an empty or null input yields an empty selection, not a null' {
    $sel = @(Select-SnapshotLogName -Names @())
    Assert-Equal 0 $sel.Count 'empty in, empty out'
    $sel2 = @(Select-SnapshotLogName -Names $null)
    Assert-Equal 0 $sel2.Count 'null in, empty out'
}

# -------------------------------------------------------------------------------------------
# Measure-SnapshotKeywordHit
# -------------------------------------------------------------------------------------------

New-Section 'Measure-SnapshotKeywordHit'

$fixtureMessages = @(
    'Remote Desktop Services: Session logon succeeded.',
    'The Remote Desktop Services graphics pipeline was reset.',      # graphics
    'Display scaling changed for session 2.',                        # scal
    'RDPGFX channel opened; gfx caps confirmed.',                    # gfx
    'Surface 1 mapped to output; GFX surface created.',              # surface + gfx
    $null,
    ''
)

Test-Case 'counts per keyword, case-insensitively, substring match' {
    $h = Measure-SnapshotKeywordHit -Messages $fixtureMessages -Keywords $script:SnapshotKeywords
    Assert-Equal 7 $h.Scanned 'every element counts as scanned, null and empty included'
    Assert-Equal 1 $h.PerKeyword['graphics'] 'graphics'
    Assert-Equal 1 $h.PerKeyword['scal'] 'scal (matches "scaling")'
    Assert-Equal 2 $h.PerKeyword['gfx'] 'gfx (RDPGFX and GFX)'
    Assert-Equal 1 $h.PerKeyword['surface'] 'surface (one message, counted once even with two occurrences)'
}

Test-Case '"Any" counts messages matching at least one keyword, each message once' {
    $h = Measure-SnapshotKeywordHit -Messages $fixtureMessages -Keywords $script:SnapshotKeywords
    Assert-Equal 4 $h.Any 'four distinct messages carry a keyword'
}

Test-Case 'no messages -> scanned 0, every count 0, Any 0' {
    $h = Measure-SnapshotKeywordHit -Messages @() -Keywords $script:SnapshotKeywords
    Assert-Equal 0 $h.Scanned
    Assert-Equal 0 $h.Any
    foreach ($k in $script:SnapshotKeywords) { Assert-Equal 0 $h.PerKeyword[$k] "count for $k" }
}

Test-Case 'a keyword is matched as a literal substring, not as a regex' {
    $h = Measure-SnapshotKeywordHit -Messages @('a.b', 'axb') -Keywords @('a.b')
    Assert-Equal 1 $h.PerKeyword['a.b'] 'the dot must not act as a wildcard'
}

Test-Case 'Format-SnapshotKeywordHitLine renders the counts in keyword order plus any' {
    $h = Measure-SnapshotKeywordHit -Messages $fixtureMessages -Keywords $script:SnapshotKeywords
    $line = Format-SnapshotKeywordHitLine -Hit $h -Keywords $script:SnapshotKeywords
    Assert-Equal 'scanned=7 graphics=1 scal=1 gfx=2 surface=1 any=4' $line
}

Test-Case 'Select-SnapshotScanText scans the rendered Message when there is one and the event XML otherwise (r1 B2: analytic channels carry no message)' {
    Assert-Equal 'rendered text' (Select-SnapshotScanText -Message 'rendered text' -Xml '<Event>x</Event>')
    Assert-Equal '<Event>x</Event>' (Select-SnapshotScanText -Message $null -Xml '<Event>x</Event>')
    Assert-Equal '<Event>x</Event>' (Select-SnapshotScanText -Message '' -Xml '<Event>x</Event>')
    Assert-Equal '' (Select-SnapshotScanText -Message $null -Xml $null)
}

Test-Case 'Format-SnapshotScanLine: a readable channel renders scanned, no_message, per-keyword, any and any3 (memo three only)' {
    # The shared fixture's surface message also says GFX, so any3 would equal any there; add a
    # surface-only message so the two columns must differ (any=5, any3=4).
    $msgs = @($fixtureMessages) + @('Surface-only line, nothing else.')
    $hit = Measure-SnapshotKeywordHit -Messages $msgs -Keywords $script:SnapshotKeywords
    $hit3 = Measure-SnapshotKeywordHit -Messages $msgs -Keywords @($script:SnapshotKeywords[0..2])
    $line = Format-SnapshotScanLine -Readable 'true' -Hit $hit -Hit3 $hit3 -NoMessage 2 -Keywords $script:SnapshotKeywords
    Assert-Equal 'readable=true scanned=8 no_message=2 graphics=1 scal=1 gfx=2 surface=2 any=5 any3=4' $line
}

Test-Case 'Format-SnapshotScanLine: an unreadable channel renders <not-scanned>, never zero counts (r1 test-honesty note)' {
    $hit = Measure-SnapshotKeywordHit -Messages @() -Keywords $script:SnapshotKeywords
    $line = Format-SnapshotScanLine -Readable 'false UnauthorizedAccessException (x)' -Hit $hit -Hit3 $hit -NoMessage 0 -Keywords $script:SnapshotKeywords
    Assert-Equal 'readable=false UnauthorizedAccessException (x) scanned=<not-scanned>' $line
}

# -------------------------------------------------------------------------------------------
# Format-SnapshotWindowsBuild (format.md windows_build: 10.0.<build>.<ubr> | unknown)
# -------------------------------------------------------------------------------------------

New-Section 'Format-SnapshotWindowsBuild'

Test-Case 'composes 10.0.<CurrentBuild>.<UBR> from the CurrentVersion values' {
    Assert-Equal '10.0.26200.6899' (Format-SnapshotWindowsBuild -CurrentBuild '26200' -Ubr 6899)
}

Test-Case 'a missing CurrentBuild or UBR yields the matrix literal unknown' {
    Assert-Equal 'unknown' (Format-SnapshotWindowsBuild -CurrentBuild $null -Ubr 6899) 'no build'
    Assert-Equal 'unknown' (Format-SnapshotWindowsBuild -CurrentBuild '26200' -Ubr $null) 'no ubr'
    Assert-Equal 'unknown' (Format-SnapshotWindowsBuild -CurrentBuild '' -Ubr '') 'both empty'
}

Test-Case 'non-numeric inputs are refused as unknown rather than pasted into the field' {
    Assert-Equal 'unknown' (Format-SnapshotWindowsBuild -CurrentBuild '26200-x' -Ubr 1)
    Assert-Equal 'unknown' (Format-SnapshotWindowsBuild -CurrentBuild '26200' -Ubr 'abc')
}

# -------------------------------------------------------------------------------------------
# Get-SnapshotHostFreshness (format.md host_freshness: rebooted-<N>m-prior | uptime-<N>h | unknown)
# -------------------------------------------------------------------------------------------

New-Section 'Get-SnapshotHostFreshness'

Test-Case 'under one hour of uptime reads rebooted-<N>m-prior with N = whole minutes' {
    Assert-Equal 'rebooted-45m-prior' (Get-SnapshotHostFreshness -UptimeSeconds 2700)
    Assert-Equal 'rebooted-0m-prior' (Get-SnapshotHostFreshness -UptimeSeconds 30)
    Assert-Equal 'rebooted-59m-prior' (Get-SnapshotHostFreshness -UptimeSeconds 3599)
}

Test-Case 'one hour or more reads uptime-<N>h with N = whole hours' {
    Assert-Equal 'uptime-1h' (Get-SnapshotHostFreshness -UptimeSeconds 3600)
    Assert-Equal 'uptime-6h' (Get-SnapshotHostFreshness -UptimeSeconds 23400)
    Assert-Equal 'uptime-49h' (Get-SnapshotHostFreshness -UptimeSeconds 178200)
}

Test-Case 'a negative or null uptime is unknown, never a fabricated label' {
    Assert-Equal 'unknown' (Get-SnapshotHostFreshness -UptimeSeconds -5)
    Assert-Equal 'unknown' (Get-SnapshotHostFreshness -UptimeSeconds $null)
}

# -------------------------------------------------------------------------------------------
# ConvertTo-SnapshotValueText
# -------------------------------------------------------------------------------------------

New-Section 'ConvertTo-SnapshotValueText'

Test-Case 'null renders as <absent>, scalars as their string, string arrays joined with " | "' {
    Assert-Equal '<absent>' (ConvertTo-SnapshotValueText -Value $null)
    Assert-Equal '1' (ConvertTo-SnapshotValueText -Value 1)
    Assert-Equal 'C:\Windows\System32\notepad.exe' (ConvertTo-SnapshotValueText -Value 'C:\Windows\System32\notepad.exe')
    Assert-Equal 'a | b' (ConvertTo-SnapshotValueText -Value @('a', 'b'))
}

Test-Case 'binary values render as a length-prefixed hex string' {
    Assert-Equal 'bytes[3]:01ff10' (ConvertTo-SnapshotValueText -Value ([byte[]]@(1, 255, 16)))
}

Test-Case 'binary values longer than 32 bytes are truncated to the first 32 bytes plus an ellipsis (the length prefix stays exact)' {
    $long = [byte[]](1..100 | ForEach-Object { [byte]($_ % 256) })
    $text = ConvertTo-SnapshotValueText -Value $long
    Assert-True ($text.StartsWith('bytes[100]:')) "prefix, got [$text]"
    Assert-True ($text.EndsWith('...')) 'ellipsis'
    $hex = $text.Substring('bytes[100]:'.Length, $text.Length - 'bytes[100]:'.Length - 3)
    Assert-Equal 64 $hex.Length '32 bytes = 64 hex chars'
    Assert-True ($hex.StartsWith('010203')) 'first bytes'
}

# -------------------------------------------------------------------------------------------
# Get-SnapshotFreshnessConsistency (dry run 2: LastBootUpTime said 10.5 h, TickCount said 1.5 h)
# -------------------------------------------------------------------------------------------

New-Section 'Get-SnapshotFreshnessConsistency'

Test-Case 'boot-based and tick-based uptimes within tolerance are consistent' {
    Assert-Equal 'consistent' (Get-SnapshotFreshnessConsistency -BootUptimeSeconds 37830 -TickSeconds 37700)
}

Test-Case 'a tick-based uptime far below the boot-based one is reported as an unexplained gap with the three numbers -- no mechanism named (r1 B1)' {
    $r = Get-SnapshotFreshnessConsistency -BootUptimeSeconds 37830 -TickSeconds 5432
    Assert-True ($r.StartsWith('boot-tick-gap-unexplained')) "label, got [$r]"
    Assert-True ($r -like '*tick=5432s*') 'tick seconds'
    Assert-True ($r -like '*boot=37830s*') 'boot seconds'
    Assert-True ($r -like '*gap=32398s*') 'gap = boot - tick'
}

Test-Case 'a negative (wrapped) tick or a boot uptime beyond the 32-bit range is not judged' {
    Assert-Equal 'tick-unavailable' (Get-SnapshotFreshnessConsistency -BootUptimeSeconds 37830 -TickSeconds -12)
    Assert-Equal 'tick-unavailable' (Get-SnapshotFreshnessConsistency -BootUptimeSeconds 2200000 -TickSeconds 100)
    Assert-Equal 'tick-unavailable' (Get-SnapshotFreshnessConsistency -BootUptimeSeconds $null -TickSeconds 100)
}

Test-Case 'the tolerance is 300 s: a 299 s gap is consistent, a 301 s gap is not' {
    Assert-Equal 'consistent' (Get-SnapshotFreshnessConsistency -BootUptimeSeconds 10000 -TickSeconds 9701)
    Assert-True ((Get-SnapshotFreshnessConsistency -BootUptimeSeconds 10000 -TickSeconds 9699).StartsWith('boot-tick-gap-unexplained'))
}

# -------------------------------------------------------------------------------------------
# Get-SnapshotEventDataValue (generic EventData datum by name, either quote style)
# -------------------------------------------------------------------------------------------

New-Section 'Get-SnapshotEventDataValue'

Test-Case 'reads a named datum from single- or double-quoted Data elements, null when absent' {
    $xml = "<Event><EventData><Data Name='OldTime'>2026-09-05T09:40:30.000Z</Data><Data Name=""NewTime"">2026-09-05T18:40:30.000Z</Data><Data Name='Reason'>2</Data></EventData></Event>"
    Assert-Equal '2026-09-05T09:40:30.000Z' (Get-SnapshotEventDataValue -Xml $xml -Name 'OldTime')
    Assert-Equal '2026-09-05T18:40:30.000Z' (Get-SnapshotEventDataValue -Xml $xml -Name 'NewTime')
    Assert-Equal '2' (Get-SnapshotEventDataValue -Xml $xml -Name 'Reason')
    Assert-Equal $null (Get-SnapshotEventDataValue -Xml $xml -Name 'Missing')
    Assert-Equal $null (Get-SnapshotEventDataValue -Xml $null -Name 'OldTime')
}

Test-Case 'the datum name is matched exactly, not as a prefix' {
    $xml = "<EventData><Data Name='NewTimeZone'>x</Data><Data Name='NewTime'>y</Data></EventData>"
    Assert-Equal 'y' (Get-SnapshotEventDataValue -Xml $xml -Name 'NewTime')
}

# -------------------------------------------------------------------------------------------
# Measure-SnapshotClockJump (dry run 6: the 9 h came as TWO corrections after boot, +28671 s and
# +3729 s; the newest alone does not explain the gap, their sum does)
# -------------------------------------------------------------------------------------------

New-Section 'Measure-SnapshotClockJump'

$bootStamp = [datetime]::new(2026, 9, 5, 18, 40, 10)
$clockEvents = @(
    [pscustomobject]@{ Time = [datetime]::new(2026, 9, 6, 4, 45, 16); Delta = 0 },
    [pscustomobject]@{ Time = [datetime]::new(2026, 9, 6, 4, 45, 16); Delta = 3729 },
    [pscustomobject]@{ Time = [datetime]::new(2026, 9, 6, 2, 43, 7);  Delta = 28671 },
    [pscustomobject]@{ Time = [datetime]::new(2026, 9, 3, 19, 31, 28); Delta = 0 },
    [pscustomobject]@{ Time = [datetime]::new(2026, 9, 1, 23, 15, 22); Delta = -5000 }
)

Test-Case 'sums the deltas of the corrections stamped at or after the boot stamp only' {
    Assert-Equal 32400 (Measure-SnapshotClockJump -Events $clockEvents -BootTime $bootStamp)
}

Test-Case 'a correction whose delta could not be parsed is skipped, not treated as zero-or-crash' {
    $ev = @([pscustomobject]@{ Time = [datetime]::new(2026, 9, 6, 1, 0, 0); Delta = '<unparsed>' },
            [pscustomobject]@{ Time = [datetime]::new(2026, 9, 6, 2, 0, 0); Delta = 100 })
    Assert-Equal 100 (Measure-SnapshotClockJump -Events $ev -BootTime $bootStamp)
}

Test-Case 'a correction whose TimeCreated is on the set-back clock (before the boot stamp) still counts when its OldTime is after boot (r1 I3)' {
    # Boot stamp 18:40:10; one hour later the clock is set back nine hours: the event is stamped
    # 10:40 (new clock, before boot) but its OldTime 19:40 is after boot.
    $ev = @([pscustomobject]@{ Time = [datetime]::new(2026, 9, 5, 10, 40, 10); Old = [datetime]::new(2026, 9, 5, 19, 40, 10); Delta = -32400 })
    Assert-Equal -32400 (Measure-SnapshotClockJump -Events $ev -BootTime $bootStamp)
    $pre = @([pscustomobject]@{ Time = [datetime]::new(2026, 9, 5, 10, 40, 10); Old = [datetime]::new(2026, 9, 5, 10, 40, 0); Delta = -32400 })
    Assert-Equal $null (Measure-SnapshotClockJump -Events $pre -BootTime $bootStamp) 'both stamps before boot -> not since boot'
}

Test-Case 'no corrections since boot -> null (no jump), not 0' {
    Assert-Equal $null (Measure-SnapshotClockJump -Events @($clockEvents[3], $clockEvents[4]) -BootTime $bootStamp)
    Assert-Equal $null (Measure-SnapshotClockJump -Events @() -BootTime $bootStamp)
    Assert-Equal $null (Measure-SnapshotClockJump -Events $clockEvents -BootTime $null)
}

# -------------------------------------------------------------------------------------------
# Select-SnapshotHostFreshnessLabel (dry run 5: gap of exactly 32400 s = 9 h = the host's UTC
# offset, no sleep events -- a boot-time clock skew corrected later, not a sleep)
# -------------------------------------------------------------------------------------------

New-Section 'Select-SnapshotHostFreshnessLabel'

Test-Case 'consistent boot and tick uptimes -> boot basis, boot-based label' {
    $r = Select-SnapshotHostFreshnessLabel -BootUptimeSeconds 37830 -TickSeconds 37700 -ClockJumpSeconds $null
    Assert-Equal 'boot' $r.Basis
    Assert-Equal 'uptime-10h' $r.Label
    Assert-Equal 'consistent' $r.Reason
}

Test-Case 'a gap matched by a clock jump after boot -> tick basis (the boot stamp was taken on a wrong clock)' {
    $r = Select-SnapshotHostFreshnessLabel -BootUptimeSeconds 38556 -TickSeconds 6156 -ClockJumpSeconds 32399
    Assert-Equal 'tick' $r.Basis
    Assert-Equal 'uptime-1h' $r.Label '6156 s -> uptime-1h'
    Assert-True ($r.Reason.StartsWith('clock-corrected-after-boot')) "reason, got [$($r.Reason)]"
    Assert-True ($r.Reason -like '*jump=32399s*') 'the jump is quoted'
    Assert-True ($r.Reason -like '*gap=32400s*') 'the gap is quoted'
}

Test-Case 'a gap NOT explained by any clock jump -> no basis, label unknown (r1 I3: never a fabricated freshness), reason names the gap' {
    $r = Select-SnapshotHostFreshnessLabel -BootUptimeSeconds 38556 -TickSeconds 6156 -ClockJumpSeconds $null
    Assert-Equal 'none' $r.Basis
    Assert-Equal 'unknown' $r.Label
    Assert-True ($r.Reason.StartsWith('boot-tick-gap-unexplained')) "reason, got [$($r.Reason)]"
    $r2 = Select-SnapshotHostFreshnessLabel -BootUptimeSeconds 38556 -TickSeconds 6156 -ClockJumpSeconds 600
    Assert-Equal 'none' $r2.Basis 'a 600 s jump does not explain a 32400 s gap'
    Assert-Equal 'unknown' $r2.Label
}

Test-Case 'a clock set BACK after boot (tick exceeds boot) with a matching negative jump -> tick basis, label from the tick (r1 I3 scenario: 10 h up, not 1 h)' {
    $r = Select-SnapshotHostFreshnessLabel -BootUptimeSeconds 3600 -TickSeconds 36000 -ClockJumpSeconds -32400
    Assert-Equal 'tick' $r.Basis
    Assert-Equal 'uptime-10h' $r.Label
    $r2 = Select-SnapshotHostFreshnessLabel -BootUptimeSeconds 3600 -TickSeconds 36000 -ClockJumpSeconds $null
    Assert-Equal 'unknown' $r2.Label 'without the jump the 1 h boot reading must NOT be reported as freshness'
}

Test-Case 'tick unavailable -> boot basis, reason tick-unavailable' {
    $r = Select-SnapshotHostFreshnessLabel -BootUptimeSeconds 38556 -TickSeconds -3 -ClockJumpSeconds 32400
    Assert-Equal 'boot' $r.Basis
    Assert-Equal 'tick-unavailable' $r.Reason
}

Test-Case 'the clock jump must match the gap within 300 s WITH its sign: gap = sum of corrections, so a set-back cannot explain a forward gap (r1 I1)' {
    $a = Select-SnapshotHostFreshnessLabel -BootUptimeSeconds 38556 -TickSeconds 6156 -ClockJumpSeconds 32101
    Assert-Equal 'tick' $a.Basis '299 s off still matches'
    $b = Select-SnapshotHostFreshnessLabel -BootUptimeSeconds 38556 -TickSeconds 6156 -ClockJumpSeconds 32099
    Assert-Equal 'none' $b.Basis '301 s off does not'
    $c = Select-SnapshotHostFreshnessLabel -BootUptimeSeconds 38556 -TickSeconds 6156 -ClockJumpSeconds -32400
    Assert-Equal 'none' $c.Basis 'a negative jump of the same magnitude does NOT explain a positive gap'
}

Test-Case 'a jump only counts as an explanation when it is itself larger than the tolerance (r1 I2: 1 s must not explain 301 s)' {
    Assert-Equal 'none' (Select-SnapshotHostFreshnessLabel -BootUptimeSeconds 6457 -TickSeconds 6156 -ClockJumpSeconds 1).Basis 'gap 301, jump 1'
    Assert-Equal 'none' (Select-SnapshotHostFreshnessLabel -BootUptimeSeconds 6756 -TickSeconds 6156 -ClockJumpSeconds 300).Basis 'gap 600, jump 300 (residual 300 but jump not > 300)'
    Assert-Equal 'tick' (Select-SnapshotHostFreshnessLabel -BootUptimeSeconds 6756 -TickSeconds 6156 -ClockJumpSeconds 301).Basis 'gap 600, jump 301'
}

# -------------------------------------------------------------------------------------------
# Kernel-Boot event 27 BootType (System log; XML EventData, locale-independent)
# -------------------------------------------------------------------------------------------

New-Section 'Get-SnapshotBootTypeFromXml / Format-SnapshotBootType'

Test-Case 'BootType is read from the EventData XML, not from the localised message' {
    $xml = '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><EventID>27</EventID></System><EventData><Data Name="BootType">1</Data><Data Name="LoadOptions"></Data></EventData></Event>'
    Assert-Equal 1 (Get-SnapshotBootTypeFromXml -Xml $xml)
}

Test-Case 'the attribute quotes EventRecord.ToXml() actually emits are SINGLE quotes (dry run 4 excerpt: <Data Name=''BootType''>0</Data>)' {
    Assert-Equal 0 (Get-SnapshotBootTypeFromXml -Xml "<EventData><Data Name='BootType'>0</Data><Data Name='LoadOptions'> NOEXECUTE=OPTIN</Data></EventData>")
    Assert-Equal 2 (Get-SnapshotBootTypeFromXml -Xml "<Event><EventData><Data Name='BootType'>2</Data></EventData></Event>")
}

Test-Case 'a hex-rendered BootType (0x1) is accepted as well, although dry run 4 showed the datum is decimal' {
    Assert-Equal 1 (Get-SnapshotBootTypeFromXml -Xml '<EventData><Data Name="BootType">0x1</Data></EventData>')
    Assert-Equal 0 (Get-SnapshotBootTypeFromXml -Xml '<EventData><Data Name="BootType">0x0</Data></EventData>')
    Assert-Equal 2 (Get-SnapshotBootTypeFromXml -Xml '<EventData><Data Name="BootType">0x2</Data></EventData>')
}

Test-Case 'an event without a BootType datum yields null' {
    Assert-Equal $null (Get-SnapshotBootTypeFromXml -Xml '<Event><EventData><Data Name="Other">1</Data></EventData></Event>')
    Assert-Equal $null (Get-SnapshotBootTypeFromXml -Xml $null)
}

Test-Case 'the three documented boot types are named; anything else keeps its number' {
    Assert-Equal 'cold-boot' (Format-SnapshotBootType -BootType 0)
    Assert-Equal 'fast-startup' (Format-SnapshotBootType -BootType 1)
    Assert-Equal 'resume-from-hibernation' (Format-SnapshotBootType -BootType 2)
    Assert-Equal 'unknown(7)' (Format-SnapshotBootType -BootType 7)
    Assert-Equal 'unknown' (Format-SnapshotBootType -BootType $null)
}

# -------------------------------------------------------------------------------------------
# Session history (LocalSessionManager/Operational): id -> name, and a line that carries ONLY the
# UTC time, the id, its name and the SessionID datum -- never the user or the client address
# (both live in those events' messages and are red-line items).
# -------------------------------------------------------------------------------------------

New-Section 'Format-SnapshotSessionEventName / Format-SnapshotSessionEventLine'

Test-Case 'the LSM event ids that matter for same-session reasoning are named; anything else is other' {
    Assert-Equal 'logon' (Format-SnapshotSessionEventName -Id 21)
    Assert-Equal 'shell-start' (Format-SnapshotSessionEventName -Id 22)
    Assert-Equal 'logoff' (Format-SnapshotSessionEventName -Id 23)
    Assert-Equal 'disconnect' (Format-SnapshotSessionEventName -Id 24)
    Assert-Equal 'reconnect' (Format-SnapshotSessionEventName -Id 25)
    Assert-Equal 'other' (Format-SnapshotSessionEventName -Id 41)
    Assert-Equal 'other' (Format-SnapshotSessionEventName -Id $null)
}

Test-Case 'a session-history line is time, id, name and SessionID only' {
    $xml = "<Event><EventData><Data Name='User'>DOMAIN\someone</Data><Data Name='SessionID'>2</Data><Data Name='Address'>203.0.113.7</Data></EventData></Event>"
    $line = Format-SnapshotSessionEventLine -TimeUtc '2026-09-05T21:10:43.0000000Z' -Id 25 -Xml $xml
    Assert-Equal 'lsm: 2026-09-05T21:10:43.0000000Z id=25 (reconnect) session=2' $line
    Assert-True ($line -notlike '*someone*') 'the user must not appear'
    Assert-True ($line -notlike '*203.0.113.7*') 'the address must not appear'
}

Test-Case 'a missing SessionID datum renders as <n/a>; a null time as <no-time>' {
    Assert-Equal 'lsm: <no-time> id=21 (logon) session=<n/a>' (Format-SnapshotSessionEventLine -TimeUtc $null -Id 21 -Xml '<Event/>')
}

# -------------------------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------------------------

Write-Host ''
Write-Host ("{0} test(s), {1} failed" -f $script:TestTotal, $script:TestFailed)
if ($script:TestFailed -gt 0) {
    Write-Host ''
    foreach ($f in $script:TestFailures) { Write-Host "  - $f" }
    exit 1
}
exit 0
