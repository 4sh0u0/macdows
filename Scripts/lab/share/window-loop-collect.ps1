<#
.SYNOPSIS
    Stops the in-session geometry loop and carries its samples back over the redirected drive.
    Run by the lab relay (jobs/window-loop-collect-1x.env / window-loop-collect-2x.env ->
    powershell.exe -File \\tsclient\lab\window-loop-collect.ps1) as the last step of a pair.

.DESCRIPTION
    The loop started by window-loop-start.ps1 writes host-local, because the redirected drive
    belongs to a connection and the loop outlives connections. This script is the other end of
    that arrangement, and it runs inside a connection of its own:

    1. SENTINEL. Creates the stop file the loop checks after every sample. This is the ONLY
       clean way to stop it: the loop's other ending, its hard deadline, means the sentinel
       never arrived, and the RESULT line says which one happened.
    2. WAIT, BOUNDED. Polls the local samples file once a second for at most WaitSeconds,
       looking for a line that STARTS with "RESULT: ". Both endings count: RESULT: FAILED is an
       answer, and waiting out the full bound for a DONE that will never come would cost the
       batch the whole timeout to report the same thing. The bound is a wall-clock deadline, not
       an iteration count, and it sits well inside the job's own TIMEOUT so the connection is
       never killed mid-copy.
    3. CARRY. Writes the samples, verbatim, to \\tsclient\lab\window-loop-out.txt, with one
       [collect] trailer appended. The samples are already sanitised by the loop (numbers, class
       and process tokens, title-len and title-sha8 only) -- this script adds nothing of its own
       to them.

    THE CLEAN NEGATIVE. If there is no local samples file at all -- the loop never started, or
    did not survive the relay disconnect, which is the load-bearing unknown of this lane -- the
    file written back holds exactly:

        [collect] out-missing=true
        [collect] read-utc= result-seen=false lines=0

    That is a RESULT, not a failure to report one. Silence would be indistinguishable from a job
    the host refused before this script ever started. An EMPTY samples file is a different
    answer again (the loop opened its output and died before its first line), and gets the
    trailer alone with no out-missing line.

    The trailer's keys: read-utc= is when the samples were read, so a stale file left by an
    earlier pair is identifiable; result-seen= is whether the loop ended in an orderly way, i.e.
    false means the process was killed; lines= counts the SAMPLE lines, never the trailer.

    OPERATOR STEP. Remove the previous \\tsclient\lab\window-loop-out.txt before launching:
    run-scenario.sh deliberately never removes host-written *-out.txt, and a job the host
    refuses before this script starts writes nothing at all, so only a missing file tells the
    truth then.

    Windows PowerShell 5.1: no ??, no ternary.

.PARAMETER WaitSeconds
    How long to wait for the loop's RESULT line after the sentinel is dropped. 45 s sits inside
    the job's TIMEOUT of 60 s with room for the RAIL handshake and the copy.

.PARAMETER NoRun
    Define the functions and constants but touch nothing. window-loop-collect.Tests.ps1
    dot-sources the script this way and drives the pure helpers on macOS.
#>

