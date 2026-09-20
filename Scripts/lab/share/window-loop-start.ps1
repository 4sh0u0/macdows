<#
.SYNOPSIS
    Starts the in-session geometry loop (window-loop.ps1) inside one relay connection and leaves
    it running after that connection is gone. Run by the lab relay
    (jobs/window-loop-start-1x.env / window-loop-start-2x.env ->
    powershell.exe -File \\tsclient\lab\window-loop-start.ps1).

.DESCRIPTION
    The relay's connection is short by design: it exists only to launch something. This script
    does four things inside it and then gets out of the way.

    1. STAGE. window-loop.ps1 and window-rects-probe.ps1 are copied from the redirected drive
       into the account's own lab directory (the one stage.ps1:5-6 already owns and creates).
       The redirected drive belongs to the CONNECTION -- the relay mounts it with /drive:lab --
       so it is gone the moment xfreerdp exits, which is exactly when the loop's value begins.
       A loop started by UNC path would probably survive (PowerShell parses a -File script
       before running it), but "probably" is not a thing to hang a lane on, and the loop must
       dot-source the probe LATER, long after the drive is gone. Staging both files removes the
       question. It is also the pattern stage.ps1:15 already uses for tray-driver.ps1.
    2. CLEAR. The previous run's sentinel and samples file are removed, so a stale sentinel
       cannot stop the new loop at its first tick and an old samples file cannot be collected as
       if it were this batch's.
    3. LAUNCH. Start-Process, detached, hidden, -PassThru for the pid. The argument list is
       built by the pure New-LoopArgumentList, whose quoting is pinned offline: Start-Process
       joins -ArgumentList into ONE command line with single spaces, so an unquoted path with a
       space in it arrives split in two and -File gets a truncated path. A loop that never
       started is indistinguishable, in the evidence, from a loop that did not survive the
       disconnect -- and telling those two apart is the entire point of the lane.
       NOTHING IS REDIRECTED. -RedirectStandardOutput onto the share would hand the detached
       process a handle to a drive that vanishes with the connection.
    4. MARK. While the drive is still there, one line goes back to
       \\tsclient\lab\window-loop-start.done:

           [loop-start] utc= pid= max-seconds= interval-ms= deadline-utc= staged=<n>

       A missing marker means the job never reached this script at all (RAIL refused it, the
       connection failed) -- a different failure from "the loop started and died", and the pair
       is what makes the lane's load-bearing unknown answerable.

    RED LINES. The marker carries NO PATH: local paths on the host contain the account name.
    pid, the two bounds, the deadline and the staged count are everything a reader needs and
    none of them identifies anybody. staged= is the number of files verified present after the
    copy, so a half-staged pair (the loop without its probe) is visible rather than showing up
    later as an unexplained empty samples file.

    deadline-utc on this line is the LAUNCHER's arithmetic. The authoritative one is
    [loop-head] deadline-utc= in the loop's own file, computed from the loop's own start; the
    two differ by however long the process took to come up.

    The probe is dot-sourced -NoRun from the staged copy purely for its formatters -- which also
    means a copy that did not land, or landed corrupt, fails HERE, inside the connection, rather
    than silently in a detached process nobody can see.

    Windows PowerShell 5.1: no ??, no ternary.

.PARAMETER MaxSeconds
    Passed straight through to the loop's hard deadline. Same default as the loop's own.

.PARAMETER IntervalMs
    Passed straight through to the loop's sample interval.

.PARAMETER NoRun
    Define the functions and constants but touch nothing. window-loop-start.Tests.ps1
    dot-sources the script this way and drives the pure helpers on macOS.
#>

[CmdletBinding()]
param(
    [int] $MaxSeconds = 420,
    [int] $IntervalMs = 250,
    [switch] $NoRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------------------------------
# Pre-registered constants (pinned by the test suite; change them there too or the suite fails)
# -------------------------------------------------------------------------------------------

# The drive the relay redirects (relay.command's /drive:lab). Named once: this lane reads two
# files from it and writes one marker to it, all by exact name and never by wildcard, because
# every other lab lane's evidence lives on the same share.
$script:LoopShareRoot = '\\tsclient\lab'

# The host-local directory and file names. The same literals are pinned in window-loop.Tests.ps1
# and window-loop-collect.Tests.ps1, so a rename in one file is red in the other two.
$script:LoopLocalDirName = 'macdows-lab'
$script:LoopScriptName = 'window-loop.ps1'
$script:LoopProbeName = 'window-rects-probe.ps1'
$script:LoopOutName = 'window-loop-out.txt'
$script:LoopSentinelName = 'window-loop.stop'
$script:LoopStartDoneName = 'window-loop-start.done'

# What is copied onto the host, in order: the loop, and the probe the loop dot-sources after the
# share is gone. Two files, both from this lane, no wildcard.
$script:LoopStagedFileNames = @($script:LoopScriptName, $script:LoopProbeName)

# -------------------------------------------------------------------------------------------
# Pure helpers (no host state; exercised off-Windows by the test suite)
#
# Format-ProbeInt and ConvertTo-ProbeToken are NOT defined here: they come from
# window-rects-probe.ps1, which the run dot-sources from the staged copy.
# -------------------------------------------------------------------------------------------

function New-LoopArgumentList {
    <#
      The argument list handed to Start-Process for the loop.

      Every path is pre-quoted HERE rather than left to the caller, for the reason spelled out
      in .DESCRIPTION: Start-Process joins -ArgumentList with single spaces into one command
      line. Pure and separate from the launch so the quoting is testable off-Windows -- the same
      shape New-MatrixAgentArgumentList uses in tsallowlist-matrix-verify.ps1.
    #>
    [CmdletBinding()]
    param(
        [string] $LoopScript,
        [string] $OutPath,
        [string] $SentinelPath,
        [string] $ProbeScript,
        [int] $MaxSeconds,
        [int] $IntervalMs
    )

    return @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $LoopScript + '"'),
        '-OutPath', ('"' + $OutPath + '"'),
        '-SentinelPath', ('"' + $SentinelPath + '"'),
        '-ProbePath', ('"' + $ProbeScript + '"'),
        '-MaxSeconds', "$MaxSeconds",
        '-IntervalMs', "$IntervalMs"
    )
}

