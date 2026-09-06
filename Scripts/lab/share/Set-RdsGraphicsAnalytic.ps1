<#
  Set-RdsGraphicsAnalytic.ps1 -- OWNER-MANUAL, run from an ELEVATED console on the test host.
  Path A-prime of docs/upgrade-gate/2026-09-scaledmap-next-step.md (owner ruling 2026-09-06
  08:21 「可以」): the A+E snapshot found the three RDS graphics Debug/Analytic channels present
  but disabled; this script turns them ON for ONE capture and turns them back to exactly what
  they were. Nothing here is run by the lab relay: changing channel configuration needs an
  administrator token, and the standard lab account cannot.

    .\Set-RdsGraphicsAnalytic.ps1 -Mode Status  [-BackupDir C:\macdows-analytic]
    .\Set-RdsGraphicsAnalytic.ps1 -Mode Enable  [-BackupDir C:\macdows-analytic]
    .\Set-RdsGraphicsAnalytic.ps1 -Mode Restore [-BackupDir C:\macdows-analytic]

  Discipline (same as Set-TsAllowListMatrix.ps1): Enable first records the CURRENT enabled state
  of the three channels in $BackupDir and REFUSES when such a record already exists (a second
  Enable would overwrite the pristine record with "all on" and Restore would then restore to
  enabled -- run Restore first). Restore refuses without a record: it never guesses "off".
  Status writes nothing. Every mode ends with a READBACK line of what the host actually reports.

  Windows PowerShell 5.1 clean (no ??, no ternary). The channel objects come from
  System.Diagnostics.Eventing.Reader.EventLogConfiguration; SaveChanges() is the write.

  -NoRun defines the functions only (Set-RdsGraphicsAnalytic.Tests.ps1 dot-sources them on macOS).
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Enable', 'Restore')][string] $Mode = 'Status',
    [string] $BackupDir = 'C:\macdows-analytic',
    [switch] $NoRun
)

$ErrorActionPreference = 'Stop'

# The three channels the A+E snapshot listed as enabled=False type=Debug (record section 3.4).
$script:AnalyticChannels = @(
    'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Debug',
    'Microsoft-Windows-Rdp-Graphics-RdpLite/Debug',
    'Microsoft-Windows-Rdp-Graphics-RdpAvenc/Debug'
)
$script:BackupFileName = 'rds-graphics-analytic.backup.txt'

# ---------------------------------------------------------------------------------------------
# Pure decision logic (exercised off-Windows by the test suite)
# ---------------------------------------------------------------------------------------------

function Get-AnalyticPlan {
    <#
      What a mode must do against the current channel states and whether a backup exists.
        Verdict      proceed | refuse (Reason says why and what to run instead)
        WriteBackup  Enable only, when no backup exists; BackupState = the CURRENT states
        SetEnabled   hashtable channel -> desired IsEnabled (Enable: all true; Restore: the backup)
        RemoveBackup Restore only, after the states are written back
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Status', 'Enable', 'Restore')][string] $Mode,
        [hashtable] $Current,
        [bool] $BackupExists,
        [hashtable] $Backup = @{}
    )
    $plan = [pscustomobject]@{
        Verdict = 'proceed'; Reason = ''; WriteBackup = $false; BackupState = @{}
        SetEnabled = @{}; RemoveBackup = $false
    }
    switch ($Mode) {
        'Status' { return $plan }
        'Enable' {
            foreach ($c in $script:AnalyticChannels) {
                if (-not $Current.ContainsKey($c)) {
                    $plan.Verdict = 'refuse'
                    $plan.Reason = "the current state is missing channel $c -- an unreadable channel is never treated as off; fix the read first"
                    return $plan
                }
            }
            if ($BackupExists) {
                $plan.Verdict = 'refuse'
                $plan.Reason = 'a backup of the pre-lab channel state already exists; run -Mode Restore first (a second Enable would overwrite the pristine record with the enabled state)'
                return $plan
            }
            $plan.WriteBackup = $true
            $bs = @{}
            foreach ($c in $script:AnalyticChannels) { $bs[$c] = [bool]$Current[$c] }
            $plan.BackupState = $bs
            $se = @{}
            foreach ($c in $script:AnalyticChannels) { $se[$c] = $true }
            $plan.SetEnabled = $se
            return $plan
        }
        'Restore' {
            if (-not $BackupExists) {
                $plan.Verdict = 'refuse'
                $plan.Reason = 'no backup of the pre-lab channel state exists; nothing to restore to and this script never guesses "off"'
                return $plan
            }
            $se = @{}
            foreach ($c in $script:AnalyticChannels) { $se[$c] = [bool]$Backup[$c] }
            $plan.SetEnabled = $se
            $plan.RemoveBackup = $true
            return $plan
        }
    }
    return $plan
}

function ConvertTo-AnalyticBackupText {
    <# One `channel=True|False` line per channel, in list order; nothing else. #>
    [CmdletBinding()]
    param([hashtable] $State)
    $lines = New-Object System.Collections.ArrayList
    foreach ($c in $script:AnalyticChannels) { [void]$lines.Add($c + '=' + ([bool]$State[$c]).ToString()) }
    return ($lines.ToArray() -join "`r`n")
}

