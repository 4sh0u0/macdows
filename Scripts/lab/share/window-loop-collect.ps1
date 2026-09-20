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
    3. CARRY. Writes the samples, verbatim, to \\tsclient\lab\window-loop-out.txt. The samples
       are already sanitised by the loop (numbers, class and process tokens, title-len and
       title-sha8 only) -- this script adds nothing of its own to them.
    4. ROTATE, then TRAILER. Once, and only once, the carry has succeeded, the host-local samples
       file is RENAMED to window-loop-out.prev.txt; then the [collect] trailer is appended, with
       renamed= reporting what actually happened.

       Why the rotation exists. window-loop-start.ps1 is the only other thing that clears the
       local samples file. A half whose launcher never ran -- RAIL refused the job, the
       connection failed -- would therefore find the PREVIOUS half's complete timeline sitting
       there, see the RESULT: DONE it ends with, stop waiting at once and carry it back under a
       freshly minted read-utc=, looking perfectly healthy. A whole timeline attributed to the
       wrong half, the wrong target, possibly the wrong scale. Renaming rather than deleting
       keeps that evidence on the host; the order (carry, then rename) means a failed carry
       leaves the samples exactly where a retry can find them.

    THE CLEAN NEGATIVE. If there is no local samples file at all -- the loop never started, or
    did not survive the relay disconnect, which is the load-bearing unknown of this lane -- the
    file written back holds exactly:

        [collect] out-missing=true
        [collect] read-utc= result-seen=false lines=0

    That is a RESULT, not a failure to report one. Silence would be indistinguishable from a job
    the host refused before this script ever started. An EMPTY samples file is a different
    answer again (the loop opened its output and died before its first line), and gets the
    trailer alone with no out-missing line.

    The trailer's keys: read-utc= is when the samples were read -- note that it identifies a
    stale file on the SHARE, and says nothing about a stale file on the host, which is what the
    rotation is for; result-seen= is whether the loop ended in an orderly way, i.e. false means
    the process was killed; lines= counts the SAMPLE lines, never the trailer; renamed= is
    whether the host-local file was rotated (see step 4).

    OPERATOR STEP. Remove the previous \\tsclient\lab\window-loop-out.txt before launching:
    run-scenario.sh deliberately never removes host-written *-out.txt, and a job the host
    refuses before this script starts writes nothing at all, so only a missing file tells the
    truth then.

    Windows PowerShell 5.1: no ??, no ternary.

.PARAMETER WaitSeconds
    How long to wait for the loop's RESULT line after the sentinel is dropped. Only ONE outcome
    ever spends it in full -- a samples file with no RESULT line, i.e. the sampler was killed,
    which is this lane's load-bearing evidence -- so it has to fit inside the job's TIMEOUT
    together with the handshake: WaitSeconds + CollectJobMarginSeconds <= TIMEOUT, pinned by the
    suite against the job templates themselves.

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
# Where the samples are rotated to once they have been carried back (gate r1 B2). Renaming, not
# deleting: a write-back that failed must leave the timeline on the host to be retried.
$script:LoopOutPrevName = 'window-loop-out.prev.txt'

# The name this lane's samples arrive under on the share.
$script:LoopShareOutName = 'window-loop-out.txt'

# The clean negative, written down once rather than invented at the moment of failure.
$script:CollectMissingLine = '[collect] out-missing=true'

# The prefix that ends the wait. Both endings the loop can write start with it.
$script:CollectResultPrefix = 'RESULT: '

# Poll period for the bounded wait, in milliseconds.
$script:CollectPollMs = 1000

# The slack a collect JOB needs on top of WaitSeconds, in seconds: the RAIL handshake and
# powershell's start-up before this script's first line, plus one write of the samples back over
# the redirected drive. Archived handshakes, measured as the batch log's relay-start stamp against
# the probe's own read-utc= (which is itself late in the probe's flow, so these are upper bounds
# read as lower ones): 8.5 s, 8.9 s and 12.6 s (routeb-20260918 1x-about, p1 notepad, p1 about).
# 30 s is more than twice the largest of those with room for a megabyte-scale write. The suite
# reads the job templates and pins WaitSeconds + this <= TIMEOUT, so the two cannot drift apart
# (gate r1 I1).
$script:CollectJobMarginSeconds = 30

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
      "[collect] read-utc= result-seen=<true|false> lines=<n> renamed=<true|false>" -- the one
      line this script adds to the evidence, and the only thing on the file that is the
      collector's own claim.

      renamed= is about the HOST-LOCAL samples file, not about this one: true means it has been
      rotated to LoopOutPrevName, so the next half cannot collect this half's timeline a second
      time (gate r1 B2). renamed=false on a collection that DID carry samples means the rotation
      failed and the next half is at risk; renamed=false on an out-missing collection is simply
      "there was nothing to rotate". It is last on the line because it is the only key here that
      describes the host rather than the file it appears in.
    #>
    [CmdletBinding()]
    param([AllowNull()] $ReadUtc, [bool] $ResultSeen, [int] $Lines, [bool] $Renamed)
    $seen = 'false'
    if ($ResultSeen) { $seen = 'true' }
    $rotated = 'false'
    if ($Renamed) { $rotated = 'true' }
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('[collect]')
    [void]$parts.Add('read-utc=' + (ConvertTo-ProbeToken -Value $ReadUtc))
    [void]$parts.Add('result-seen=' + $seen)
    [void]$parts.Add('lines=' + (Format-ProbeInt -Value $Lines))
    [void]$parts.Add('renamed=' + $rotated)
    return ($parts.ToArray() -join ' ')
}

