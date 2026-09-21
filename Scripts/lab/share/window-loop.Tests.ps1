#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test suite for window-loop.ps1's pure helpers, line grammars and stop decision.

.DESCRIPTION
    Runs on macOS under PowerShell 7 (Tier 1 runs it on ubuntu-latest's pwsh) with no external
    dependencies. Self-contained assertion harness, exit code propagated: 0 when every case
    passes, 1 otherwise. Style follows window-rects-probe.Tests.ps1.

    window-loop.ps1 samples the host's window geometry from INSIDE the lab account's session,
    across a relay disconnect. The half that has to run on Windows -- the awareness declaration,
    EnumWindows, the per-tick native calls, the detached lifetime itself -- CANNOT be exercised
    here and is not exercised here; the suite dot-sources the script with -NoRun, which defines
    the functions and touches nothing. What IS driven is every decision a reader of the output
    depends on: the three line grammars, that seq groups a tick with its rows, that the stop
    decision distinguishes a sentinel from a deadline, that tokens stay single tokens, and that
    a window title never reaches a line. Plus source pins for the things the offline path cannot
    observe: that the red-line helpers are REUSED from the probe rather than copied, that the
    awareness declaration precedes the sampling, and that nothing runs under -NoRun.

    window-rects-probe.ps1 is dot-sourced -NoRun first, because that is exactly what the loop
    does on the host: the formatters, the token sanitiser and the title digest have one
    implementation, in the probe, and this suite drives the loop against that same one.

    Fixtures are synthetic. The fixture "titles" are the literal strings lab-fixture-alpha and
    lab-fixture-beta -- no real window title, host name, account name or path appears in this
    file.

.EXAMPLE
    pwsh -NoProfile -File ./window-loop.Tests.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProbeScriptPath = Join-Path $PSScriptRoot 'window-rects-probe.ps1'
$script:SubjectPath = Join-Path $PSScriptRoot 'window-loop.ps1'
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

$script:FixtureTitleA = 'lab-fixture-alpha'
$script:FixtureTitleB = 'lab-fixture-beta'

function New-FixtureRect {
    param([int] $Left, [int] $Top, [int] $Right, [int] $Bottom)
    return [pscustomobject]@{ Left = $Left; Top = $Top; Right = $Right; Bottom = $Bottom }
}

function New-FixturePoint {
    param([int] $X, [int] $Y)
    return [pscustomobject]@{ X = $X; Y = $Y }
}

function New-FixtureHead {
    param()
    return [pscustomobject]@{
        Utc         = '2026-09-18T09:00:00.0000000Z'
        PsVersion   = '5.1.26200.1'
        ProcessId   = 4242
        SessionId   = 3
        IntervalMs  = 250
        MaxSeconds  = 420
        DeadlineUtc = '2026-09-18T09:07:00.0000000Z'
        Awareness   = 2
        SetVia      = 'v2'
    }
}

function New-FixtureTick {
    <#
      Torn and DesktopChanged are added ONLY when asked for, so every case that does not pass
      them drives the shape a tick record had before those fields existed -- which is the same
      shape a partially built record has when a sample threw halfway through.
    #>
    param([int] $Seq = 0, [int] $RectOk = 2, [int] $Selected = 2, [AllowNull()] $Torn = $null, [AllowNull()] $DesktopChanged = $null)
    $tick = [pscustomobject]@{
        Seq      = $Seq
        Utc      = '2026-09-18T09:00:00.2500000Z'
        Cx       = 2560
        Cy       = 1600
        WorkArea = (New-FixtureRect -Left 0 -Top 0 -Right 2560 -Bottom 1520)
        RectOk   = $RectOk
        Selected = $Selected
    }
    if ($null -ne $Torn) { Add-Member -InputObject $tick -MemberType NoteProperty -Name 'Torn' -Value $Torn }
    if ($null -ne $DesktopChanged) { Add-Member -InputObject $tick -MemberType NoteProperty -Name 'DesktopChanged' -Value $DesktopChanged }
    return $tick
}

function New-FixtureDetail {
    <#
      A detailed record as Add-ProbeWindowDetail builds it AFTER the re-read: WindowRect is the
      second read, taken next to the frame, and WindowRectFirst is the one the enumeration pass
      sorted and capped on. -Torn makes the two disagree by one pixel in each edge, which is the
      smallest re-layout the loop has to be able to see.
    #>
    param([long] $Hwnd = 983040, [switch] $Torn)
    $w = New-FixtureWindow
    $w.Hwnd = $Hwnd
    Add-Member -InputObject $w -MemberType NoteProperty -Name 'WindowRectFirst' -Value (New-FixtureRect -Left 54 -Top 0 -Right 754 -Bottom 500)
    if ($Torn) { $w.WindowRect = New-FixtureRect -Left 55 -Top 1 -Right 755 -Bottom 501 }
    return $w
}

function New-FixtureWindow {
    <# A fully detailed record as the probe's Add-ProbeWindowDetail builds it. #>
    param()
    return [pscustomobject]@{
        Handle          = $null
        Hwnd            = 983040
        Visible         = $true
        WindowRect      = (New-FixtureRect -Left 54 -Top 0 -Right 754 -Bottom 500)
        ProcessId       = 4242
        ProcessName     = 'notepad'
        ClassName       = 'Notepad'
        Style           = 0x16CF0000
        ExStyle         = 0x00000100
        Owner           = 0
        Dpi             = 96
        ExtendedFrame   = (New-FixtureRect -Left 61 -Top 0 -Right 747 -Bottom 497)
        ExtendedFrameHr = 0
        ClientScreen    = (New-FixturePoint -X 50 -Y 0)
        ClientRect      = (New-FixtureRect -Left 0 -Top 0 -Right 686 -Bottom 497)
        Title           = $script:FixtureTitleA
    }
}

# The line grammars, as regular expressions, written down once and reused. A field renamed or
# reordered in the script fails every case that uses them. seq= is the join key between a tick
# and its rows, so it is pinned as a bare decimal in both.
$script:LoopHeadPattern = '^\[loop-head\] utc=\S+ ps=\S+ pid=\S+ session=\S+ interval-ms=\d+ max-seconds=\d+ deadline-utc=\S+ awareness=\S+ set-via=(v2|shcore|none)$'
$script:LoopTickPattern = '^\[loop-tick\] seq=\d+ utc=\S+ cx=\S+ cy=\S+ wa=\S+( truncated=true)?( torn=\d+)?( desktop-changed=1)?$'
$script:TickRectPattern = '^\[tick-rect\] seq=\d+ hwnd=\S+ pid=\S+ proc=\S+ class=\S+ style=\S+ dpi=\S+ wr=\S+ ef=\S+ cs=\S+ cr=\S+ owner=\S+ title-len=\S+ title-sha8=\S+$'
$script:LoopDonePattern = '^RESULT: DONE seq=\d+ reason=(sentinel|deadline)$'

# -------------------------------------------------------------------------------------------
# Pre-registered constants
# -------------------------------------------------------------------------------------------

New-Section 'pre-registered constants'

Test-Case 'the stop reasons are a closed set of exactly sentinel / deadline' {
    $r = @($script:LoopStopReasons)
    Assert-Equal 2 $r.Count
    Assert-Equal 'sentinel' $r[0]
    Assert-Equal 'deadline' $r[1]
}

Test-Case 'the local file names are the ones the launcher and the collector agree on' {
    # These three names are the entire contract between window-loop-start.ps1 (which creates the
    # arguments), this script (which honours them) and window-loop-collect.ps1 (which writes the
    # sentinel and reads the out file). Each of the three suites pins the same literals, so a
    # rename in one file is red in the other two rather than silently producing an empty batch.
    Assert-Equal 'macdows-lab' $script:LoopLocalDirName
    Assert-Equal 'window-loop-out.txt' $script:LoopOutName
    Assert-Equal 'window-loop.stop' $script:LoopSentinelName
    Assert-Equal 'window-rects-probe.ps1' $script:LoopProbeName
    Assert-Equal 'window-loop-out.prev.txt' $script:LoopOutPrevName
}

Test-Case 'the defaults are 420 s at 250 ms, i.e. about 1680 samples at four per second' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:SubjectPath, [ref]$null, [ref]$null)
    $params = @($ast.ParamBlock.Parameters)
    $byName = @{}
    foreach ($p in $params) { $byName[$p.Name.VariablePath.UserPath] = $p }
    Assert-Equal 420 $byName['MaxSeconds'].DefaultValue.Value 'covers one smoke run plus one probe, well under the batch wait'
    Assert-Equal 250 $byName['IntervalMs'].DefaultValue.Value
}