function ConvertFrom-AnalyticBackupText {
    <# The inverse; throws when any channel is missing so a partial record is never treated as "off". #>
    [CmdletBinding()]
    param([string] $Text)
    $state = @{}
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line.Length -eq 0) { continue }
        $eq = $line.LastIndexOf('=')
        if ($eq -lt 1) { throw "unreadable backup line: $line" }
        $name = $line.Substring(0, $eq)
        $val = $line.Substring($eq + 1)
        if ($val -eq 'True') { $state[$name] = $true } elseif ($val -eq 'False') { $state[$name] = $false } else { throw "unreadable backup value: $line" }
    }
    foreach ($c in $script:AnalyticChannels) {
        if (-not $state.ContainsKey($c)) { throw "backup is missing channel $c -- refusing to restore from a partial record" }
    }
    return $state
}

function Format-AnalyticReadback {
    <# READBACK: <short>=<state> ... -- short = the channel's last two path segments. #>
    [CmdletBinding()]
    param([hashtable] $State)
    $parts = New-Object System.Collections.ArrayList
    foreach ($c in $script:AnalyticChannels) {
        $short = ($c -replace '^Microsoft-Windows-(RemoteDesktopServices-|Rdp-Graphics-)', '')
        [void]$parts.Add($short + '=' + ([bool]$State[$c]).ToString())
    }
    return 'READBACK: ' + ($parts.ToArray() -join ' ')
}

function Format-AnalyticBackupRecordLine {
    <# The script's trailing line: where the pre-lab record is NOW. Decided from the record's
       existence AFTER the action -- A-prime r1 (2026-09-07) printed "restored; backup record
       removed (...)" followed by "backup record: <the same path>" because the line was decided
       from the pre-action check; Restore had just deleted the file it named. #>
    [CmdletBinding()]
    param([bool] $Exists, [string] $Path)
    if ($Exists) { return "backup record: $Path" }
    return 'backup record: none'
}

# ---------------------------------------------------------------------------------------------
# Host side (Windows only; never reached under -NoRun)
# ---------------------------------------------------------------------------------------------

function Get-AnalyticCurrentState {
    [CmdletBinding()]
    param()
    $state = @{}
    foreach ($c in $script:AnalyticChannels) {
        $cfg = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($c)
        $state[$c] = [bool]$cfg.IsEnabled
    }
    return $state
}

function Set-AnalyticState {
    [CmdletBinding()]
    param([hashtable] $Desired)
    foreach ($c in $script:AnalyticChannels) {
        $cfg = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($c)
        if ([bool]$cfg.IsEnabled -ne [bool]$Desired[$c]) {
            try {
                $cfg.IsEnabled = [bool]$Desired[$c]
                $cfg.SaveChanges()
            } catch {
                # Operator-facing (gate m3): say which channel failed and that the backup record is
                # untouched, so re-running the SAME mode converges (each channel is judged on its own).
                throw ("SaveChanges failed on {0} (wanted IsEnabled={1}): {2}. The backup record is untouched; " +
                       "fix the cause and re-run -Mode {3} -- channels already at their target are skipped.") -f $c, $Desired[$c], $_.Exception.Message, $Mode
            }
            Write-Host ("set {0} IsEnabled={1}" -f $c, $Desired[$c])
        } else {
            Write-Host ("{0} already IsEnabled={1}" -f $c, $Desired[$c])
        }
    }
}

if (-not $NoRun) {
    $pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($Mode -ne 'Status' -and -not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Not elevated. Re-run this script from an elevated console -- channel configuration is an administrator write.'
    }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $backupPath = Join-Path $BackupDir $script:BackupFileName
    $backupExists = Test-Path -LiteralPath $backupPath
    $current = Get-AnalyticCurrentState
    $backup = @{}
    if ($backupExists) { $backup = ConvertFrom-AnalyticBackupText -Text ([IO.File]::ReadAllText($backupPath)) }

    $plan = Get-AnalyticPlan -Mode $Mode -Current $current -BackupExists $backupExists -Backup $backup
    if ($plan.Verdict -eq 'refuse') { throw ("REFUSING -Mode {0}: {1}" -f $Mode, $plan.Reason) }

    if ($plan.WriteBackup) {
        [IO.File]::WriteAllText($backupPath, (ConvertTo-AnalyticBackupText -State $plan.BackupState))
        Write-Host "backed up pre-lab channel state -> $backupPath"
    }
    if (@($plan.SetEnabled.Keys).Count -gt 0) { Set-AnalyticState -Desired $plan.SetEnabled }
    if ($plan.RemoveBackup) {
        Remove-Item -LiteralPath $backupPath -Force
        Write-Host "restored; backup record removed ($backupPath)"
    }
    # Read back what the host now actually reports -- never trust the write, verify it.
    Write-Host (Format-AnalyticReadback -State (Get-AnalyticCurrentState))
    # The Test-Path here MUST stay after the Enable/Restore actions above and MUST NOT be replaced by
    # the pre-action $backupExists: this line is inside the -NoRun-gated host block, so the pwsh
    # suite cannot catch that regression (analytic-tail-gate m1) -- only the operator's eyes can.
    Write-Host (Format-AnalyticBackupRecordLine -Exists (Test-Path -LiteralPath $backupPath) -Path $backupPath)
}
