<#
.SYNOPSIS
    READ-ONLY host-side window-rectangle probe, run in the lab account's own RDP session by the
    lab relay (jobs/window-rects-1x.env / window-rects-2x.env ->
    powershell.exe -File \\tsclient\lab\window-rects-probe.ps1).

.DESCRIPTION
    Asks Windows directly what every visible top-level window's rectangles are, so the RAIL
    wire fields can be checked against an independent source (adr/0018 section 5.2 row 3).

    Why this exists. On the wire RAIL delivers windowOffsetX/Y (off), clientOffsetX/Y (coff) and
    windowClientDeltaX/Y (delta), and the read-only field trace found delta = off + K and
    coff = 2*off + K -- K (window origin -> client-area origin) is INFERRED from those three
    numbers, never measured, and all three logs share one parser, so they cannot disagree with
    each other. This probe measures the same quantities on the host:

        GetWindowRect          wr  -- the window rectangle in screen coordinates
        ClientToScreen(0,0)    cs  -- the client area's origin in screen coordinates
        GetClientRect          cr  -- the client area's size (its origin is always 0,0)
        DWMWA_EXTENDED_FRAME_BOUNDS
                               ef  -- the visible frame, i.e. wr minus the invisible resize halo
        GetDpiForWindow        dpi -- the DPI Windows believes that window is laid out for
        GetSystemMetricsForDpi     -- the frame/caption metrics at the session DPI, at 96 and 192

    K_host is then cs - wr.topleft, computed by the reader of the report; this script prints
    numbers and never an interpretation. HWND is the same 32-bit value RAIL sends as windowId,
    so every row joins to the [client-rect] lines of the same run by hwnd.

    DPI AWARENESS COMES FIRST. A process that is not per-monitor aware is fed virtualized
    coordinates on a session whose DPI is not the system DPI: at 200 % every rectangle above
    would come back divided by two and K with it, which is precisely the number under
    investigation. So the first thing this script does -- before any window call and before any
    DPI query -- is declare per-monitor DPI awareness v2 via SetProcessDpiAwarenessContext(-4),
    falling back to shcore's SetProcessDpiAwareness(PROCESS_PER_MONITOR_DPI_AWARE). Neither is
    guaranteed to succeed: if the host process was started with an awareness already baked in by
    its manifest, both calls fail and the coordinates in the report ARE virtualized. That is why
    the first line reports both which call succeeded (set-via=v2|shcore|none) and the awareness
    the thread actually ended up with (awareness=, from
    GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext()); 0 unaware, 1 system
    aware, 2 per-monitor aware -- v2 also reports 2, which is why set-via is printed next to it).
    A report with set-via=none and awareness other than 2 must not be read as a measurement of K.

    RED LINES. The report carries numbers, window class names and process image names only.
    The window TITLE is never written: only its length in UTF-16 code units and the first four
    bytes of SHA-256 over its UTF-16LE bytes (title-sha8), which is enough to tell two windows
    apart and to match a window across two runs, and is not the text. No user name, no computer
    name, no path and no window text reach the file. Class and process tokens are sanitised to
    printable ASCII without spaces (anything else becomes ?) so one row is always one line of
    space-separated key=value pairs, and are truncated at 64 characters with a trailing ~.

    Report shape (exact grammar; every value is a single token, decimal for counts and
    coordinates, 0x + 8 uppercase hex for style/exstyle/HRESULT, lowercase hex for title-sha8,
    n/a for any value whose call failed):

        [host-probe] awareness= set-via= system-dpi= session= pid= usable=
        [host-metrics] dpi= for= cxsizeframe= cysizeframe= cxpaddedborder= cycaption=
                       cxfixedframe= cyfixedframe= cxborder= cyborder=
                            (one line per DPI in ProbeFixedMetricDpi, plus the session's)
        [host-enum] read-utc= ps= enumerated= visible= rect-ok= selected= cap= truncated=
        [host-rect] hwnd= pid= proc= class= style= exstyle= owner= dpi= wr= ef= cs= cr=
                    title-len= title-sha8= [hr=]              (one line per selected window)
        RESULT: DONE | RESULT: FAILED <stage>/<ExceptionType>

    usable= is DERIVED, not measured: it is true only when the awareness declaration both took
    the intended route and landed (set-via=v2 AND awareness=2). It is a machine-readable form of
    the paragraph above -- a pre-registration can gate on that one key instead of on prose -- and
    it is the only judgement in the file. The script does NOT act on it: a run with usable=false
    still enumerates, still prints its rows and still ends RESULT: DONE, because the rows of a
    virtualized run are evidence OF the virtualization and throwing them away would hide it. The
    reader decides; the report only refuses to look fine.

    for= tells the session's own metrics line apart from the fixed ones. Without it a 1x session
    (system DPI 96) or a 2x session (192) printed two byte-identical [host-metrics] lines and a
    reader joining on dpi= could not tell a duplicate from a second measurement. for=session is
    written exactly once per report; the ProbeFixedMetricDpi lines are for=fixed.

    The line carries TWO different frame widths on purpose. cxsizeframe/cysizeframe are
    SM_CXSIZEFRAME/SM_CYSIZEFRAME (32/33), the RESIZABLE border -- what a sizeable top-level
    window such as the modern Notepad has. cxfixedframe/cyfixedframe are
    SM_CXFIXEDFRAME/SM_CYFIXEDFRAME (7/8), the NON-resizable dialog border -- and that is the
    metric the About window's border constant has to be compared with, because that window is a
    dialog and does not carry a sizing frame at all (controller ruling 2026-09-15). SM_CXFRAME /
    SM_CYFRAME are NOT printed: they are aliases of the sizing pair in WinUser.h (same indices
    32/33), so they could only ever repeat a number already on the line.

    The file is written twice: a short CHECKPOINT: started file as soon as the awareness and
    metric lines exist -- so a run that hangs in EnumWindows cannot leave the PREVIOUS run's
    complete report on the drive looking like a fresh success -- and the full report at the end.
    Even so the OPERATOR STEP from jobs/*.env applies: remove the previous *-out.txt before
    launching, because a job the host refuses before the script starts writes nothing at all.

    FAILURE SHAPES. A RESULT: FAILED file carries every line the run had produced before the
    exception, which means its length says where it died:

      RESULT: FAILED native/<Type>            one line, no header at all -- the Add-Type compile
                                              itself failed, which is the likeliest way this job
                                              dies on the host; nothing had been measured yet
      [host-probe] ... + RESULT: FAILED metrics/<Type>
                                              the process facts were read, the metric lines were
                                              not
      [host-probe] ... + three [host-metrics] ... + RESULT: FAILED enumerate|select|detail|report/<Type>
                                              everything before the windows survived

    So a one-line file is a real and expected result, not a truncated report. Only CHECKPOINT:
    started files end without any RESULT line at all.

    Windows PowerShell 5.1 notes: no ??, no ternary, no ForEach-Object -Parallel; the P/Invoke
    surface is compiled once by Add-Type inside Initialize-ProbeNative, which is the only
    function that touches Windows and is called only when -NoRun is absent. Every native call is
    made through Invoke-ProbeCall, which turns a missing export (GetDpiForWindow, GetDpiForSystem
    and GetSystemMetricsForDpi all arrived in Windows 10 1607, SetProcessDpiAwarenessContext in
    1703) or a refused handle into $null, i.e. into n/a in the report, rather than into a dead
    run.

.PARAMETER OutPath
    Where the report is written. The default is the redirected lab drive the relay mounts.

.PARAMETER NoRun
    Define the functions and constants but touch nothing. window-rects-probe.Tests.ps1
    dot-sources the script this way and drives the pure helpers with synthetic records on macOS.
#>

[CmdletBinding()]
param(
    [string] $OutPath = '\\tsclient\lab\window-rects-out.txt',
    [switch] $NoRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------------------------------
# Pre-registered constants (pinned by the test suite; change them there too or the suite fails)
# -------------------------------------------------------------------------------------------

# Most rows this report will ever carry. A RAIL session under test holds a handful of windows;
# the cap exists so a session that somehow enumerates hundreds cannot turn one relay job into an
# unbounded file. Truncation is never silent: [host-enum] prints rect-ok and selected side by
# side plus truncated=true.
$script:ProbeMaxRows = 64

# DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 is the pseudo-handle (DPI_AWARENESS_CONTEXT)-4.
$script:ProbeAwarenessContextPerMonitorV2 = -4
# PROCESS_DPI_AWARENESS.PROCESS_PER_MONITOR_DPI_AWARE, the shcore fallback's argument.
$script:ProbeShcorePerMonitorAwareness = 2
# The closed set of set-via values. Anything else is reported as none rather than pasted in.
$script:ProbeSetViaValues = @('v2', 'shcore', 'none')

# The closed set of [host-metrics] for= values: the session's own DPI, or one of the fixed DPIs
# every report carries. Anything else renders n/a -- a marker that the caller passed something the
# grammar does not admit, never a line that silently claims to be the session's.
$script:ProbeMetricsForValues = @('session', 'fixed')

# usable= on [host-probe] is true only for this pair: the declaration took the v2 route AND the
# thread ended up per-monitor aware. DPI_AWARENESS.PER_MONITOR_AWARE is 2 (v2 reports 2 as well --
# there is no separate enum value for it, which is exactly why set-via has to agree).
$script:ProbeUsableSetVia = 'v2'
$script:ProbeUsableAwareness = 2

# GetSystemMetricsForDpi indices, in the order the [host-metrics] line prints them. The two
# frame pairs are DIFFERENT metrics, not a repetition: 32/33 is the resizable (sizing) border a
# sizeable window has, 7/8 is the fixed dialog border -- the one to compare the About window's
# constant against. SM_CXFRAME/SM_CYFRAME are deliberately absent: WinUser.h defines them as the
# same 32/33, so printing them would only duplicate the sizing pair.
$script:ProbeMetricIndex = [ordered]@{
    cxsizeframe    = 32  # SM_CXSIZEFRAME   -- resizable border width, per DPI
    cysizeframe    = 33  # SM_CYSIZEFRAME   -- resizable border height, per DPI
    cxpaddedborder = 92  # SM_CXPADDEDBORDER -- the border padding added to the sizing border
    cycaption      = 4   # SM_CYCAPTION     -- caption height (the About dialog's K_y candidate)
    cxfixedframe   = 7   # SM_CXFIXEDFRAME  -- non-resizable (dialog) border width, K_x candidate
    cyfixedframe   = 8   # SM_CYFIXEDFRAME  -- non-resizable (dialog) border height
    cxborder       = 5   # SM_CXBORDER      -- window border width
    cyborder       = 6   # SM_CYBORDER      -- window border height
}

# The two fixed DPIs every report carries next to the session's own, so a 1x and a 2x run can be
# compared without knowing what either session's DPI was: 96 = 100 %, 192 = 200 %.
$script:ProbeFixedMetricDpi = @(96, 192)

# Sanitised tokens (class, proc) are cut here and marked with a trailing ~.
$script:ProbeTokenMaxLength = 64

# -------------------------------------------------------------------------------------------
# Pure helpers (no host state; exercised off-Windows by the test suite)
# -------------------------------------------------------------------------------------------

function Get-ProbeProp {
    <# A property value, or null when the object is null or lacks the property (StrictMode-safe). #>
    [CmdletBinding()]
    param([AllowNull()] $Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Format-ProbeInt {
    <#
      A decimal integer token, or n/a when the value is missing or is not a number. Invariant
      culture: a host running a culture with non-ASCII digits must not be able to rewrite the
      grammar.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return 'n/a' }
    try {
        return ([int64]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return 'n/a'
    }
}

function Format-ProbeHex32 {
    <# 0x + 8 uppercase hex over the low 32 bits (styles and HRESULTs), or n/a. #>
    [CmdletBinding()]
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return 'n/a' }
    try {
        # 0xFFFFFFFFL, with the long suffix: PowerShell parses the bare literal 0xFFFFFFFF as
        # [int] -1, and -band -1 leaves a negative HRESULT negative, which [uint32] then refuses
        # -- an extended-frame failure would have printed hr=n/a instead of its real HRESULT.
        $low = ([int64]$Value) -band 0xFFFFFFFFL
        return '0x' + ([uint32]$low).ToString('X8', [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return 'n/a'
    }
}

function Format-Rect {
    <#
      "l,t,r,b" from anything carrying Left/Top/Right/Bottom (the native RECT and the suite's
      fixtures both do). Any missing or non-numeric edge makes the WHOLE rectangle n/a: half a
      rectangle is not a measurement.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Rect)
    if ($null -eq $Rect) { return 'n/a' }
    $parts = New-Object System.Collections.ArrayList
    foreach ($name in @('Left', 'Top', 'Right', 'Bottom')) {
        $text = Format-ProbeInt -Value (Get-ProbeProp -Object $Rect -Name $name)
        if ($text -eq 'n/a') { return 'n/a' }
        [void]$parts.Add($text)
    }
    return ($parts.ToArray() -join ',')
}

function Format-Size {
    <# "w,h" from a RECT: right-left, bottom-top. GetClientRect's origin is always 0,0, but the
       subtraction is done anyway so the helper is correct for any rectangle. #>
    [CmdletBinding()]
    param([AllowNull()] $Rect)
    if ($null -eq $Rect) { return 'n/a' }
    $l = Get-ProbeProp -Object $Rect -Name 'Left'
    $t = Get-ProbeProp -Object $Rect -Name 'Top'
    $r = Get-ProbeProp -Object $Rect -Name 'Right'
    $b = Get-ProbeProp -Object $Rect -Name 'Bottom'
    if ($null -eq $l -or $null -eq $t -or $null -eq $r -or $null -eq $b) { return 'n/a' }
    try {
        $w = ([int64]$r) - ([int64]$l)
        $h = ([int64]$b) - ([int64]$t)
    } catch {
        return 'n/a'
    }
    return (Format-ProbeInt -Value $w) + ',' + (Format-ProbeInt -Value $h)
}

function Format-Point {
    <# "x,y" from anything carrying X/Y (the native POINT and the suite's fixtures). #>
    [CmdletBinding()]
    param([AllowNull()] $Point)
    if ($null -eq $Point) { return 'n/a' }
    $x = Format-ProbeInt -Value (Get-ProbeProp -Object $Point -Name 'X')
    $y = Format-ProbeInt -Value (Get-ProbeProp -Object $Point -Name 'Y')
    if ($x -eq 'n/a' -or $y -eq 'n/a') { return 'n/a' }
    return "$x,$y"
}

function ConvertTo-ProbeToken {
    <#
      A class name or process image name reduced to one grammar-safe token: printable ASCII
      without space (0x21-0x7E) survives, everything else -- space, tab, any non-ASCII letter --
      becomes ?, and the result is cut at ProbeTokenMaxLength with a trailing ~. An empty string
      is a real answer (some windows have an empty class) and renders <empty>; a missing value
      renders n/a. Without this one class name containing a space would split into two tokens
      and shift every following key=value pair of that row.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return 'n/a' }
    $text = [string]$Value
    if ($text.Length -eq 0) { return '<empty>' }
    $sb = New-Object System.Text.StringBuilder
    $take = $text.Length
    if ($take -gt $script:ProbeTokenMaxLength) { $take = $script:ProbeTokenMaxLength }
    for ($i = 0; $i -lt $take; $i++) {
        $code = [int][char]$text[$i]
        if ($code -ge 33 -and $code -le 126) {
            [void]$sb.Append($text[$i])
        } else {
            [void]$sb.Append('?')
        }
    }
    if ($text.Length -gt $script:ProbeTokenMaxLength) { [void]$sb.Append('~') }
    return $sb.ToString()
}

function ConvertTo-TitleSha8 {
    <#
      The first four bytes of SHA-256 over the title's UTF-16LE bytes, as 8 lowercase hex
      digits; none for a missing or empty title. This is the ONLY thing derived from a window
      title that is allowed to reach the report -- it tells two windows apart and matches one
      window across two runs without carrying the text.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Title)
    if ($null -eq $Title) { return 'none' }
    $text = [string]$Title
    if ($text.Length -eq 0) { return 'none' }
    $bytes = [Text.Encoding]::Unicode.GetBytes($text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 4; $i++) {
        [void]$sb.Append($hash[$i].ToString('x2', [Globalization.CultureInfo]::InvariantCulture))
    }
    return $sb.ToString()
}

function Select-ProbeSetVia {
    <# The set-via token, restricted to the pre-registered closed set. #>
    [CmdletBinding()]
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return 'none' }
    $text = [string]$Value
    if ($script:ProbeSetViaValues -contains $text) { return $text }
    return 'none'
}

function Select-ProbeMetricsFor {
    <# The [host-metrics] for= token, restricted to the pre-registered closed set. #>
    [CmdletBinding()]
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return 'n/a' }
    $text = [string]$Value
    if ($script:ProbeMetricsForValues -contains $text) { return $text }
    return 'n/a'
}

function Test-ProbeUsable {
    <#
      Whether the report may be read as a measurement of K: the awareness declaration took the v2
      route AND the thread came out per-monitor aware. Derived from the same two fields the line
      already prints, so usable= can never contradict awareness= / set-via=. set-via is normalised
      first, so a value outside the closed set (which prints as none) cannot claim usable.
    #>
    [CmdletBinding()]
    param([AllowNull()] $SetVia, [AllowNull()] $Awareness)
    if ((Select-ProbeSetVia -Value $SetVia) -ne $script:ProbeUsableSetVia) { return $false }
    if ($null -eq $Awareness) { return $false }
    try {
        return ([int]$Awareness -eq $script:ProbeUsableAwareness)
    } catch {
        return $false
    }
}

function Test-ProbeWindowVisible {
    <# IsWindowVisible as recorded on the base record. #>
    [CmdletBinding()]
    param([AllowNull()] $Window)
    $v = Get-ProbeProp -Object $Window -Name 'Visible'
    if ($null -eq $v) { return $false }
    return [bool]$v
}

function Test-ProbeWindowRectOk {
    <#
      "GetWindowRect came back non-empty": the call succeeded (a rectangle is present) and it has
      positive width AND height. A zero-area rectangle is what a hidden helper window reports and
      says nothing about frames.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Window)
    $rect = Get-ProbeProp -Object $Window -Name 'WindowRect'
    if ($null -eq $rect) { return $false }
    $l = Get-ProbeProp -Object $rect -Name 'Left'
    $t = Get-ProbeProp -Object $rect -Name 'Top'
    $r = Get-ProbeProp -Object $rect -Name 'Right'
    $b = Get-ProbeProp -Object $rect -Name 'Bottom'
    if ($null -eq $l -or $null -eq $t -or $null -eq $r -or $null -eq $b) { return $false }
    try {
        if (([int64]$r - [int64]$l) -le 0) { return $false }
        if (([int64]$b - [int64]$t) -le 0) { return $false }
    } catch {
        return $false
    }
    return $true
}

function Select-ProbeWindows {
    <#
      The rows the report will carry: visible windows with a non-empty rectangle, ordered by
      hwnd ascending, capped at Cap. Ordering comes BEFORE the cap on purpose -- the selection
      must not depend on the z-order EnumWindows happened to walk, so two runs of the same
      session choose the same windows. Hwnd is unique, so the sort needs no stability guarantee
      (Windows PowerShell 5.1 has no Sort-Object -Stable).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()] $Windows,
        [int] $Cap = -1
    )
    if ($Cap -lt 0) { $Cap = $script:ProbeMaxRows }
    $kept = New-Object System.Collections.ArrayList
    if ($null -ne $Windows) {
        foreach ($w in $Windows) {
            if ($null -eq $w) { continue }
            if (-not (Test-ProbeWindowVisible -Window $w)) { continue }
            if (-not (Test-ProbeWindowRectOk -Window $w)) { continue }
            [void]$kept.Add($w)
        }
    }
    $sorted = @($kept.ToArray() | Sort-Object -Property @{ Expression = { [int64](Get-ProbeProp -Object $_ -Name 'Hwnd') } })
    if ($Cap -ge 0 -and $sorted.Count -gt $Cap) {
        if ($Cap -eq 0) { return @() }
        $sorted = @($sorted[0..($Cap - 1)])
    }
    return @($sorted)
}

function Measure-ProbeWindows {
    <#
      The three counts the [host-enum] line reports, over the windows as enumerated: how many
      came back from EnumWindows, how many of those are visible, and how many of THOSE also have
      a non-empty rectangle. rect-ok minus selected is what the cap dropped.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()] $Windows)
    $enumerated = 0
    $visible = 0
    $rectOk = 0
    if ($null -ne $Windows) {
        foreach ($w in $Windows) {
            if ($null -eq $w) { continue }
            $enumerated++
            if (-not (Test-ProbeWindowVisible -Window $w)) { continue }
            $visible++
            if (Test-ProbeWindowRectOk -Window $w) { $rectOk++ }
        }
    }
    return [pscustomobject]@{
        Enumerated = $enumerated
        Visible    = $visible
        RectOk     = $rectOk
    }
}

function New-ProbeMetricsPlan {
    <#
      Which [host-metrics] lines a report carries, in order: the session's own DPI first
      (for=session, exactly once), then one line per pre-registered fixed DPI (for=fixed). The
      session line is kept even when its DPI is already one of the fixed ones -- dropping it would
      make the report's shape depend on the session, and for= is what tells the two apart.
    #>
    [CmdletBinding()]
    param([AllowNull()] $SessionDpi)
    $plan = New-Object System.Collections.ArrayList
    [void]$plan.Add([pscustomobject]@{ Dpi = $SessionDpi; For = 'session' })
    foreach ($dpi in @($script:ProbeFixedMetricDpi)) {
        [void]$plan.Add([pscustomobject]@{ Dpi = $dpi; For = 'fixed' })
    }
    return @($plan.ToArray())
}

function Format-HostProbeRow {
    <#
      "[host-probe] awareness= set-via= system-dpi= session= pid= usable=" -- the report's first
      line. usable= is derived here from the two fields printed beside it (see Test-ProbeUsable),
      so the verdict and the evidence for it always travel together and cannot disagree.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Probe)
    $setVia = Get-ProbeProp -Object $Probe -Name 'SetVia'
    $awareness = Get-ProbeProp -Object $Probe -Name 'Awareness'
    $usable = 'false'
    if (Test-ProbeUsable -SetVia $setVia -Awareness $awareness) { $usable = 'true' }
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('[host-probe]')
    [void]$parts.Add('awareness=' + (Format-ProbeInt -Value $awareness))
    [void]$parts.Add('set-via=' + (Select-ProbeSetVia -Value $setVia))
    [void]$parts.Add('system-dpi=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Probe -Name 'SystemDpi')))
    [void]$parts.Add('session=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Probe -Name 'SessionId')))
    [void]$parts.Add('pid=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Probe -Name 'ProcessId')))
    [void]$parts.Add('usable=' + $usable)
    return ($parts.ToArray() -join ' ')
}

function Format-HostMetricsRow {
    <#
      "[host-metrics] dpi= for= <every ProbeMetricIndex key in order>". The keys drive both the
      collection and this line, so a metric can never be collected under one name and printed
      under another. for= comes second so that the session's line stays distinguishable from a
      fixed line of the same DPI even when only the first two tokens are read.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Metrics)
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('[host-metrics]')
    [void]$parts.Add('dpi=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Metrics -Name 'dpi')))
    [void]$parts.Add('for=' + (Select-ProbeMetricsFor -Value (Get-ProbeProp -Object $Metrics -Name 'for')))
    foreach ($name in $script:ProbeMetricIndex.Keys) {
        [void]$parts.Add($name + '=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Metrics -Name $name)))
    }
    return ($parts.ToArray() -join ' ')
}

function Format-HostEnumRow {
    <#
      "[host-enum] read-utc= ps= enumerated= visible= rect-ok= selected= cap= truncated=".

      Not in the original grammar sketch and added deliberately (declared as a deviation): a cap
      that drops windows silently is unfalsifiable -- a reader of a 64-row report could not tell
      whether the window they came for was missing or never existed -- and a report with no read
      time cannot be told apart from the previous run's file left on the redirected drive. Both
      failures have bitten this lab before (jobs/server-snapshot.env's OPERATOR STEP note).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $ReadUtc,
        [AllowNull()] $PsVersion,
        [int] $Enumerated,
        [int] $Visible,
        [int] $RectOk,
        [int] $Selected,
        [int] $Cap
    )
    $truncated = 'false'
    if ($RectOk -gt $Selected) { $truncated = 'true' }
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('[host-enum]')
    [void]$parts.Add('read-utc=' + (ConvertTo-ProbeToken -Value $ReadUtc))
    [void]$parts.Add('ps=' + (ConvertTo-ProbeToken -Value $PsVersion))
    [void]$parts.Add('enumerated=' + (Format-ProbeInt -Value $Enumerated))
    [void]$parts.Add('visible=' + (Format-ProbeInt -Value $Visible))
    [void]$parts.Add('rect-ok=' + (Format-ProbeInt -Value $RectOk))
    [void]$parts.Add('selected=' + (Format-ProbeInt -Value $Selected))
    [void]$parts.Add('cap=' + (Format-ProbeInt -Value $Cap))
    [void]$parts.Add('truncated=' + $truncated)
    return ($parts.ToArray() -join ' ')
}

function Format-HostRectRow {
    <#
      One window, one line:

        [host-rect] hwnd= pid= proc= class= style= exstyle= owner= dpi= wr= ef= cs= cr=
                    title-len= title-sha8= [hr=]

      title-len and title-sha8 are BOTH derived from the same Title field here, so the two can
      never disagree, and the title itself is the one thing this function must never emit. hr=
      is appended only when the DWM extended-frame call failed: it carries that call's HRESULT
      (or the HResult of the exception that stopped it), which is the difference between "DWM
      says this window has no frame bounds" and "the call never happened".
    #>
    [CmdletBinding()]
    param([AllowNull()] $Window)
    $title = Get-ProbeProp -Object $Window -Name 'Title'
    $titleLength = $null
    if ($null -ne $title) { $titleLength = ([string]$title).Length }
    $frame = Get-ProbeProp -Object $Window -Name 'ExtendedFrame'

    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('[host-rect]')
    [void]$parts.Add('hwnd=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Window -Name 'Hwnd')))
    [void]$parts.Add('pid=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Window -Name 'ProcessId')))
    [void]$parts.Add('proc=' + (ConvertTo-ProbeToken -Value (Get-ProbeProp -Object $Window -Name 'ProcessName')))
    [void]$parts.Add('class=' + (ConvertTo-ProbeToken -Value (Get-ProbeProp -Object $Window -Name 'ClassName')))
    [void]$parts.Add('style=' + (Format-ProbeHex32 -Value (Get-ProbeProp -Object $Window -Name 'Style')))
    [void]$parts.Add('exstyle=' + (Format-ProbeHex32 -Value (Get-ProbeProp -Object $Window -Name 'ExStyle')))
    [void]$parts.Add('owner=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Window -Name 'Owner')))
    [void]$parts.Add('dpi=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Window -Name 'Dpi')))
    [void]$parts.Add('wr=' + (Format-Rect -Rect (Get-ProbeProp -Object $Window -Name 'WindowRect')))
    [void]$parts.Add('ef=' + (Format-Rect -Rect $frame))
    [void]$parts.Add('cs=' + (Format-Point -Point (Get-ProbeProp -Object $Window -Name 'ClientScreen')))
    [void]$parts.Add('cr=' + (Format-Size -Rect (Get-ProbeProp -Object $Window -Name 'ClientRect')))
    [void]$parts.Add('title-len=' + (Format-ProbeInt -Value $titleLength))
    [void]$parts.Add('title-sha8=' + (ConvertTo-TitleSha8 -Title $title))
    if ($null -eq $frame) {
        $hr = Get-ProbeProp -Object $Window -Name 'ExtendedFrameHr'
        if ($null -ne $hr) { [void]$parts.Add('hr=' + (Format-ProbeHex32 -Value $hr)) }
    }
    return ($parts.ToArray() -join ' ')
}

function Format-ProbeReport {
    <#
      The whole file as an array of lines. selected= is derived HERE from the window array that
      is about to be printed, never taken from the caller: the count and the rows cannot
      disagree.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $Probe,
        [AllowNull()][AllowEmptyCollection()] $Metrics,
        [AllowNull()] $Stats,
        [AllowNull()][AllowEmptyCollection()] $Windows,
        [string] $Result
    )
    $rows = @()
    if ($null -ne $Windows) { $rows = @($Windows) }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add((Format-HostProbeRow -Probe $Probe))
    if ($null -ne $Metrics) {
        foreach ($m in @($Metrics)) { [void]$lines.Add((Format-HostMetricsRow -Metrics $m)) }
    }
    [void]$lines.Add((Format-HostEnumRow `
        -ReadUtc (Get-ProbeProp -Object $Stats -Name 'ReadUtc') `
        -PsVersion (Get-ProbeProp -Object $Stats -Name 'PsVersion') `
        -Enumerated ([int](Get-ProbeProp -Object $Stats -Name 'Enumerated')) `
        -Visible ([int](Get-ProbeProp -Object $Stats -Name 'Visible')) `
        -RectOk ([int](Get-ProbeProp -Object $Stats -Name 'RectOk')) `
        -Selected $rows.Count `
        -Cap ([int](Get-ProbeProp -Object $Stats -Name 'Cap'))))
    foreach ($w in $rows) { [void]$lines.Add((Format-HostRectRow -Window $w)) }
    [void]$lines.Add($Result)
    return @($lines.ToArray())
}

function Write-ProbeReport {
    <#
      UTF-8 without BOM (what [IO.File]::WriteAllLines writes); every token this report can
      produce is ASCII already, because ConvertTo-ProbeToken guarantees it. Set-Content is not
      used: Windows PowerShell 5.1's -Encoding UTF8 writes a BOM, and -Encoding ASCII would turn
      a non-ASCII class name into a silent ? that did not come from the sanitiser.

      OutPath goes to the .NET API as given, so a RELATIVE path would resolve against the
      process's working directory rather than against PowerShell's current location -- the two
      differ often enough to matter. Every shipped caller passes the absolute UNC default, and the
      job files never override it.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][string[]] $Lines, [string] $OutPath)
    $payload = @()
    if ($null -ne $Lines) { $payload = @($Lines) }
    [IO.File]::WriteAllLines($OutPath, [string[]]$payload)
}

# -------------------------------------------------------------------------------------------
# Host-side collection (Windows only; never reached under -NoRun)
# -------------------------------------------------------------------------------------------

function Invoke-ProbeCall {
    <#
      Every native call goes through here: a missing export (GetDpiForWindow and
      GetSystemMetricsForDpi do not exist before Windows 10 1607, SetProcessDpiAwarenessContext
      before 1703), a handle the session refuses, a window that died between EnumWindows and the
      call -- all of them become $null, which the formatters render as n/a. A probe that dies on
      one unlucky window would be worth nothing; a probe that says n/a on it is still a
      measurement of every other window.
    #>
    [CmdletBinding()]
    param([scriptblock] $Call)
    try {
        return (& $Call)
    } catch {
        return $null
    }
}

function Initialize-ProbeNative {
    <#
      Compiles the P/Invoke surface once per process. This is the ONLY function in this file
      that requires Windows, and it is called only from Invoke-WindowRectsProbe, which runs only
      when -NoRun is absent -- that is what lets the whole file be dot-sourced on macOS.
    #>
    [CmdletBinding()]
    param()
    if ($null -ne ('MacdowsLab.WindowProbeNative' -as [type])) { return }
    $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace MacdowsLab
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    public class DwmFrame
    {
        public bool Ok;
        public int Hr;
        public RECT Bounds;
    }

    public static class WindowProbeNative
    {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "GetClassNameW")]
        private static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "GetWindowTextW")]
        private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "GetWindowTextLengthW")]
        private static extern int GetWindowTextLengthW(IntPtr hWnd);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
        [DllImport("user32.dll", SetLastError = true, EntryPoint = "GetWindowLongW")]
        private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll", SetLastError = true, EntryPoint = "GetWindowLongPtrW")]
        private static extern IntPtr GetWindowLong64(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetDpiForWindow(IntPtr hWnd);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetDpiForSystem();
        [DllImport("user32.dll", SetLastError = true)]
        private static extern int GetSystemMetricsForDpi(int nIndex, uint dpi);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")]
        private static extern IntPtr GetThreadDpiAwarenessContext();
        [DllImport("user32.dll")]
        private static extern int GetAwarenessFromDpiAwarenessContext(IntPtr value);
        [DllImport("shcore.dll")]
        private static extern int SetProcessDpiAwareness(int value);
        [DllImport("dwmapi.dll")]
        private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out RECT pvAttribute, int cbAttribute);

        // GetWindowLong indices and GetWindow command, spelled out so the numbers in the calls
        // below are never bare: GWL_STYLE = -16, GWL_EXSTYLE = -20, GW_OWNER = 4.
        private const int GWL_STYLE = -16;
        private const int GWL_EXSTYLE = -20;
        private const uint GW_OWNER = 4;
        // DWMWA_EXTENDED_FRAME_BOUNDS, the ninth DWMWINDOWATTRIBUTE.
        private const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

        // The caller passes the awareness constants in, so the one place they are written down
        // is the PowerShell constants block that the test suite pins.
        public static bool SetPerMonitorAwareV2(int contextValue)
        {
            return SetProcessDpiAwarenessContext(new IntPtr(contextValue));
        }

        public static int SetAwarenessViaShcore(int awareness)
        {
            return SetProcessDpiAwareness(awareness);
        }

        public static int CurrentAwareness()
        {
            return GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext());
        }

        public static int SystemDpi()
        {
            return (int)GetDpiForSystem();
        }

        public static int WindowDpi(IntPtr hWnd)
        {
            return (int)GetDpiForWindow(hWnd);
        }

        public static int MetricForDpi(int index, int dpi)
        {
            return GetSystemMetricsForDpi(index, (uint)dpi);
        }

        public static IntPtr[] EnumTopLevel()
        {
            List<IntPtr> found = new List<IntPtr>();
            EnumWindowsProc callback = delegate(IntPtr hWnd, IntPtr lParam) { found.Add(hWnd); return true; };
            EnumWindows(callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            return found.ToArray();
        }

        public static bool VisibleOf(IntPtr hWnd)
        {
            return IsWindowVisible(hWnd);
        }

        // Boxed RECT/POINT or null: PowerShell reads the fields straight off the box, and a
        // failed call becomes $null, i.e. n/a, without an out-parameter dance on the script side.
        public static object WindowRectOf(IntPtr hWnd)
        {
            RECT r;
            if (GetWindowRect(hWnd, out r)) { return r; }
            return null;
        }

        public static object ClientRectOf(IntPtr hWnd)
        {
            RECT r;
            if (GetClientRect(hWnd, out r)) { return r; }
            return null;
        }

        public static object ClientOriginOf(IntPtr hWnd)
        {
            POINT p;
            p.X = 0;
            p.Y = 0;
            if (ClientToScreen(hWnd, ref p)) { return p; }
            return null;
        }

        public static DwmFrame ExtendedFrameOf(IntPtr hWnd)
        {
            DwmFrame frame = new DwmFrame();
            RECT r;
            int hr = DwmGetWindowAttribute(hWnd, DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(RECT)));
            frame.Hr = hr;
            frame.Ok = (hr == 0);
            frame.Bounds = r;
            return frame;
        }

        public static string ClassOf(IntPtr hWnd)
        {
            StringBuilder sb = new StringBuilder(256);
            int n = GetClassNameW(hWnd, sb, sb.Capacity);
            if (n <= 0) { return null; }
            return sb.ToString();
        }

        // GetWindowText does not send WM_GETTEXT across a process boundary (it copies the
        // window's cached text), so this cannot hang on an unresponsive window.
        public static string TitleOf(IntPtr hWnd)
        {
            int length = GetWindowTextLengthW(hWnd);
            if (length <= 0) { return string.Empty; }
            StringBuilder sb = new StringBuilder(length + 2);
            int n = GetWindowTextW(hWnd, sb, sb.Capacity);
            if (n <= 0) { return string.Empty; }
            return sb.ToString();
        }

        public static int ProcessIdOf(IntPtr hWnd)
        {
            uint pid = 0;
            GetWindowThreadProcessId(hWnd, out pid);
            return (int)pid;
        }

        public static long OwnerOf(IntPtr hWnd)
        {
            return GetWindow(hWnd, GW_OWNER).ToInt64();
        }

        public static long StyleOf(IntPtr hWnd)
        {
            return WindowLongOf(hWnd, GWL_STYLE);
        }

        public static long ExStyleOf(IntPtr hWnd)
        {
            return WindowLongOf(hWnd, GWL_EXSTYLE);
        }

        // GetWindowLongPtrW exists only in the 64-bit user32; on a 32-bit host the 32-bit entry
        // point is the whole API. The size test picks the one that is actually exported rather
        // than letting the first call throw EntryPointNotFoundException.
        private static long WindowLongOf(IntPtr hWnd, int index)
        {
            if (IntPtr.Size == 8) { return GetWindowLong64(hWnd, index).ToInt64(); }
            return (long)GetWindowLong32(hWnd, index);
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp
}

function Get-ProbeProcessName {
    <# Image name without extension for a pid, cached (many windows share one process), n/a when
       the process is gone or the account may not look at it. #>
    [CmdletBinding()]
    param([AllowNull()] $ProcessId, [AllowNull()] $Cache)
    if ($null -eq $ProcessId) { return $null }
    $key = [string]$ProcessId
    if ($null -ne $Cache -and $Cache.Contains($key)) { return $Cache[$key] }
    $name = $null
    try {
        $name = (Get-Process -Id ([int]$ProcessId) -ErrorAction Stop).ProcessName
    } catch {
        $name = $null
    }
    if ($null -ne $Cache) { $Cache[$key] = $name }
    return $name
}

function Get-ProbeWindowBase {
    <#
      The two facts the selection needs, for every enumerated handle: is it visible and what is
      its window rectangle. Nothing else is read here -- a window that will not be reported never
      has its title or class touched.
    #>
    [CmdletBinding()]
    param($Handle)
    $hwnd = Invoke-ProbeCall { $Handle.ToInt64() }
    return [pscustomobject]@{
        Handle     = $Handle
        Hwnd       = $hwnd
        Visible    = [bool](Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::VisibleOf($Handle) })
        WindowRect = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::WindowRectOf($Handle) }
    }
}

function Add-ProbeWindowDetail {
    <#
      Everything the row needs, read only for the windows that were selected. The DWM call keeps
      both halves of its answer: the bounds when it succeeded, the HRESULT either way.
    #>
    [CmdletBinding()]
    param($Window, [AllowNull()] $ProcessNameCache)
    $handle = Get-ProbeProp -Object $Window -Name 'Handle'
    $processId = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::ProcessIdOf($handle) }
    # The DWM call keeps its own try/catch instead of going through Invoke-ProbeCall: it is the
    # one call whose FAILURE is reported (as hr=), so the exception has to stay in hand. A call
    # that never happened at all -- dwmapi missing, marshalling refused -- reports that
    # exception's HResult, which is how "DWM has no frame bounds for this window" stays
    # distinguishable from "the call was never made".
    $frameBounds = $null
    $frameHr = $null
    try {
        $frame = [MacdowsLab.WindowProbeNative]::ExtendedFrameOf($handle)
        $frameHr = $frame.Hr
        if ($frame.Ok) { $frameBounds = $frame.Bounds }
    } catch {
        $frameHr = $_.Exception.HResult
    }
    return [pscustomobject]@{
        Handle          = $handle
        Hwnd            = Get-ProbeProp -Object $Window -Name 'Hwnd'
        Visible         = Get-ProbeProp -Object $Window -Name 'Visible'
        WindowRect      = Get-ProbeProp -Object $Window -Name 'WindowRect'
        ProcessId       = $processId
        ProcessName     = Get-ProbeProcessName -ProcessId $processId -Cache $ProcessNameCache
        ClassName       = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::ClassOf($handle) }
        Style           = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::StyleOf($handle) }
        ExStyle         = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::ExStyleOf($handle) }
        Owner           = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::OwnerOf($handle) }
        Dpi             = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::WindowDpi($handle) }
        ExtendedFrame   = $frameBounds
        ExtendedFrameHr = $frameHr
        ClientScreen    = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::ClientOriginOf($handle) }
        ClientRect      = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::ClientRectOf($handle) }
        Title           = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::TitleOf($handle) }
    }
}

function New-ProbeMetricsRecord {
    <#
      One [host-metrics] line's worth of GetSystemMetricsForDpi results for one DPI. For is the
      line's role -- 'session' for the DPI this session reported, 'fixed' for the pre-registered
      ones -- and is what keeps the lines distinguishable when the two DPIs coincide.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Dpi, [string] $For)
    $record = [ordered]@{ dpi = $Dpi; 'for' = $For }
    foreach ($name in $script:ProbeMetricIndex.Keys) {
        $value = $null
        if ($null -ne $Dpi) {
            $index = [int]$script:ProbeMetricIndex[$name]
            $value = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::MetricForDpi($index, [int]$Dpi) }
        }
        $record[$name] = $value
    }
    return [pscustomobject]$record
}

function Invoke-WindowRectsProbe {
    <#
      The run: declare awareness, read the process-wide facts, checkpoint the file, enumerate,
      select, detail the selection, write the report. Any exception ends as RESULT: FAILED
      <stage>/<ExceptionType> -- the stage name and the exception's type only, never its message,
      which could carry a path.
    #>
    [CmdletBinding()]
    param([string] $OutPath)

    $stage = 'start'
    $header = New-Object System.Collections.ArrayList
    try {
        $stage = 'native'
        Initialize-ProbeNative

        # ------------------------------------------------------------------------------------
        # DPI awareness FIRST: before any window call and before any DPI or metric query, so
        # nothing below is read through the compatibility scaler (see .DESCRIPTION).
        # ------------------------------------------------------------------------------------
        $stage = 'awareness'
        $setVia = 'none'
        $v2 = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::SetPerMonitorAwareV2($script:ProbeAwarenessContextPerMonitorV2) }
        if ($null -ne $v2 -and [bool]$v2) {
            $setVia = 'v2'
        } else {
            $hr = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::SetAwarenessViaShcore($script:ProbeShcorePerMonitorAwareness) }
            if ($null -ne $hr -and [int]$hr -eq 0) { $setVia = 'shcore' }
        }
        $awareness = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::CurrentAwareness() }

        $stage = 'process-facts'
        $systemDpi = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::SystemDpi() }
        if ($null -ne $systemDpi -and [int]$systemDpi -le 0) { $systemDpi = $null }
        $sessionId = Invoke-ProbeCall { (Get-Process -Id $PID -ErrorAction Stop).SessionId }
        $probe = [pscustomobject]@{
            Awareness = $awareness
            SetVia    = $setVia
            SystemDpi = $systemDpi
            SessionId = $sessionId
            ProcessId = $PID
        }

        # The header grows as it is produced, so a RESULT: FAILED file carries every line that
        # existed when the exception hit and its length says which stage died (see FAILURE SHAPES).
        [void]$header.Add((Format-HostProbeRow -Probe $probe))

        $stage = 'metrics'
        $metrics = New-Object System.Collections.ArrayList
        foreach ($entry in @(New-ProbeMetricsPlan -SessionDpi $systemDpi)) {
            $record = New-ProbeMetricsRecord -Dpi $entry.Dpi -For $entry.For
            [void]$metrics.Add($record)
            [void]$header.Add((Format-HostMetricsRow -Metrics $record))
        }
        # Checkpoint: from here on the drive cannot hold the PREVIOUS run's complete report under
        # this run's name. A partial file has no RESULT line at all, so it can never be misread
        # as a finished one.
        Write-ProbeReport -Lines (@($header.ToArray()) + @('CHECKPOINT: started')) -OutPath $OutPath

        $stage = 'enumerate'
        $handles = @()
        $enumerated = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::EnumTopLevel() }
        if ($null -ne $enumerated) { $handles = @($enumerated) }
        $bases = New-Object System.Collections.ArrayList
        foreach ($handle in $handles) { [void]$bases.Add((Get-ProbeWindowBase -Handle $handle)) }

        $stage = 'select'
        $counts = Measure-ProbeWindows -Windows @($bases.ToArray())
        $selected = @(Select-ProbeWindows -Windows @($bases.ToArray()) -Cap $script:ProbeMaxRows)

        $stage = 'detail'
        $cache = @{}
        $rows = New-Object System.Collections.ArrayList
        foreach ($window in $selected) {
            [void]$rows.Add((Add-ProbeWindowDetail -Window $window -ProcessNameCache $cache))
        }

        $stage = 'report'
        $stats = [pscustomobject]@{
            ReadUtc    = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            PsVersion  = $PSVersionTable.PSVersion.ToString()
            Enumerated = $counts.Enumerated
            Visible    = $counts.Visible
            RectOk     = $counts.RectOk
            Cap        = $script:ProbeMaxRows
        }
        $lines = Format-ProbeReport -Probe $probe -Metrics @($metrics.ToArray()) -Stats $stats -Windows $rows.ToArray() -Result 'RESULT: DONE'
        Write-ProbeReport -Lines $lines -OutPath $OutPath
    } catch {
        $reason = $stage + '/' + $_.Exception.GetType().Name
        try {
            Write-ProbeReport -Lines (@($header.ToArray()) + @("RESULT: FAILED $reason")) -OutPath $OutPath
        } catch {
            # The drive itself is gone; the relay's own log is the only remaining evidence.
        }
    }
}

if (-not $NoRun) {
    Invoke-WindowRectsProbe -OutPath $OutPath
    # Always 0: the relay writes the run's real rc into relay.log, and a non-zero exit here would
    # only leave a [Process completed] Terminal window behind (owner rule).
    exit 0
}