# -------------------------------------------------------------------------------------------
# Format-LoopHeadRow
# -------------------------------------------------------------------------------------------

New-Section 'Format-LoopHeadRow'

Test-Case 'the head line prints the run facts in order, ending with the awareness verdict' {
    $line = Format-LoopHeadRow -Head (New-FixtureHead)
    Assert-Equal '[loop-head] utc=2026-09-18T09:00:00.0000000Z ps=5.1.26200.1 pid=4242 session=3 interval-ms=250 max-seconds=420 deadline-utc=2026-09-18T09:07:00.0000000Z awareness=2 set-via=v2' $line
    Assert-Match $script:LoopHeadPattern $line
}

Test-Case 'a head whose every fact is missing keeps the line shape and claims no awareness route' {
    $line = Format-LoopHeadRow -Head $null
    Assert-Equal '[loop-head] utc=n/a ps=n/a pid=n/a session=n/a interval-ms=n/a max-seconds=n/a deadline-utc=n/a awareness=n/a set-via=none' $line
}

Test-Case 'set-via outside the closed set renders none, so a stray value cannot claim a route' {
    $h = New-FixtureHead
    $h.SetVia = 'manifest'
    Assert-Match ' set-via=none$' (Format-LoopHeadRow -Head $h)
    $h.SetVia = 'shcore'
    Assert-Match ' set-via=shcore$' (Format-LoopHeadRow -Head $h)
}

Test-Case 'the UTC stamps are the probe round-trip format, so the two evidence files join on time' {
    # window-rects-probe.ps1 prints read-utc= with ToString('o', InvariantCulture). If the loop
    # invented its own format the two files could not be laid on one timeline at all.
    $line = Format-LoopHeadRow -Head (New-FixtureHead)
    Assert-Match ' utc=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z ' $line
    Assert-Match ' deadline-utc=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z ' $line
    $stamp = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    Assert-Equal 28 $stamp.Length 'the real stamp is one space-free token'
    Assert-Equal $stamp (ConvertTo-ProbeToken -Value $stamp) 'and survives the sanitiser unchanged'
}

# -------------------------------------------------------------------------------------------
# Format-LoopTickRow
# -------------------------------------------------------------------------------------------

New-Section 'Format-LoopTickRow'

Test-Case 'the tick line prints seq, the sample time and the desktop size of that instant' {
    $line = Format-LoopTickRow -Tick (New-FixtureTick -Seq 7)
    Assert-Equal '[loop-tick] seq=7 utc=2026-09-18T09:00:00.2500000Z cx=2560 cy=1600 wa=0,0,2560,1520' $line
    Assert-Match $script:LoopTickPattern $line
}

Test-Case 'a tick whose native calls all failed keeps the line shape' {
    $t = New-FixtureTick
    $t.Cx = $null
    $t.Cy = $null
    $t.WorkArea = $null
    $line = Format-LoopTickRow -Tick $t
    Assert-Equal '[loop-tick] seq=0 utc=2026-09-18T09:00:00.2500000Z cx=n/a cy=n/a wa=n/a' $line
    Assert-Match $script:LoopTickPattern $line
}

Test-Case 'a work area missing one edge renders wa=n/a, never half a rectangle' {
    $t = New-FixtureTick
    $t.WorkArea = [pscustomobject]@{ Left = 0; Top = 0; Right = 2560 }
    Assert-Match ' wa=n/a$' (Format-LoopTickRow -Tick $t)
}

Test-Case 'truncated=true is appended -- and only appended -- when the cap dropped windows' {
    # The cap is the probe's ProbeMaxRows and the loop uses the same one. A tick that silently
    # dropped the window under study would be unfalsifiable; this is the same rule [host-enum]
    # already carries, derived from the two counts so it cannot contradict them.
    Assert-Match ' wa=0,0,2560,1520$' (Format-LoopTickRow -Tick (New-FixtureTick -RectOk 2 -Selected 2))
    $line = Format-LoopTickRow -Tick (New-FixtureTick -RectOk 70 -Selected 64)
    Assert-Match ' wa=0,0,2560,1520 truncated=true$' $line
    Assert-Match $script:LoopTickPattern $line
    Assert-Match ' wa=0,0,2560,1520$' (Format-LoopTickRow -Tick (New-FixtureTick -RectOk 60 -Selected 64)) 'fewer kept than seen is not truncation'
}

Test-Case 'seq is a bare decimal that counts from zero and never carries a separator' {
    Assert-Match '^\[loop-tick\] seq=0 ' (Format-LoopTickRow -Tick (New-FixtureTick -Seq 0))
    Assert-Match '^\[loop-tick\] seq=1680 ' (Format-LoopTickRow -Tick (New-FixtureTick -Seq 1680))
}

