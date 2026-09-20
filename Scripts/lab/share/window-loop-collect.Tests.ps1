#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test suite for window-loop-collect.ps1's trailer grammar, RESULT detection and the shape of
    a collection that found nothing.

.DESCRIPTION
    Runs on macOS under PowerShell 7 (Tier 1 runs it on ubuntu-latest's pwsh) with no external
    dependencies. Self-contained assertion harness, exit code propagated: 0 when every case
    passes, 1 otherwise. Style follows window-rects-probe.Tests.ps1.

    window-loop-collect.ps1 runs inside one relay connection at the end of a pair: it drops the
    sentinel that stops the loop, waits a bounded time for the loop to write its RESULT line,
    and copies the samples back over the redirected drive. The waiting and the copying cannot be
    exercised here and are not; the suite dot-sources the script with -NoRun and drives the pure
    helpers with synthetic line arrays.

    The case that matters most is the CLEAN NEGATIVE. When there is no samples file at all --
    the loop never started, or did not survive the disconnect, which is the lane's load-bearing
    unknown -- the collector must still write a file, and that file must say so in one
    unambiguous line. Silence would be indistinguishable from a job the host refused before the
    script ever ran.

    window-rects-probe.ps1 is dot-sourced -NoRun first: the collector renders its trailer with
    the probe's formatters, exactly as it does on the host.

.EXAMPLE
    pwsh -NoProfile -File ./window-loop-collect.Tests.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProbeScriptPath = Join-Path $PSScriptRoot 'window-rects-probe.ps1'
$script:SubjectPath = Join-Path $PSScriptRoot 'window-loop-collect.ps1'
. $script:ProbeScriptPath -NoRun
. $script:SubjectPath -NoRun

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

function Assert-Match {
    param([string] $Pattern, [string] $Actual, [string] $Because = '')
    if ($Actual -notmatch $Pattern) {
        $msg = "expected [$Actual] to match /$Pattern/"
        if ($Because) { $msg = "$Because - $msg" }
        throw $msg
    }
}

function New-Section { param([string] $Name) Write-Host ''; Write-Host "== $Name" }

# -------------------------------------------------------------------------------------------
# Fixtures (synthetic; nothing here came off a host)
# -------------------------------------------------------------------------------------------

$script:FixtureUtc = '2026-09-18T09:07:11.0000000Z'

function New-FixtureOutLines {
    <# What a healthy loop leaves behind: a head, two samples with a row each, and a RESULT. #>
    param([string] $Result = 'RESULT: DONE seq=1 reason=sentinel')
    $lines = @(
        '[loop-head] utc=2026-09-18T09:00:00.0000000Z ps=5.1.26200.1 pid=4242 session=3 interval-ms=250 max-seconds=420 deadline-utc=2026-09-18T09:07:00.0000000Z awareness=2 set-via=v2',
        '[loop-tick] seq=0 utc=2026-09-18T09:00:00.2500000Z cx=2560 cy=1600 wa=0,0,2560,1520',
        '[tick-rect] seq=0 hwnd=983040 pid=4242 proc=notepad class=Notepad style=0x16CF0000 dpi=96 wr=54,0,754,500 ef=61,0,747,497 cs=50,0 cr=686,497 owner=0 title-len=17 title-sha8=00eee4a7',
        '[loop-tick] seq=1 utc=2026-09-18T09:00:00.5000000Z cx=2560 cy=1600 wa=0,0,2560,1520',
        '[tick-rect] seq=1 hwnd=983040 pid=4242 proc=notepad class=Notepad style=0x16CF0000 dpi=96 wr=154,0,854,500 ef=161,0,847,497 cs=150,0 cr=686,497 owner=0 title-len=17 title-sha8=00eee4a7'
    )
    if ($Result.Length -gt 0) { $lines += $Result }
    return @($lines)
}

$script:TrailerPattern = '^\[collect\] read-utc=\S+ result-seen=(true|false) lines=\d+ renamed=(true|false)$'

# -------------------------------------------------------------------------------------------
# Pre-registered constants
# -------------------------------------------------------------------------------------------

New-Section 'pre-registered constants'

Test-Case 'the file names are the ones the loop and the launcher agree on' {
    # The same literals are pinned in window-loop.Tests.ps1 and window-loop-start.Tests.ps1.
    Assert-Equal 'macdows-lab' $script:LoopLocalDirName
    Assert-Equal 'window-loop-out.txt' $script:LoopOutName
    Assert-Equal 'window-loop.stop' $script:LoopSentinelName
    Assert-Equal 'window-rects-probe.ps1' $script:LoopProbeName
    Assert-Equal '\\tsclient\lab' $script:LoopShareRoot
    Assert-Equal 'window-loop-out.txt' $script:LoopShareOutName
    Assert-Equal 'window-loop-out.prev.txt' $script:LoopOutPrevName
}

Test-Case 'the job margin is a named constant with archived handshakes behind it' {
    # gate r1 I1: WaitSeconds is only ever spent in full on the ONE path that matters (no RESULT
    # line at all), and it has to fit inside the relay's TIMEOUT together with the RAIL handshake
    # and one write of the samples back. The margin is that slack, written down once.
    Assert-Equal 30 $script:CollectJobMarginSeconds
    Assert-True ($script:CollectJobMarginSeconds -gt 12.6) 'larger than the largest archived handshake (12.6 s)'
}

Test-Case 'every collect job template allows WaitSeconds + margin, measured against its own TIMEOUT' {
    # The pin reads the templates rather than restating their numbers: an edit that lowers
    # TIMEOUT without lowering the wait is then red here instead of being discovered by a
    # connection killed mid-copy on the host.
    $jobs = Join-Path (Split-Path -Parent $PSScriptRoot) 'jobs'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:SubjectPath, [ref]$null, [ref]$null)
    $wait = 0
    foreach ($p in @($ast.ParamBlock.Parameters)) {
        if ($p.Name.VariablePath.UserPath -eq 'WaitSeconds') { $wait = [int]$p.DefaultValue.Value }
    }
    Assert-True ($wait -gt 0) 'the default wait was found'
    $seen = 0
    foreach ($name in @('window-loop-collect-1x.env', 'window-loop-collect-2x.env')) {
        $path = Join-Path $jobs $name
        Assert-True (Test-Path -LiteralPath $path) "[$name] is present"
        $timeout = 0
        foreach ($line in @([IO.File]::ReadAllLines($path))) {
            if ($line -match '^TIMEOUT=(\d+)$') { $timeout = [int]$Matches[1] }
        }
        Assert-True ($timeout -gt 0) "[$name] sets a TIMEOUT"
        Assert-True (($wait + $script:CollectJobMarginSeconds) -le $timeout) `
            "[$name]: WaitSeconds ($wait) + margin ($($script:CollectJobMarginSeconds)) must fit inside TIMEOUT ($timeout)"
        $seen++
    }
    Assert-Equal 2 $seen 'both scale forms are checked'
}

Test-Case 'the formatters are dot-sourced from the SHARE, not from the host-local copy' {
    # The local copy exists only if the launcher got as far as staging it -- and "it did not" is
    # exactly the case whose clean negative this script has to be able to write. Sourcing the
    # local copy would make the collector die precisely when its answer matters most.
    $source = [IO.File]::ReadAllText($script:SubjectPath)
    Assert-Match '\.\s+\(Join-Path\s+\$script:LoopShareRoot\s+\$script:LoopProbeName\)\s+-NoRun' $source
    Assert-True (-not ($source -match '\.\s+\(Join-Path\s+\$dir\s')) 'nothing is dot-sourced out of the local directory'
}

Test-Case 'the clean negative is one pre-registered line, not a shape invented at the failure' {
    Assert-Equal '[collect] out-missing=true' $script:CollectMissingLine
}

Test-Case 'the wait is bounded and polled once a second' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:SubjectPath, [ref]$null, [ref]$null)
    $params = @($ast.ParamBlock.Parameters)
    $byName = @{}
    foreach ($p in $params) { $byName[$p.Name.VariablePath.UserPath] = $p }
    Assert-Equal 45 $byName['WaitSeconds'].DefaultValue.Value
    Assert-Equal 1000 $script:CollectPollMs
}

# -------------------------------------------------------------------------------------------
# Test-OutHasResult
# -------------------------------------------------------------------------------------------

New-Section 'Test-OutHasResult'

Test-Case 'a finished loop is recognised by its RESULT: DONE line' {
    Assert-True (Test-OutHasResult -Lines (New-FixtureOutLines))
}

Test-Case 'a loop that died in an orderly way is ALSO a result -- the wait must not keep waiting' {
    # RESULT: FAILED is an answer. Waiting the full bound for a DONE that will never come would
    # cost the batch 45 s and then report the same thing, one polling cycle later.
    Assert-True (Test-OutHasResult -Lines (New-FixtureOutLines -Result 'RESULT: FAILED tick/InvalidOperationException'))
}

Test-Case 'samples with no RESULT line at all are NOT a result: that is the killed-process shape' {
    Assert-True (-not (Test-OutHasResult -Lines (New-FixtureOutLines -Result '')))
}

Test-Case 'an empty or missing file is not a result either' {
    Assert-True (-not (Test-OutHasResult -Lines @()))
    Assert-True (-not (Test-OutHasResult -Lines $null))
}

Test-Case 'the marker must start the line: a RESULT mentioned inside a row does not end the wait' {
    Assert-True (-not (Test-OutHasResult -Lines @('[loop-tick] seq=0 utc=x cx=1 cy=1 wa=0,0,1,1 RESULT: DONE')))
    Assert-True (-not (Test-OutHasResult -Lines @(' RESULT: DONE seq=0 reason=sentinel'))) 'a leading space is not the grammar'
    Assert-True (-not (Test-OutHasResult -Lines @('RESULTX: DONE')))
}

# -------------------------------------------------------------------------------------------
# Format-CollectTrailer
# -------------------------------------------------------------------------------------------

New-Section 'Format-CollectTrailer'

Test-Case 'the trailer says when the samples were read, whether they were complete and how many' {
    $line = Format-CollectTrailer -ReadUtc $script:FixtureUtc -ResultSeen $true -Lines 6 -Renamed $true
    Assert-Equal '[collect] read-utc=2026-09-18T09:07:11.0000000Z result-seen=true lines=6 renamed=true' $line
    Assert-Match $script:TrailerPattern $line
}

Test-Case 'result-seen=false is what a killed loop looks like from the collector side' {
    $line = Format-CollectTrailer -ReadUtc $script:FixtureUtc -ResultSeen $false -Lines 5 -Renamed $true
    Assert-Equal '[collect] read-utc=2026-09-18T09:07:11.0000000Z result-seen=false lines=5 renamed=true' $line
    Assert-Match $script:TrailerPattern $line
}

Test-Case 'renamed= is last, and it is about the HOST-LOCAL file, not about this one' {
    # gate r1 B2. renamed=true says the sampler's local file has been rotated out of the way, so
    # the next half cannot collect this half's timeline a second time. renamed=false on a
    # collection that DID carry samples means the rotation failed and the next half is at risk.
    $kept = Format-CollectTrailer -ReadUtc $script:FixtureUtc -ResultSeen $true -Lines 6 -Renamed $false
    Assert-Match ' lines=6 renamed=false$' $kept
    Assert-Match $script:TrailerPattern $kept
}

Test-Case 'a trailer with no read time keeps its shape and claims nothing' {
    $line = Format-CollectTrailer -ReadUtc $null -ResultSeen $false -Lines 0 -Renamed $false
    Assert-Equal '[collect] read-utc=n/a result-seen=false lines=0 renamed=false' $line
}

# -------------------------------------------------------------------------------------------
# New-CollectLines
# -------------------------------------------------------------------------------------------

New-Section 'New-CollectLines'

Test-Case 'a healthy collection is the samples verbatim plus one trailer' {
    $out = New-FixtureOutLines
    $lines = @(New-CollectLines -OutLines $out -ReadUtc $script:FixtureUtc -Renamed $true)
    Assert-Equal ($out.Count + 1) $lines.Count 'the samples plus the trailer'
    for ($i = 0; $i -lt $out.Count; $i++) { Assert-Equal $out[$i] $lines[$i] "sample line $i is copied verbatim" }
    Assert-Equal "[collect] read-utc=$($script:FixtureUtc) result-seen=true lines=6 renamed=true" $lines[$lines.Count - 1]
}

Test-Case 'lines= counts the SAMPLES, not the file the collector writes' {
    # The trailer is the collector talking about the loop. Counting itself would make a
    # collection of zero samples report lines=1.
    $lines = @(New-CollectLines -OutLines (New-FixtureOutLines) -ReadUtc $script:FixtureUtc -Renamed $true)
    Assert-Match ' lines=6 renamed=true$' $lines[$lines.Count - 1]
    Assert-Equal 7 $lines.Count
}

Test-Case 'CLEAN NEGATIVE: a missing samples file becomes exactly two lines, and says so first' {
    # The loop never started, or did not survive the disconnect. The file exists, is short, and
    # cannot be mistaken either for a successful collection or for a job that never ran.
    $lines = @(New-CollectLines -OutLines $null -ReadUtc $script:FixtureUtc -Renamed $false)
    Assert-Equal 2 $lines.Count
    Assert-Equal '[collect] out-missing=true' $lines[0]
    Assert-Equal "[collect] read-utc=$($script:FixtureUtc) result-seen=false lines=0 renamed=false" $lines[1]
    Assert-Match $script:TrailerPattern $lines[1]
    Assert-Equal 0 (@($lines | Where-Object { $_ -like '[[]loop-*' })).Count 'no sample line is invented'
}

Test-Case 'an EMPTY samples file is not the same thing as a missing one' {
    # A zero-line file means the loop opened its output and died before the head line -- the
    # process did start. out-missing=true would report the opposite.
    $lines = @(New-CollectLines -OutLines @() -ReadUtc $script:FixtureUtc -Renamed $true)
    Assert-Equal 1 $lines.Count 'the trailer alone'
    Assert-Equal "[collect] read-utc=$($script:FixtureUtc) result-seen=false lines=0 renamed=true" $lines[0]
    Assert-Equal 0 (@($lines | Where-Object { $_ -eq $script:CollectMissingLine })).Count 'the missing marker must not appear'
}

Test-Case 'a truncated collection reports result-seen=false, which is the whole point of the key' {
    $lines = @(New-CollectLines -OutLines (New-FixtureOutLines -Result '') -ReadUtc $script:FixtureUtc -Renamed $true)
    Assert-Match ' result-seen=false lines=5 renamed=true$' $lines[$lines.Count - 1]
    Assert-Equal '[loop-head] utc=2026-09-18T09:00:00.0000000Z ps=5.1.26200.1 pid=4242 session=3 interval-ms=250 max-seconds=420 deadline-utc=2026-09-18T09:07:00.0000000Z awareness=2 set-via=v2' $lines[0] 'every sample it did take is still returned'
}

Test-Case 'the payload and the trailer are the two pieces the run writes, and together they ARE the file' {
    # The run cannot write the whole file in one call any more (gate r1 B2): the trailer's
    # renamed= is only known after the payload has reached the share and the local file has been
    # rotated. So the run writes New-CollectPayload, rotates, then appends Format-CollectTrailer.
    # This case is what keeps the whole-file cases above meaningful: the two pieces, concatenated,
    # are byte-for-byte what New-CollectLines produces.
    foreach ($outLines in @((New-FixtureOutLines), @(), $null)) {
        foreach ($renamed in @($true, $false)) {
            $payload = @(New-CollectPayload -OutLines $outLines)
            $samples = @()
            if ($null -ne $outLines) { $samples = @($outLines) }
            $trailer = Format-CollectTrailer -ReadUtc $script:FixtureUtc `
                -ResultSeen (Test-OutHasResult -Lines $samples) -Lines $samples.Count -Renamed $renamed
            $whole = @(New-CollectLines -OutLines $outLines -ReadUtc $script:FixtureUtc -Renamed $renamed)
            $joined = @($payload + @($trailer))
            Assert-Equal $joined.Count $whole.Count 'same number of lines'
            for ($i = 0; $i -lt $joined.Count; $i++) { Assert-Equal $joined[$i] $whole[$i] "line $i" }
        }
    }
}