[CmdletBinding()]
param(
    [int] $WaitSeconds = 45,
    [switch] $NoRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------------------------------
# Pre-registered constants (pinned by the test suite; change them there too or the suite fails)
# -------------------------------------------------------------------------------------------

# The drive the relay redirects. Named once; this lane writes one file to it, by exact name.
$script:LoopShareRoot = '\\tsclient\lab'

# The host-local directory and file names. The same literals are pinned in window-loop.Tests.ps1
# and window-loop-start.Tests.ps1, so a rename in one file is red in the other two.
$script:LoopLocalDirName = 'macdows-lab'
$script:LoopOutName = 'window-loop-out.txt'
$script:LoopSentinelName = 'window-loop.stop'
$script:LoopProbeName = 'window-rects-probe.ps1'

# The name this lane's samples arrive under on the share.
$script:LoopShareOutName = 'window-loop-out.txt'

# The clean negative, written down once rather than invented at the moment of failure.
$script:CollectMissingLine = '[collect] out-missing=true'

# The prefix that ends the wait. Both endings the loop can write start with it.
$script:CollectResultPrefix = 'RESULT: '

# Poll period for the bounded wait, in milliseconds.
$script:CollectPollMs = 1000

# -------------------------------------------------------------------------------------------
# Pure helpers (no host state; exercised off-Windows by the test suite)
#
# Format-ProbeInt and ConvertTo-ProbeToken are NOT defined here: they come from
# window-rects-probe.ps1, which the run dot-sources from the staged copy.
# -------------------------------------------------------------------------------------------

function Test-OutHasResult {
    <#
      Whether the loop has finished writing: does any line START with the RESULT prefix.

      Anchored at the start on purpose. A sample row could in principle carry the text (a class
      name is sanitised but not forbidden from containing letters), and a wait that ended on a
      substring would copy a file the loop was still appending to.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()] $Lines)
    if ($null -eq $Lines) { return $false }
    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        if (([string]$line).StartsWith($script:CollectResultPrefix, [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Format-CollectTrailer {
    <#
      "[collect] read-utc= result-seen=<true|false> lines=<n>" -- the one line this script adds
      to the evidence, and the only thing on the file that is the collector's own claim.
    #>
    [CmdletBinding()]
    param([AllowNull()] $ReadUtc, [bool] $ResultSeen, [int] $Lines)
    $seen = 'false'
    if ($ResultSeen) { $seen = 'true' }
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('[collect]')
    [void]$parts.Add('read-utc=' + (ConvertTo-ProbeToken -Value $ReadUtc))
    [void]$parts.Add('result-seen=' + $seen)
    [void]$parts.Add('lines=' + (Format-ProbeInt -Value $Lines))
    return ($parts.ToArray() -join ' ')
}

function New-CollectLines {
    <#
      The whole file to write back: the samples verbatim plus one trailer, or -- when there were
      no samples to read at all ($null, as opposed to an empty array) -- the pre-registered
      out-missing line plus that same trailer.

      result-seen= and lines= are DERIVED here from the very array that is about to be written,
      never taken from the caller, so the trailer cannot describe a different file from the one
      it trails.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()] $OutLines, [AllowNull()] $ReadUtc)
    $lines = New-Object System.Collections.ArrayList
    $samples = @()
    if ($null -eq $OutLines) {
        [void]$lines.Add($script:CollectMissingLine)
    } else {
        $samples = @($OutLines)
        foreach ($line in $samples) { [void]$lines.Add([string]$line) }
    }
    [void]$lines.Add((Format-CollectTrailer -ReadUtc $ReadUtc `
        -ResultSeen (Test-OutHasResult -Lines $samples) -Lines $samples.Count))
    return @($lines.ToArray())
}

# -------------------------------------------------------------------------------------------
# The run (Windows only; never reached under -NoRun)
# -------------------------------------------------------------------------------------------

function Invoke-WindowLoopCollect {
    <#
      Drop the sentinel, wait for the loop's RESULT line within the bound, write the samples and
      the trailer back to the share. Any exception propagates: this runs inside a relay
      connection whose log records the failure.
    #>
    [CmdletBinding()]
    param([int] $WaitSeconds)

    $dir = Join-Path $env:USERPROFILE $script:LoopLocalDirName
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    # $loopOutPath, NOT $outPath: dot-sourcing a script BINDS ITS PARAMETERS into the current
    # scope, PowerShell variable names are case-insensitive, and window-rects-probe.ps1 takes
    # -OutPath defaulting to \\tsclient\lab\window-rects-out.txt. A local named $outPath would
    # become that path at the dot-source below -- and this script would then poll the WINDOW-RECTS
    # PROBE'S report for a RESULT line, find the one every probe report ends with, and carry that
    # report back as if it were the loop's samples. Silently wrong evidence. The suite pins that
    # no such name exists here.
    $loopOutPath = Join-Path $dir $script:LoopOutName
    $sentinelPath = Join-Path $dir $script:LoopSentinelName

    # The formatters, from the SHARE rather than from the host-local copy. The local copy exists
    # only if window-loop-start.ps1 got that far -- and "it did not" is precisely the case whose
    # clean negative this script has to be able to write. The share is mounted for the duration
    # of this connection and run-scenario.sh re-stages every share/*.ps1 before each relay job,
    # so it is the one source that is present whatever the loop did.
    . (Join-Path $script:LoopShareRoot $script:LoopProbeName) -NoRun

    # -- sentinel ------------------------------------------------------------------------
    # Empty on purpose: the loop tests for existence only, and a file with content would invite
    # a reader to believe the content means something.
    [IO.File]::WriteAllText($sentinelPath, '')

    # -- bounded wait --------------------------------------------------------------------
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $outLines = $null
    while ($true) {
        $outLines = $null
        if ([IO.File]::Exists($loopOutPath)) {
            # ReadAllLines can race the loop's own writer for one poll; a read that throws is
            # simply not an answer yet, and the next poll gets a consistent file.
            try { $outLines = @([IO.File]::ReadAllLines($loopOutPath)) } catch { $outLines = $null }
        }
        if (Test-OutHasResult -Lines $outLines) { break }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds $script:CollectPollMs
    }

    # -- carry ---------------------------------------------------------------------------
    $readUtc = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $lines = New-CollectLines -OutLines $outLines -ReadUtc $readUtc
    $share = Join-Path $script:LoopShareRoot $script:LoopShareOutName
    # UTF-8 without BOM, like every other report this lab writes back.
    [IO.File]::WriteAllLines($share, [string[]]$lines)
}

if (-not $NoRun) {
    Invoke-WindowLoopCollect -WaitSeconds $WaitSeconds
    # Always 0: the relay writes the run's real rc into relay.log, and a non-zero exit here would
    # only leave a [Process completed] Terminal window behind (owner rule).
    exit 0
}