Test-Case 'GOLDEN: a quiet tick renders the pre-torn line byte for byte, with and without truncated' {
    # The first promise of the torn work: a run in which nothing moved must produce EXACTLY the
    # file it produced before the tail fields existed. Both expectations below are the literal
    # strings the script emitted at 58a48ac, pasted in, so any field that starts appearing
    # unconditionally -- torn=0 most of all -- is red here rather than in a batch six hours in.
    Assert-Equal '[loop-tick] seq=0 utc=2026-09-18T09:00:00.2500000Z cx=2560 cy=1600 wa=0,0,2560,1520' `
        (Format-LoopTickRow -Tick (New-FixtureTick))
    Assert-Equal '[loop-tick] seq=9 utc=2026-09-18T09:00:00.2500000Z cx=2560 cy=1600 wa=0,0,2560,1520 truncated=true' `
        (Format-LoopTickRow -Tick (New-FixtureTick -Seq 9 -RectOk 70 -Selected 64))
    # and the same when the counts ARE there and say nothing happened
    Assert-Equal '[loop-tick] seq=0 utc=2026-09-18T09:00:00.2500000Z cx=2560 cy=1600 wa=0,0,2560,1520' `
        (Format-LoopTickRow -Tick (New-FixtureTick -Torn 0 -DesktopChanged $false))
}

Test-Case 'torn= appears only when a window rectangle moved across the two reads, and carries the count' {
    # A torn tick is one whose rows cannot be read as one instant: the enumeration pass and the
    # detail pass saw different geometry, so the reader has to step the anchor back a tick. The
    # count is on the TICK because a re-layout happens once and hits every row of that sample.
    Assert-Match ' wa=0,0,2560,1520 torn=1$' (Format-LoopTickRow -Tick (New-FixtureTick -Torn 1))
    Assert-Match ' wa=0,0,2560,1520 torn=2$' (Format-LoopTickRow -Tick (New-FixtureTick -Torn 2))
    Assert-Match ' wa=0,0,2560,1520 torn=64$' (Format-LoopTickRow -Tick (New-FixtureTick -Torn 64))
    Assert-Match $script:LoopTickPattern (Format-LoopTickRow -Tick (New-FixtureTick -Torn 2))
    Assert-Match ' wa=0,0,2560,1520$' (Format-LoopTickRow -Tick (New-FixtureTick -Torn 0)) 'nothing moved, so the field costs nothing'
    Assert-Match ' wa=0,0,2560,1520$' (Format-LoopTickRow -Tick (New-FixtureTick -Torn 'not-a-number')) 'an uncountable value claims nothing'
}

Test-Case 'desktop-changed=1 appears only when the re-read disagreed, and never reports the re-read values' {
    $line = Format-LoopTickRow -Tick (New-FixtureTick -DesktopChanged $true)
    Assert-Equal '[loop-tick] seq=0 utc=2026-09-18T09:00:00.2500000Z cx=2560 cy=1600 wa=0,0,2560,1520 desktop-changed=1' $line
    Assert-Match $script:LoopTickPattern $line
    Assert-Match ' wa=0,0,2560,1520$' (Format-LoopTickRow -Tick (New-FixtureTick -DesktopChanged $false))
}

Test-Case 'the three tail fields appear in the ONE order truncated / torn / desktop-changed' {
    # A reader gates on the end of the line, so the order is part of the grammar, not a detail
    # of how the row is built. All three at once is the case that pins it.
    $line = Format-LoopTickRow -Tick (New-FixtureTick -Seq 97 -RectOk 70 -Selected 64 -Torn 3 -DesktopChanged $true)
    Assert-Equal '[loop-tick] seq=97 utc=2026-09-18T09:00:00.2500000Z cx=2560 cy=1600 wa=0,0,2560,1520 truncated=true torn=3 desktop-changed=1' $line
    Assert-Match $script:LoopTickPattern $line
    Assert-Equal 9 (@($line -split ' ')).Count 'six fields plus the three tail flags'
    # and each pair on its own, so the order pin cannot be satisfied by luck
    Assert-Match ' truncated=true torn=3$' (Format-LoopTickRow -Tick (New-FixtureTick -RectOk 70 -Selected 64 -Torn 3))
    Assert-Match ' truncated=true desktop-changed=1$' (Format-LoopTickRow -Tick (New-FixtureTick -RectOk 70 -Selected 64 -DesktopChanged $true))
    Assert-Match ' torn=3 desktop-changed=1$' (Format-LoopTickRow -Tick (New-FixtureTick -Torn 3 -DesktopChanged $true))
}

# -------------------------------------------------------------------------------------------
# Test-LoopRectTorn / Measure-LoopTornWindows / Test-LoopDesktopChanged
# -------------------------------------------------------------------------------------------

New-Section 'torn and desktop-change decisions'

Test-Case 'a rectangle is torn when the two reads disagree on ANY edge, and only then' {
    $a = New-FixtureRect -Left 54 -Top 0 -Right 754 -Bottom 500
    Assert-True (-not (Test-LoopRectTorn -Before $a -After (New-FixtureRect -Left 54 -Top 0 -Right 754 -Bottom 500)))
    foreach ($moved in @(
        (New-FixtureRect -Left 55 -Top 0 -Right 754 -Bottom 500),
        (New-FixtureRect -Left 54 -Top 1 -Right 754 -Bottom 500),
        (New-FixtureRect -Left 54 -Top 0 -Right 755 -Bottom 500),
        (New-FixtureRect -Left 54 -Top 0 -Right 754 -Bottom 501))) {
        Assert-True (Test-LoopRectTorn -Before $a -After $moved) 'one edge is enough'
    }
}

Test-Case 'a read that failed on one side only is torn; two failed reads claim nothing' {
    # n/a against a rectangle means the window died or the call was refused between the two
    # reads, which is exactly the kind of tick an anchor must not be taken from. Two failures
    # in a row say nothing about movement, so they are not counted as one.
    $a = New-FixtureRect -Left 54 -Top 0 -Right 754 -Bottom 500
    Assert-True (Test-LoopRectTorn -Before $a -After $null)
    Assert-True (Test-LoopRectTorn -Before $null -After $a)
    Assert-True (-not (Test-LoopRectTorn -Before $null -After $null))
    # half a rectangle is n/a to the formatter, so it is n/a here too
    Assert-True (-not (Test-LoopRectTorn -Before $null -After ([pscustomobject]@{ Left = 0; Top = 0; Right = 10 })))
}

Test-Case 'the tick count is how many of the selected windows moved, counted over the same records the rows use' {
    Assert-Equal 0 (Measure-LoopTornWindows -Windows @())
    Assert-Equal 0 (Measure-LoopTornWindows -Windows $null)
    Assert-Equal 0 (Measure-LoopTornWindows -Windows @((New-FixtureDetail), (New-FixtureDetail -Hwnd 2)))
    Assert-Equal 1 (Measure-LoopTornWindows -Windows @((New-FixtureDetail -Torn), (New-FixtureDetail -Hwnd 2)))
    Assert-Equal 2 (Measure-LoopTornWindows -Windows @((New-FixtureDetail -Torn), (New-FixtureDetail -Hwnd 2 -Torn)))
}

Test-Case 'a record from before the re-read existed counts as not torn, never as torn' {
    # WindowRectFirst absent means nothing can be claimed; claiming torn there would mark every
    # tick of an older file.
    Assert-Equal 0 (Measure-LoopTornWindows -Windows @((New-FixtureWindow)))
}

Test-Case 'the desktop changed when cx, cy OR the work area moved across the detail pass' {
    $wa = New-FixtureRect -Left 0 -Top 0 -Right 2560 -Bottom 1520
    $same = @{ BeforeCx = 2560; BeforeCy = 1440; BeforeWorkArea = $wa; AfterCx = 2560; AfterCy = 1440; AfterWorkArea = $wa }
    Assert-True (-not (Test-LoopDesktopChanged @same))
    Assert-True (Test-LoopDesktopChanged -BeforeCx 2560 -BeforeCy 1440 -BeforeWorkArea $wa -AfterCx 1280 -AfterCy 1440 -AfterWorkArea $wa) 'cx moved'
    Assert-True (Test-LoopDesktopChanged -BeforeCx 2560 -BeforeCy 1440 -BeforeWorkArea $wa -AfterCx 2560 -AfterCy 1410 -AfterWorkArea $wa) 'cy moved'
    # the work area alone is enough: a taskbar that resizes without the screen resizing still
    # means the session was re-laid-out under the rows being read
    Assert-True (Test-LoopDesktopChanged -BeforeCx 2560 -BeforeCy 1440 -BeforeWorkArea $wa `
        -AfterCx 2560 -AfterCy 1440 -AfterWorkArea (New-FixtureRect -Left 0 -Top 0 -Right 2560 -Bottom 1400)) 'the work area alone moved'
}