Test-Case 'the payload carries no trailer of its own, so the run cannot write two' {
    $payload = @(New-CollectPayload -OutLines (New-FixtureOutLines))
    Assert-Equal 6 $payload.Count
    Assert-Equal 0 (@($payload | Where-Object { $_ -like '[[]collect[]] read-utc=*' })).Count
    $missing = @(New-CollectPayload -OutLines $null)
    Assert-Equal 1 $missing.Count
    Assert-Equal '[collect] out-missing=true' $missing[0]
    Assert-Equal 0 (@(New-CollectPayload -OutLines @())).Count 'an empty file yields an empty payload'
}

Test-Case 'RED LINE: the collector adds nothing of its own to the samples it carries' {
    # It is a transport. Anything it appended beyond the trailer would be evidence nobody
    # measured, and the loop has already done the sanitising.
    $out = New-FixtureOutLines
    $lines = @(New-CollectLines -OutLines $out -ReadUtc $script:FixtureUtc -Renamed $true)
    $added = @($lines | Where-Object { $out -notcontains $_ })
    Assert-Equal 1 $added.Count 'exactly one line is the collector own'
    Assert-Match $script:TrailerPattern $added[0]
}

# -------------------------------------------------------------------------------------------
# The whole run -- driven end to end against a stand-in "share" directory
# -------------------------------------------------------------------------------------------

