<#
.SYNOPSIS
    READ-ONLY in-session geometry timeline: samples every visible top-level window's rectangles
    a few times a second from inside the lab account's own RDP session, ACROSS relay
    disconnects, and writes the samples to a host-local file.

.DESCRIPTION
    window-rects-probe.ps1 answers "where were the windows when the probe connected". That is
    one instant, and it is an instant during a DIFFERENT connection from the one under study: a
    client that joins a retained session with its own declared desktop scale can make the server
    re-lay-out the session, so the probe can never rule out that it measured a state which never
    existed while the smoke run was connected. This script is the other half. It is started by
    window-loop-start.ps1 inside one relay connection, keeps running after that connection is
    gone (the session survives an xfreerdp exit -- a disconnect is not a logoff, which is the
    premise the whole probe lane already rests on), and so covers the entire span

        relay disconnects -> window-smoke connects -> windows are created / moved / resized
        -> smoke disconnects -> the probe's relay connects

    with one sample every IntervalMs. The reader joins a sample to the wire trace by hwnd (RAIL's
    windowId) and to the probe's report by hwnd and by the UTC stamp, which is deliberately the
    same round-trip format window-rects-probe.ps1 prints on [host-enum] read-utc=.

    NOTHING IS MEASURED TWICE. Every formatter, the token sanitiser, the title digest, the
    selection, the per-window detail read and the P/Invoke surface itself come from
    window-rects-probe.ps1, which is dot-sourced with -NoRun at start-up. Copying them would give
    the lab two implementations of one red-line promise, free to drift apart. The cost is a name
    dependency on the probe's functions -- and the probe's own suite pins those names.

    DPI AWARENESS COMES FIRST, for the same reason as in the probe and by the same route: before
    any window or metric call, per-monitor-v2 is declared via the probe's
    SetPerMonitorAwareV2 wrapper with the shcore fallback behind it, and the header line records
    both which call succeeded (set-via=) and the awareness the thread ended up with (awareness=).
    A run with set-via=none and awareness other than 2 is reporting virtualized coordinates and
    must not be read as a measurement of geometry. There is no usable= key here: the two fields
    it would be derived from are on the same line, and the probe's report -- taken in the same
    session minutes later -- already carries the verdict in the form a pre-registration gates on.

    RED LINES. Exactly as the probe: numbers, window class names and process image names only.
    The window TITLE is never written, only its length in UTF-16 code units and title-sha8. No
    user name, no computer name, no path and no window text reach the file. The launcher's done
    marker carries no path either.

    Output grammar (every value a single token, n/a for any value whose call failed):

        [loop-head] utc= ps= pid= session= interval-ms= max-seconds= deadline-utc= awareness=
                    set-via=                                              (exactly once, first)
        [loop-tick] seq= utc= cx= cy= wa= [truncated=true] [torn=<n>] [desktop-changed=1]
                                                                      (one line per sample)
        [tick-rect] seq= hwnd= pid= proc= class= style= dpi= wr= ef= cs= cr= owner= title-len=
                    title-sha8=                       (one line per selected window per sample)
        RESULT: DONE seq=<n> reason=<sentinel|deadline>
        RESULT: FAILED <stage>/<ExceptionType>

    seq counts from 0 and is the ONLY grouping key: a [loop-tick] and the [tick-rect] rows that
    follow it carry the same seq, which is what lets a reader reassemble one instant out of an
    append-only file. cx/cy are SM_CXSCREEN/SM_CYSCREEN -- the desktop size AT THAT INSTANT,
    which is the number that changes when a joining client re-lays out the session -- and wa is
    SPI_GETWORKAREA. The window set per tick is the probe's Select-ProbeWindows with the probe's
    cap; a tick that hit the cap says truncated=true rather than dropping rows in silence.

    A SAMPLE IS NOT AN INSTANT, AND SAYS SO. One tick reads the desktop metrics, then a window
    rectangle for every top-level window, then sorts and caps them, then reads each selected
    window's four rectangles -- hundreds of native calls, during which the server can re-lay-out
    the session underneath. When that happens the rows mix two layouts, which is exactly the
    tick a reader must not anchor on, and before 2026-09-21 nothing in the file said so (four of
    seven anchor rows in batch h2fix-20260921 were torn and were only caught by hand). Two
    optional tail fields on [loop-tick] now report it: torn=<n> counts the selected windows
    whose rectangle differed between the enumeration read and the detail read (the probe's
    Add-ProbeWindowDetail keeps both), and desktop-changed=1 says cx/cy/wa differed when re-read
    after the detail pass. Neither appears when there is nothing to report, so a quiet run is
    byte for byte the file it always was. NOTHING IS RE-SAMPLED: a torn tick is reported, not
    hidden, and the reader steps its anchor back a tick.

    STOPPING IS TRIPLE. (1) A hard deadline computed once at start-up and printed on the header,
    so a lost sentinel can never leave a process running in the owner's session; (2) the sentinel
    file, which window-loop-collect.ps1 writes and which is checked after every sample; (3) the
    file itself, written through an auto-flushing writer and flushed again after every sample, so
    a run that is killed outright -- by a logoff, or because a detached process does not survive
    a disconnect after all -- still leaves every sample it had taken. reason= tells the two clean
    endings apart: reason=deadline means the collector never reached the loop, which is a
    transport failure even though the data is good.

    FAILURE SHAPES. The file's length says where the run died: a missing file means the process
    never started or died before its first flush; a file with only [loop-head] means the first
    sample threw; ticks with no RESULT line at all mean the process was killed (the load-bearing
    unknown of this lane); RESULT: FAILED <stage>/<Type> is an orderly death, message-free
    because an exception message can carry a path. Since 2026-09-21 a tick is written as ONE
    group -- its [loop-tick] line and its rows are held until the detail pass has run, then
    flushed together -- so a kill during the detail pass loses that whole tick instead of
    leaving a tick line with a partial set of rows: the file then ends on the previous complete
    tick, and "where it died" is one tick earlier than the last line suggests.

    Windows PowerShell 5.1 notes: no ??, no ternary; every native call goes through the probe's
    Invoke-ProbeCall, so a missing export or a window that died between EnumWindows and the call
    becomes n/a rather than a dead run.