Test-Case 'a metric that could not be read on ONE side is a change; refused on both sides is not' {
    $wa = New-FixtureRect -Left 0 -Top 0 -Right 2560 -Bottom 1520
    Assert-True (Test-LoopDesktopChanged -BeforeCx 2560 -BeforeCy 1440 -BeforeWorkArea $wa -AfterCx $null -AfterCy 1440 -AfterWorkArea $wa)
    Assert-True (Test-LoopDesktopChanged -BeforeCx 2560 -BeforeCy 1440 -BeforeWorkArea $wa -AfterCx 2560 -AfterCy 1440 -AfterWorkArea $null)
    Assert-True (-not (Test-LoopDesktopChanged -BeforeCx $null -BeforeCy $null -BeforeWorkArea $null -AfterCx $null -AfterCy $null -AfterWorkArea $null)) `
        'a runner that refuses every metric call must not mark every tick'
}

# -------------------------------------------------------------------------------------------
# Format-TickRectRow
# -------------------------------------------------------------------------------------------

New-Section 'Format-TickRectRow'

Test-Case 'the rect row leads with the tick it belongs to and then the window geometry' {
    $line = Format-TickRectRow -Seq 7 -Window (New-FixtureWindow)
    Assert-Equal '[tick-rect] seq=7 hwnd=983040 pid=4242 proc=notepad class=Notepad style=0x16CF0000 dpi=96 wr=54,0,754,500 ef=61,0,747,497 cs=50,0 cr=686,497 owner=0 title-len=17 title-sha8=00eee4a7' $line
    Assert-Match $script:TickRectPattern $line
}

Test-Case 'owner sits between cr and title-len and carries the probe row own value, so the About join works on loop rows too' {
    # Controller addendum 2026-09-21: the lab's About window is identified by hwnd + class +
    # proc + owner=0 together. owner is stable per window, so it is the one field kept here
    # despite not moving; it comes from the same Owner field [host-rect] prints.
    $w = New-FixtureWindow
    Assert-Match ' cr=686,497 owner=0 title-len=' (Format-TickRectRow -Seq 0 -Window $w)
    $w.Owner = 2148007936
    Assert-Match ' cr=686,497 owner=2148007936 title-len=' (Format-TickRectRow -Seq 0 -Window $w)
    $w.Owner = $null
    Assert-Match ' cr=686,497 owner=n/a title-len=' (Format-TickRectRow -Seq 0 -Window $w)
    # and the probe's own row for the same record agrees on the value, because both read Owner
    Assert-Match ' owner=0 ' (Format-HostRectRow -Window (New-FixtureWindow))
}

Test-Case 'a tick and its rows carry the SAME seq, which is what groups one sample' {
    $seq = 12
    $tick = Format-LoopTickRow -Tick (New-FixtureTick -Seq $seq)
    $rows = @((Format-TickRectRow -Seq $seq -Window (New-FixtureWindow)), (Format-TickRectRow -Seq $seq -Window (New-FixtureWindow)))
    Assert-Match '^\[loop-tick\] seq=12 ' $tick
    foreach ($r in $rows) { Assert-Match '^\[tick-rect\] seq=12 ' $r }
}

Test-Case 'a window whose every detail call failed still renders one well-formed row' {
    $w = [pscustomobject]@{ Hwnd = $null }
    $line = Format-TickRectRow -Seq 0 -Window $w
    Assert-Equal '[tick-rect] seq=0 hwnd=n/a pid=n/a proc=n/a class=n/a style=n/a dpi=n/a wr=n/a ef=n/a cs=n/a cr=n/a owner=n/a title-len=n/a title-sha8=none' $line
    Assert-Match $script:TickRectPattern $line
}

Test-Case 'class and process names are sanitised to one token, so a spacy class cannot shift the row' {
    $w = New-FixtureWindow
    $w.ClassName = 'class with spaces'
    $w.ProcessName = "weird`tname"
    $line = Format-TickRectRow -Seq 3 -Window $w
    Assert-Match $script:TickRectPattern $line
    Assert-Match ' proc=weird\?name class=class\?with\?spaces ' $line
    Assert-Equal 15 (@($line -split ' ')).Count 'the row is exactly fifteen space-separated tokens'
}

Test-Case 'RED LINE: the title text never reaches a row -- only its length and its digest' {
    $w = New-FixtureWindow
    $line = Format-TickRectRow -Seq 0 -Window $w
    Assert-True ($line -notlike "*$($script:FixtureTitleA)*") 'the title text must not appear'
    Assert-Match ' title-len=17 title-sha8=00eee4a7$' $line
    $w.Title = $script:FixtureTitleB
    $line2 = Format-TickRectRow -Seq 0 -Window $w
    Assert-True ($line2 -notlike "*$($script:FixtureTitleB)*") 'the second title text must not appear either'
    Assert-Match ' title-len=16 title-sha8=279b8a26$' $line2
    $w.Title = ''
    Assert-Match ' title-len=0 title-sha8=none$' (Format-TickRectRow -Seq 0 -Window $w)
}

Test-Case 'RED LINE: a whole tick of rows carries no title text at all' {
    $a = New-FixtureWindow
    $b = New-FixtureWindow
    $b.Hwnd = 2148007936
    $b.Title = $script:FixtureTitleB
    $block = @((Format-LoopTickRow -Tick (New-FixtureTick -Seq 4)), (Format-TickRectRow -Seq 4 -Window $a), (Format-TickRectRow -Seq 4 -Window $b)) -join "`n"
    Assert-True (-not $block.Contains($script:FixtureTitleA)) 'no alpha title anywhere in the block'
    Assert-True (-not $block.Contains($script:FixtureTitleB)) 'no beta title anywhere in the block'
    foreach ($ch in @($block.ToCharArray())) {
        Assert-True ([int][char]$ch -lt 128) 'every byte the loop can write is ASCII'
    }
}

# -------------------------------------------------------------------------------------------
# Test-LoopShouldStop
# -------------------------------------------------------------------------------------------

New-Section 'Test-LoopShouldStop'

