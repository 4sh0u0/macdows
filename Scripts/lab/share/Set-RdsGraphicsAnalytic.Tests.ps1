#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test suite for Set-RdsGraphicsAnalytic.ps1's decision logic (A-prime: enable the three RDS
    graphics Debug/Analytic channels for one capture, then restore).

.DESCRIPTION
    Runs on macOS under PowerShell 7 (Tier 1 runs it on ubuntu-latest's pwsh); dependency-free.
    The shipped script is OWNER-MANUAL and elevated (it writes event-log channel configuration),
    so nothing here touches Windows: the suite drives the pure decision functions with fixtures --
    which channels, what Enable/Restore/Status must do against a given (current state, backup
    present) pair, and how the readback line is rendered -- exactly the cells where an elevated
    write could destroy the record of the host's prior configuration. Style follows
    tsallowlist-matrix-verify.Tests.ps1 (Test-Case harness, exit code propagated).

.EXAMPLE
    pwsh -NoProfile -File ./Set-RdsGraphicsAnalytic.Tests.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Set-RdsGraphicsAnalytic.ps1') -NoRun

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
function Assert-True { param($Condition, [string] $Because = 'expected a true condition'); if (-not $Condition) { throw $Because } }
function Assert-Equal {
    param($Expected, $Actual, [string] $Because = '')
    if ($Expected -ne $Actual) { $msg = "expected [$Expected] but got [$Actual]"; if ($Because) { $msg = "$Because - $msg" }; throw $msg }
}
function New-Section { param([string] $Name) Write-Host ''; Write-Host "== $Name" }

New-Section 'channel list (A+E record section 3.4: the three disabled Debug/Analytic channels)'

Test-Case 'exactly the three RDS graphics Debug channels, in a fixed order' {
    $c = @($script:AnalyticChannels)
    Assert-Equal 3 $c.Count
    Assert-Equal 'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Debug' $c[0]
    Assert-Equal 'Microsoft-Windows-Rdp-Graphics-RdpLite/Debug' $c[1]
    Assert-Equal 'Microsoft-Windows-Rdp-Graphics-RdpAvenc/Debug' $c[2]
}

New-Section 'Get-AnalyticPlan -- what each mode does against (current state, backup present)'

$allOff = @{ 'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Debug' = $false; 'Microsoft-Windows-Rdp-Graphics-RdpLite/Debug' = $false; 'Microsoft-Windows-Rdp-Graphics-RdpAvenc/Debug' = $false }
$allOn  = @{ 'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Debug' = $true;  'Microsoft-Windows-Rdp-Graphics-RdpLite/Debug' = $true;  'Microsoft-Windows-Rdp-Graphics-RdpAvenc/Debug' = $true }

Test-Case 'Enable on a pristine host (all off, no backup): back up, then enable all three' {
    $p = Get-AnalyticPlan -Mode Enable -Current $allOff -BackupExists $false
    Assert-Equal 'proceed' $p.Verdict
    Assert-True $p.WriteBackup 'a backup of the current state must be written first'
    Assert-Equal 3 @($p.SetEnabled.Keys).Count
    foreach ($k in $p.SetEnabled.Keys) { Assert-Equal $true $p.SetEnabled[$k] "$k -> enabled" }
}

Test-Case 'Enable REFUSES when a backup already exists (clobber guard: Restore first)' {
    $p = Get-AnalyticPlan -Mode Enable -Current $allOff -BackupExists $true
    Assert-Equal 'refuse' $p.Verdict
    Assert-True ($p.Reason -like '*Restore*') "the refusal must point at Restore, got [$($p.Reason)]"
    Assert-True (-not $p.WriteBackup)
    Assert-Equal 0 @($p.SetEnabled.Keys).Count
}

Test-Case 'Enable on a host where a channel is ALREADY on and no backup exists still backs up the true prior state (that channel stays on after Restore)' {
    $mixed = @{ 'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Debug' = $true; 'Microsoft-Windows-Rdp-Graphics-RdpLite/Debug' = $false; 'Microsoft-Windows-Rdp-Graphics-RdpAvenc/Debug' = $false }
    $p = Get-AnalyticPlan -Mode Enable -Current $mixed -BackupExists $false
    Assert-Equal 'proceed' $p.Verdict
    Assert-True $p.WriteBackup
    Assert-Equal $true $p.BackupState['Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Debug'] 'the backup records the pre-existing ON'
    Assert-Equal $false $p.BackupState['Microsoft-Windows-Rdp-Graphics-RdpLite/Debug']
}

Test-Case 'Restore with a backup: set each channel back to its backed-up state, then remove the backup' {
    $bak = @{ 'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Debug' = $true; 'Microsoft-Windows-Rdp-Graphics-RdpLite/Debug' = $false; 'Microsoft-Windows-Rdp-Graphics-RdpAvenc/Debug' = $false }
    $p = Get-AnalyticPlan -Mode Restore -Current $allOn -BackupExists $true -Backup $bak
    Assert-Equal 'proceed' $p.Verdict
    Assert-Equal $true  $p.SetEnabled['Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Debug'] 'was on before -> stays on'
    Assert-Equal $false $p.SetEnabled['Microsoft-Windows-Rdp-Graphics-RdpLite/Debug']
    Assert-Equal $false $p.SetEnabled['Microsoft-Windows-Rdp-Graphics-RdpAvenc/Debug']
    Assert-True $p.RemoveBackup
}

Test-Case 'Restore without a backup REFUSES (nothing to restore to -- never guess "off")' {
    $p = Get-AnalyticPlan -Mode Restore -Current $allOn -BackupExists $false
    Assert-Equal 'refuse' $p.Verdict
    Assert-Equal 0 @($p.SetEnabled.Keys).Count
    Assert-True (-not $p.RemoveBackup)
}

Test-Case 'Status never writes anything' {
    foreach ($b in @($true, $false)) {
        $p = Get-AnalyticPlan -Mode Status -Current $allOn -BackupExists $b
        Assert-Equal 'proceed' $p.Verdict
        Assert-True (-not $p.WriteBackup); Assert-True (-not $p.RemoveBackup)
        Assert-Equal 0 @($p.SetEnabled.Keys).Count
    }
}

New-Section 'ConvertTo-AnalyticBackupText / ConvertFrom-AnalyticBackupText (round trip, no host data)'

Test-Case 'the backup text round-trips the three states and nothing else' {
    $txt = ConvertTo-AnalyticBackupText -State $allOn
    Assert-True ($txt -notmatch 'COMPUTERNAME|USERNAME') 'no host identity in the backup'
    $back = ConvertFrom-AnalyticBackupText -Text $txt
    Assert-Equal 3 @($back.Keys).Count
    foreach ($k in $script:AnalyticChannels) { Assert-Equal $true $back[$k] "$k" }
    $txt2 = ConvertTo-AnalyticBackupText -State $allOff
    $back2 = ConvertFrom-AnalyticBackupText -Text $txt2
    foreach ($k in $script:AnalyticChannels) { Assert-Equal $false $back2[$k] "$k off" }
}

Test-Case 'a backup text missing a channel is rejected, never defaulted' {
    $threw = $false
    try { ConvertFrom-AnalyticBackupText -Text "Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Debug=True" | Out-Null } catch { $threw = $true }
    Assert-True $threw 'partial backup must throw'
}

New-Section 'Format-AnalyticReadback'

Test-Case 'the readback line lists each channel with its enabled state, in order' {
    $line = Format-AnalyticReadback -State $allOff
    Assert-Equal 'READBACK: RdpCoreTS/Debug=False RdpLite/Debug=False RdpAvenc/Debug=False' $line
}

Write-Host ''
Write-Host ("{0} test(s), {1} failed" -f $script:TestTotal, $script:TestFailed)
if ($script:TestFailed -gt 0) { Write-Host ''; foreach ($f in $script:TestFailures) { Write-Host "  - $f" }; exit 1 }
exit 0