New-Section 'Invoke-WindowLoopCollect'

function Invoke-CollectFixtureRun {
    <#
      Runs Invoke-WindowLoopCollect for real against two throw-away directories: USERPROFILE is
      pointed at one (the run derives the host-local lab directory from it) and the share-root
      CONSTANT at the other, into which the real probe is copied so the run's own dot-source
      finds it. Nothing else is stubbed -- the sentinel write, the bounded wait, the share
      write-back and the rotation all really happen.

      This is what makes gate r1 B2 checkable offline: whether the local samples file is still
      collectable a second time is a property of the run, not of any pure helper.
    #>
    param([scriptblock] $Body)
    $root = Join-Path ([IO.Path]::GetTempPath()) ('window-loop-collect-tests-' + [Guid]::NewGuid().ToString('N'))
    $share = Join-Path $root 'share'
    [void][IO.Directory]::CreateDirectory($share)
    $local = Join-Path $root ('profile' + [IO.Path]::DirectorySeparatorChar + $script:LoopLocalDirName)
    [void][IO.Directory]::CreateDirectory($local)
    Copy-Item $script:ProbeScriptPath (Join-Path $share $script:LoopProbeName) -Force
    $hadProfile = Test-Path Env:\USERPROFILE
    $beforeProfile = ''
    if ($hadProfile) { $beforeProfile = $env:USERPROFILE }
    $beforeShare = $script:LoopShareRoot
    try {
        $env:USERPROFILE = (Join-Path $root 'profile')
        $script:LoopShareRoot = $share
        & $Body $local $share
    } finally {
        $script:LoopShareRoot = $beforeShare
        if ($hadProfile) { $env:USERPROFILE = $beforeProfile } else { Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Test-Case 'a second collection of the same host-local file is a CLEAN NEGATIVE, not the first one again' {
    # gate r1 B2: the launcher is the only thing that clears the local samples file, so a half
    # whose launcher never ran would otherwise collect the PREVIOUS half's complete timeline --
    # RESULT line and all -- and report it as healthy, with a freshly minted read-utc=.
    Invoke-CollectFixtureRun -Body {
        param($Local, $Share)
        [IO.File]::WriteAllLines((Join-Path $Local $script:LoopOutName), [string[]](New-FixtureOutLines))
        $shareOut = Join-Path $Share $script:LoopShareOutName

        Invoke-WindowLoopCollect -WaitSeconds 1
        $first = @([IO.File]::ReadAllLines($shareOut))
        Assert-Equal 7 $first.Count 'six sample lines and the trailer'
        Assert-Match ' result-seen=true lines=6 renamed=true$' $first[6]
        Assert-True (-not [IO.File]::Exists((Join-Path $Local $script:LoopOutName))) 'the local samples file was rotated away'
        Assert-True ([IO.File]::Exists((Join-Path $Local $script:LoopOutPrevName))) 'and is still on disk under the prev name'

        Invoke-WindowLoopCollect -WaitSeconds 1
        $second = @([IO.File]::ReadAllLines($shareOut))
        Assert-Equal 2 $second.Count
        Assert-Equal '[collect] out-missing=true' $second[0]
        Assert-Match ' result-seen=false lines=0 renamed=false$' $second[1]
        Assert-Equal 0 (@($second | Where-Object { $_ -like '[[]loop-*' })).Count 'not one line of the first half survived into the second'
    }
}

Test-Case 'the rotation overwrites an older prev rather than failing on it' {
    Invoke-CollectFixtureRun -Body {
        param($Local, $Share)
        [IO.File]::WriteAllLines((Join-Path $Local $script:LoopOutPrevName), [string[]]@('[loop-head] older half'))
        [IO.File]::WriteAllLines((Join-Path $Local $script:LoopOutName), [string[]](New-FixtureOutLines))
        Invoke-WindowLoopCollect -WaitSeconds 1
        $prev = @([IO.File]::ReadAllLines((Join-Path $Local $script:LoopOutPrevName)))
        Assert-Equal 6 $prev.Count 'prev now holds THIS half, not the older one'
        Assert-Match '^\[loop-head\] utc=' $prev[0]
        Assert-Match ' renamed=true$' (@([IO.File]::ReadAllLines((Join-Path $Share $script:LoopShareOutName))))[6]
    }
}

Test-Case 'a FAILED write-back leaves the samples where they are: no rotation without a carry' {
    # Order is load-bearing. Rotating first would destroy the only copy of a timeline whose
    # write-back then failed, and the batch would have nothing at all instead of a retryable file.
    Invoke-CollectFixtureRun -Body {
        param($Local, $Share)
        [IO.File]::WriteAllLines((Join-Path $Local $script:LoopOutName), [string[]](New-FixtureOutLines))
        # The share target is a DIRECTORY, so the write-back throws.
        [void][IO.Directory]::CreateDirectory((Join-Path $Share $script:LoopShareOutName))
        $threw = $false
        try { Invoke-WindowLoopCollect -WaitSeconds 1 } catch { $threw = $true }
        Assert-True $threw 'the failed write-back is not swallowed'
        Assert-True ([IO.File]::Exists((Join-Path $Local $script:LoopOutName))) 'the samples are still collectable'
        Assert-True (-not [IO.File]::Exists((Join-Path $Local $script:LoopOutPrevName))) 'nothing was rotated'
    }
}

Test-Case 'the clean negative really is written when there was never a local file' {
    Invoke-CollectFixtureRun -Body {
        param($Local, $Share)
        Invoke-WindowLoopCollect -WaitSeconds 1
        $lines = @([IO.File]::ReadAllLines((Join-Path $Share $script:LoopShareOutName)))
        Assert-Equal 2 $lines.Count
        Assert-Equal '[collect] out-missing=true' $lines[0]
        Assert-Match $script:TrailerPattern $lines[1]
        Assert-True ([IO.File]::Exists((Join-Path $Local $script:LoopSentinelName))) 'the sentinel was dropped even so'
    }
}

# -------------------------------------------------------------------------------------------
# Source pins -- properties the offline path cannot observe by running the script
# -------------------------------------------------------------------------------------------

New-Section 'source pins'

$script:SubjectSource = [IO.File]::ReadAllText($script:SubjectPath)

function Get-CodeOnly {
    <#
      The source with its comments removed, for pins that COUNT something: a pin that counts a
      bare name also counts every mention of it in a doc comment (lab lesson, 2026-09-08).
    #>
    param([string] $Text)
    $stripped = [regex]::Replace($Text, '(?s)<#.*?#>', '')
    return [regex]::Replace($stripped, '(?m)#.*$', '')
}

$script:SubjectCode = Get-CodeOnly -Text $script:SubjectSource

Test-Case 'the script takes exactly the two documented parameters' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:SubjectPath, [ref]$null, [ref]$null)
    $params = @($ast.ParamBlock.Parameters)
    $want = @('WaitSeconds', 'NoRun')
    Assert-Equal $want.Count $params.Count
    for ($i = 0; $i -lt $want.Count; $i++) { Assert-Equal $want[$i] $params[$i].Name.VariablePath.UserPath "parameter $i" }
    Assert-Equal 'switch' $params[1].StaticType.Name.ToLowerInvariant().Substring(0, 6)
}

Test-Case 'the sentinel is written BEFORE the wait, or the wait could never end' {
    $start = $script:SubjectSource.IndexOf('function Invoke-WindowLoopCollect')
    Assert-True ($start -gt 0) 'the run function is present'
    $body = Get-CodeOnly -Text $script:SubjectSource.Substring($start)
    $write = $body.IndexOf('WriteAllText')
    $wait = $body.IndexOf('Start-Sleep')
    $copy = $body.IndexOf('New-CollectPayload')
    Assert-True ($write -gt 0) 'the sentinel is written'
    Assert-True ($wait -gt $write) 'the wait comes after the sentinel'
    Assert-True ($copy -gt $wait) 'the samples are assembled after the wait'
}

Test-Case 'the rotation happens AFTER the write-back and BEFORE the trailer -- in that order' {
    # gate r1 B2. Rotating before the carry would destroy a timeline whose write-back then
    # failed; appending the trailer before the rotation would make renamed= a guess rather than
    # a fact. Source order is the only offline evidence for the second half of that.
    $start = $script:SubjectSource.IndexOf('function Invoke-WindowLoopCollect')
    Assert-True ($start -gt 0) 'the run function is present'
    $body = Get-CodeOnly -Text $script:SubjectSource.Substring($start)
    $payloadWrite = $body.IndexOf('WriteAllLines')
    $rename = $body.IndexOf('Move-Item')
    $trailer = $body.IndexOf('Format-CollectTrailer')
    $append = $body.IndexOf('AppendAllLines')
    Assert-True ($payloadWrite -gt 0) 'the payload is written to the share'
    Assert-True ($rename -gt $payloadWrite) 'the rotation follows the write-back'
    Assert-True ($trailer -gt $rename) 'the trailer is rendered after the rotation, so renamed= is a fact'
    Assert-True ($append -gt $rename) 'and appended last'
    Assert-Equal 1 ([regex]::Matches($body, 'Move-Item')).Count 'exactly one rotation'
    Assert-Equal 1 ([regex]::Matches($body, 'WriteAllLines')).Count 'exactly one write-back'
}

Test-Case 'no local shares a name with a probe parameter -- dot-sourcing the probe overwrites those' {
    # Dot-sourcing a script BINDS ITS PARAMETERS into the current scope, and PowerShell variable
    # names are case-insensitive. window-rects-probe.ps1 takes -OutPath, defaulting to
    # \\tsclient\lab\window-rects-out.txt. A local called $outPath in the run function would
    # therefore become that UNC path the instant the probe is dot-sourced -- and this script
    # would poll the WINDOW-RECTS PROBE'S OWN REPORT for a RESULT line, find one (the probe ends
    # every report with RESULT: DONE), and carry that report back as if it were the loop's
    # samples. Silently wrong evidence, which is worse than a crash. Verified by experiment.
    # Scoped to the function that dot-sources, because that is exactly where the hazard is. The
    # dot-source is therefore pinned to live in that one function and nowhere else first.
    $dotSources = [regex]::Matches($script:SubjectCode, '(?m)^\s*\.\s+\(Join-Path\s+\$script:LoopShareRoot\s+\$script:LoopProbeName\)\s+-NoRun\s*$')
    Assert-Equal 1 $dotSources.Count 'the probe is dot-sourced exactly once'
    $from = $script:SubjectCode.IndexOf('function Invoke-WindowLoopCollect')
    Assert-True ($from -gt 0 -and $dotSources[0].Index -gt $from) 'and only inside the run function'
    # Cut at the guard: the trailing `if (-not $NoRun)` is script scope, which runs before this
    # function is ever called and is therefore not the scope the dot-source rewrites.
    $to = $script:SubjectCode.LastIndexOf('if (-not $NoRun) {')
    Assert-True ($to -gt $from) 'the guard follows the run function'
    $body = $script:SubjectCode.Substring($from, $to - $from)
    foreach ($taken in @('outPath', 'noRun')) {
        Assert-True (-not ($body -match ('(?i)\$' + $taken + '\b'))) `
            "[`$$taken] is a window-rects-probe.ps1 parameter name; a variable of that name in this scope is overwritten by the dot-source"
    }
}

