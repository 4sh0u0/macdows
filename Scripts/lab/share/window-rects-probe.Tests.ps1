#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test suite for window-rects-probe.ps1's pure helpers and report grammar.

.DESCRIPTION
    Runs on macOS under PowerShell 7 (Tier 1 runs it on ubuntu-latest's pwsh) with no external
    dependencies. Self-contained assertion harness, exit code propagated: 0 when every case
    passes, 1 otherwise. Style follows server-snapshot.Tests.ps1.

    window-rects-probe.ps1 is a READ-ONLY host probe. The half that has to run on Windows -- the
    Add-Type P/Invoke surface, SetProcessDpiAwarenessContext, EnumWindows, GetWindowRect,
    DwmGetWindowAttribute, GetSystemMetricsForDpi -- CANNOT be exercised here and is not
    exercised here; the suite dot-sources the script with -NoRun, which defines the functions and
    touches nothing. What IS driven is every decision the report depends on: which windows are
    selected and in what order, how each field is rendered, that a failed call degrades to n/a
    rather than to a broken line, that the counts cannot contradict the rows, and that a window
    title never reaches the file. Plus source pins for the things the offline path cannot
    observe: that the DPI awareness declaration precedes every window and DPI call, that Add-Type
    lives in exactly one function, and that nothing runs at all when -NoRun is passed.

    Fixtures are synthetic records. The fixture "titles" are the literal strings lab-fixture-alpha
    and lab-fixture-beta -- no real window title, host name, account name or path appears in this
    file, and the report-writing case asserts that neither fixture string reaches the written
    file.

.EXAMPLE
    pwsh -NoProfile -File ./window-rects-probe.Tests.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:SubjectPath = Join-Path $PSScriptRoot 'window-rects-probe.ps1'
. $script:SubjectPath -NoRun

# -------------------------------------------------------------------------------------------
# Assertion harness
# -------------------------------------------------------------------------------------------

$script:TestTotal = 0
$script:TestFailed = 0
$script:TestFailures = New-Object System.Collections.ArrayList
$script:TestSkipped = New-Object System.Collections.ArrayList

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

function Test-Skipped {
    <#
      A case that could not run HERE, announced loudly and counted. Used only where the runner
      itself is missing a capability (Add-Type); never for a case that failed. A skip prints SKIP
      on its own line and is repeated in the summary, so it can never read as coverage.
    #>
    param([string] $Name, [string] $Reason)
    $script:TestTotal++
    [void]$script:TestSkipped.Add("$Name :: $Reason")
    Write-Host "  SKIP $Name"
    Write-Host "       $Reason"
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

function New-FixtureBase {
    <# A base record as Get-ProbeWindowBase builds it: only what the selection reads. #>
    param([long] $Hwnd, [bool] $Visible = $true, $Rect = $null)
    if ($null -eq $Rect) { $Rect = New-FixtureRect -Left 0 -Top 0 -Right 100 -Bottom 100 }
    return [pscustomobject]@{ Handle = $null; Hwnd = $Hwnd; Visible = $Visible; WindowRect = $Rect }
}

function New-FixtureWindow {
    <# A fully detailed record as Add-ProbeWindowDetail builds it. #>
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

function New-FixtureMetrics {
    param([AllowNull()] $Dpi, [string] $For = 'fixed')
    return [pscustomobject]@{
        dpi            = $Dpi
        'for'          = $For
        cxsizeframe    = 4
        cysizeframe    = 4
        cxpaddedborder = 4
        cycaption      = 23
        cxfixedframe   = 3
        cyfixedframe   = 3
        cxborder       = 1
        cyborder       = 1
    }
}

function New-FixtureStats {
    param([int] $Enumerated = 9, [int] $Visible = 4, [int] $RectOk = 3, [int] $Cap = 64)
    return [pscustomobject]@{
        ReadUtc    = '2026-09-15T12:00:00.0000000Z'
        PsVersion  = '5.1.0.0'
        Enumerated = $Enumerated
        Visible    = $Visible
        RectOk     = $RectOk
        Cap        = $Cap
    }
}

function New-FixtureProbe {
    param()
    return [pscustomobject]@{ Awareness = 2; SetVia = 'v2'; SystemDpi = 192; SessionId = 3; ProcessId = 1234 }
}

# The three line grammars, as regular expressions, written down once and reused. A field renamed
# or reordered in the script fails every case that uses them.
$script:ProbeLinePattern = '^\[host-probe\] awareness=\S+ set-via=(v2|shcore|none) system-dpi=\S+ session=\S+ pid=\S+ usable=(true|false)$'
$script:MetricsLinePattern = '^\[host-metrics\] dpi=\S+ for=(session|fixed) cxsizeframe=\S+ cysizeframe=\S+ cxpaddedborder=\S+ cycaption=\S+ cxfixedframe=\S+ cyfixedframe=\S+ cxborder=\S+ cyborder=\S+$'
$script:EnumLinePattern = '^\[host-enum\] read-utc=\S+ ps=\S+ enumerated=\d+ visible=\d+ rect-ok=\d+ selected=\d+ cap=\d+ truncated=(true|false)$'
$script:RectLinePattern = '^\[host-rect\] hwnd=\S+ pid=\S+ proc=\S+ class=\S+ style=\S+ exstyle=\S+ owner=\S+ dpi=\S+ wr=\S+ ef=\S+ cs=\S+ cr=\S+ title-len=\S+ title-sha8=\S+( hr=\S+)?$'

# -------------------------------------------------------------------------------------------
# Pre-registered constants
# -------------------------------------------------------------------------------------------

New-Section 'pre-registered constants'

Test-Case 'the row cap is 64' {
    Assert-Equal 64 $script:ProbeMaxRows
}

Test-Case 'the per-monitor-v2 awareness context is -4 and the shcore fallback asks for 2' {
    Assert-Equal (-4) $script:ProbeAwarenessContextPerMonitorV2 'DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2'
    Assert-Equal 2 $script:ProbeShcorePerMonitorAwareness 'PROCESS_PER_MONITOR_DPI_AWARE'
}

Test-Case 'set-via is a closed set of exactly v2 / shcore / none' {
    $v = @($script:ProbeSetViaValues)
    Assert-Equal 3 $v.Count
    Assert-Equal 'v2' $v[0]
    Assert-Equal 'shcore' $v[1]
    Assert-Equal 'none' $v[2]
}

Test-Case 'every report carries the two fixed metric DPIs 96 and 192 beside the session DPI' {
    $d = @($script:ProbeFixedMetricDpi)
    Assert-Equal 2 $d.Count
    Assert-Equal 96 $d[0]
    Assert-Equal 192 $d[1]
}

Test-Case 'the metric map names the eight fields in report order' {
    $keys = @($script:ProbeMetricIndex.Keys)
    $want = @('cxsizeframe', 'cysizeframe', 'cxpaddedborder', 'cycaption', 'cxfixedframe', 'cyfixedframe', 'cxborder', 'cyborder')
    Assert-Equal $want.Count $keys.Count "metric field count"
    for ($i = 0; $i -lt $want.Count; $i++) { Assert-Equal $want[$i] $keys[$i] "metric field $i" }
}

Test-Case 'the metric map uses the documented SM_* indices' {
    Assert-Equal 32 $script:ProbeMetricIndex['cxsizeframe'] 'SM_CXSIZEFRAME'
    Assert-Equal 33 $script:ProbeMetricIndex['cysizeframe'] 'SM_CYSIZEFRAME'
    Assert-Equal 92 $script:ProbeMetricIndex['cxpaddedborder'] 'SM_CXPADDEDBORDER'
    Assert-Equal 7  $script:ProbeMetricIndex['cxfixedframe'] 'SM_CXFIXEDFRAME'
    Assert-Equal 8  $script:ProbeMetricIndex['cyfixedframe'] 'SM_CYFIXEDFRAME'
    Assert-Equal 4  $script:ProbeMetricIndex['cycaption'] 'SM_CYCAPTION'
    Assert-Equal 5  $script:ProbeMetricIndex['cxborder'] 'SM_CXBORDER'
    Assert-Equal 6  $script:ProbeMetricIndex['cyborder'] 'SM_CYBORDER'
}

Test-Case 'the sizing frame and the fixed (dialog) frame are two DIFFERENT metrics, 32/33 against 7/8' {
    # Controller ruling 2026-09-15: the About window is a dialog and carries no sizing frame, so
    # the metric its border constant has to be compared with is SM_CXFIXEDFRAME/SM_CYFIXEDFRAME.
    # SM_CXFRAME/SM_CYFRAME are NOT in the map: WinUser.h aliases them to 32/33, so they could
    # only repeat the sizing pair. This case fails if either pair is ever pointed at the other.
    Assert-Equal 7 $script:ProbeMetricIndex['cxfixedframe'] 'SM_CXFIXEDFRAME'
    Assert-Equal 8 $script:ProbeMetricIndex['cyfixedframe'] 'SM_CYFIXEDFRAME'
    Assert-True ($script:ProbeMetricIndex['cxfixedframe'] -ne $script:ProbeMetricIndex['cxsizeframe']) 'fixed and sizing widths are distinct indices'
    Assert-True ($script:ProbeMetricIndex['cyfixedframe'] -ne $script:ProbeMetricIndex['cysizeframe']) 'fixed and sizing heights are distinct indices'
    foreach ($gone in @('cxframe', 'cyframe')) {
        Assert-True (-not (@($script:ProbeMetricIndex.Keys) -contains $gone)) "[$gone] is an alias of the sizing pair and must not be printed"
    }
}

Test-Case 'the metrics for= closed set is exactly session / fixed' {
    $v = @($script:ProbeMetricsForValues)
    Assert-Equal 2 $v.Count
    Assert-Equal 'session' $v[0]
    Assert-Equal 'fixed' $v[1]
}

Test-Case 'usable= is pre-registered as set-via=v2 AND awareness=2, and nothing else' {
    Assert-Equal 'v2' $script:ProbeUsableSetVia
    Assert-Equal 2 $script:ProbeUsableAwareness
    Assert-True (@($script:ProbeSetViaValues) -contains $script:ProbeUsableSetVia) 'the usable route is one of the admitted set-via values'
}

Test-Case 'sanitised tokens are cut at 64 characters' {
    Assert-Equal 64 $script:ProbeTokenMaxLength
}

# -------------------------------------------------------------------------------------------
# Format-ProbeInt / Format-ProbeHex32
# -------------------------------------------------------------------------------------------

New-Section 'scalar formatters'

Test-Case 'Format-ProbeInt renders decimals, zero and negatives without separators' {
    Assert-Equal '0' (Format-ProbeInt -Value 0)
    Assert-Equal '983040' (Format-ProbeInt -Value 983040)
    Assert-Equal '-31' (Format-ProbeInt -Value -31)
    Assert-Equal '2147483648' (Format-ProbeInt -Value 2147483648)
    Assert-Equal '1234567890' (Format-ProbeInt -Value 1234567890)
}

Test-Case 'Format-ProbeInt renders a missing or non-numeric value as n/a' {
    Assert-Equal 'n/a' (Format-ProbeInt -Value $null)
    Assert-Equal 'n/a' (Format-ProbeInt -Value 'not-a-number')
    Assert-Equal 'n/a' (Format-ProbeInt -Value (New-FixturePoint -X 1 -Y 2))
}

Test-Case 'Format-ProbeHex32 renders 0x + eight uppercase hex digits' {
    Assert-Equal '0x00000000' (Format-ProbeHex32 -Value 0)
    Assert-Equal '0x00000100' (Format-ProbeHex32 -Value 256)
    Assert-Equal '0x16CF0000' (Format-ProbeHex32 -Value 0x16CF0000)
}

Test-Case 'Format-ProbeHex32 keeps the top bit: a style or HRESULT that arrived negative still prints its 32 bits' {
    # Regression pin: -band 0xFFFFFFFF (no L suffix) is -band [int]-1 in PowerShell, which leaves
    # a negative HRESULT negative and made [uint32] throw -- every failed DWM call printed hr=n/a.
    Assert-Equal '0x80070057' (Format-ProbeHex32 -Value (-2147024809))
    Assert-Equal '0x80000000' (Format-ProbeHex32 -Value (-2147483648))
    Assert-Equal '0x80004005' (Format-ProbeHex32 -Value (-2147467259))
}

Test-Case 'Format-ProbeHex32 renders a missing or non-numeric value as n/a' {
    Assert-Equal 'n/a' (Format-ProbeHex32 -Value $null)
    Assert-Equal 'n/a' (Format-ProbeHex32 -Value 'style')
}

# -------------------------------------------------------------------------------------------
# Format-Rect / Format-Size / Format-Point
# -------------------------------------------------------------------------------------------

New-Section 'geometry formatters'

Test-Case 'Format-Rect renders l,t,r,b' {
    Assert-Equal '54,0,754,500' (Format-Rect -Rect (New-FixtureRect -Left 54 -Top 0 -Right 754 -Bottom 500))
    Assert-Equal '-8,-8,1928,1088' (Format-Rect -Rect (New-FixtureRect -Left -8 -Top -8 -Right 1928 -Bottom 1088))
}

Test-Case 'Format-Rect renders a missing rectangle -- or a rectangle missing one edge -- as n/a, never half of one' {
    Assert-Equal 'n/a' (Format-Rect -Rect $null)
    Assert-Equal 'n/a' (Format-Rect -Rect ([pscustomobject]@{ Left = 1; Top = 2; Right = 3 }))
    Assert-Equal 'n/a' (Format-Rect -Rect ([pscustomobject]@{ Left = 1; Top = 2; Right = 3; Bottom = $null }))
}

Test-Case 'Format-Size subtracts the rectangle into w,h' {
    Assert-Equal '686,497' (Format-Size -Rect (New-FixtureRect -Left 0 -Top 0 -Right 686 -Bottom 497))
    Assert-Equal '700,500' (Format-Size -Rect (New-FixtureRect -Left 54 -Top 0 -Right 754 -Bottom 500))
    Assert-Equal '0,0' (Format-Size -Rect (New-FixtureRect -Left 5 -Top 5 -Right 5 -Bottom 5))
}

Test-Case 'Format-Size renders a missing or incomplete rectangle as n/a' {
    Assert-Equal 'n/a' (Format-Size -Rect $null)
    Assert-Equal 'n/a' (Format-Size -Rect ([pscustomobject]@{ Left = 0; Top = 0; Right = 10 }))
}

Test-Case 'Format-Point renders x,y and n/a for a missing point or coordinate' {
    Assert-Equal '50,0' (Format-Point -Point (New-FixturePoint -X 50 -Y 0))
    Assert-Equal '-6,31' (Format-Point -Point (New-FixturePoint -X -6 -Y 31))
    Assert-Equal 'n/a' (Format-Point -Point $null)
    Assert-Equal 'n/a' (Format-Point -Point ([pscustomobject]@{ X = 3 }))
}

# -------------------------------------------------------------------------------------------
# ConvertTo-ProbeToken
# -------------------------------------------------------------------------------------------

New-Section 'ConvertTo-ProbeToken'

Test-Case 'a plain class or process name passes through unchanged' {
    Assert-Equal 'Notepad' (ConvertTo-ProbeToken -Value 'Notepad')
    Assert-Equal '#32770' (ConvertTo-ProbeToken -Value '#32770')
    Assert-Equal 'Chrome_WidgetWin_1' (ConvertTo-ProbeToken -Value 'Chrome_WidgetWin_1')
}

Test-Case 'a space becomes ? so one row can never split into two sets of key=value pairs' {
    Assert-Equal 'two?words' (ConvertTo-ProbeToken -Value 'two words')
    Assert-Equal 'tab?here' (ConvertTo-ProbeToken -Value "tab`there")
}

Test-Case 'anything outside printable ASCII becomes ?' {
    Assert-Equal '??' (ConvertTo-ProbeToken -Value ([string][char]0x00E9 + [string][char]0x4E2D))
    Assert-Equal 'a?b' (ConvertTo-ProbeToken -Value ("a`nb"))
}

Test-Case 'an empty value is a real answer (<empty>) and a missing one is n/a' {
    Assert-Equal '<empty>' (ConvertTo-ProbeToken -Value '')
    Assert-Equal 'n/a' (ConvertTo-ProbeToken -Value $null)
}

Test-Case 'a long token is cut at the cap and marked with a trailing ~' {
    $exact = 'a' * $script:ProbeTokenMaxLength
    Assert-Equal $exact (ConvertTo-ProbeToken -Value $exact) 'a token exactly at the cap is untouched'
    $long = 'b' * ($script:ProbeTokenMaxLength + 20)
    $got = ConvertTo-ProbeToken -Value $long
    Assert-Equal ($script:ProbeTokenMaxLength + 1) $got.Length
    Assert-Equal '~' $got.Substring($got.Length - 1, 1)
}

Test-Case 'no sanitised token can contain whitespace, whatever went in' {
    foreach ($nasty in @('a b', "c`td", "e`nf", "g`r`nh", ' ', '  spaced  name  ')) {
        $got = ConvertTo-ProbeToken -Value $nasty
        Assert-True ($got -notmatch '\s') "token [$got] from [$nasty] must carry no whitespace"
    }
}

# -------------------------------------------------------------------------------------------
# ConvertTo-TitleSha8
# -------------------------------------------------------------------------------------------

New-Section 'ConvertTo-TitleSha8'

Test-Case 'the pinned fixture titles hash to their pre-registered eight hex digits' {
    # Independently computed; 00eee4a7 is kept as a pin on purpose because it starts with a zero
    # byte -- a formatter that dropped leading zeros would still be eight characters for most
    # titles and would silently fail here.
    Assert-Equal '00eee4a7' (ConvertTo-TitleSha8 -Title $script:FixtureTitleA)
    Assert-Equal '279b8a26' (ConvertTo-TitleSha8 -Title $script:FixtureTitleB)
}

Test-Case 'an empty or missing title is none, not a hash of nothing' {
    Assert-Equal 'none' (ConvertTo-TitleSha8 -Title '')
    Assert-Equal 'none' (ConvertTo-TitleSha8 -Title $null)
}

Test-Case 'the digest is always eight lowercase hex digits and is stable for one title' {
    foreach ($t in @('a', $script:FixtureTitleA, ('z' * 500))) {
        $got = ConvertTo-TitleSha8 -Title $t
        Assert-Match '^[0-9a-f]{8}$' $got "digest of a $($t.Length)-character title"
        Assert-Equal $got (ConvertTo-TitleSha8 -Title $t) 'the same title hashes the same way twice'
    }
    Assert-True ((ConvertTo-TitleSha8 -Title $script:FixtureTitleA) -ne (ConvertTo-TitleSha8 -Title $script:FixtureTitleB)) 'two titles, two digests'
}

Test-Case 'the digest is taken over UTF-16LE bytes, not UTF-8' {
    # Same text, two encodings, two different digests: this case fails if the script ever changes
    # to [Text.Encoding]::UTF8, which would break the join with any digest taken the documented way.
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $utf8 = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:FixtureTitleA))
        $utf16 = $sha.ComputeHash([Text.Encoding]::Unicode.GetBytes($script:FixtureTitleA))
    } finally {
        $sha.Dispose()
    }
    $utf8Eight = (($utf8[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
    $utf16Eight = (($utf16[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
    Assert-True ($utf8Eight -ne $utf16Eight) 'the two encodings must differ for this fixture'
    Assert-Equal $utf16Eight (ConvertTo-TitleSha8 -Title $script:FixtureTitleA)
}

# -------------------------------------------------------------------------------------------
# Select-ProbeSetVia
# -------------------------------------------------------------------------------------------

New-Section 'Select-ProbeSetVia'

Test-Case 'the three admitted values pass through and anything else is none' {
    Assert-Equal 'v2' (Select-ProbeSetVia -Value 'v2')
    Assert-Equal 'shcore' (Select-ProbeSetVia -Value 'shcore')
    Assert-Equal 'none' (Select-ProbeSetVia -Value 'none')
    Assert-Equal 'none' (Select-ProbeSetVia -Value 'manifest')
    Assert-Equal 'none' (Select-ProbeSetVia -Value '')
    Assert-Equal 'none' (Select-ProbeSetVia -Value $null)
}

# -------------------------------------------------------------------------------------------
# Select-ProbeMetricsFor / Test-ProbeUsable
# -------------------------------------------------------------------------------------------

New-Section 'Select-ProbeMetricsFor'

Test-Case 'session and fixed pass through; anything else is n/a, never a silent relabel' {
    Assert-Equal 'session' (Select-ProbeMetricsFor -Value 'session')
    Assert-Equal 'fixed' (Select-ProbeMetricsFor -Value 'fixed')
    Assert-Equal 'n/a' (Select-ProbeMetricsFor -Value 'both')
    Assert-Equal 'n/a' (Select-ProbeMetricsFor -Value '')
    Assert-Equal 'n/a' (Select-ProbeMetricsFor -Value $null)
}

New-Section 'Test-ProbeUsable'

Test-Case 'usable is true only for the v2 route landing on awareness 2' {
    Assert-True (Test-ProbeUsable -SetVia 'v2' -Awareness 2) 'the one usable combination'
    foreach ($case in @(
        @{ SetVia = 'shcore'; Awareness = 2 },
        @{ SetVia = 'none'; Awareness = 2 },
        @{ SetVia = 'v2'; Awareness = 1 },
        @{ SetVia = 'v2'; Awareness = 0 },
        @{ SetVia = 'v2'; Awareness = -1 },
        @{ SetVia = 'v2'; Awareness = $null },
        @{ SetVia = $null; Awareness = 2 },
        @{ SetVia = 'manifest'; Awareness = 2 },
        @{ SetVia = 'v2'; Awareness = 'two' })) {
        Assert-True (-not (Test-ProbeUsable -SetVia $case.SetVia -Awareness $case.Awareness)) "set-via=$($case.SetVia) awareness=$($case.Awareness) must not be usable"
    }
}

# -------------------------------------------------------------------------------------------
# Test-ProbeWindowVisible / Test-ProbeWindowRectOk
# -------------------------------------------------------------------------------------------

New-Section 'selection predicates'

Test-Case 'visibility comes off the record and a missing flag is not visible' {
    Assert-True (Test-ProbeWindowVisible -Window (New-FixtureBase -Hwnd 1 -Visible $true))
    Assert-True (-not (Test-ProbeWindowVisible -Window (New-FixtureBase -Hwnd 1 -Visible $false)))
    Assert-True (-not (Test-ProbeWindowVisible -Window ([pscustomobject]@{ Hwnd = 1 })))
    Assert-True (-not (Test-ProbeWindowVisible -Window $null))
}

Test-Case 'a non-empty rectangle needs positive width AND height' {
    $ok = New-FixtureBase -Hwnd 1 -Rect (New-FixtureRect -Left 0 -Top 0 -Right 10 -Bottom 10)
    Assert-True (Test-ProbeWindowRectOk -Window $ok)
    foreach ($bad in @(
        (New-FixtureRect -Left 0 -Top 0 -Right 0 -Bottom 10),
        (New-FixtureRect -Left 0 -Top 0 -Right 10 -Bottom 0),
        (New-FixtureRect -Left 0 -Top 0 -Right 0 -Bottom 0),
        (New-FixtureRect -Left 10 -Top 0 -Right 5 -Bottom 10))) {
        Assert-True (-not (Test-ProbeWindowRectOk -Window (New-FixtureBase -Hwnd 1 -Rect $bad))) "rectangle $($bad.Left),$($bad.Top),$($bad.Right),$($bad.Bottom) is empty"
    }
}

Test-Case 'a window whose GetWindowRect failed has no rectangle and is not selectable' {
    $rec = [pscustomobject]@{ Handle = $null; Hwnd = 1; Visible = $true; WindowRect = $null }
    Assert-True (-not (Test-ProbeWindowRectOk -Window $rec))
    $partial = [pscustomobject]@{ Handle = $null; Hwnd = 1; Visible = $true; WindowRect = ([pscustomobject]@{ Left = 0; Top = 0; Right = 10 }) }
    Assert-True (-not (Test-ProbeWindowRectOk -Window $partial))
}

# -------------------------------------------------------------------------------------------
# Select-ProbeWindows
# -------------------------------------------------------------------------------------------

New-Section 'Select-ProbeWindows'

Test-Case 'invisible windows and empty rectangles are dropped' {
    $windows = @(
        (New-FixtureBase -Hwnd 10 -Visible $true),
        (New-FixtureBase -Hwnd 11 -Visible $false),
        (New-FixtureBase -Hwnd 12 -Visible $true -Rect (New-FixtureRect -Left 0 -Top 0 -Right 0 -Bottom 0)),
        (New-FixtureBase -Hwnd 13 -Visible $true)
    )
    $sel = @(Select-ProbeWindows -Windows $windows)
    Assert-Equal 2 $sel.Count
    Assert-Equal 10 $sel[0].Hwnd
    Assert-Equal 13 $sel[1].Hwnd
}

Test-Case 'the rows come out ordered by hwnd, whatever order EnumWindows walked' {
    $windows = @(
        (New-FixtureBase -Hwnd 2148007936),
        (New-FixtureBase -Hwnd 7),
        (New-FixtureBase -Hwnd 983040),
        (New-FixtureBase -Hwnd 131074)
    )
    $sel = @(Select-ProbeWindows -Windows $windows)
    $got = @($sel | ForEach-Object { $_.Hwnd })
    Assert-Equal '7,131074,983040,2148007936' ($got -join ',')
}

Test-Case 'the cap keeps the lowest hwnds and is applied after the ordering, so two runs choose the same windows' {
    $windows = @()
    foreach ($i in 1..70) { $windows += (New-FixtureBase -Hwnd (1000 - $i)) }
    $sel = @(Select-ProbeWindows -Windows $windows)
    Assert-Equal $script:ProbeMaxRows $sel.Count
    Assert-Equal 930 $sel[0].Hwnd
    Assert-Equal 993 $sel[$sel.Count - 1].Hwnd
    $again = @(Select-ProbeWindows -Windows @($windows[($windows.Count - 1)..0]))
    Assert-Equal ((@($sel | ForEach-Object { $_.Hwnd })) -join ',') ((@($again | ForEach-Object { $_.Hwnd })) -join ',') 'input order must not change the selection'
}

Test-Case 'an explicit cap binds and a cap of zero selects nothing' {
    $windows = @()
    foreach ($i in 1..10) { $windows += (New-FixtureBase -Hwnd $i) }
    Assert-Equal 3 (@(Select-ProbeWindows -Windows $windows -Cap 3)).Count
    Assert-Equal 0 (@(Select-ProbeWindows -Windows $windows -Cap 0)).Count
    Assert-Equal 10 (@(Select-ProbeWindows -Windows $windows -Cap 99)).Count
}

Test-Case 'no windows, a null list and a list of nulls all select nothing' {
    Assert-Equal 0 (@(Select-ProbeWindows -Windows @())).Count
    Assert-Equal 0 (@(Select-ProbeWindows -Windows $null)).Count
    Assert-Equal 0 (@(Select-ProbeWindows -Windows @($null, $null))).Count
}

# -------------------------------------------------------------------------------------------
# Measure-ProbeWindows
# -------------------------------------------------------------------------------------------

New-Section 'Measure-ProbeWindows'

Test-Case 'the three counts narrow: enumerated >= visible >= rect-ok' {
    $windows = @(
        (New-FixtureBase -Hwnd 1 -Visible $true),
        (New-FixtureBase -Hwnd 2 -Visible $false),
        (New-FixtureBase -Hwnd 3 -Visible $false),
        (New-FixtureBase -Hwnd 4 -Visible $true -Rect (New-FixtureRect -Left 0 -Top 0 -Right 0 -Bottom 0)),
        (New-FixtureBase -Hwnd 5 -Visible $true)
    )
    $counts = Measure-ProbeWindows -Windows $windows
    Assert-Equal 5 $counts.Enumerated
    Assert-Equal 3 $counts.Visible
    Assert-Equal 2 $counts.RectOk
}

Test-Case 'an empty or null enumeration counts zero three times' {
    foreach ($fixture in @(@(), $null)) {
        $counts = Measure-ProbeWindows -Windows $fixture
        Assert-Equal 0 $counts.Enumerated
        Assert-Equal 0 $counts.Visible
        Assert-Equal 0 $counts.RectOk
    }
}

# -------------------------------------------------------------------------------------------
# Line formatters
# -------------------------------------------------------------------------------------------

New-Section 'Format-HostProbeRow'

Test-Case 'the first line carries awareness, how it was set, the system DPI, the session and the pid' {
    $line = Format-HostProbeRow -Probe (New-FixtureProbe)
    Assert-Equal '[host-probe] awareness=2 set-via=v2 system-dpi=192 session=3 pid=1234 usable=true' $line
    Assert-Match $script:ProbeLinePattern $line
}

Test-Case 'a probe that could not declare awareness still produces a full line' {
    $line = Format-HostProbeRow -Probe ([pscustomobject]@{ Awareness = $null; SetVia = $null; SystemDpi = $null; SessionId = $null; ProcessId = 9 })
    Assert-Equal '[host-probe] awareness=n/a set-via=none system-dpi=n/a session=n/a pid=9 usable=false' $line
    Assert-Match $script:ProbeLinePattern $line
}

Test-Case 'a set-via value outside the closed set is reported as none, and such a run is not usable' {
    $line = Format-HostProbeRow -Probe ([pscustomobject]@{ Awareness = 1; SetVia = 'manifest'; SystemDpi = 96; SessionId = 2; ProcessId = 9 })
    Assert-Match ' set-via=none ' $line
    Assert-Match ' usable=false$' $line
    Assert-Match $script:ProbeLinePattern $line
}

Test-Case 'usable= is derived from the same awareness/set-via the line prints, so the verdict travels with its evidence' {
    # The lane exists because K came back wrong once; a virtualized run must be detectable by a
    # machine, not only by a reader who knows what awareness=1 means.
    $usable = Format-HostProbeRow -Probe ([pscustomobject]@{ Awareness = 2; SetVia = 'v2'; SystemDpi = 192; SessionId = 3; ProcessId = 9 })
    Assert-Match ' awareness=2 set-via=v2 ' $usable
    Assert-Match ' usable=true$' $usable
    foreach ($bad in @(
        ([pscustomobject]@{ Awareness = 1; SetVia = 'v2'; SystemDpi = 192; SessionId = 3; ProcessId = 9 }),
        ([pscustomobject]@{ Awareness = 2; SetVia = 'shcore'; SystemDpi = 192; SessionId = 3; ProcessId = 9 }),
        ([pscustomobject]@{ Awareness = 0; SetVia = 'none'; SystemDpi = 192; SessionId = 3; ProcessId = 9 }))) {
        $line = Format-HostProbeRow -Probe $bad
        Assert-Match ' usable=false$' $line
        Assert-Match $script:ProbeLinePattern $line
    }
}

New-Section 'Format-HostMetricsRow'

Test-Case 'the metrics line prints dpi and for first and then the eight metrics in map order' {
    $line = Format-HostMetricsRow -Metrics (New-FixtureMetrics -Dpi 96 -For 'session')
    Assert-Equal '[host-metrics] dpi=96 for=session cxsizeframe=4 cysizeframe=4 cxpaddedborder=4 cycaption=23 cxfixedframe=3 cyfixedframe=3 cxborder=1 cyborder=1' $line
    Assert-Match $script:MetricsLinePattern $line
}

Test-Case 'a metrics record with no DPI renders every field as n/a, keeping the line shape' {
    $empty = [pscustomobject]@{ dpi = $null; 'for' = 'fixed' }
    $line = Format-HostMetricsRow -Metrics $empty
    Assert-Equal '[host-metrics] dpi=n/a for=fixed cxsizeframe=n/a cysizeframe=n/a cxpaddedborder=n/a cycaption=n/a cxfixedframe=n/a cyfixedframe=n/a cxborder=n/a cyborder=n/a' $line
    Assert-Match $script:MetricsLinePattern $line
}

New-Section 'New-ProbeMetricsPlan'

Test-Case 'the plan is the session DPI first (exactly one session line) and then one fixed line per pre-registered DPI' {
    $plan = @(New-ProbeMetricsPlan -SessionDpi 192)
    Assert-Equal (1 + @($script:ProbeFixedMetricDpi).Count) $plan.Count
    Assert-Equal 'session' $plan[0].For
    Assert-Equal 192 $plan[0].Dpi
    Assert-Equal 1 (@($plan | Where-Object { $_.For -eq 'session' })).Count 'exactly one session line'
    for ($i = 0; $i -lt @($script:ProbeFixedMetricDpi).Count; $i++) {
        Assert-Equal 'fixed' $plan[$i + 1].For
        Assert-Equal $script:ProbeFixedMetricDpi[$i] $plan[$i + 1].Dpi
    }
}

Test-Case 'a session whose DPI is already a fixed one keeps its own line, and the three lines stay byte-distinct' {
    # Before for= existed, a 1x session (96) or a 2x session (192) printed two byte-identical
    # [host-metrics] lines and a reader joining on dpi= could not tell a duplicate from a second
    # measurement. This is the case that keeps them apart.
    foreach ($sessionDpi in @(96, 192)) {
        $plan = @(New-ProbeMetricsPlan -SessionDpi $sessionDpi)
        $lines = @($plan | ForEach-Object { Format-HostMetricsRow -Metrics (New-FixtureMetrics -Dpi $_.Dpi -For $_.For) })
        Assert-Equal 3 $lines.Count
        Assert-Equal 3 (@($lines | Select-Object -Unique)).Count "the three metrics lines of a $sessionDpi session must differ"
        Assert-Equal 1 (@($lines | Where-Object { $_ -like '*[ ]for=session *' })).Count 'exactly one line is the session one'
        foreach ($line in $lines) { Assert-Match $script:MetricsLinePattern $line }
    }
}

Test-Case 'a session whose DPI could not be read still produces its own line, marked for=session' {
    $plan = @(New-ProbeMetricsPlan -SessionDpi $null)
    Assert-Equal 'session' $plan[0].For
    $line = Format-HostMetricsRow -Metrics (New-FixtureMetrics -Dpi $plan[0].Dpi -For $plan[0].For)
    Assert-Match '^\[host-metrics\] dpi=n/a for=session ' $line
    Assert-Match $script:MetricsLinePattern $line
}

New-Section 'Format-HostEnumRow'

Test-Case 'the enum line reports the read time, the three counts, the cap and truncated=false' {
    $line = Format-HostEnumRow -ReadUtc '2026-09-15T12:00:00.0000000Z' -PsVersion '5.1.0.0' -Enumerated 40 -Visible 12 -RectOk 9 -Selected 9 -Cap 64
    Assert-Equal '[host-enum] read-utc=2026-09-15T12:00:00.0000000Z ps=5.1.0.0 enumerated=40 visible=12 rect-ok=9 selected=9 cap=64 truncated=false' $line
    Assert-Match $script:EnumLinePattern $line
}

Test-Case 'a cap that dropped windows says so -- truncation is never silent' {
    $line = Format-HostEnumRow -ReadUtc 'x' -PsVersion 'y' -Enumerated 400 -Visible 90 -RectOk 80 -Selected 64 -Cap 64
    Assert-Match ' rect-ok=80 selected=64 cap=64 truncated=true$' $line
    Assert-Match $script:EnumLinePattern $line
}

Test-Case 'truncated= is derived from rect-ok against selected, and only rect-ok > selected is true' {
    # The derivation, at the boundary: equal counts mean nothing was dropped, and a selected count
    # that somehow exceeded rect-ok is still not a truncation. This is the whole meaning of the
    # field -- a reader uses it to decide whether a window they cannot find was dropped or absent.
    foreach ($case in @(
        @{ RectOk = 9;  Selected = 9;  Want = 'false' },
        @{ RectOk = 0;  Selected = 0;  Want = 'false' },
        @{ RectOk = 5;  Selected = 9;  Want = 'false' },
        @{ RectOk = 10; Selected = 9;  Want = 'true' },
        @{ RectOk = 65; Selected = 64; Want = 'true' })) {
        $line = Format-HostEnumRow -ReadUtc 'u' -PsVersion 'p' -Enumerated 100 -Visible 99 -RectOk $case.RectOk -Selected $case.Selected -Cap 64
        Assert-Match (' truncated=' + $case.Want + '$') $line "rect-ok=$($case.RectOk) selected=$($case.Selected)"
        Assert-Match $script:EnumLinePattern $line
    }
}

Test-Case 'the enum line is one line of single tokens: read-utc and ps are sanitised like any other token' {
    $line = Format-HostEnumRow -ReadUtc '2026-09-15T12:00:00.0000000Z' -PsVersion '5 1 0' -Enumerated 1 -Visible 1 -RectOk 1 -Selected 1 -Cap 64
    Assert-True ($line.Contains(' ps=5?1?0 ')) "the spaces in a version string become ? like any other token: [$line]"
    $tokens = @($line -split ' ')
    Assert-Equal 9 $tokens.Count 'tag plus eight key=value pairs'
    for ($i = 1; $i -lt $tokens.Count; $i++) { Assert-Match '^[a-z-]+=[^ ]+$' $tokens[$i] "token $i" }
    Assert-Match $script:EnumLinePattern $line
    Assert-True ($line -notmatch "[`r`n]") 'the enum line never spans two lines'
}

New-Section 'Format-HostRectRow'

Test-Case 'a complete window renders every field in the pre-registered order' {
    $line = Format-HostRectRow -Window (New-FixtureWindow)
    Assert-Equal ('[host-rect] hwnd=983040 pid=4242 proc=notepad class=Notepad style=0x16CF0000 exstyle=0x00000100 owner=0 dpi=96 ' +
        'wr=54,0,754,500 ef=61,0,747,497 cs=50,0 cr=686,497 title-len=17 title-sha8=00eee4a7') $line
    Assert-Match $script:RectLinePattern $line
}

Test-Case 'a failed DWM call renders ef=n/a and appends that call HRESULT as hr=' {
    $w = New-FixtureWindow
    $w.ExtendedFrame = $null
    $w.ExtendedFrameHr = -2147024809
    $line = Format-HostRectRow -Window $w
    Assert-Match ' ef=n/a ' $line
    Assert-Match ' hr=0x80070057$' $line
    Assert-Match $script:RectLinePattern $line
}

Test-Case 'hr= is appended only when the frame is missing, never beside a frame that was read' {
    $w = New-FixtureWindow
    $w.ExtendedFrameHr = 0
    $line = Format-HostRectRow -Window $w
    Assert-True ($line -notmatch ' hr=') 'a successful DWM call adds no hr= field'
    $w2 = New-FixtureWindow
    $w2.ExtendedFrame = $null
    $w2.ExtendedFrameHr = $null
    $line2 = Format-HostRectRow -Window $w2
    Assert-Match ' ef=n/a ' $line2
    Assert-True ($line2 -notmatch ' hr=') 'no HRESULT to report means no hr= field'
    Assert-Match $script:RectLinePattern $line2
}

Test-Case 'a window whose every call failed still renders one well-formed line of n/a' {
    $line = Format-HostRectRow -Window ([pscustomobject]@{ Hwnd = 7 })
    Assert-Equal '[host-rect] hwnd=7 pid=n/a proc=n/a class=n/a style=n/a exstyle=n/a owner=n/a dpi=n/a wr=n/a ef=n/a cs=n/a cr=n/a title-len=n/a title-sha8=none' $line
    Assert-Match $script:RectLinePattern $line
}

Test-Case 'the row is one line and every value is a single whitespace-free token' {
    $w = New-FixtureWindow
    $w.ClassName = 'class with spaces'
    $w.ProcessName = "proc`twith`ttabs"
    $line = Format-HostRectRow -Window $w
    Assert-True ($line -notmatch "[`r`n]") 'a row never spans two lines'
    $tokens = @($line -split ' ')
    Assert-Equal 15 $tokens.Count 'tag plus fourteen key=value pairs'
    for ($i = 1; $i -lt $tokens.Count; $i++) {
        Assert-Match '^[a-z0-9-]+=[^ ]+$' $tokens[$i] "token $i"
    }
    Assert-Match $script:RectLinePattern $line
}

Test-Case 'the window title never reaches the row -- only its length and its digest do' {
    $w = New-FixtureWindow
    $line = Format-HostRectRow -Window $w
    Assert-True ($line -notlike "*$($script:FixtureTitleA)*") 'the title text must not appear'
    Assert-Match ' title-len=17 ' " $line "
    Assert-Match ' title-sha8=00eee4a7$' $line
    $w.Title = $script:FixtureTitleB
    $line2 = Format-HostRectRow -Window $w
    Assert-True ($line2 -notlike "*$($script:FixtureTitleB)*") 'the second title text must not appear either'
    Assert-Match ' title-len=16 title-sha8=279b8a26$' $line2
}

Test-Case 'title-len and title-sha8 are both derived from the one Title field, so they cannot disagree' {
    $w = New-FixtureWindow
    $w.Title = ''
    Assert-Match ' title-len=0 title-sha8=none$' (Format-HostRectRow -Window $w)
    $w.Title = $null
    Assert-Match ' title-len=n/a title-sha8=none$' (Format-HostRectRow -Window $w)
    $w.Title = 'ab'
    Assert-Match ' title-len=2 title-sha8=[0-9a-f]{8}$' (Format-HostRectRow -Window $w)
}

# -------------------------------------------------------------------------------------------
# Format-ProbeReport
# -------------------------------------------------------------------------------------------

New-Section 'Format-ProbeReport'

Test-Case 'the report is probe line, metrics lines, enum line, rect lines, RESULT -- in that order' {
    $metrics = @(New-ProbeMetricsPlan -SessionDpi 192 | ForEach-Object { New-FixtureMetrics -Dpi $_.Dpi -For $_.For })
    $lines = @(Format-ProbeReport -Probe (New-FixtureProbe) -Metrics $metrics -Stats (New-FixtureStats) -Windows @((New-FixtureWindow), (New-FixtureWindow)) -Result 'RESULT: DONE')
    Assert-Equal 8 $lines.Count 'probe + three metrics + enum + two rects + RESULT'
    Assert-Match $script:ProbeLinePattern $lines[0]
    for ($i = 1; $i -le 3; $i++) { Assert-Match $script:MetricsLinePattern $lines[$i] }
    Assert-Match $script:EnumLinePattern $lines[4]
    Assert-Match $script:RectLinePattern $lines[5]
    Assert-Match $script:RectLinePattern $lines[6]
    Assert-Equal 'RESULT: DONE' $lines[$lines.Count - 1]
}

Test-Case 'a whole report of a 2x session carries three distinguishable metrics lines and one usable verdict' {
    $metrics = @(New-ProbeMetricsPlan -SessionDpi 192 | ForEach-Object { New-FixtureMetrics -Dpi $_.Dpi -For $_.For })
    $lines = @(Format-ProbeReport -Probe (New-FixtureProbe) -Metrics $metrics -Stats (New-FixtureStats) -Windows @((New-FixtureWindow)) -Result 'RESULT: DONE')
    $metricLines = @($lines | Where-Object { $_ -like '[[]host-metrics[]]*' })
    Assert-Equal 3 $metricLines.Count
    Assert-Equal 3 (@($metricLines | Select-Object -Unique)).Count 'the 192 session line and the 192 fixed line must not be byte-identical'
    Assert-Equal 1 (@($lines | Where-Object { $_ -like '*[ ]for=session *' })).Count
    Assert-Equal 1 (@($lines | Where-Object { $_ -like '[[]host-probe[]]*' })).Count
    Assert-Match ' usable=true$' $lines[0]
}

Test-Case 'selected= counts the rows that are actually printed, not what the caller claimed' {
    # The stats record says three windows survived the filters; two are handed over. selected=
    # must follow the rows, or a reader could believe a window was reported that never was.
    $lines = @(Format-ProbeReport -Probe (New-FixtureProbe) -Metrics @((New-FixtureMetrics -Dpi 96)) -Stats (New-FixtureStats -Enumerated 9 -Visible 4 -RectOk 3) -Windows @((New-FixtureWindow), (New-FixtureWindow)) -Result 'RESULT: DONE')
    $enum = $lines[2]
    Assert-Match ' rect-ok=3 selected=2 cap=64 truncated=true$' $enum
    $rects = @($lines | Where-Object { $_ -like '[[]host-rect[]]*' })
    Assert-Equal 2 $rects.Count 'as many rect lines as selected='
}

Test-Case 'a report with no windows still carries its header, its counts and its RESULT' {
    $lines = @(Format-ProbeReport -Probe (New-FixtureProbe) -Metrics @((New-FixtureMetrics -Dpi 96)) -Stats (New-FixtureStats -Enumerated 0 -Visible 0 -RectOk 0) -Windows @() -Result 'RESULT: DONE')
    Assert-Equal 4 $lines.Count
    Assert-Match ' enumerated=0 visible=0 rect-ok=0 selected=0 cap=64 truncated=false$' $lines[2]
    Assert-Equal 'RESULT: DONE' $lines[3]
}

Test-Case 'the RESULT line is whatever the run decided, including the failure shape' {
    $lines = @(Format-ProbeReport -Probe (New-FixtureProbe) -Metrics $null -Stats (New-FixtureStats) -Windows $null -Result 'RESULT: FAILED enumerate/InvalidOperationException')
    Assert-Equal 3 $lines.Count
    Assert-Equal 'RESULT: FAILED enumerate/InvalidOperationException' $lines[2]
    Assert-Match ' selected=0 ' $lines[1]
}

# -------------------------------------------------------------------------------------------
# Write-ProbeReport
# -------------------------------------------------------------------------------------------

New-Section 'Write-ProbeReport'

Test-Case 'the written file is byte-for-byte the rendered lines, pure ASCII, with no BOM, and carries no title' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('window-rects-probe-tests-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    $out = Join-Path $dir 'window-rects-out.txt'
    try {
        $w2 = New-FixtureWindow
        $w2.Hwnd = 2148007936
        $w2.Title = $script:FixtureTitleB
        $w2.ClassName = 'class with spaces'
        $w2.ExtendedFrame = $null
        $w2.ExtendedFrameHr = -2147024809
        $lines = @(Format-ProbeReport -Probe (New-FixtureProbe) `
            -Metrics @(New-ProbeMetricsPlan -SessionDpi 192 | ForEach-Object { New-FixtureMetrics -Dpi $_.Dpi -For $_.For }) `
            -Stats (New-FixtureStats) -Windows @((New-FixtureWindow), $w2) -Result 'RESULT: DONE')
        Write-ProbeReport -Lines $lines -OutPath $out

        $bytes = [IO.File]::ReadAllBytes($out)
        Assert-True ($bytes.Length -gt 0) 'the file is not empty'
        Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'no UTF-8 BOM'
        foreach ($b in $bytes) { Assert-True ($b -lt 128) "byte $b is outside ASCII" }

        $text = [IO.File]::ReadAllText($out)
        Assert-True (-not $text.Contains($script:FixtureTitleA)) 'the written file carries no title text (alpha)'
        Assert-True (-not $text.Contains($script:FixtureTitleB)) 'the written file carries no title text (beta)'

        $read = @([IO.File]::ReadAllLines($out))
        Assert-Equal $lines.Count $read.Count
        for ($i = 0; $i -lt $lines.Count; $i++) { Assert-Equal $lines[$i] $read[$i] "line $i round-trips" }
        Assert-Equal 'RESULT: DONE' $read[$read.Count - 1]
    } finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

Test-Case 'a checkpoint file has no RESULT line at all, so it can never be read as a finished run' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('window-rects-probe-tests-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    $out = Join-Path $dir 'window-rects-out.txt'
    try {
        $header = @((Format-HostProbeRow -Probe (New-FixtureProbe)), (Format-HostMetricsRow -Metrics (New-FixtureMetrics -Dpi 96)))
        Write-ProbeReport -Lines (@($header) + @('CHECKPOINT: started')) -OutPath $out
        $read = @([IO.File]::ReadAllLines($out))
        Assert-Equal 3 $read.Count
        Assert-Equal 'CHECKPOINT: started' $read[2]
        Assert-Equal 0 (@($read | Where-Object { $_ -like 'RESULT:*' })).Count 'a partial file carries no RESULT line'
    } finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

# -------------------------------------------------------------------------------------------
# Failure shapes -- the run's catch path, driven by shadowing one stage with a thrower
# -------------------------------------------------------------------------------------------

New-Section 'RESULT: FAILED shapes'

function Invoke-ProbeFixtureRun {
    <#
      Runs Invoke-WindowRectsProbe into a throw-away file with ONE stage replaced by an injected
      failure, and returns the lines it wrote. The replacement is a function of the same name
      defined in a child scope: PowerShell resolves function calls through the caller's scope
      chain, so the run picks up the shadow without the script on disk being touched, and the
      shadow dies with the scriptblock. No Windows API is reached: the native surface is either
      the thrower itself or a no-op, after which every [MacdowsLab...] call fails inside
      Invoke-ProbeCall and degrades to n/a exactly as it would on a host that refused the call.
    #>
    param([scriptblock] $Injection)
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('window-rects-probe-tests-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    $out = Join-Path $dir 'window-rects-out.txt'
    try {
        & $Injection $out
        return @([IO.File]::ReadAllLines($out))
    } finally {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

Test-Case 'the earliest failure writes a one-line, header-less file -- a real result, not a truncated report' {
    # A refused Add-Type is the likeliest way this job dies on the host, and it dies before a
    # single field has been measured. The header block of .DESCRIPTION documents this shape.
    $lines = @(Invoke-ProbeFixtureRun -Injection {
        param($OutFile)
        function Initialize-ProbeNative { throw (New-Object System.InvalidOperationException 'injected') }
        Invoke-WindowRectsProbe -OutPath $OutFile
    })
    Assert-Equal 1 $lines.Count 'nothing had been produced yet, so nothing but the trailer is written'
    Assert-Equal 'RESULT: FAILED native/InvalidOperationException' $lines[0]
}

Test-Case 'a later failure keeps every line produced so far and names the stage that died' {
    $lines = @(Invoke-ProbeFixtureRun -Injection {
        param($OutFile)
        function Initialize-ProbeNative { }
        function Measure-ProbeWindows { param($Windows) throw (New-Object System.InvalidOperationException 'injected') }
        Invoke-WindowRectsProbe -OutPath $OutFile
    })
    Assert-Equal 5 $lines.Count 'the probe line, three metrics lines and the trailer'
    Assert-Match $script:ProbeLinePattern $lines[0]
    Assert-Match ' usable=false$' $lines[0] 'a run with no awareness declaration is never usable'
    for ($i = 1; $i -le 3; $i++) { Assert-Match $script:MetricsLinePattern $lines[$i] }
    Assert-Match '^\[host-metrics\] dpi=n/a for=session ' $lines[1]
    Assert-Equal 'RESULT: FAILED select/InvalidOperationException' $lines[4]
    Assert-Equal 0 (@($lines | Where-Object { $_ -like '[[]host-rect[]]*' })).Count 'no window was reported'
    Assert-Equal 0 (@($lines | Where-Object { $_ -like 'CHECKPOINT:*' })).Count 'the failure write replaced the checkpoint file'
}

Test-Case 'the failure trailer carries the stage and the exception type only -- never a message' {
    $lines = @(Invoke-ProbeFixtureRun -Injection {
        param($OutFile)
        function Initialize-ProbeNative { throw (New-Object System.InvalidOperationException 'a secret-looking message with a path in it') }
        Invoke-WindowRectsProbe -OutPath $OutFile
    })
    $trailer = $lines[$lines.Count - 1]
    Assert-Match '^RESULT: FAILED [a-z-]+/[A-Za-z]+$' $trailer
    Assert-True (-not $trailer.Contains('secret-looking')) 'the exception message must not reach the file'
}

# -------------------------------------------------------------------------------------------
# Boxed struct fields -- the shape the host path actually feeds the geometry formatters
# -------------------------------------------------------------------------------------------

New-Section 'boxed struct records'

Test-Case 'the geometry formatters read public FIELDS of a boxed struct, not only PSNoteProperties' {
    # On the host, WindowRectOf/ClientRectOf/ClientOriginOf return a boxed MacdowsLab.RECT/POINT --
    # public fields, while every other fixture in this suite is a [pscustomobject] with note
    # properties. Get-ProbeProp goes through $Object.PSObject.Properties[$Name] for both, but that
    # equivalence is an assumption until something drives it. This case drives it with an
    # equivalent managed struct compiled here, in its own namespace, with no P/Invoke at all --
    # so it runs on macOS and on the CI runner.
    if ($null -eq (Get-Command Add-Type -ErrorAction SilentlyContinue)) {
        Test-Skipped 'boxed struct fields' 'Add-Type is not available on this runner, so the struct stub cannot be compiled; the field-vs-property read stays unproven HERE'
        return
    }
    $compiled = $true
    $reason = ''
    if ($null -eq ('MacdowsLabTest.Boxer' -as [type])) {
        try {
            Add-Type -Language CSharp -TypeDefinition @'
namespace MacdowsLabTest
{
    public struct RectLike { public int Left; public int Top; public int Right; public int Bottom; }
    public struct PointLike { public int X; public int Y; }
    public static class Boxer
    {
        public static object Rect(int l, int t, int r, int b)
        {
            RectLike v = new RectLike();
            v.Left = l; v.Top = t; v.Right = r; v.Bottom = b;
            return v;
        }
        public static object Point(int x, int y)
        {
            PointLike v = new PointLike();
            v.X = x; v.Y = y;
            return v;
        }
    }
}
'@
        } catch {
            $compiled = $false
            $reason = $_.Exception.GetType().Name
        }
    }
    if (-not $compiled) {
        Test-Skipped 'boxed struct fields' "Add-Type exists but could not compile the struct stub ($reason); the field-vs-property read stays unproven HERE"
        return
    }

    $rect = [MacdowsLabTest.Boxer]::Rect(54, 0, 754, 500)
    $client = [MacdowsLabTest.Boxer]::Rect(0, 0, 686, 497)
    $point = [MacdowsLabTest.Boxer]::Point(50, 0)
    Assert-Equal '54' (Format-ProbeInt -Value (Get-ProbeProp -Object $rect -Name 'Left')) 'a public field is reachable through PSObject.Properties'
    Assert-Equal '54,0,754,500' (Format-Rect -Rect $rect)
    Assert-Equal '700,500' (Format-Size -Rect $rect)
    Assert-Equal '686,497' (Format-Size -Rect $client)
    Assert-Equal '50,0' (Format-Point -Point $point)

    # and the selection predicates, which read the same fields off the same boxes
    $base = [pscustomobject]@{ Handle = $null; Hwnd = 983040; Visible = $true; WindowRect = $rect }
    Assert-True (Test-ProbeWindowRectOk -Window $base)
    $empty = [pscustomobject]@{ Handle = $null; Hwnd = 1; Visible = $true; WindowRect = [MacdowsLabTest.Boxer]::Rect(5, 5, 5, 5) }
    Assert-True (-not (Test-ProbeWindowRectOk -Window $empty))
    Assert-Equal 1 (@(Select-ProbeWindows -Windows @($base, $empty))).Count

    # and a whole row, so the row grammar is proven over the host's own record shape
    $window = New-FixtureWindow
    $window.WindowRect = $rect
    $window.ClientRect = $client
    $window.ClientScreen = $point
    $window.ExtendedFrame = [MacdowsLabTest.Boxer]::Rect(61, 0, 747, 497)
    $line = Format-HostRectRow -Window $window
    Assert-Match $script:RectLinePattern $line
    Assert-Match ' wr=54,0,754,500 ef=61,0,747,497 cs=50,0 cr=686,497 ' $line
}

# -------------------------------------------------------------------------------------------
# Source pins -- properties the offline path cannot observe by running the script
# -------------------------------------------------------------------------------------------

New-Section 'source pins'

$script:SubjectSource = [IO.File]::ReadAllText($script:SubjectPath)

Test-Case 'the script takes exactly two parameters: OutPath (defaulting to the lab drive) and the NoRun switch' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:SubjectPath, [ref]$null, [ref]$null)
    $params = @($ast.ParamBlock.Parameters)
    Assert-Equal 2 $params.Count
    Assert-Equal 'OutPath' $params[0].Name.VariablePath.UserPath
    Assert-Equal '\\tsclient\lab\window-rects-out.txt' $params[0].DefaultValue.Value 'the relay mounts the lab share as tsclient\lab'
    Assert-Equal 'NoRun' $params[1].Name.VariablePath.UserPath
    Assert-Equal 'switch' $params[1].StaticType.Name.ToLowerInvariant().Substring(0, 6)
}

Test-Case 'Add-Type appears exactly once and only inside Initialize-ProbeNative' {
    $matches = [regex]::Matches($script:SubjectSource, 'Add-Type\s+-TypeDefinition')
    Assert-Equal 1 $matches.Count 'one compilation, one place'
    $start = $script:SubjectSource.IndexOf('function Initialize-ProbeNative')
    $end = $script:SubjectSource.IndexOf('function Get-ProbeProcessName')
    Assert-True ($start -gt 0 -and $end -gt $start) 'both functions are present in that order'
    Assert-True ($matches[0].Index -gt $start -and $matches[0].Index -lt $end) 'the Add-Type call lies inside Initialize-ProbeNative'
}

Test-Case 'the DPI awareness declaration precedes every window and DPI call in the run' {
    # The reason this probe exists at all: on a 200 % session a process that is not per-monitor
    # aware is handed virtualized rectangles, and K -- the number under investigation -- comes
    # back halved. Source order is the only offline evidence available for it.
    $start = $script:SubjectSource.IndexOf('function Invoke-WindowRectsProbe')
    Assert-True ($start -gt 0) 'the run function is present'
    $body = $script:SubjectSource.Substring($start)
    $awareness = $body.IndexOf('SetPerMonitorAwareV2')
    Assert-True ($awareness -gt 0) 'the run declares per-monitor awareness'
    foreach ($later in @('SetAwarenessViaShcore', 'CurrentAwareness()', 'SystemDpi()', 'New-ProbeMetricsRecord', 'EnumTopLevel()', 'Get-ProbeWindowBase', 'Add-ProbeWindowDetail')) {
        $at = $body.IndexOf($later)
        Assert-True ($at -gt $awareness) "[$later] must be called after the awareness declaration (found at $at, awareness at $awareness)"
    }
}

Test-Case 'nothing runs unless -NoRun is absent: the only top-level call is inside that guard' {
    $guard = $script:SubjectSource.LastIndexOf('if (-not $NoRun) {')
    Assert-True ($guard -gt 0) 'the guard is present'
    $tail = $script:SubjectSource.Substring($guard)
    Assert-True ($tail.Contains('Invoke-WindowRectsProbe -OutPath $OutPath')) 'the run is started inside the guard'
    Assert-True ($tail.Contains('exit 0')) 'the script always exits 0; the relay writes the real rc'
    $unguarded = [regex]::Matches($script:SubjectSource, '(?m)^Invoke-WindowRectsProbe')
    Assert-Equal 0 $unguarded.Count 'no unguarded top-level invocation'
    $calls = [regex]::Matches($script:SubjectSource, 'Invoke-WindowRectsProbe\s+-OutPath')
    Assert-Equal 1 $calls.Count 'exactly one invocation in the file'
}

Test-Case 'the native constants are named, not bare numbers' {
    foreach ($needle in @(
        'private const int GWL_STYLE = -16;',
        'private const int GWL_EXSTYLE = -20;',
        'private const uint GW_OWNER = 4;',
        'private const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;')) {
        Assert-True ($script:SubjectSource.Contains($needle)) "the C# surface must declare [$needle]"
    }
    Assert-True ($script:SubjectSource.Contains('DwmGetWindowAttribute(hWnd, DWMWA_EXTENDED_FRAME_BOUNDS,')) 'the DWM call uses the named attribute'
}

Test-Case 'the row formatter emits a digest and a length, and no field that could carry the text' {
    $start = $script:SubjectSource.IndexOf('function Format-HostRectRow')
    $end = $script:SubjectSource.IndexOf('function Format-ProbeReport')
    Assert-True ($start -gt 0 -and $end -gt $start) 'both functions are present in that order'
    $body = $script:SubjectSource.Substring($start, $end - $start)
    Assert-True ($body.Contains("'title-len='")) 'the row reports the title length'
    Assert-True ($body.Contains("'title-sha8='")) 'the row reports the title digest'
    Assert-True (-not $body.Contains("'title='")) 'no field named title'
    $emits = [regex]::Matches($body, '\$title\b')
    foreach ($m in $emits) {
        $after = $body.Substring($m.Index, [Math]::Min(40, $body.Length - $m.Index))
        Assert-True ($after -match '^\$title(Length)?\s*(=|\)|\s|-eq|\.)' ) "the raw title is only measured or hashed, never appended: [$after]"
    }
}

Test-Case 'the suite itself carries no host identifier: only the two synthetic fixture titles' {
    $self = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'window-rects-probe.Tests.ps1'))
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
    Assert-True $ran '-NoRun must bind and return without running the probe'
    Assert-True ($null -ne (Get-Command Select-ProbeWindows -ErrorAction SilentlyContinue)) 'the helpers are defined'
}

Test-Case 'an explicit -OutPath binds alongside -NoRun' {
    $ran = $true
    try { & $script:SubjectPath -NoRun -OutPath 'ignored.txt' } catch { $ran = $false }
    Assert-True $ran
}

# -------------------------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------------------------

Write-Host ''
Write-Host ("{0} test(s), {1} failed, {2} skipped" -f $script:TestTotal, $script:TestFailed, $script:TestSkipped.Count)
if ($script:TestSkipped.Count -gt 0) {
    Write-Host ''
    Write-Host '  SKIPPED (this runner could not host these -- they are NOT passes):'
    foreach ($sk in $script:TestSkipped) { Write-Host "  - $sk" }
}
if ($script:TestFailed -gt 0) {
    Write-Host ''
    foreach ($f in $script:TestFailures) { Write-Host "  - $f" }
    exit 1
}
exit 0