function New-CollectPayload {
    <#
      Everything the file carries EXCEPT the trailer: the samples verbatim, or -- when there were
      no samples to read at all ($null, as opposed to an empty array) -- the pre-registered
      out-missing line. An empty array yields an empty payload, which is a third answer again
      (the sampler opened its output and died before its first line).

      Separate from the trailer because the run cannot write them in one call: renamed= is only
      known after the payload has reached the share and the local file has been rotated.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()] $OutLines)
    $lines = New-Object System.Collections.ArrayList
    if ($null -eq $OutLines) {
        [void]$lines.Add($script:CollectMissingLine)
    } else {
        foreach ($line in @($OutLines)) { [void]$lines.Add([string]$line) }
    }
    return @($lines.ToArray())
}

function New-CollectLines {
    <#
      The whole file: the payload plus its trailer. The run writes the two pieces separately (see
      New-CollectPayload); this is the assembled form the suite drives, and one case pins that
      the two are byte-for-byte the same thing.

      result-seen= and lines= are DERIVED here from the very array that is about to be written,
      never taken from the caller, so the trailer cannot describe a different file from the one
      it trails.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()] $OutLines, [AllowNull()] $ReadUtc, [bool] $Renamed)
    $samples = @()
    if ($null -ne $OutLines) { $samples = @($OutLines) }
    $lines = New-Object System.Collections.ArrayList
    foreach ($line in @(New-CollectPayload -OutLines $OutLines)) { [void]$lines.Add($line) }
    [void]$lines.Add((Format-CollectTrailer -ReadUtc $ReadUtc `
        -ResultSeen (Test-OutHasResult -Lines $samples) -Lines $samples.Count -Renamed $Renamed))
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
    # UTF-8 without BOM, like every other report this lab writes back. This call is the one that
    # must succeed before anything on the host is touched: if it throws, the exception propagates
    # and the samples are still on the host to be retried.
    $readUtc = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $share = Join-Path $script:LoopShareRoot $script:LoopShareOutName
    [IO.File]::WriteAllLines($share, [string[]](New-CollectPayload -OutLines $outLines))

    # -- rotate --------------------------------------------------------------------------
    # AFTER the carry, never before (gate r1 B2). The launcher is the only other thing that
    # clears this file, so without the rotation a half whose launcher never ran would collect the
    # PREVIOUS half's complete timeline -- RESULT line and all -- and report it as healthy under
    # a freshly minted read-utc=. Renaming rather than deleting keeps the evidence on the host;
    # -Force overwrites an older prev, which belongs to a half that has already been carried.
    $renamed = $false
    if ($null -ne $outLines) {
        try {
            Move-Item -LiteralPath $loopOutPath -Destination (Join-Path $dir $script:LoopOutPrevName) -Force
            $renamed = $true
        } catch {
            # The rotation is best-effort: the timeline is already on the share, and saying so on
            # the trailer is more use than failing a job that has done its work.
            $renamed = $false
        }
    }

    # -- trailer -------------------------------------------------------------------------
    # Appended last, so renamed= reports what really happened rather than what was intended. A
    # share file that ends without a [collect] line is itself a visible shape: the carry
    # succeeded and this append did not.
    $samples = @()
    if ($null -ne $outLines) { $samples = @($outLines) }
    $trailer = Format-CollectTrailer -ReadUtc $readUtc `
        -ResultSeen (Test-OutHasResult -Lines $samples) -Lines $samples.Count -Renamed $renamed
    [IO.File]::AppendAllLines($share, [string[]]@($trailer), (New-Object System.Text.UTF8Encoding($false)))
}

if (-not $NoRun) {
    Invoke-WindowLoopCollect -WaitSeconds $WaitSeconds
    # Always 0: the relay writes the run's real rc into relay.log, and a non-zero exit here would
    # only leave a [Process completed] Terminal window behind (owner rule).
    exit 0
}
