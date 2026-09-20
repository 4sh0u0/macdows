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

$script:TrailerPattern = '^\[collect\] read-utc=\S+ result-seen=(true|false) lines=\d+$'

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
    Assert-Equal 45 $byName['WaitSeconds'].DefaultValue.Value 'well inside the job TIMEOUT of 60 s'
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
    $line = Format-CollectTrailer -ReadUtc $script:FixtureUtc -ResultSeen $true -Lines 6
    Assert-Equal '[collect] read-utc=2026-09-18T09:07:11.0000000Z result-seen=true lines=6' $line
    Assert-Match $script:TrailerPattern $line
}

Test-Case 'result-seen=false is what a killed loop looks like from the collector side' {
    $line = Format-CollectTrailer -ReadUtc $script:FixtureUtc -ResultSeen $false -Lines 5
    Assert-Equal '[collect] read-utc=2026-09-18T09:07:11.0000000Z result-seen=false lines=5' $line
    Assert-Match $script:TrailerPattern $line
}

Test-Case 'a trailer with no read time keeps its shape and claims nothing' {
    $line = Format-CollectTrailer -ReadUtc $null -ResultSeen $false -Lines 0
    Assert-Equal '[collect] read-utc=n/a result-seen=false lines=0' $line
}

# -------------------------------------------------------------------------------------------
# New-CollectLines
# -------------------------------------------------------------------------------------------

New-Section 'New-CollectLines'

Test-Case 'a healthy collection is the samples verbatim plus one trailer' {
    $out = New-FixtureOutLines
    $lines = @(New-CollectLines -OutLines $out -ReadUtc $script:FixtureUtc)
    Assert-Equal ($out.Count + 1) $lines.Count 'the samples plus the trailer'
    for ($i = 0; $i -lt $out.Count; $i++) { Assert-Equal $out[$i] $lines[$i] "sample line $i is copied verbatim" }
    Assert-Equal "[collect] read-utc=$($script:FixtureUtc) result-seen=true lines=6" $lines[$lines.Count - 1]
}

Test-Case 'lines= counts the SAMPLES, not the file the collector writes' {
    # The trailer is the collector talking about the loop. Counting itself would make a
    # collection of zero samples report lines=1.
    $lines = @(New-CollectLines -OutLines (New-FixtureOutLines) -ReadUtc $script:FixtureUtc)
    Assert-Match ' lines=6$' $lines[$lines.Count - 1]
    Assert-Equal 7 $lines.Count
}

Test-Case 'CLEAN NEGATIVE: a missing samples file becomes exactly two lines, and says so first' {
    # The loop never started, or did not survive the disconnect. The file exists, is short, and
    # cannot be mistaken either for a successful collection or for a job that never ran.
    $lines = @(New-CollectLines -OutLines $null -ReadUtc $script:FixtureUtc)
    Assert-Equal 2 $lines.Count
    Assert-Equal '[collect] out-missing=true' $lines[0]
    Assert-Equal "[collect] read-utc=$($script:FixtureUtc) result-seen=false lines=0" $lines[1]
    Assert-Match $script:TrailerPattern $lines[1]
    Assert-Equal 0 (@($lines | Where-Object { $_ -like '[[]loop-*' })).Count 'no sample line is invented'
}

Test-Case 'an EMPTY samples file is not the same thing as a missing one' {
    # A zero-line file means the loop opened its output and died before the head line -- the
    # process did start. out-missing=true would report the opposite.
    $lines = @(New-CollectLines -OutLines @() -ReadUtc $script:FixtureUtc)
    Assert-Equal 1 $lines.Count 'the trailer alone'
    Assert-Equal "[collect] read-utc=$($script:FixtureUtc) result-seen=false lines=0" $lines[0]
    Assert-Equal 0 (@($lines | Where-Object { $_ -eq $script:CollectMissingLine })).Count 'the missing marker must not appear'
}

Test-Case 'a truncated collection reports result-seen=false, which is the whole point of the key' {
    $lines = @(New-CollectLines -OutLines (New-FixtureOutLines -Result '') -ReadUtc $script:FixtureUtc)
    Assert-Match ' result-seen=false lines=5$' $lines[$lines.Count - 1]
    Assert-Equal '[loop-head] utc=2026-09-18T09:00:00.0000000Z ps=5.1.26200.1 pid=4242 session=3 interval-ms=250 max-seconds=420 deadline-utc=2026-09-18T09:07:00.0000000Z awareness=2 set-via=v2' $lines[0] 'every sample it did take is still returned'
}

Test-Case 'RED LINE: the collector adds nothing of its own to the samples it carries' {
    # It is a transport. Anything it appended beyond the trailer would be evidence nobody
    # measured, and the loop has already done the sanitising.
    $out = New-FixtureOutLines
    $lines = @(New-CollectLines -OutLines $out -ReadUtc $script:FixtureUtc)
    $added = @($lines | Where-Object { $out -notcontains $_ })
    Assert-Equal 1 $added.Count 'exactly one line is the collector own'
    Assert-Match $script:TrailerPattern $added[0]
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
    $copy = $body.IndexOf('New-CollectLines')
    Assert-True ($write -gt 0) 'the sentinel is written'
    Assert-True ($wait -gt $write) 'the wait comes after the sentinel'
    Assert-True ($copy -gt $wait) 'the samples are assembled after the wait'
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
