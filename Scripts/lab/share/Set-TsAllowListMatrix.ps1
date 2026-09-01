<#
  Set-TsAllowListMatrix.ps1 -- OWNER-MANUAL, run ONCE from an ELEVATED console on the
  test host. Puts the host into TSAppAllowList *enforced* mode with the lab's own
  RemoteApp programs published, and puts it back again. Nothing here is run by the lab
  relay: every write below is HKLM and needs an administrator token.

    .\Set-TsAllowListMatrix.ps1 -Mode Enforce  -BackupDir C:\macdows-matrix [-ArmRestoreIn 4]
    .\Set-TsAllowListMatrix.ps1 -Mode Restore  -BackupDir C:\macdows-matrix

  -ArmRestoreIn <hours> also registers a SYSTEM scheduled task that runs -Mode Restore
  at that offset: a dead-man switch, so a lab lockout self-heals without console access.

  Enforce REFUSES to run when backing up would destroy the record of the host's real
  prior configuration -- there are two such records and both are protected:
    * already enforced AND a $Backup or $Marker exists  -> run -Mode Restore first;
    * key absent AND a $Backup from an earlier run exists -> finish the Restore first.
  See the clobber guards in Backup-State; each refusal names the files at risk.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Enforce','Restore')][string] $Mode,
    [string] $BackupDir = 'C:\macdows-matrix',
    [int] $ArmRestoreIn = 0
)

$ErrorActionPreference = 'Stop'
$TsKey    = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList'
$TsKeyPS  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList'
$PolKeyPS = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$Backup   = Join-Path $BackupDir 'TSAppAllowList.backup.reg'
$Marker   = Join-Path $BackupDir 'key-was-absent.marker'
$PolBak   = Join-Path $BackupDir 'policy-fAllowUnlisted.txt'
# This script's own path, for the paste-able commands in the refusal messages below.
# $PSCommandPath is exact, where '.\Set-TsAllowListMatrix.ps1' only resolves from the right
# working directory; the fallback covers being pasted into a console rather than run as a file.
# NB deliberately NOT named $self -- PowerShell variables are case-insensitive and the
# -ArmRestoreIn arm already uses $self for the same value later on.
$ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { 'Set-TsAllowListMatrix.ps1' }

$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Not elevated. Re-run this script from an elevated console -- every write below is HKLM.'
}
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

# The four programs the lab launches over RAIL. charmap.exe is deliberately ABSENT:
# it is the negative control that must come back RAIL_EXEC_E_NOT_IN_ALLOWLIST (0x0003).
# Key name == Name == the "||alias" the client sends; CommandLineSetting 1 = any command
# line allowed (powershell and notepad are both launched WITH arguments by the lab).
$Publish = @(
    @{ Key = 'winver';     Path = '%SystemRoot%\System32\winver.exe';                          Cls = 0 }
    @{ Key = 'logoff';     Path = '%SystemRoot%\System32\logoff.exe';                          Cls = 0 }
    @{ Key = 'notepad';    Path = '%SystemRoot%\System32\notepad.exe';                         Cls = 1 }
    @{ Key = 'powershell'; Path = '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'; Cls = 1 }
)