.PARAMETER OutPath
    Where the samples are written. Host-local by necessity: the redirected lab drive belongs to
    a connection and is gone the moment that connection ends. Empty falls back to the local lab
    directory.

.PARAMETER MaxSeconds
    The hard deadline, in seconds from start-up. 420 covers a smoke run plus a probe with room
    to spare while staying far under the batch's own per-step waits, so a stuck smoke run makes
    the loop stop by deadline (visibly) instead of filling the disk for a quarter of an hour.

.PARAMETER IntervalMs
    Sleep between samples. 250 ms is four samples a second, about 1680 for a full 420 s run.

.PARAMETER SentinelPath
    The file whose existence stops the run. window-loop-collect.ps1 creates it.

.PARAMETER ProbePath
    The local copy of window-rects-probe.ps1 to dot-source for the shared helpers.

.PARAMETER NoRun
    Define the functions and constants but touch nothing. window-loop.Tests.ps1 dot-sources the
    script this way and drives the pure helpers with synthetic records on macOS.
#>

[CmdletBinding()]
param(
    [string] $OutPath,
    [int] $MaxSeconds = 420,
    [int] $IntervalMs = 250,
    [string] $SentinelPath,
    [string] $ProbePath,
    [switch] $NoRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------------------------------
# Pre-registered constants (pinned by the test suite; change them there too or the suite fails)
# -------------------------------------------------------------------------------------------

# The closed set of stop reasons, in priority order: a run that was collected says sentinel even
# when the deadline had also passed, so "the sentinel never arrived" stays a distinguishable
# failure of the collection path rather than being absorbed into a normal ending.
$script:LoopStopReasons = @('sentinel', 'deadline')

# The host-local directory and file names. These are the whole contract between
# window-loop-start.ps1 (which builds the arguments), this script and window-loop-collect.ps1
# (which writes the sentinel and reads the samples back). The same literals are pinned in all
# three suites, so a rename in one file turns the other two red instead of quietly producing an
# empty batch. The directory is the one stage.ps1 already owns.
$script:LoopLocalDirName = 'macdows-lab'
$script:LoopOutName = 'window-loop-out.txt'
$script:LoopSentinelName = 'window-loop.stop'
$script:LoopProbeName = 'window-rects-probe.ps1'
# The name window-loop-collect.ps1 rotates the samples to once it has carried them back, so a
# half whose launcher never ran cannot have the PREVIOUS half's timeline collected as its own
# (gate r1 B2). Declared here only to keep the three-way name pin whole: this script must never
# open that file, and its suite pins that the name is referenced nowhere below.
$script:LoopOutPrevName = 'window-loop-out.prev.txt'

# -------------------------------------------------------------------------------------------
# Pure helpers (no host state; exercised off-Windows by the test suite)
#
# Format-ProbeInt, Format-Rect, Format-Point, Format-Size, Format-ProbeHex32, Get-ProbeProp,
# ConvertTo-ProbeToken, ConvertTo-TitleSha8 and Select-ProbeSetVia are NOT defined here: they
# come from window-rects-probe.ps1 (see .DESCRIPTION).
# -------------------------------------------------------------------------------------------

function Resolve-LoopPath {
    <#
      The path to use: the one that was passed, or the local lab directory's default name when
      nothing usable was. The launcher always passes all three; the fallback exists so a run
      started by hand -- or by a launcher that lost an argument -- still produces evidence
      instead of dying before its first line, which would look exactly like a process that never
      survived the disconnect.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Value, [string] $Root, [string] $Name)
    if ($null -ne $Value) {
        $text = ([string]$Value).Trim()
        if ($text.Length -gt 0) { return ([string]$Value) }
    }
    # Concatenated, not Join-Path: Join-Path resolves the drive qualifier through the provider,
    # so it throws on a path whose drive this machine does not have -- which is every Windows
    # path on the macOS / Linux runner the suite drives this function from. The result has to be
    # a Windows path regardless of where the string was built.
    return (([string]$Root).TrimEnd('\', '/') + '\' + $Name)
}

function Format-LoopHeadRow {
    <#
      "[loop-head] utc= ps= pid= session= interval-ms= max-seconds= deadline-utc= awareness=
       set-via=" -- the file's first line, written before the first sample.

      awareness= and set-via= are the same pair the probe prints, by the same rules, so the two
      files can be read against one another. deadline-utc= is on the header on purpose: a reader
      of a truncated file can tell "killed early" from "stopped as designed" without the RESULT
      line, simply by comparing the last tick's utc= with it.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Head)
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('[loop-head]')
    [void]$parts.Add('utc=' + (ConvertTo-ProbeToken -Value (Get-ProbeProp -Object $Head -Name 'Utc')))
    [void]$parts.Add('ps=' + (ConvertTo-ProbeToken -Value (Get-ProbeProp -Object $Head -Name 'PsVersion')))
    [void]$parts.Add('pid=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Head -Name 'ProcessId')))
    [void]$parts.Add('session=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Head -Name 'SessionId')))
    [void]$parts.Add('interval-ms=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Head -Name 'IntervalMs')))
    [void]$parts.Add('max-seconds=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Head -Name 'MaxSeconds')))
    [void]$parts.Add('deadline-utc=' + (ConvertTo-ProbeToken -Value (Get-ProbeProp -Object $Head -Name 'DeadlineUtc')))
    [void]$parts.Add('awareness=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Head -Name 'Awareness')))
    [void]$parts.Add('set-via=' + (Select-ProbeSetVia -Value (Get-ProbeProp -Object $Head -Name 'SetVia')))
    return ($parts.ToArray() -join ' ')
}

function Format-LoopTickRow {
    <#
      "[loop-tick] seq= utc= cx= cy= wa= [truncated=true] [torn=<n>] [desktop-changed=1]" -- one
      sample's session-wide facts, followed in the file by that sample's [tick-rect] rows
      carrying the same seq.

      truncated= is DERIVED here from the two counts the sample took, exactly as the probe's
      [host-enum] line does it, so the flag can never contradict the rows. It is appended rather
      than always present because a tick line is written four times a second: the common case
      pays no bytes for it, and its presence is the whole signal.

      torn= and desktop-changed= follow the same rule for the same reason, and their ORDER is
      part of the grammar -- truncated, then torn, then desktop-changed -- because a reader
      gates on the end of the line. torn=<n> is the number of selected windows whose window
      rectangle differed between the enumeration read and the detail read; zero is written as
      absence, never as torn=0, so a quiet tick is the line it has always been. desktop-changed
      is a flag and not a pair of values on purpose: cx=/cy=/wa= keep reporting what the sample
      OPENED with, which is what every existing reader gates on, and the re-read is never
      printed.

      A tick record that carries neither field -- the shape this function saw before 2026-09-21,
      and the shape a half-built record has when a sample threw -- renders the quiet line. A
      value that is not a number claims nothing rather than pasting itself into the grammar.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Tick)
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('[loop-tick]')
    [void]$parts.Add('seq=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Tick -Name 'Seq')))
    [void]$parts.Add('utc=' + (ConvertTo-ProbeToken -Value (Get-ProbeProp -Object $Tick -Name 'Utc')))
    [void]$parts.Add('cx=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Tick -Name 'Cx')))
    [void]$parts.Add('cy=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Tick -Name 'Cy')))
    [void]$parts.Add('wa=' + (Format-Rect -Rect (Get-ProbeProp -Object $Tick -Name 'WorkArea')))
    $rectOk = Get-ProbeProp -Object $Tick -Name 'RectOk'
    $selected = Get-ProbeProp -Object $Tick -Name 'Selected'
    if ($null -ne $rectOk -and $null -ne $selected) {
        try {
            if ([int64]$rectOk -gt [int64]$selected) { [void]$parts.Add('truncated=true') }
        } catch {
            # Neither count is a number, so nothing can be claimed about truncation. The row
            # stays in its common shape rather than asserting something it cannot know.
        }
    }
    $torn = Get-ProbeProp -Object $Tick -Name 'Torn'
    if ($null -ne $torn) {
        try {
            if ([int64]$torn -gt 0) { [void]$parts.Add('torn=' + (Format-ProbeInt -Value $torn)) }
        } catch {
            # Not a number, so no count can be claimed. Same rule as truncated= above.
        }
    }
    $desktopChanged = Get-ProbeProp -Object $Tick -Name 'DesktopChanged'
    if ($null -ne $desktopChanged) {
        try {
            if ([bool]$desktopChanged) { [void]$parts.Add('desktop-changed=1') }
        } catch {
            # Not a truth value; the tick says nothing about the desktop rather than guessing.
        }
    }
    return ($parts.ToArray() -join ' ')
}

function Test-LoopRectTorn {
    <#
      Did the window rectangle move between the enumeration read and the detail read?

      The comparison goes through the probe's Format-Rect rather than over the edges directly,
      so it sees exactly what the row will print: a rectangle missing an edge is n/a to the
      formatter and is n/a here too, and two failed reads compare equal because "the call was
      refused twice" says nothing about movement. One failed read against one good one IS a
      difference -- a window that died or was refused mid-tick is not one this tick measured.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Before, [AllowNull()] $After)
    return ((Format-Rect -Rect $Before) -ne (Format-Rect -Rect $After))
}

function Measure-LoopTornWindows {
    <#
      How many of one tick's selected windows moved across its two reads -- the number torn=
      reports, counted over the SAME records the [tick-rect] rows are formatted from, so the
      count and the rows can never disagree.

      A record with no WindowRectFirst (one built before the re-read existed, or by a caller
      that does not supply it) counts as not torn: nothing can be claimed from a single read,
      and claiming torn there would mark every tick of every older file. The same null check
      also swallows a first read that came back n/a, and the two are deliberately not told
      apart here: Select-ProbeWindows only hands this function windows whose FIRST read was a
      rectangle (Test-ProbeWindowRectOk gates the selection), so that branch is unreachable for
      a selected window and Test-LoopRectTorn's one-sided rule can only ever fire on the
      SECOND read.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Windows)
    $torn = 0
    if ($null -eq $Windows) { return $torn }
    foreach ($window in @($Windows)) {
        $first = Get-ProbeProp -Object $window -Name 'WindowRectFirst'
        if ($null -eq $first) { continue }
        if (Test-LoopRectTorn -Before $first -After (Get-ProbeProp -Object $window -Name 'WindowRect')) { $torn++ }
    }
    return $torn
}

function Test-LoopDesktopChanged {
    <#
      Did the session itself change shape while this tick's rows were being read?

      All three are compared, not just cx/cy: a work area that moves without the screen moving
      is still a re-layout under the rows, and the reader's join gates on wa= as much as on the
      screen size. Comparison is again through the formatters, so a metric that was refused on
      BOTH reads is not a change -- otherwise a host that refuses the call would mark every
      single tick and the flag would carry no information at all.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $BeforeCx, [AllowNull()] $BeforeCy, [AllowNull()] $BeforeWorkArea,
        [AllowNull()] $AfterCx, [AllowNull()] $AfterCy, [AllowNull()] $AfterWorkArea
    )
    if ((Format-ProbeInt -Value $BeforeCx) -ne (Format-ProbeInt -Value $AfterCx)) { return $true }
    if ((Format-ProbeInt -Value $BeforeCy) -ne (Format-ProbeInt -Value $AfterCy)) { return $true }
    if ((Format-Rect -Rect $BeforeWorkArea) -ne (Format-Rect -Rect $AfterWorkArea)) { return $true }
    return $false
}

function Format-TickRectRow {
    <#
      One window at one sample, one line:

        [tick-rect] seq= hwnd= pid= proc= class= style= dpi= wr= ef= cs= cr= owner= title-len=
                    title-sha8=

      A subset of the probe's [host-rect]: exstyle and hr are dropped because they do not change
      from sample to sample (and at four samples a second they would be most of the file), while
      everything that CAN move is kept. seq leads the row so the file can be grouped by a single
      sort key.

      owner= stays (controller addendum, 2026-09-21) even though it is stable per window: it is
      read from the same GetWindow(GW_OWNER) the probe's [host-rect] reports and rendered by the
      same formatter, and the lab's About window is identified by hwnd + class + proc + owner=0
      together -- dropping owner would leave the loop unable to make that join on its own rows.

      title-len and title-sha8 are BOTH derived from the same Title field here, so they cannot
      disagree, and the title itself is the one thing this function must never emit.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Seq, [AllowNull()] $Window)
    $title = Get-ProbeProp -Object $Window -Name 'Title'
    $titleLength = $null
    if ($null -ne $title) { $titleLength = ([string]$title).Length }

    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('[tick-rect]')
    [void]$parts.Add('seq=' + (Format-ProbeInt -Value $Seq))
    [void]$parts.Add('hwnd=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Window -Name 'Hwnd')))
    [void]$parts.Add('pid=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Window -Name 'ProcessId')))
    [void]$parts.Add('proc=' + (ConvertTo-ProbeToken -Value (Get-ProbeProp -Object $Window -Name 'ProcessName')))
    [void]$parts.Add('class=' + (ConvertTo-ProbeToken -Value (Get-ProbeProp -Object $Window -Name 'ClassName')))
    [void]$parts.Add('style=' + (Format-ProbeHex32 -Value (Get-ProbeProp -Object $Window -Name 'Style')))
    [void]$parts.Add('dpi=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Window -Name 'Dpi')))
    [void]$parts.Add('wr=' + (Format-Rect -Rect (Get-ProbeProp -Object $Window -Name 'WindowRect')))
    [void]$parts.Add('ef=' + (Format-Rect -Rect (Get-ProbeProp -Object $Window -Name 'ExtendedFrame')))
    [void]$parts.Add('cs=' + (Format-Point -Point (Get-ProbeProp -Object $Window -Name 'ClientScreen')))
    [void]$parts.Add('cr=' + (Format-Size -Rect (Get-ProbeProp -Object $Window -Name 'ClientRect')))
    [void]$parts.Add('owner=' + (Format-ProbeInt -Value (Get-ProbeProp -Object $Window -Name 'Owner')))
    [void]$parts.Add('title-len=' + (Format-ProbeInt -Value $titleLength))
    [void]$parts.Add('title-sha8=' + (ConvertTo-TitleSha8 -Title $title))
    return ($parts.ToArray() -join ' ')
}

function Test-LoopShouldStop {
    <#
      The stop decision for one sample: '' to keep going, or the reason to stop.

      The sentinel is checked FIRST and wins outright. At the end of a long batch both
      conditions are often true at once, and reporting deadline there would make a genuinely
      lost sentinel -- which means the collection leg failed and the next pair will lose its
      data -- indistinguishable from a normal ending.
    #>
    [CmdletBinding()]
    param([datetime] $Now, [datetime] $Deadline, [bool] $SentinelPresent)
    if ($SentinelPresent) { return $script:LoopStopReasons[0] }
    if ($Now -ge $Deadline) { return $script:LoopStopReasons[1] }
    return ''
}

function Format-LoopResultLine {
    <#
      "RESULT: DONE seq=<n> reason=<sentinel|deadline>" -- the orderly ending.

      seq is the LAST sample taken, not the next one, so the line joins to a tick that is really
      in the file. A reason outside the closed set renders n/a instead of being pasted in: the
      grammar is the contract, and an unknown token in it would break every reader that gates on
      reason=.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Seq, [AllowNull()] $Reason)
    # $normalized, NOT $reason: PowerShell variable names are case-insensitive, so a local
    # $reason would BE the $Reason parameter and the default would overwrite the argument
    # before it was ever examined.
    $normalized = 'n/a'
    if ($null -ne $Reason -and ($script:LoopStopReasons -contains [string]$Reason)) { $normalized = [string]$Reason }
    return 'RESULT: DONE seq=' + (Format-ProbeInt -Value $Seq) + ' reason=' + $normalized
}

# -------------------------------------------------------------------------------------------
# The run (Windows only; never reached under -NoRun)
# -------------------------------------------------------------------------------------------

function Invoke-WindowLoop {
    <#
      Dot-source the probe, declare awareness, open the file, then sample until the sentinel
      appears or the deadline passes. Any exception ends as RESULT: FAILED <stage>/<Type> -- the
      stage name and the exception's type only, never its message, which could carry a path.

      The FIRST sample is always taken, before the first stop check, so seq on the RESULT line
      is a real sample's seq and never negative; a run whose sentinel is already present when it
      starts still leaves one measured instant behind.
    #>
    [CmdletBinding()]
    param(
        [string] $OutPath,
        [int] $MaxSeconds,
        [int] $IntervalMs,
        [string] $SentinelPath,
        [string] $ProbePath
    )

    $stage = 'start'
    $outFile = $null
    $writer = $null
    try {
        $stage = 'resolve'
        $root = Join-Path $env:USERPROFILE $script:LoopLocalDirName
        $outFile = Resolve-LoopPath -Value $OutPath -Root $root -Name $script:LoopOutName
        $sentinelFile = Resolve-LoopPath -Value $SentinelPath -Root $root -Name $script:LoopSentinelName
        $probeScript = Resolve-LoopPath -Value $ProbePath -Root $root -Name $script:LoopProbeName

        # -NoRun: dot-sourcing the probe defines its helpers and starts no probe run. The
        # functions land in this function's scope and the constants in this script's, which is
        # all the sampling below needs.
        $stage = 'probe'
        . $probeScript -NoRun

        $stage = 'native'
        Initialize-ProbeNative

        # ------------------------------------------------------------------------------------
        # DPI awareness FIRST, before any metric or window call, by the probe's own route.
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

        $stage = 'open'
        $startedAt = Get-Date
        $deadline = $startedAt.AddSeconds($MaxSeconds)
        # UTF-8 without BOM and append=false: the file belongs to THIS run. AutoFlush makes every
        # WriteLine reach the file, which is the difference between "killed after four minutes"
        # and "never started" when a detached process is taken down without warning.
        $writer = New-Object System.IO.StreamWriter($outFile, $false, (New-Object System.Text.UTF8Encoding($false)))
        $writer.AutoFlush = $true

        $stage = 'head'
        $head = [pscustomobject]@{
            Utc         = $startedAt.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            PsVersion   = $PSVersionTable.PSVersion.ToString()
            ProcessId   = $PID
            SessionId   = (Invoke-ProbeCall { (Get-Process -Id $PID -ErrorAction Stop).SessionId })
            IntervalMs  = $IntervalMs
            MaxSeconds  = $MaxSeconds
            DeadlineUtc = $deadline.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Awareness   = $awareness
            SetVia      = $setVia
        }
        $writer.WriteLine((Format-LoopHeadRow -Head $head))
        $writer.Flush()

        $stage = 'tick'
        $cxIndex = [int]$script:ProbeDesktopMetricIndex['cx']
        $cyIndex = [int]$script:ProbeDesktopMetricIndex['cy']
        $workAreaAction = [int]$script:ProbeSpiGetWorkArea
        # One process-name cache for the whole run: at four samples a second a Get-Process per
        # window per tick would cost more than the measurement itself. The trade-off is that a
        # pid recycled during the run keeps its first name -- acceptable here, where the rows are
        # joined by hwnd and proc= is a label, and stated so it is never mistaken for a fresh read.
        $cache = @{}
        $seq = 0
        $lastSeq = 0
        $reason = $script:LoopStopReasons[1]
        while ($true) {
            $utc = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $cx = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::MetricOf($cxIndex) }
            $cy = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::MetricOf($cyIndex) }
            $workArea = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::WorkAreaOf($workAreaAction) }

            $handles = @()
            $enumerated = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::EnumTopLevel() }
            if ($null -ne $enumerated) { $handles = @($enumerated) }
            $bases = New-Object System.Collections.ArrayList
            foreach ($handle in $handles) { [void]$bases.Add((Get-ProbeWindowBase -Handle $handle)) }
            $counts = Measure-ProbeWindows -Windows @($bases.ToArray())
            $selected = @(Select-ProbeWindows -Windows @($bases.ToArray()) -Cap $script:ProbeMaxRows)

            # The detail pass runs BEFORE the tick line is assembled, because torn= and
            # desktop-changed= are facts it produces. The rows are therefore held for the length
            # of one tick and written after their tick line: the FILE's order is unchanged --
            # [loop-tick] first, then its rows, which is the grouping contract -- only the
            # assembly order is. The buffer is at most the probe's cap, i.e. 64 strings.
            $details = New-Object System.Collections.ArrayList
            foreach ($window in $selected) {
                [void]$details.Add((Add-ProbeWindowDetail -Window $window -ProcessNameCache $cache))
            }

            # The desktop metrics again, now that the rows have been read. Whatever comes back
            # is compared, never printed: cx=/cy=/wa= keep reporting the values this sample
            # opened with, and a disagreement becomes the flag.
            $cxAfter = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::MetricOf($cxIndex) }
            $cyAfter = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::MetricOf($cyIndex) }
            $workAreaAfter = Invoke-ProbeCall { [MacdowsLab.WindowProbeNative]::WorkAreaOf($workAreaAction) }

            $tick = [pscustomobject]@{
                Seq            = $seq
                Utc            = $utc
                Cx             = $cx
                Cy             = $cy
                WorkArea       = $workArea
                RectOk         = $counts.RectOk
                Selected       = $selected.Count
                Torn           = (Measure-LoopTornWindows -Windows @($details.ToArray()))
                DesktopChanged = (Test-LoopDesktopChanged -BeforeCx $cx -BeforeCy $cy -BeforeWorkArea $workArea `
                    -AfterCx $cxAfter -AfterCy $cyAfter -AfterWorkArea $workAreaAfter)
            }
            $writer.WriteLine((Format-LoopTickRow -Tick $tick))
            foreach ($detail in @($details.ToArray())) {
                $writer.WriteLine((Format-TickRectRow -Seq $seq -Window $detail))
            }
            $writer.Flush()

            $lastSeq = $seq
            $seq++
            $reason = Test-LoopShouldStop -Now (Get-Date) -Deadline $deadline `
                -SentinelPresent ([IO.File]::Exists($sentinelFile))
            if ($reason -ne '') { break }
            Start-Sleep -Milliseconds $IntervalMs
        }

        $stage = 'result'
        $writer.WriteLine((Format-LoopResultLine -Seq $lastSeq -Reason $reason))
        $writer.Flush()
    } catch {
        $failure = 'RESULT: FAILED ' + $stage + '/' + $_.Exception.GetType().Name
        try {
            if ($null -ne $writer) {
                $writer.WriteLine($failure)
                $writer.Flush()
            } elseif ($null -ne $outFile) {
                # The writer never opened, so the samples file does not exist yet. Write the one
                # line on its own: a one-line file is a real result (see FAILURE SHAPES).
                [IO.File]::WriteAllLines($outFile, [string[]]@($failure))
            }
        } catch {
            # The local disk itself is gone; nothing further can be recorded from here.
        }
    } finally {
        if ($null -ne $writer) {
            try { $writer.Dispose() } catch { }
        }
    }
}

if (-not $NoRun) {
    Invoke-WindowLoop -OutPath $OutPath -MaxSeconds $MaxSeconds -IntervalMs $IntervalMs `
        -SentinelPath $SentinelPath -ProbePath $ProbePath
    # Always 0: this process is detached and nobody reads its exit code; the file is the result.
    exit 0
}