$script:StopNow = [datetime]::ParseExact('2026-09-18T09:03:00Z', "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)

Test-Case 'no sentinel and time left means keep going' {
    Assert-Equal '' (Test-LoopShouldStop -Now $script:StopNow -Deadline $script:StopNow.AddSeconds(60) -SentinelPresent $false)
}

Test-Case 'the sentinel stops the run and says so' {
    Assert-Equal 'sentinel' (Test-LoopShouldStop -Now $script:StopNow -Deadline $script:StopNow.AddSeconds(60) -SentinelPresent $true)
}

Test-Case 'the deadline stops the run even with no sentinel -- a lost collector cannot leak a process' {
    Assert-Equal 'deadline' (Test-LoopShouldStop -Now $script:StopNow -Deadline $script:StopNow.AddSeconds(-1) -SentinelPresent $false)
    Assert-Equal 'deadline' (Test-LoopShouldStop -Now $script:StopNow -Deadline $script:StopNow -SentinelPresent $false) 'the deadline instant itself is already over'
}

Test-Case 'the sentinel wins over the deadline, so a collected run is never reported as abandoned' {
    # Both true at once is the normal end of a long batch. Reporting deadline there would make
    # "the sentinel never arrived" -- a real transport failure -- indistinguishable from success.
    Assert-Equal 'sentinel' (Test-LoopShouldStop -Now $script:StopNow -Deadline $script:StopNow.AddSeconds(-30) -SentinelPresent $true)
}

# -------------------------------------------------------------------------------------------
# Format-LoopResultLine
# -------------------------------------------------------------------------------------------

New-Section 'Format-LoopResultLine'

Test-Case 'a sentinel stop and a deadline stop are two visibly different endings' {
    $a = Format-LoopResultLine -Seq 1679 -Reason 'sentinel'
    $b = Format-LoopResultLine -Seq 1679 -Reason 'deadline'
    Assert-Equal 'RESULT: DONE seq=1679 reason=sentinel' $a
    Assert-Equal 'RESULT: DONE seq=1679 reason=deadline' $b
    Assert-Match $script:LoopDonePattern $a
    Assert-Match $script:LoopDonePattern $b
}

Test-Case 'a reason outside the closed set renders n/a rather than being pasted into the line' {
    Assert-Equal 'RESULT: DONE seq=0 reason=n/a' (Format-LoopResultLine -Seq 0 -Reason 'because')
    Assert-Equal 'RESULT: DONE seq=0 reason=n/a' (Format-LoopResultLine -Seq 0 -Reason $null)
}

Test-Case 'the seq on the RESULT line is the last sample taken, so it joins to a real tick' {
    Assert-Match '^RESULT: DONE seq=0 ' (Format-LoopResultLine -Seq 0 -Reason 'sentinel')
    Assert-Match '^RESULT: DONE seq=41 ' (Format-LoopResultLine -Seq 41 -Reason 'deadline')
}

# -------------------------------------------------------------------------------------------
# Resolve-LoopPath
# -------------------------------------------------------------------------------------------

New-Section 'Resolve-LoopPath'

Test-Case 'a given path is honoured verbatim, spaces and all' {
    Assert-Equal 'C:\Temp\dir with space\out.txt' (Resolve-LoopPath -Value 'C:\Temp\dir with space\out.txt' -Root 'C:\Root' -Name 'window-loop-out.txt')
}

Test-Case 'an empty path falls back to the local lab directory rather than crashing the run' {
    # The launcher always passes all three paths. The fallback exists so that a hand-started run
    # (or a launcher that lost an argument) still produces evidence instead of dying before the
    # first line, which would be indistinguishable from "the process never survived".
    Assert-Equal 'C:\Root\window-loop-out.txt' (Resolve-LoopPath -Value '' -Root 'C:\Root' -Name 'window-loop-out.txt')
    Assert-Equal 'C:\Root\window-loop-out.txt' (Resolve-LoopPath -Value $null -Root 'C:\Root' -Name 'window-loop-out.txt')
    Assert-Equal 'C:\Root\window-loop-out.txt' (Resolve-LoopPath -Value '   ' -Root 'C:\Root' -Name 'window-loop-out.txt')
}

Test-Case 'the fallback builds a WINDOWS path and never doubles the separator' {
    # Join-Path is deliberately not used: it resolves the drive qualifier through the provider
    # and throws on C:\ from a runner that has no C: drive -- which is every runner this suite
    # uses. The separator is therefore written out, and a root that already ends in one must not
    # produce C:\Root\\file.
    Assert-Equal 'C:\Root\window-loop.stop' (Resolve-LoopPath -Value '' -Root 'C:\Root\' -Name 'window-loop.stop')
    Assert-Equal 'C:\Root\window-loop.stop' (Resolve-LoopPath -Value '' -Root 'C:\Root/' -Name 'window-loop.stop')
    Assert-True ((Resolve-LoopPath -Value '' -Root 'C:\Root' -Name 'x.txt') -notmatch '\\\\') 'no doubled separator'
}

# -------------------------------------------------------------------------------------------
# The whole run -- driven end to end with the native surface stubbed out
# -------------------------------------------------------------------------------------------

New-Section 'Invoke-WindowLoop'

function New-StubProbe {
    <#
      A probe stand-in for the run: it dot-sources the real window-rects-probe.ps1 (so every
      helper, constant and red-line rule under test is the real one) and then replaces
      Initialize-ProbeNative with a no-op, because the Add-Type surface it compiles is Windows
      P/Invoke. Every [MacdowsLab...] call in the run then fails inside Invoke-ProbeCall and
      degrades to n/a, exactly as it would on a host that refused the call.

      The stub is a FILE because that is how the loop consumes it: -ProbePath is dot-sourced
      inside Invoke-WindowLoop, and whether that dot-source makes the probe's helpers and
      $script: constants reachable from there is the single riskiest assumption in this script.
      Nothing but a real run can answer it.
    #>
    param([string] $Directory, [int] $Windows = 0, [int] $Torn = 0)
    $path = Join-Path $Directory 'stub-probe.ps1'
    $escaped = $script:ProbeScriptPath.Replace("'", "''")
    $body = @"
param([switch] `$NoRun)
. '$escaped' -NoRun
function Initialize-ProbeNative { }
"@
    if ($Windows -gt 0) {
        # Synthetic windows, injected at the SELECTION: EnumTopLevel is a .NET static method and
        # cannot be overridden from here, so a stubbed run sees no handles at all and would
        # otherwise never write a [tick-rect] row. Overriding the selection and the detail pass
        # is enough to drive both -- and the detail pass is where "the first read and the second
        # read disagree" can be synthesised, which no offline runner can produce for real. The
        # counts below are written into the file as literals so the stub depends on no scope.
        $body += @"

function Select-ProbeWindows {
    param(`$Windows, `$Cap)
    `$out = New-Object System.Collections.ArrayList
    for (`$i = 0; `$i -lt $Windows; `$i++) {
        [void]`$out.Add([pscustomobject]@{
            Handle = `$null
            Hwnd = (983040 + `$i)
            Visible = `$true
            WindowRect = [pscustomobject]@{ Left = 10; Top = 20; Right = 110; Bottom = 120 }
        })
    }
    return @(`$out.ToArray())
}

function Add-ProbeWindowDetail {
    param(`$Window, `$ProcessNameCache)
    `$first = `$Window.WindowRect
    `$second = `$first
    if ((([int]`$Window.Hwnd) - 983040) -lt $Torn) {
        `$second = [pscustomobject]@{ Left = 11; Top = 21; Right = 111; Bottom = 121 }
    }
    return [pscustomobject]@{
        Handle = `$null
        Hwnd = `$Window.Hwnd
        Visible = `$true
        WindowRect = `$second
        WindowRectFirst = `$first
        ProcessId = 4242
        ProcessName = 'notepad'
        ClassName = 'Notepad'
        Style = 0x16CF0000
        ExStyle = 0
        Owner = 0
        Dpi = 96
        ExtendedFrame = `$null
        ExtendedFrameHr = 0
        ClientScreen = `$null
        ClientRect = `$null
        Title = 'lab-fixture-alpha'
    }
}
"@
    }
    [IO.File]::WriteAllText($path, $body)
    return $path
}

function Invoke-LoopFixtureRun {
    <#
      Runs Invoke-WindowLoop into a throw-away directory and returns the lines it wrote.
      USERPROFILE is pointed at that directory for the duration: the run computes a local root
      from it before resolving its arguments, and this runner has no such variable.
    #>
    param([scriptblock] $Body)
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('window-loop-tests-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    $hadProfile = Test-Path Env:\USERPROFILE
    $beforeProfile = ''
    if ($hadProfile) { $beforeProfile = $env:USERPROFILE }
    try {
        $env:USERPROFILE = $dir
        $out = Join-Path $dir 'window-loop-out.txt'
        & $Body $dir $out
        if (-not [IO.File]::Exists($out)) { return $null }
        return @([IO.File]::ReadAllLines($out))
    } finally {
        if ($hadProfile) { $env:USERPROFILE = $beforeProfile } else { Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

Test-Case 'a sentinel that is already there still leaves one measured sample, and says sentinel' {
    $lines = @(Invoke-LoopFixtureRun -Body {
        param($Dir, $Out)
        $sentinel = Join-Path $Dir 'window-loop.stop'
        [IO.File]::WriteAllText($sentinel, '')
        Invoke-WindowLoop -OutPath $Out -MaxSeconds 30 -IntervalMs 10 `
            -SentinelPath $sentinel -ProbePath (New-StubProbe -Directory $Dir)
    })
    Assert-Equal 3 $lines.Count 'head, one tick, RESULT -- the first sample is always taken'
    Assert-Match $script:LoopHeadPattern $lines[0]
    Assert-Match $script:LoopTickPattern $lines[1]
    Assert-Match '^\[loop-tick\] seq=0 ' $lines[1]
    Assert-Match ' cx=n/a cy=n/a wa=n/a$' $lines[1] 'every native call was refused here, so every value is n/a'
    Assert-Equal 'RESULT: DONE seq=0 reason=sentinel' $lines[2]
    Assert-Match ' interval-ms=10 max-seconds=30 ' $lines[0] 'the head reports the bounds it was given'
    Assert-Match ' set-via=none$' $lines[0] 'no awareness could be declared on this runner'
}

Test-Case 'a passed deadline with no sentinel ends the run and says deadline, visibly' {
    # The degradation the lane has to be able to see: the data is good but the collector never
    # reached the loop. If this ending were spelled the same as a collected one, a broken
    # collection leg would be invisible until the next pair lost its samples too.
    $lines = @(Invoke-LoopFixtureRun -Body {
        param($Dir, $Out)
        Invoke-WindowLoop -OutPath $Out -MaxSeconds 0 -IntervalMs 10 `
            -SentinelPath (Join-Path $Dir 'window-loop.stop') -ProbePath (New-StubProbe -Directory $Dir)
    })
    Assert-Equal 3 $lines.Count
    Assert-Equal 'RESULT: DONE seq=0 reason=deadline' $lines[2]
}

Test-Case 'the run writes the probe helpers real output -- the dot-source inside the run works' {
    # If -ProbePath were dot-sourced into a scope the sampling cannot see, the run would die on
    # the first Format-* call instead of producing a graded file. This is the case that says the
    # reuse design holds at run time and not only in the source pins.
    $lines = @(Invoke-LoopFixtureRun -Body {
        param($Dir, $Out)
        $sentinel = Join-Path $Dir 'window-loop.stop'
        [IO.File]::WriteAllText($sentinel, '')
        Invoke-WindowLoop -OutPath $Out -MaxSeconds 30 -IntervalMs 10 `
            -SentinelPath $sentinel -ProbePath (New-StubProbe -Directory $Dir)
    })
    Assert-Equal 0 (@($lines | Where-Object { $_ -like 'RESULT: FAILED*' })).Count 'no stage failed'
    Assert-Match '^\[loop-head\] utc=\d{4}-' $lines[0] 'the probe token sanitiser rendered the stamp'
    foreach ($ch in @((($lines -join "`n")).ToCharArray())) {
        Assert-True ([int][char]$ch -lt 128) 'the file is pure ASCII'
    }
}

Test-Case 'a tick whose windows moved between the two reads says torn= on its OWN tick line' {
    # End to end, because the thing under test is WHEN the tick line is assembled: the count can
    # only be on it if the detail pass ran first. A run that writes the tick line before the
    # rows -- the shape this script had at 58a48ac -- produces the same rows and no torn=.
    $lines = @(Invoke-LoopFixtureRun -Body {
        param($Dir, $Out)
        $sentinel = Join-Path $Dir 'window-loop.stop'
        [IO.File]::WriteAllText($sentinel, '')
        Invoke-WindowLoop -OutPath $Out -MaxSeconds 30 -IntervalMs 10 `
            -SentinelPath $sentinel -ProbePath (New-StubProbe -Directory $Dir -Windows 3 -Torn 1)
    })
    Assert-Equal 6 $lines.Count 'head, tick, three rows, RESULT'
    Assert-Match $script:LoopTickPattern $lines[1]
    Assert-Match ' torn=1$' $lines[1] 'one of the three windows moved across the two reads'
    Assert-Equal 3 (@($lines | Where-Object { $_ -like '`[tick-rect`]*' })).Count
}

Test-Case 'the torn count is the number of windows that moved, not whether any did' {
    $lines = @(Invoke-LoopFixtureRun -Body {
        param($Dir, $Out)
        $sentinel = Join-Path $Dir 'window-loop.stop'
        [IO.File]::WriteAllText($sentinel, '')
        Invoke-WindowLoop -OutPath $Out -MaxSeconds 30 -IntervalMs 10 `
            -SentinelPath $sentinel -ProbePath (New-StubProbe -Directory $Dir -Windows 2 -Torn 2)
    })
    Assert-Match ' torn=2$' $lines[1]
}

Test-Case 'a tick whose windows held still carries no torn= at all, and its rows are unchanged' {
    $lines = @(Invoke-LoopFixtureRun -Body {
        param($Dir, $Out)
        $sentinel = Join-Path $Dir 'window-loop.stop'
        [IO.File]::WriteAllText($sentinel, '')
        Invoke-WindowLoop -OutPath $Out -MaxSeconds 30 -IntervalMs 10 `
            -SentinelPath $sentinel -ProbePath (New-StubProbe -Directory $Dir -Windows 2 -Torn 0)
    })
    Assert-Equal 5 $lines.Count
    Assert-True (-not ($lines[1] -like '*torn=*')) 'nothing moved, so the tick line is the quiet one'
    Assert-True (-not ($lines[1] -like '*desktop-changed*')) 'no metric could be read at all here, and n/a twice is not a change'
    Assert-Match $script:LoopTickPattern $lines[1]
    # Gate r1 I1 (2026-09-21): the line-level golden strings above cover the tick line; these two
    # cover the rows, so "a quiet run is byte for byte the file it always was" is pinned for the
    # whole tick group and not only for its first line. The stub's rows are fully determined.
    Assert-Equal '[tick-rect] seq=0 hwnd=983040 pid=4242 proc=notepad class=Notepad style=0x16CF0000 dpi=96 wr=10,20,110,120 ef=n/a cs=n/a cr=n/a owner=0 title-len=17 title-sha8=00eee4a7' $lines[2] 'a quiet row is byte for byte the row it always was'
    Assert-Equal '[tick-rect] seq=0 hwnd=983041 pid=4242 proc=notepad class=Notepad style=0x16CF0000 dpi=96 wr=10,20,110,120 ef=n/a cs=n/a cr=n/a owner=0 title-len=17 title-sha8=00eee4a7' $lines[3] 'and so is the second one'
}

Test-Case 'the row reports the SECOND read, and a torn row differs from the rectangle it was selected on' {
    # The C half of the fix: wr= on the row is the re-read taken next to ef/cs/cr, not the one
    # the enumeration pass sorted with. The stub's torn window is selected on 10,20,110,120 and
    # re-read at 11,21,111,121, so the row must carry the latter.
    $lines = @(Invoke-LoopFixtureRun -Body {
        param($Dir, $Out)
        $sentinel = Join-Path $Dir 'window-loop.stop'
        [IO.File]::WriteAllText($sentinel, '')
        Invoke-WindowLoop -OutPath $Out -MaxSeconds 30 -IntervalMs 10 `
            -SentinelPath $sentinel -ProbePath (New-StubProbe -Directory $Dir -Windows 2 -Torn 1)
    })
    $rows = @($lines | Where-Object { $_ -like '`[tick-rect`]*' })
    Assert-Equal 2 $rows.Count
    Assert-Match ' wr=11,21,111,121 ' $rows[0] 'the torn window reports the re-read'
    Assert-Match ' wr=10,20,110,120 ' $rows[1] 'the still window reports the same rectangle either way'
    foreach ($r in $rows) { Assert-Match $script:TickRectPattern $r 'the row grammar is untouched by any of this' }
}

Test-Case 'FILE ORDER: the tick line still precedes the rows that carry its seq, tail fields and all' {
    # Assembling the tick line after the detail pass must not reorder the FILE: a reader groups
    # by seq and relies on the tick arriving first, and the collector fixtures are written that
    # way too.
    $lines = @(Invoke-LoopFixtureRun -Body {
        param($Dir, $Out)
        $sentinel = Join-Path $Dir 'window-loop.stop'
        [IO.File]::WriteAllText($sentinel, '')
        Invoke-WindowLoop -OutPath $Out -MaxSeconds 30 -IntervalMs 10 `
            -SentinelPath $sentinel -ProbePath (New-StubProbe -Directory $Dir -Windows 2 -Torn 2)
    })
    Assert-Match $script:LoopHeadPattern $lines[0]
    Assert-Match '^\[loop-tick\] seq=0 ' $lines[1]
    Assert-Match ' torn=2$' $lines[1]
    Assert-Match '^\[tick-rect\] seq=0 ' $lines[2]
    Assert-Match '^\[tick-rect\] seq=0 ' $lines[3]
    Assert-Equal 'RESULT: DONE seq=0 reason=sentinel' $lines[4]
}

Test-Case 'a probe that cannot be dot-sourced writes a one-line file naming that stage' {
    # The earliest failure this script can have. A one-line file is a real result: it says the
    # process ran and could not find its helpers, which is a different diagnosis from an absent
    # file (the process never started or never survived).
    $lines = @(Invoke-LoopFixtureRun -Body {
        param($Dir, $Out)
        Invoke-WindowLoop -OutPath $Out -MaxSeconds 30 -IntervalMs 10 `
            -SentinelPath (Join-Path $Dir 'window-loop.stop') -ProbePath (Join-Path $Dir 'not-staged.ps1')
    })
    Assert-Equal 1 $lines.Count 'nothing had been produced yet, so nothing but the trailer is written'
    Assert-Match '^RESULT: FAILED probe/[A-Za-z]+$' $lines[0]
    Assert-True (-not $lines[0].Contains('not-staged')) 'the exception message, which carries a path, never reaches the file'
}

# -------------------------------------------------------------------------------------------
# Source pins -- properties the offline path cannot observe by running the script
# -------------------------------------------------------------------------------------------

New-Section 'source pins'

$script:SubjectSource = [IO.File]::ReadAllText($script:SubjectPath)

Test-Case 'the script takes exactly the six documented parameters' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:SubjectPath, [ref]$null, [ref]$null)
    $params = @($ast.ParamBlock.Parameters)
    $want = @('OutPath', 'MaxSeconds', 'IntervalMs', 'SentinelPath', 'ProbePath', 'NoRun')
    Assert-Equal $want.Count $params.Count
    for ($i = 0; $i -lt $want.Count; $i++) { Assert-Equal $want[$i] $params[$i].Name.VariablePath.UserPath "parameter $i" }
    Assert-Equal 'switch' $params[5].StaticType.Name.ToLowerInvariant().Substring(0, 6)
}

Test-Case 'RED LINE: the red-line helpers are REUSED from the probe, never redefined here' {
    # Copying ConvertTo-TitleSha8 or ConvertTo-ProbeToken would give the lab two implementations
    # of the same promise, free to drift apart. The loop dot-sources the probe instead; this case
    # is what keeps the copy from ever landing.
    foreach ($owned in @('ConvertTo-TitleSha8', 'ConvertTo-ProbeToken', 'Format-ProbeInt', 'Format-Rect', 'Format-Size', 'Format-Point', 'Format-ProbeHex32', 'Select-ProbeWindows', 'Add-ProbeWindowDetail', 'Get-ProbeWindowBase', 'Invoke-ProbeCall', 'Initialize-ProbeNative')) {
        Assert-True (-not ($script:SubjectSource -match ('(?m)^\s*function\s+' + [regex]::Escape($owned) + '\b'))) "[$owned] belongs to window-rects-probe.ps1 and must not be redefined here"
    }
    Assert-Equal 0 ([regex]::Matches($script:SubjectSource, 'Add-Type')).Count 'the P/Invoke surface is compiled by the probe, in one place'
}

Test-Case 'RED LINE: no field named title and no direct window-text call anywhere in the file' {
    Assert-True (-not ($script:SubjectSource -match "'title='")) 'no field named title'
    Assert-True (-not ($script:SubjectSource -match 'GetWindowText')) 'the loop never calls for window text itself'
    Assert-True ($script:SubjectSource.Contains("'title-len='")) 'the row reports the title length'
    Assert-True ($script:SubjectSource.Contains("'title-sha8='")) 'the row reports the title digest'
}

Test-Case 'the run dot-sources the probe with -NoRun, so loading it can never start a second probe' {
    Assert-Match '\.\s+\$probeScript\s+-NoRun' $script:SubjectSource
    Assert-Equal 0 ([regex]::Matches($script:SubjectSource, '(?m)^\s*Invoke-WindowRectsProbe')).Count 'the loop never starts the probe run'
}

Test-Case 'the awareness declaration precedes every sampling call in the run' {
    $start = $script:SubjectSource.IndexOf('function Invoke-WindowLoop')
    Assert-True ($start -gt 0) 'the run function is present'
    $body = $script:SubjectSource.Substring($start)
    $awareness = $body.IndexOf('SetPerMonitorAwareV2')
    Assert-True ($awareness -gt 0) 'the run declares per-monitor awareness'
    foreach ($later in @('CurrentAwareness()', 'MetricOf(', 'WorkAreaOf(', 'EnumTopLevel()', 'Get-ProbeWindowBase', 'Add-ProbeWindowDetail')) {
        $at = $body.IndexOf($later)
        Assert-True ($at -gt $awareness) "[$later] must be called after the awareness declaration (found at $at, awareness at $awareness)"
    }
}

Test-Case 'the run finishes with $OutPath BEFORE dot-sourcing the probe, which overwrites it' {
    # Dot-sourcing a script BINDS ITS PARAMETERS into the current scope. window-rects-probe.ps1
    # takes -OutPath, defaulting to \\tsclient\lab\window-rects-out.txt, so from the dot-source
    # onwards THIS function's own $OutPath parameter holds that UNC path instead of the caller's
    # argument -- a drive that is gone by the time the samples matter. The resolved path is
    # captured before, and nothing may read the parameter after. Verified by experiment.
    $from = $script:SubjectSource.IndexOf('function Invoke-WindowLoop')
    $to = $script:SubjectSource.LastIndexOf('if (-not $NoRun) {')
    Assert-True ($from -gt 0 -and $to -gt $from) 'the run function and the guard are both present'
    $body = $script:SubjectSource.Substring($from, $to - $from)
    $lastRead = $body.LastIndexOf('$OutPath')
    $dotSource = $body.IndexOf('. $probeScript')
    Assert-True ($lastRead -gt 0 -and $dotSource -gt 0) 'both the parameter and the dot-source are in the run function'
    Assert-True ($lastRead -lt $dotSource) "the last read of `$OutPath (at $lastRead) must precede the dot-source (at $dotSource)"
    Assert-True ($body.IndexOf('$outFile') -lt $dotSource) 'the resolved path is captured before the dot-source too'
}

Test-Case 'every sample is flushed as it is written, so a killed run leaves a readable prefix' {
    # The load-bearing unknown of this lane is whether a detached process survives the relay
    # disconnect at all. A buffered writer would turn "it survived for four minutes and was then
    # killed" into an empty file, i.e. into the same evidence as "it never started".
    #
    # Scoped to the SAMPLING LOOP, not to the whole function (gate r1 m1): Invoke-WindowLoop has
    # four Flush() calls -- head, tick, result and catch -- so a whole-body search claims a
    # per-tick property it is not checking, and a mutant that deletes the tick flush stays green.
    $start = $script:SubjectSource.IndexOf('function Invoke-WindowLoop')
    Assert-True ($start -gt 0) 'the run function is present'
    $body = $script:SubjectSource.Substring($start)
    Assert-True ($body.Contains('AutoFlush')) 'the writer flushes on every line'
    $loopFrom = $body.IndexOf('while ($true) {')
    $loopTo = $body.IndexOf("`$stage = 'result'")
    Assert-True ($loopFrom -gt 0 -and $loopTo -gt $loopFrom) 'the sampling loop and the result stage are both present'
    $tickBody = $body.Substring($loopFrom, $loopTo - $loopFrom)
    Assert-Equal 1 ([regex]::Matches($tickBody, '\$writer\.Flush\(\)')).Count 'the tick loop flushes exactly once per sample'
}

Test-Case 'the tick line is ASSEMBLED after the detail pass and still WRITTEN before its rows' {
    # Two properties at once, and they pull in opposite directions. torn= and desktop-changed=
    # are facts the detail pass produces, so the line cannot be built until it has run; the file
    # must nevertheless keep the tick ahead of its rows, which is the grouping contract. The
    # rows are therefore buffered for one tick. Source order is the only offline evidence for
    # the first half beyond the stubbed run.
    $start = $script:SubjectSource.IndexOf('function Invoke-WindowLoop')
    Assert-True ($start -gt 0) 'the run function is present'
    $body = $script:SubjectSource.Substring($start)
    $loopFrom = $body.IndexOf('while ($true) {')
    $loopTo = $body.IndexOf("`$stage = 'result'")
    Assert-True ($loopFrom -gt 0 -and $loopTo -gt $loopFrom) 'the sampling loop is present'
    $tickBody = $body.Substring($loopFrom, $loopTo - $loopFrom)
    $detail = $tickBody.IndexOf('Add-ProbeWindowDetail')
    $assemble = $tickBody.IndexOf('Format-LoopTickRow')
    $rows = $tickBody.IndexOf('Format-TickRectRow')
    Assert-True ($detail -gt 0 -and $assemble -gt 0 -and $rows -gt 0) 'all three steps are in the tick body'
    Assert-True ($detail -lt $assemble) "the detail pass (at $detail) must run before the tick line is built (at $assemble)"
    Assert-True ($assemble -lt $rows) "the tick line (at $assemble) must be written before its rows (at $rows)"
}

Test-Case 'the desktop metrics are re-read AFTER the detail pass, and the line still reports the opening values' {
    # The flag compares the metrics either side of the detail pass; the VALUES on the line stay
    # the ones the tick opened with, so cx=/cy=/wa= keep meaning "when this sample started" for
    # every reader that already gates on them.
    $start = $script:SubjectSource.IndexOf('function Invoke-WindowLoop')
    $body = $script:SubjectSource.Substring($start)
    $loopFrom = $body.IndexOf('while ($true) {')
    $loopTo = $body.IndexOf("`$stage = 'result'")
    $tickBody = $body.Substring($loopFrom, $loopTo - $loopFrom)
    $detail = $tickBody.IndexOf('Add-ProbeWindowDetail')
    $reread = $tickBody.IndexOf('$cxAfter =')
    Assert-True ($reread -gt $detail) "the re-read (at $reread) must follow the detail pass (at $detail)"
    # Comment lines are stripped before counting: a name count over prose is not a pin (the
    # project has been bitten by doc comments feeding a call count twice; gate r1 m2).
    $tickCode = (($tickBody -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Assert-Equal 4 ([regex]::Matches($tickCode, 'MetricOf\(')).Count 'cx and cy, once each side of the detail pass'
    Assert-Equal 2 ([regex]::Matches($tickCode, 'WorkAreaOf\(')).Count 'the work area, once each side'
    Assert-Match '(?m)^\s*Cx\s+=\s+\$cx\s*$' $tickBody 'the printed cx is the opening read, not the re-read'
    Assert-Match '(?m)^\s*Cy\s+=\s+\$cy\s*$' $tickBody
    Assert-Match '(?m)^\s*WorkArea\s+=\s+\$workArea\s*$' $tickBody
}

Test-Case 'the header usage block spells the two grammars the script actually emits' {
    # The usage block drifted once already: owner= was added to the row on 2026-09-21 and the
    # header kept the pre-owner shape, so a reader working from the file header would have
    # mis-parsed the rows. The fields are listed here against the same source, which is the
    # cheapest place to notice the next drift.
    $usage = $script:SubjectSource.Substring(0, $script:SubjectSource.IndexOf('.PARAMETER OutPath'))
    Assert-Match '\[loop-tick\] seq= utc= cx= cy= wa= \[truncated=true\] \[torn=<n>\] \[desktop-changed=1\]' $usage
    Assert-Match '\[tick-rect\] seq= hwnd= pid= proc= class= style= dpi= wr= ef= cs= cr= owner= title-len=' $usage
    Assert-True ($usage.Contains('title-sha8=')) 'the digest field is documented too'
}

Test-Case 'the sampler never opens the PREVIOUS half timeline, which the collector rotated away' {
    # window-loop-out.prev.txt is the previous half's evidence, parked there by
    # window-loop-collect.ps1 after a successful write-back (gate r1 B2). The sampler declares
    # the name only so the three-way name pin covers it; writing it would destroy the very file
    # the rotation exists to preserve.
    Assert-Match "(?m)^\s*\`$script:LoopOutPrevName = 'window-loop-out\.prev\.txt'\s*$" $script:SubjectSource `
        'the name is declared here so a rename in the collector turns this suite red too'
    Assert-Equal 1 ([regex]::Matches($script:SubjectSource, '\$script:LoopOutPrevName')).Count `
        'declared once and referenced nowhere else: the sampler must never open that file'
    Assert-Equal 1 ([regex]::Matches($script:SubjectSource, 'out\.prev')).Count `
        'and the literal appears nowhere but in that one declaration'
}

Test-Case 'nothing runs unless -NoRun is absent: the only top-level call is inside that guard' {
    $guard = $script:SubjectSource.LastIndexOf('if (-not $NoRun) {')
    Assert-True ($guard -gt 0) 'the guard is present'
    $tail = $script:SubjectSource.Substring($guard)
    Assert-True ($tail.Contains('Invoke-WindowLoop')) 'the run is started inside the guard'
    Assert-True ($tail.Contains('exit 0')) 'the script always exits 0; the relay writes the real rc'
    Assert-Equal 0 ([regex]::Matches($script:SubjectSource, '(?m)^Invoke-WindowLoop')).Count 'no unguarded top-level invocation'
}

Test-Case 'the suite itself carries no host identifier: only the two synthetic fixture titles' {
    $self = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'window-loop.Tests.ps1'))
    Assert-True ($self.Contains($script:FixtureTitleA)) 'the fixture titles are the synthetic ones'
    Assert-True ($self.Contains($script:FixtureTitleB))
    Assert-True (-not ($self -match '(?i)\\\\[a-z0-9-]*\\c\$')) 'no administrative share path'
}

# -------------------------------------------------------------------------------------------
# Parameter binding
# -------------------------------------------------------------------------------------------

New-Section 'parameter binding'

Test-Case 'dot-sourcing with -NoRun defines the helpers and touches nothing' {
    $ran = $true
    try { & $script:SubjectPath -NoRun } catch { $ran = $false }
    Assert-True $ran '-NoRun must bind and return without running the loop'
    Assert-True ($null -ne (Get-Command Test-LoopShouldStop -ErrorAction SilentlyContinue)) 'the helpers are defined'
}

Test-Case 'every path and bound binds alongside -NoRun' {
    $ran = $true
    try {
        & $script:SubjectPath -NoRun -OutPath 'ignored-out.txt' -SentinelPath 'ignored-stop' `
            -ProbePath 'ignored-probe.ps1' -MaxSeconds 30 -IntervalMs 500
    } catch { $ran = $false }
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