function Backup-State {
    if (Test-Path -LiteralPath $TsKeyPS) {
        # CLOBBER GUARD -- first thing in this branch, before anything is written.
        # reg export below runs with /y, so a second plain Enforce on an already-enforced
        # host would overwrite the pristine pre-enforce snapshot with enforced state, and
        # the later Restore would then "restore" the host to enforced -- silently, with the
        # only record of the real prior configuration gone. Nearly happened between runs
        # 1-3 on 2026-09-01; manual "Restore first" discipline is not an invariant.
        #
        # The live registry is the ground truth, deliberately in preference to a marker file
        # that could drift (a run that died after writing the marker but before changing
        # state would lie). [string] rather than [int]: $ErrorActionPreference is Stop, so
        # casting a hand-edited non-numeric REG_SZ would throw instead of reaching the
        # comparison; DWord 0, REG_SZ '0' and a single-zero-byte REG_BINARY all give '0',
        # and over-triggering on the odd hive is the fail-safe direction.
        #
        # BOTH pristine records count, not just $Backup. This function keeps two mutually
        # exclusive records of the pre-lab state -- $Backup ("the key existed, here it is")
        # and $Marker ("the key did NOT exist"), which Restore-State reads as authoritative.
        # Testing only $Backup left the whole key-absent population exposed to the very
        # double-Enforce this guard exists to stop: Enforce #1 writes the marker, Enforce #2
        # finds fd=0 with no backup, sails past the guard, deletes the marker and exports a
        # backup OF ENFORCED STATE -- after which Restore puts the host back to enforced and
        # the true prior configuration is gone. Found in review, 2026-09-01.
        #
        # Refuse ONLY where something pristine would actually be destroyed. A first-ever run
        # against a host somebody else left enforced (no backup, no marker) still proceeds,
        # and so does the normal Restore -> Enforce cycle on either path: after Restore the
        # key is either back to its snapshot value (fd=1, guard not armed) or absent again
        # (this branch not even entered).
        $cur = Get-ItemProperty -LiteralPath $TsKeyPS -ErrorAction SilentlyContinue
        $alreadyEnforced = $cur -and
            ($cur.PSObject.Properties.Name -contains 'fDisabledAllowList') -and
            ([string]$cur.fDisabledAllowList -eq '0')
        $pristineExists = (Test-Path -LiteralPath $Backup) -or (Test-Path -LiteralPath $Marker)
        if ($alreadyEnforced -and $pristineExists) {
            $records = @()
            if (Test-Path -LiteralPath $Backup) { $records += $Backup }
            if (Test-Path -LiteralPath $Marker) { $records += $Marker }
            # Is the surviving backup ITSELF a snapshot of enforced state? If it is, telling
            # the operator to restore first sends them round in a circle -- Restore would
            # re-import enforced state and land right back on this refusal. That is the
            # accepted deadlock population (a host enforced before the lab ever ran); the
            # guard's posture is right for them, the instructions were not. reg.exe exports
            # UTF-16LE with a BOM and Get-Content honours it; an unreadable backup counts as
            # "unknown", so the message degrades to the generic advice and the refusal itself
            # never depends on this read.
            $bakEnforced = $false
            if (Test-Path -LiteralPath $Backup) {
                try {
                    $bakEnforced = ((Get-Content -LiteralPath $Backup -Raw -ErrorAction Stop) `
                        -match '"fDisabledAllowList"\s*=\s*dword:00000000')
                } catch {
                    $bakEnforced = $false
                }
            }
            $msg = "REFUSING to back up: TSAppAllowList is ALREADY enforced " +
                   "(fDisabledAllowList=0), and exporting now would destroy the record of " +
                   "this host's real prior configuration: " + ($records -join ', ') + ".`n"
            if ($bakEnforced) {
                $msg += "That backup ALREADY records fDisabledAllowList=0 -- it is a snapshot " +
                        "of ENFORCED state, not of the pre-lab host, so -Mode Restore will NOT " +
                        "clear this refusal: it would re-import enforced state and land you " +
                        "straight back here. There is nothing pristine left to protect on this " +
                        "host, so re-baseline deliberately -- delete " +
                        ($records -join ' and ') + " by hand, then re-run Enforce."
            } else {
                $msg += "Do this instead -- restore first, then enforce again:`n" +
                        "    & '$ScriptPath' -Mode Restore -BackupDir '$BackupDir'`n" +
                        "    & '$ScriptPath' -Mode Enforce -BackupDir '$BackupDir'`n" +
                        "If you really do mean to re-baseline against the CURRENT (enforced) " +
                        "state, delete " + ($records -join ' and ') + " by hand first. That is " +
                        "the only way past this guard, on purpose: it has to be a deliberate " +
                        "act, not a flag."
            }
            throw $msg
        }
        Remove-Item -Force -ErrorAction SilentlyContinue $Marker
        & reg.exe export $TsKey $Backup /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg export failed ($LASTEXITCODE)" }
        Write-Host "backed up $TsKey -> $Backup"
    } else {
        # Same clobber class as the guard above, pointing the other way. The key is gone but a
        # backup from an earlier run is still on disk -- most credibly a Restore that deleted
        # the key (Restore-State does that first) and then threw on a failed reg import, after
        # which the operator re-ran Enforce instead of Restore. Deleting that backup and
        # writing "the key never existed" would replace a true record of the prior
        # configuration with a false one, and Restore would afterwards leave the key absent
        # forever. Refuse: finish the restore, or re-baseline by hand.
        if (Test-Path -LiteralPath $Backup) {
            throw ("REFUSING to record TSAppAllowList as absent: the key is gone, but a backup " +
                   "from an earlier run still exists at $Backup. Writing the 'key was absent' " +
                   "marker would delete that backup and replace a true record of this host's " +
                   "prior configuration with a false one.`n" +
                   "Finish the restore first:`n" +
                   "    & '$ScriptPath' -Mode Restore -BackupDir '$BackupDir'`n" +
                   "or, if this host genuinely never had a TSAppAllowList key and the backup is " +
                   "stale, delete $Backup by hand and re-run Enforce.")
        }
        # Provably a no-op after the refusal above; kept so this branch still cannot leave a
        # stale backup sitting next to a fresh marker if that guard is ever narrowed.
        Remove-Item -Force -ErrorAction SilentlyContinue $Backup
        Set-Content -LiteralPath $Marker -Value 'TSAppAllowList did not exist before this run'
        Write-Host "TSAppAllowList absent before this run -- recorded in $Marker"
    }
    $pol = '<absent>'
    if (Test-Path -LiteralPath $PolKeyPS) {
        $p = Get-ItemProperty -LiteralPath $PolKeyPS -ErrorAction SilentlyContinue
        if ($p -and ($p.PSObject.Properties.Name -contains 'fAllowUnlistedRemotePrograms')) {
            $pol = [string]$p.fAllowUnlistedRemotePrograms
        }
    }
    Set-Content -LiteralPath $PolBak -Value $pol
    Write-Host "policy fAllowUnlistedRemotePrograms was: $pol (recorded in $PolBak)"
}

function Set-Enforced {
    New-Item -Path $TsKeyPS -Force | Out-Null
    New-Item -Path (Join-Path $TsKeyPS 'Applications') -Force | Out-Null
    foreach ($a in $Publish) {
        $k = Join-Path $TsKeyPS ('Applications\' + $a.Key)
        New-Item -Path $k -Force | Out-Null
        # Path/VPath/IconPath must be written PRE-EXPANDED: these are REG_SZ values and
        # termsrv uses them literally -- measured 2026-09-01 on the live host: an
        # unexpanded '%SystemRoot%\...' entry fails path comparison for full-path
        # launches (RAIL_EXEC_E_NOT_IN_ALLOWLIST) and fails the launch itself for
        # ||alias launches (RAIL_EXEC_E_FILE_NOT_FOUND). Real-world publishers write
        # literal paths for the same reason. The verify half normalizes both forms,
        # so it is unaffected either way.
        $xp = [Environment]::ExpandEnvironmentVariables($a.Path)
        New-ItemProperty -LiteralPath $k -Name 'Name'               -Value $a.Key  -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $k -Name 'Path'               -Value $xp -PropertyType String -Force | Out-Null
        # VPath mirrors Path. Publishers in the wild (remoteapptool, RemoteApplicationPublisher)
        # always write both, and it is not established which one termsrv matches against --
        # setting both removes that as a source of a false negative on the positive control.
        New-ItemProperty -LiteralPath $k -Name 'VPath'              -Value $xp -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $k -Name 'CommandLineSetting' -Value $a.Cls  -PropertyType DWord  -Force | Out-Null
        New-ItemProperty -LiteralPath $k -Name 'RequiredCommandLine' -Value ''     -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $k -Name 'ShowInTSWA'         -Value 1       -PropertyType DWord  -Force | Out-Null
        New-ItemProperty -LiteralPath $k -Name 'IconPath'           -Value $xp -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $k -Name 'IconIndex'          -Value 0       -PropertyType DWord  -Force | Out-Null
        Write-Host "published ||$($a.Key) -> $xp (CommandLineSetting=$($a.Cls))"
    }
    # 0 = the allow list IS checked and enforced. This is the whole point of the matrix.
    New-ItemProperty -LiteralPath $TsKeyPS -Name 'fDisabledAllowList' -Value 0 -PropertyType DWord -Force | Out-Null
    # The policy twin would re-open the door if it is 1 -- close it too, having saved it.
    if (Test-Path -LiteralPath $PolKeyPS) {
        New-ItemProperty -LiteralPath $PolKeyPS -Name 'fAllowUnlistedRemotePrograms' -Value 0 -PropertyType DWord -Force | Out-Null
    }
    Write-Host 'fDisabledAllowList=0, fAllowUnlistedRemotePrograms=0 -- allow list ENFORCED.'
}

function Restore-State {
    # reg import is additive: it never deletes keys created after the export. Blow the
    # whole subtree away first, then re-import the snapshot (or leave it absent).
    if (Test-Path -LiteralPath $TsKeyPS) { & reg.exe delete $TsKey /f | Out-Null }
    if (Test-Path -LiteralPath $Backup) {
        & reg.exe import $Backup | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg import failed ($LASTEXITCODE)" }
        Write-Host "restored $TsKey from $Backup"
    } elseif (Test-Path -LiteralPath $Marker) {
        Write-Host "$TsKey left absent, as it was before the matrix run"
    } else {
        throw "neither $Backup nor $Marker exists -- refusing to guess the prior state"
    }
    if (Test-Path -LiteralPath $PolBak) {
        $pol = (Get-Content -LiteralPath $PolBak -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($null -eq $pol -or $pol -eq '<absent>') {
            if (Test-Path -LiteralPath $PolKeyPS) {
                Remove-ItemProperty -LiteralPath $PolKeyPS -Name 'fAllowUnlistedRemotePrograms' -ErrorAction SilentlyContinue
            }
            Write-Host 'policy fAllowUnlistedRemotePrograms removed (was absent before)'
        } else {
            New-Item -Path $PolKeyPS -Force | Out-Null
            New-ItemProperty -LiteralPath $PolKeyPS -Name 'fAllowUnlistedRemotePrograms' `
                -Value ([int]$pol) -PropertyType DWord -Force | Out-Null
            Write-Host "policy fAllowUnlistedRemotePrograms restored to $pol"
        }
    }
    Unregister-ScheduledTask -TaskName 'MacdowsMatrixRestore' -Confirm:$false -ErrorAction SilentlyContinue
}

switch ($Mode) {
    'Enforce' {
        Backup-State
        Set-Enforced
        if ($ArmRestoreIn -gt 0) {
            $self = $MyInvocation.MyCommand.Path
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"$self`" -Mode Restore -BackupDir `"$BackupDir`"")
            $trg = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddHours($ArmRestoreIn))
            Register-ScheduledTask -TaskName 'MacdowsMatrixRestore' -Action $act -Trigger $trg `
                -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
            Write-Host "dead-man switch armed: MacdowsMatrixRestore fires in $ArmRestoreIn h"
        }
    }
    'Restore' { Restore-State }
}

# Read back what the host now actually reports -- never trust the write, verify it.
$p = Get-ItemProperty -LiteralPath $TsKeyPS -ErrorAction SilentlyContinue
$fd = if ($p -and ($p.PSObject.Properties.Name -contains 'fDisabledAllowList')) { $p.fDisabledAllowList } else { '<absent>' }
$n  = @(Get-ChildItem -LiteralPath (Join-Path $TsKeyPS 'Applications') -ErrorAction SilentlyContinue).Count
Write-Host "READBACK: fDisabledAllowList=$fd publishedApplications=$n"
