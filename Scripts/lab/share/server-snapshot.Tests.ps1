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
    # Remove every other alternative from the fixture: the only thing that can select this name
    # is Remote-?Desktop matching "Remote-Desktop".
    $sel = @(Select-SnapshotLogName -Names @('Microsoft-Windows-Remote-Desktop-Management-Service/Admin'))
    Assert-Equal 1 $sel.Count
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

Test-Case 'a tick-based uptime far below the boot-based one names a fast-startup or sleep gap with the three numbers' {
    $r = Get-SnapshotFreshnessConsistency -BootUptimeSeconds 37830 -TickSeconds 5432
    Assert-True ($r.StartsWith('fast-startup-or-sleep-suspected')) "label, got [$r]"
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
    Assert-True ((Get-SnapshotFreshnessConsistency -BootUptimeSeconds 10000 -TickSeconds 9699).StartsWith('fast-startup-or-sleep-suspected'))
}

# -------------------------------------------------------------------------------------------
# Kernel-Boot event 27 BootType (System log; XML EventData, locale-independent)
# -------------------------------------------------------------------------------------------

New-Section 'Get-SnapshotBootTypeFromXml / Format-SnapshotBootType'

Test-Case 'BootType is read from the EventData XML, not from the localised message' {
    $xml = '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><EventID>27</EventID></System><EventData><Data Name="BootType">1</Data><Data Name="LoadOptions"></Data></EventData></Event>'
    Assert-Equal 1 (Get-SnapshotBootTypeFromXml -Xml $xml)
}

Test-Case 'BootType rendered as HexInt32 (0x1, as the manifest renders it -- dry run 3 read unknown for all five events) parses too' {
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