function Format-LoopStartRow {
    <#
      "[loop-start] utc= pid= max-seconds= interval-ms= deadline-utc= staged=<n>" -- the whole
      done marker, one line.

      No path appears on it, by design (see RED LINES). A missing record renders every value as
      n/a rather than dropping a key, so the marker's presence always means the same thing.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Start)
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('[loop-start]')
    [void]$parts.Add('utc=' + (ConvertTo-ProbeToken -Value (Get-ProbeProp -Object $Start -Name 'Utc')))
    [void]$parts.Add('pid=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Start -Name 'ProcessId')))
    [void]$parts.Add('max-seconds=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Start -Name 'MaxSeconds')))
    [void]$parts.Add('interval-ms=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Start -Name 'IntervalMs')))
    [void]$parts.Add('deadline-utc=' + (ConvertTo-ProbeToken -Value (Get-ProbeProp -Object $Start -Name 'DeadlineUtc')))
    [void]$parts.Add('staged=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Start -Name 'Staged')))
    return ($parts.ToArray() -join ' ')
}

# -------------------------------------------------------------------------------------------
# The run (Windows only; never reached under -NoRun)
# -------------------------------------------------------------------------------------------

function Invoke-WindowLoopStart {
    <#
      Stage, clear, launch, mark. Any exception propagates: this script runs inside a relay
      connection whose log records the failure, and a missing done marker is itself the
      documented evidence that the launch never completed.
    #>
    [CmdletBinding()]
    param([int] $MaxSeconds, [int] $IntervalMs)

    $dir = Join-Path $env:USERPROFILE $script:LoopLocalDirName
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    # -- stage ---------------------------------------------------------------------------
    $staged = 0
    foreach ($name in $script:LoopStagedFileNames) {
        Copy-Item (Join-Path $script:LoopShareRoot $name) (Join-Path $dir $name) -Force
        if (Test-Path -LiteralPath (Join-Path $dir $name) -PathType Leaf) { $staged++ }
    }

    # $loopOutPath, NOT $outPath: dot-sourcing a script BINDS ITS PARAMETERS into the current
    # scope, PowerShell variable names are case-insensitive, and window-rects-probe.ps1 takes
    # -OutPath with the redirected drive as its default. A local named $outPath would become
    # \\tsclient\lab\window-rects-out.txt at the dot-source below, and the loop would be launched
    # pointing at a drive that dies with this connection -- writing over the window-rects probe's
    # own report name while it was at it. The suite pins that no such name exists here.
    $loopScript = Join-Path $dir $script:LoopScriptName
    $probeScript = Join-Path $dir $script:LoopProbeName
    $loopOutPath = Join-Path $dir $script:LoopOutName
    $sentinelPath = Join-Path $dir $script:LoopSentinelName

    # -- clear ---------------------------------------------------------------------------
    # A sentinel left by the previous pair would stop this loop at its first tick; an old
    # samples file would be collected as if it were this batch's.
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $sentinelPath
    Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $loopOutPath

    # The formatters, from the copy that was just staged -- which also proves the copy landed
    # and parses, here, where the failure is still visible to the relay. See the naming note
    # above: this line rewrites every variable that shares a name with a probe parameter.
    . $probeScript -NoRun

    # -- launch --------------------------------------------------------------------------
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = New-LoopArgumentList -LoopScript $loopScript -OutPath $loopOutPath `
        -SentinelPath $sentinelPath -ProbeScript $probeScript `
        -MaxSeconds $MaxSeconds -IntervalMs $IntervalMs
    $startedAt = Get-Date
    $proc = Start-Process -FilePath $psExe -ArgumentList $argList -PassThru -WindowStyle Hidden
    if ($null -eq $proc) {
        # -PassThru returning nothing would make $proc.Id a StrictMode error below, reported as
        # an unrelated property fault. Say it here.
        throw 'Start-Process -PassThru returned no process handle for the loop'
    }

    # -- mark ----------------------------------------------------------------------------
    $record = [pscustomobject]@{
        Utc         = $startedAt.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        ProcessId   = $proc.Id
        MaxSeconds  = $MaxSeconds
        IntervalMs  = $IntervalMs
        DeadlineUtc = $startedAt.AddSeconds($MaxSeconds).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        Staged      = $staged
    }
    $marker = Join-Path $script:LoopShareRoot $script:LoopStartDoneName
    [IO.File]::WriteAllLines($marker, [string[]]@((Format-LoopStartRow -Start $record)))
}

if (-not $NoRun) {
    Invoke-WindowLoopStart -MaxSeconds $MaxSeconds -IntervalMs $IntervalMs
    # Always 0: the relay writes the run's real rc into relay.log, and a non-zero exit here would
    # only leave a [Process completed] Terminal window behind (owner rule).
    exit 0
}