Test-Case 'the wait is bounded by a deadline, not only by an iteration count' {
    $start = $script:SubjectSource.IndexOf('function Invoke-WindowLoopCollect')
    $body = Get-CodeOnly -Text $script:SubjectSource.Substring($start)
    Assert-Match 'AddSeconds\(\$WaitSeconds\)' $body 'the deadline comes from the parameter'
    Assert-Equal 1 ([regex]::Matches($body, 'Start-Sleep')).Count 'exactly one sleep, in the one wait loop'
}

Test-Case 'the share is named once, as a constant, and is never globbed' {
    Assert-True ($script:SubjectSource.Contains("`$script:LoopShareRoot = '\\tsclient\lab'")) 'the share root is a named constant'
    Assert-Equal 0 ([regex]::Matches($script:SubjectCode, '\\\*')).Count 'no glob in any path'
}

Test-Case 'RED LINE: the collector redefines no probe helper and never reads a window itself' {
    foreach ($owned in @('ConvertTo-ProbeToken', 'Format-ProbeInt', 'ConvertTo-TitleSha8')) {
        Assert-True (-not ($script:SubjectSource -match ('(?m)^\s*function\s+' + [regex]::Escape($owned) + '\b'))) "[$owned] belongs to window-rects-probe.ps1"
    }
    Assert-Equal 0 ([regex]::Matches($script:SubjectCode, 'Add-Type')).Count 'no P/Invoke surface here'
    Assert-True (-not ($script:SubjectSource -match 'GetWindowText')) 'the collector reads no window text'
    Assert-True (-not ($script:SubjectSource -match "'title='")) 'no field named title'
}

Test-Case 'nothing runs unless -NoRun is absent: the only top-level call is inside that guard' {
    $guard = $script:SubjectSource.LastIndexOf('if (-not $NoRun) {')
    Assert-True ($guard -gt 0) 'the guard is present'
    $tail = $script:SubjectSource.Substring($guard)
    Assert-True ($tail.Contains('Invoke-WindowLoopCollect')) 'the run is started inside the guard'
    Assert-True ($tail.Contains('exit 0')) 'the script always exits 0; the relay writes the real rc'
    Assert-Equal 0 ([regex]::Matches($script:SubjectSource, '(?m)^Invoke-WindowLoopCollect')).Count 'no unguarded top-level invocation'
}

# -------------------------------------------------------------------------------------------
# Parameter binding
# -------------------------------------------------------------------------------------------

New-Section 'parameter binding'

Test-Case 'dot-sourcing with -NoRun defines the helpers and touches nothing' {
    $ran = $true
    try { & $script:SubjectPath -NoRun } catch { $ran = $false }
    Assert-True $ran '-NoRun must bind and return without collecting anything'
    Assert-True ($null -ne (Get-Command Test-OutHasResult -ErrorAction SilentlyContinue)) 'the helpers are defined'
}

Test-Case 'an explicit wait binds alongside -NoRun' {
    $ran = $true
    try { & $script:SubjectPath -NoRun -WaitSeconds 5 } catch { $ran = $false }
    Assert-True $ran
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
