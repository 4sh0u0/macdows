<#
.SYNOPSIS
    READ-ONLY server-side snapshot for the scaled-map memo's paths A + E, run on the host by the
    lab relay (jobs/server-snapshot.env -> powershell.exe -File \\tsclient\lab\server-snapshot.ps1).

.DESCRIPTION
    Standard lab account, no elevation, nothing written on the host. One report goes back over
    the redirected drive; it is rewritten at every checkpoint -- immediately at start (so a run
    that dies early cannot leave the PREVIOUS run's complete report on the drive, r1 B3), after
    winver/freshness, after the registry section, after the channel list, after every channel,
    and at the end -- so a relay TIMEOUT still leaves the sections that finished; the same shape
    tsallowlist-matrix-verify.ps1 uses and for the same reason.

    What it collects (docs/upgrade-gate/2026-09-scaledmap-next-step.md section 3, rows A and E):

      winver / host_freshness  -- the two matrix fields (docs/matrix/format.md section 2.1) that
                                  every live-host env record must carry: windows_build as
                                  10.0.<CurrentBuild>.<UBR> from HKLM CurrentVersion, and
                                  host_freshness from EITHER Win32_OperatingSystem.LastBootUpTime
                                  or the 32-bit tick count -- Select-SnapshotHostFreshnessLabel
                                  decides which from the System log's clock-correction history
                                  (Kernel-General 1), and writes `unknown` when neither is
                                  trustworthy. Boot/sleep history (Kernel-Boot 27, Kernel-General
                                  12/13, Kernel-Power 42/107) is printed alongside -- the clock
                                  corrections read newest-ClockChangeCount (default 50), only the
                                  ones that moved the clock printed -- and so is the
                                  session history: the newest SessionHistoryCount (default 60)
                                  LocalSessionManager/Operational events as UTC time / id / name /
                                  SessionID only (user and client address are never read);
                                  and the connection digest: the newest ConnectionDigestCount
                                  (default 6) RDP connections found in RdpCoreTS/Operational
                                  (newest MaxEventsPerChannel events, grouped by ActivityId --
                                  one connection = one ActivityId, ~110 events), one line each:
                                  first/last UTC, event count, SessionID (event 66), the
                                  client's requested monitors (168: number, WxH, origin), the
                                  graphics capability line (162: version, mode, AVC, profile),
                                  whether advanced RemoteApp graphics was used (257), the
                                  transport verdict (135) and the end signature (226/107/102/
                                  144). Only those EventData names are read; ServerName,
                                  ConnectionName, ChannelName and the client address (131)
                                  are red-line items and never touched. This is the host-side
                                  record of the desktop size a client declared (2x checkpoint
                                  clause v2) and of the session it landed in (v6).
      E. configuration surface -- every value under the RDS-relevant registry keys listed in
                                  $script:SnapshotRegistryKeys (policy hive, Terminal Server,
                                  TSAppAllowList, the RDP-Tcp winstation, session DPI), rendered
                                  as "name = value" lines, plus an explicit <absent> line for
                                  each pre-registered policy name that is NOT set, so a later
                                  snapshot can be diffed field by field.
      A. event log channels    -- Get-WinEvent -ListLog, filtered to the RDS-related channels
                                  (Select-SnapshotLogName), each with enabled/record-count/mode
                                  and a readability probe (a standard account may be refused the
                                  Operational channels -- the refusal is itself a result), then
                                  then up to MaxEventsPerChannel events of every readable channel
                                  (newest-first; Analytic/Debug channels can only be read
                                  oldest-first and are marked so on their window line) scanned for
                                  the pre-registered keywords (graphics / scal / gfx, plus surface)
                                  in the rendered Message or, when an event has none (analytic
                                  channels usually do not), in its XML; counts per keyword, any,
                                  any3 (memo keywords only), no_message, and up to five sample
                                  hits. Channels with at most three events list them all.

    Deliberately NOT written into the report: $env:COMPUTERNAME and $env:USERNAME. Event
    messages and registry values are copied verbatim, so the report may still carry host
    identifiers -- it lives under .build/lab-runtime/ (git-ignored) and only counts, ids and
    build strings are transcribed into docs.

    Windows PowerShell 5.1 notes: no ??, no ternary, no -Parallel; [Environment]::TickCount64
    does not exist on .NET Framework, so the tick-based uptime uses the 32-bit TickCount (24.9-day
    wrap guarded: tick-unavailable). Every [channel] and [reg] block carries its own UTC read time
    and the literal cmdlet it ran (memo section 8 columns).

.PARAMETER NoRun
    Define the functions but do not touch the host. Used by server-snapshot.Tests.ps1 to
    dot-source the pure helpers and drive them with fixtures on macOS.
#>

[CmdletBinding()]
param(
    [string] $OutPath = '\\tsclient\lab\server-snapshot-out.txt',
    # Newest events read per readable channel. Bounded so the whole scan stays inside the relay
    # job's TIMEOUT even on a channel with years of history; 2500 covers the whole of every
    # channel dry run 2 met (largest: RdpCoreTS/Operational, 1952 records), and the report
    # prints the covered time window per channel so a partial scan is visible as such.
    [int] $MaxEventsPerChannel = 2500,
    # Newest LocalSessionManager/Operational events printed as the "session history" block. It was
    # a literal 12 until 2026-09-07: one other-client connection (4 rows: 40,25 / 40,24) plus the
    # lab's own rail-probe (7 rows: 41,40,40,25,42 / 40,24) and the relay session reading this
    # snapshot (5 rows at read time) already fill 12, so in 4 of the 5 T6-prime forms the other
    # client's 24/25 had been pushed out and clause (c) had to be judged from the owner's manual
    # 60-row query. 60 is that window; the header prints whatever value was used.
    [ValidateRange(1, 2500)]
    [int] $SessionHistoryCount = 60,
    # Newest Kernel-General 1 (system time changed) events READ for clock_jump_since_boot. It was a
    # literal 5 until 2026-09-07: the T6-prime RA3 snapshot showed two fresh zero-delta time-sync
    # events pushing the +28671 s correction out of that window, and the jump fell from 32400 s
    # to 3729 s -- with LastBootUpTime still nine hours early that would have left the boot/tick
    # gap "unexplained" and the label `unknown`. On this host the System log held about eight
    # Kernel-General 1 events for 09-01..09-07 (intervals from 30 min to 55 h), so 50 reaches back
    # well over a month at that rate; the sum runs over everything read since boot, while only the
    # corrections that moved the clock (or could not be parsed) are printed.
    [ValidateRange(1, 2500)]
    [int] $ClockChangeCount = 50,
    # Newest RDP connections (distinct RdpCoreTS ActivityIds) printed as the "connection digest"
    # block. The 2x checkpoint (docs/upgrade-gate/2026-09-w3-2x-checkpoint-prereg.md) is four
    # window-smoke runs, each followed by a relay read of this snapshot, so the run under
    # judgement is at most the second newest connection at read time; 6 leaves room for a
    # retried run and a stray client. Host digest v1 (2026-09-08) counted 18 connections in the
    # ~25 h the circular log held, so the window is a small slice of what is available.
    [ValidateRange(1, 50)]
    [int] $ConnectionDigestCount = 6,
    [switch] $NoRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Pre-registered keyword list. The memo names graphics / scal / gfx; surface is added here
# because the PDU under investigation is RDPGFX_MAP_SURFACE_TO_SCALED_OUTPUT. Order is the
# report's column order.
$script:SnapshotKeywords = @('graphics', 'scal', 'gfx', 'surface')

# Which Get-WinEvent -ListLog names count as RDS-related. Case-insensitive regex alternatives:
# TerminalServices (the TS-* channels), Remote-?Desktop (RemoteDesktopServices-* AND the
# hyphenated Remote-Desktop-Management-Service), Remote-?App (RemoteApp and Desktop
# Connections), the bare tokens RemoteFX / Rdms, and Rdp either as a separated token
# (Microsoft-Windows-Rdp-Graphics-RdpLite: "-Rdp-") or as a CamelCase stem (RdpCoreTS, RdpLite,
# RdpAvenc -- that group is case-SENSITIVE via (?-i:...), which is what keeps
# Microsoft-Windows-Wordpad out: dry run 2 selected all three Wordpad channels on the bare
# "rdp" inside "Wordpad"). Dwm is deliberately NOT included (a DWM channel exists on every
# desktop and says nothing about the RDP graphics pipeline).
$script:SnapshotChannelPattern = 'TerminalServices|Remote-?Desktop|Remote-?App|RemoteFX|Rdms|(^|[-/ ])Rdp([-/ ]|$)|(?-i:Rdp[A-Z])'

# Registry keys read for path E. AllValues=$true: every value present under the key is
# reported; Names lists the pre-registered names that are additionally reported as <absent>
# when not set, so the report shape does not depend on what the host happens to have configured.
# AllValues=$false (the HKCU desktop key): only the pre-registered names are read -- dry run 2
# showed the full key is 46 mostly unrelated values including the wallpaper path and an 800-byte
# image cache, none of which belongs in an RDS configuration snapshot.
$script:SnapshotRegistryKeys = @(
    [pscustomobject]@{
        Path  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
        AllValues = $true
        Names = @('fAllowUnlistedRemotePrograms', 'fEnableRemoteFXAdvancedRemoteApp',
                  'fEnableVirtualGraphics', 'bEnumerateHWBeforeSW', 'AVC444ModePreferred',
                  'AVCHardwareEncodePreferred', 'fEnableWddmDriver', 'MaxMonitors',
                  'MaxXResolution', 'MaxYResolution', 'ColorDepth', 'ImageQuality',
                  'VisualExperiencePolicy', 'DWMFRAMEINTERVAL', 'SelectTransport',
                  'fDisableClip', 'fNoRemoteDesktopWallpaper', 'fDenyTSConnections')
    },
    [pscustomobject]@{
        Path  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server'
        AllValues = $true
        Names = @('fAllowUnlistedRemotePrograms', 'fDenyTSConnections')
    },
    [pscustomobject]@{
        Path  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList'
        AllValues = $true
        Names = @('fDisabledAllowList', 'fHasCertificate', 'CustomRDPSettings')
    },
    [pscustomobject]@{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        AllValues = $true
        Names = @('fDenyTSConnections', 'fSingleSessionPerUser', 'TSUserEnabled')
    },
    [pscustomobject]@{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        AllValues = $true
        Names = @('UserAuthentication', 'SecurityLayer', 'MinEncryptionLevel', 'ColorDepth',
                  'MaxMonitors', 'MaxXResolution', 'MaxYResolution', 'fEnableWinStation',
                  'SelectTransport', 'fInheritColorDepth')
    },
    [pscustomobject]@{
        Path  = 'HKCU:\Control Panel\Desktop'
        AllValues = $false
        Names = @('LogPixels', 'Win8DpiScaling', 'DpiScalingVer', 'MaxVirtualDesktopDimension', 'MaxMonitorDimension')
    }
)

# -------------------------------------------------------------------------------------------
# Pure helpers (no host state; exercised off-Windows by the test suite)
# -------------------------------------------------------------------------------------------

function Get-SnapshotProp {
    <# A property value, or null when the object is null or lacks the property (StrictMode-safe). #>
    [CmdletBinding()]
    param([AllowNull()] $Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Select-SnapshotScanText {
    <#
      The text a keyword scan runs over for one event: the rendered Message when the event has
      one, otherwise its XML (analytic/debug channels usually carry no message resource -- r1 B2:
      scanning Message alone reported them as scanned-and-clean).
    #>
    [CmdletBinding()]
    param([AllowNull()] $Message, [AllowNull()] $Xml)
    if ($null -ne $Message -and ([string]$Message).Length -gt 0) { return [string]$Message }
    if ($null -ne $Xml) { return [string]$Xml }
    return ''
}

function Format-SnapshotScanLine {
    <#
      The per-channel result line. Unreadable channels render `scanned=<not-scanned>` instead of
      a row of zeros, so a refusal can never be misread as "scanned and clean".
    #>
    [CmdletBinding()]
    param([string] $Readable, $Hit, $Hit3, [int] $NoMessage, [string[]] $Keywords)
    if ($Readable -like 'false*') { return "readable=$Readable scanned=<not-scanned>" }
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add("readable=$Readable")
    [void]$parts.Add("scanned=$($Hit.Scanned)")
    [void]$parts.Add("no_message=$NoMessage")
    foreach ($k in $Keywords) { [void]$parts.Add("$k=$($Hit.PerKeyword[$k])") }
    [void]$parts.Add("any=$($Hit.Any)")
    [void]$parts.Add("any3=$($Hit3.Any)")
    return ($parts.ToArray() -join ' ')
}

function Select-SnapshotLogName {
    <# The RDS-related subset of a list of event log names, input order kept. #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][string[]] $Names)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Names) { return @($out.ToArray()) }
    foreach ($n in $Names) {
        if ($null -eq $n) { continue }
        if ($n -match $script:SnapshotChannelPattern) { [void]$out.Add($n) }
    }
    return @($out.ToArray())
}

function Measure-SnapshotKeywordHit {
    <#
      Counts, over a list of message strings, how many messages contain each keyword (literal,
      case-insensitive substring; a message counts once per keyword however many times the word
      occurs) and how many messages contain at least one keyword (Any). Null and empty messages
      are scanned (they count toward Scanned) and never hit.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]] $Messages,
        [string[]] $Keywords
    )
    $per = [ordered]@{}
    foreach ($k in $Keywords) { $per[$k] = 0 }
    $scanned = 0
    $any = 0
    if ($null -ne $Messages) {
        foreach ($m in $Messages) {
            $scanned++
            if ($null -eq $m) { continue }
            $text = [string]$m
            if ($text.Length -eq 0) { continue }
            $hitThis = $false
            foreach ($k in $Keywords) {
                if ($text.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $per[$k] = $per[$k] + 1
                    $hitThis = $true
                }
            }
            if ($hitThis) { $any++ }
        }
    }
    return [pscustomobject]@{
        Scanned    = $scanned
        Any        = $any
        PerKeyword = $per
    }
}

function Format-SnapshotKeywordHitLine {
    <# "scanned=N <kw>=n ... any=M" in keyword order -- the report's per-channel summary. #>
    [CmdletBinding()]
    param($Hit, [string[]] $Keywords)
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add("scanned=$($Hit.Scanned)")
    foreach ($k in $Keywords) { [void]$parts.Add("$k=$($Hit.PerKeyword[$k])") }
    [void]$parts.Add("any=$($Hit.Any)")
    return ($parts.ToArray() -join ' ')
}

function Format-SnapshotWindowsBuild {
    <#
      format.md windows_build: 10.0.<build>.<ubr> | unknown. Both parts must be present and
      purely numeric; anything else is reported as unknown rather than pasted into the field.
    #>
    [CmdletBinding()]
    param($CurrentBuild, $Ubr)
    $b = ''
    $u = ''
    if ($null -ne $CurrentBuild) { $b = ([string]$CurrentBuild).Trim() }
    if ($null -ne $Ubr) { $u = ([string]$Ubr).Trim() }
    if ($b -notmatch '^[0-9]+$' -or $u -notmatch '^[0-9]+$') { return 'unknown' }
    return "10.0.$b.$u"
}

function Get-SnapshotHostFreshness {
    <#
      format.md host_freshness: rebooted-<N>m-prior | uptime-<N>h | unknown. The two labels
      split at one hour: under 3600 s the host was rebooted N whole minutes ago; from 3600 s on
      it has been up N whole hours. A null or negative uptime is unknown.
    #>
    [CmdletBinding()]
    param($UptimeSeconds)
    if ($null -eq $UptimeSeconds) { return 'unknown' }
    $s = [double]$UptimeSeconds
    if ($s -lt 0) { return 'unknown' }
    if ($s -lt 3600) { return ('rebooted-{0}m-prior' -f [int][math]::Floor($s / 60)) }
    return ('uptime-{0}h' -f [int][math]::Floor($s / 3600))
}

function Get-SnapshotFreshnessConsistency {
    <#
      Compares the boot-based uptime (Win32_OperatingSystem LastBootUpTime) with the tick-based
      one ([Environment]::TickCount) and names the gap WITHOUT naming a mechanism (r1 B1: an
      earlier version called it fast-startup/sleep; dry runs 5-7 showed the only gap this host
      produces is a boot-time clock error later corrected -- 37830 vs 5432 s on dry run 2 was
      already that same nine-hour offset). Which mechanism explains a gap is decided by
      Select-SnapshotHostFreshnessLabel from the clock-correction history, never here.
        consistent                  |gap| <= tolerance
        boot-tick-gap-unexplained   |gap| > tolerance, either sign (gap = boot - tick is quoted)
        tick-unavailable            null boot, negative (wrapped) tick, or boot past the 32-bit
                                    tick range (2147483 s)
    #>
    [CmdletBinding()]
    param($BootUptimeSeconds, $TickSeconds, [int] $ToleranceSeconds = 300)
    if ($null -eq $BootUptimeSeconds -or $null -eq $TickSeconds) { return 'tick-unavailable' }
    $boot = [double]$BootUptimeSeconds
    $tick = [double]$TickSeconds
    if ($tick -lt 0 -or $boot -gt 2147483) { return 'tick-unavailable' }
    $gap = [int][math]::Round($boot - $tick)
    if ([math]::Abs($gap) -le $ToleranceSeconds) { return 'consistent' }
    $detail = ('(tick={0}s boot={1}s gap={2}s)' -f [int][math]::Round($tick), [int][math]::Round($boot), $gap)
    return "boot-tick-gap-unexplained $detail"
}

function Get-SnapshotEventDataValue {
    <#
      One named EventData datum from an EventRecord.ToXml() string (locale-independent: the
      XML carries the raw data, the Message carries the localised rendering). ToXml() emits
      attribute values in SINGLE quotes -- <Data Name='BootType'>0</Data> is what dry run 4's
      excerpt showed -- so both quote styles are accepted. Null when the datum is absent.
    #>
    [CmdletBinding()]
    param([AllowNull()][string] $Xml, [string] $Name)
    if ([string]::IsNullOrEmpty($Xml)) { return $null }
    $pattern = '<Data Name=[''"]' + [regex]::Escape($Name) + '[''"]>(.*?)</Data>'
    $m = [regex]::Match($Xml, $pattern, 'Singleline')
    if ($m.Success) { return $m.Groups[1].Value }
    # UserData/EventXML form: providers such as TerminalServices-LocalSessionManager emit the datum
    # as its own element, <SessionID>2</SessionID>, not as <Data Name=...> (dry run 9).
    $pattern2 = '<' + [regex]::Escape($Name) + '(?:\s[^>]*)?>(.*?)</' + [regex]::Escape($Name) + '>'
    $m2 = [regex]::Match($Xml, $pattern2, 'Singleline')
    if ($m2.Success) { return $m2.Groups[1].Value }
    return $null
}

function Get-SnapshotBootTypeFromXml {
    <#
      Kernel-Boot event 27's BootType datum. Dry run 4 showed it is a plain decimal (0 = cold
      boot); a hex rendering (0x1) is tolerated in case another build renders it that way. Dry
      runs 3 and 4 read unknown for all five events under a double-quote-only pattern.
    #>
    [CmdletBinding()]
    param([AllowNull()][string] $Xml)
    $v = Get-SnapshotEventDataValue -Xml $Xml -Name 'BootType'
    if ($null -eq $v) { return $null }
    $v = $v.Trim()
    if ($v -match '^0x[0-9A-Fa-f]+$') { return [int][Convert]::ToInt32($v.Substring(2), 16) }
    if ($v -match '^[0-9]+$') { return [int]$v }
    return $null
}

function Select-SnapshotClockEventsToPrint {
    <#
      Which clock-change events the report prints: the ones whose delta is non-zero or could not
      be parsed (they are the corrections that matter to the jump), in the order given (newest
      first), capped at Max; the zero-delta ones and the non-zero ones beyond the cap are counted
      so the reader knows what was read but not shown. Pure: the sum is taken elsewhere over the
      whole list.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]] $Events, [int] $Max = 10)
    $shown = New-Object System.Collections.ArrayList
    $omittedZero = 0
    $omittedBeyondCap = 0
    if ($null -ne $Events) {
        foreach ($e in $Events) {
            if ($null -eq $e) { continue }
            $d = $e.Delta
            $parsed = 0
            $isZero = ($null -ne $d) -and [int]::TryParse([string]$d, [ref]$parsed) -and ($parsed -eq 0)
            if ($isZero) { $omittedZero++; continue }
            if ($shown.Count -ge $Max) { $omittedBeyondCap++; continue }
            [void]$shown.Add($e)
        }
    }
    return [pscustomobject]@{ Shown = @($shown.ToArray()); OmittedZero = $omittedZero; OmittedBeyondCap = $omittedBeyondCap }
}

function Format-SnapshotClockChangeHeader {
    <# The clock-change block's header line; it names the window read and the print rule. #>
    [CmdletBinding()]
    param([int] $Count)
    return "  clock changes (Kernel-General 1, System log, newest $Count read; corrections with delta != 0 or unparsed shown, zero-delta ones counted):"
}

function Measure-SnapshotClockJump {
    <#
      Net clock correction since boot: the sum of the Kernel-General 1 deltas stamped at or after
      the boot stamp. Dry run 6 showed the nine hours arrive as TWO corrections (+28671 s, then
      +3729 s an hour later); the newest alone does not account for the gap, the sum does.
      "Since boot" means TimeCreated at or after the boot stamp OR OldTime at or after it (r1 I3):
      a correction that sets the clock BACK is stamped on the new, earlier clock and can land
      before the boot stamp although it happened after boot -- its OldTime says so.
      Deltas that could not be parsed are skipped; null when there is nothing to sum (no events
      since boot, or no boot time), so the caller can tell "no correction" from "corrected by 0".
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]] $Events, $BootTime)
    if ($null -eq $BootTime -or $null -eq $Events) { return $null }
    $sum = 0
    $n = 0
    foreach ($e in $Events) {
        if ($null -eq $e) { continue }
        $old = Get-SnapshotProp -Object $e -Name 'Old'
        $sinceBoot = ($e.Time -ge $BootTime) -or ($null -ne $old -and $old -ge $BootTime)
        if (-not $sinceBoot) { continue }
        $d = $e.Delta
        if ($null -eq $d) { continue }
        $parsed = 0
        if (-not [int]::TryParse([string]$d, [ref]$parsed)) { continue }
        $sum += $parsed
        $n++
    }
    if ($n -eq 0) { return $null }
    return $sum
}

function Select-SnapshotHostFreshnessLabel {
    <#
      Which uptime the matrix host_freshness label is taken from, and why.

      Dry run 5 read boot-based 38556 s against tick-based 6156 s with NO sleep/resume events
      and a gap of exactly 32400 s -- nine hours, the host's UTC offset. That is not a sleep:
      the host booted with its clock nine hours behind (a dual-boot machine whose other OS
      leaves the RTC in UTC), so LastBootUpTime and the boot-time event stamps are nine hours
      early, and the later correction shows up as Kernel-General 1 "system time changed" events
      whose old->new jumps SUM to the gap (Measure-SnapshotClockJump). In that regime the TICK
      count is the truthful "since boot" and the label is taken from it.
        Basis boot: tick unavailable, or gap within tolerance
        Basis tick: ClockJumpSeconds matches gap within the tolerance WITH ITS SIGN (gap = boot -
                    tick = the net correction, r1 I1) and the jump itself exceeds the tolerance
                    (r1 I2: a 1 s correction does not explain a 301 s gap)
        Basis none: gap beyond tolerance and not explained -- Label is the matrix literal
                    `unknown` (r1 I3: a boot reading on an unexplained gap could report a
                    degraded host as fresh, the one direction adr/0012 section 4.7 forbids); the
                    boot- and tick-based labels are still printed for the reader.
    #>
    [CmdletBinding()]
    param($BootUptimeSeconds, $TickSeconds, $ClockJumpSeconds, [int] $ToleranceSeconds = 300)
    $cons = Get-SnapshotFreshnessConsistency -BootUptimeSeconds $BootUptimeSeconds -TickSeconds $TickSeconds -ToleranceSeconds $ToleranceSeconds
    $basis = 'boot'
    $reason = $cons
    if ($cons -ne 'tick-unavailable' -and $cons -ne 'consistent') {
        $basis = 'none'
        if ($null -ne $ClockJumpSeconds) {
            $gap = [int][math]::Round([double]$BootUptimeSeconds - [double]$TickSeconds)
            $jump = [int][math]::Round([double]$ClockJumpSeconds)
            if ([math]::Abs($jump - $gap) -le $ToleranceSeconds -and [math]::Abs($jump) -gt $ToleranceSeconds) {
                $basis = 'tick'
                $reason = ('clock-corrected-after-boot (jump={0}s gap={1}s)' -f $jump, $gap)
            }
        }
    }
    $label = 'unknown'
    if ($basis -eq 'boot') { $label = Get-SnapshotHostFreshness -UptimeSeconds $BootUptimeSeconds }
    if ($basis -eq 'tick') { $label = Get-SnapshotHostFreshness -UptimeSeconds $TickSeconds }
    return [pscustomobject]@{
        Basis  = $basis
        Label  = $label
        Reason = $reason
    }
}

function Format-SnapshotBootType {
    <# 0 cold boot, 1 fast startup (hybrid shutdown), 2 resume from hibernation. #>
    [CmdletBinding()]
    param($BootType)
    if ($null -eq $BootType) { return 'unknown' }
    switch ([int]$BootType) {
        0 { return 'cold-boot' }
        1 { return 'fast-startup' }
        2 { return 'resume-from-hibernation' }
    }
    return ('unknown({0})' -f [int]$BootType)
}

function Format-SnapshotSessionEventName {
    <#
      LocalSessionManager/Operational event ids that matter when asking "is this the same session
      the previous client left behind": 21 logon, 22 shell start, 23 logoff, 24 disconnect,
      25 reconnect, 39 disconnected by another session, 40 disconnect reason code -- documented
      meanings; 41/42 are named 'arbitration begin/end' from observation only (dry runs 9/10 show them
      bracketing every reconnect) and carry an (unconfirmed) qualifier. Everything else is 'other'
      (memo section 5, T6-prime clause (c)).
    #>
    [CmdletBinding()]
    param($Id)
    if ($null -eq $Id) { return 'other' }
    switch ([int]$Id) {
        21 { return 'logon' }
        22 { return 'shell-start' }
        23 { return 'logoff' }
        24 { return 'disconnect' }
        25 { return 'reconnect' }
        39 { return 'disconnected-by-other-session' }
        40 { return 'disconnect-reason' }
        41 { return 'arbitration-begin(unconfirmed)' }
        42 { return 'arbitration-end(unconfirmed)' }
    }
    return 'other'
}

function Format-SnapshotSessionEventLine {
    <#
      One session-history line: UTC time, id, name, SessionID -- and nothing else. The LSM events'
      messages and EventData also carry the user name and the client's network address, both
      red-line items (format.md section 2.2); this function reads only the SessionID datum.
    #>
    [CmdletBinding()]
    param([AllowNull()] $TimeUtc, $Id, [AllowNull()][string] $Xml)
    $t = '<no-time>'
    if ($null -ne $TimeUtc -and ([string]$TimeUtc).Length -gt 0) { $t = [string]$TimeUtc }
    $sid = Get-SnapshotEventDataValue -Xml $Xml -Name 'SessionID'
    if ($null -eq $sid -or ([string]$sid).Length -eq 0) { $sid = '<n/a>' }
    $name = Format-SnapshotSessionEventName -Id $Id
    return "lsm: $t id=$Id ($name) session=$sid"
}

function Format-SnapshotSessionHistoryHeader {
    <# The session-history block's header line; it names the window actually read. #>
    [CmdletBinding()]
    param([int] $Count)
    return "  session history (LSM/Operational, newest $Count; user and address omitted by design):"
}

function Format-SnapshotConnectionDigestHeader {
    <# The connection-digest block's header line; it names the window and the events actually read. #>
    [CmdletBinding()]
    param([int] $Count, [int] $Scanned)
    return "  connection digest (RdpCoreTS/Operational, newest $Count connections by ActivityId over the newest $Scanned events read; addresses, server and channel names omitted by design):"
}

function Group-SnapshotConnectionEvents {
    <#
      Groups RdpCoreTS events (objects with ActivityId, Id, TimeUtc, Xml) into connections: one
      group per ActivityId, events oldest-first inside a group, groups newest-first by their
      first event, capped at Count. Events without an ActivityId are not grouped and are
      counted (Ungrouped); Scanned counts every event seen. TimeUtc is the ISO 8601 'o'
      rendering, fixed width, so ordinal string order is time order; a null time sorts oldest.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][object[]] $Events, [int] $Count)
    $byId = [ordered]@{}
    $ungrouped = 0
    $scanned = 0
    if ($null -ne $Events) {
        foreach ($e in $Events) {
            if ($null -eq $e) { continue }
            $scanned++
            $aid = [string](Get-SnapshotProp -Object $e -Name 'ActivityId')
            if ([string]::IsNullOrEmpty($aid)) { $ungrouped++; continue }
            if (-not $byId.Contains($aid)) { $byId[$aid] = New-Object System.Collections.ArrayList }
            [void]$byId[$aid].Add($e)
        }
    }
    $groups = New-Object System.Collections.ArrayList
    foreach ($aid in @($byId.Keys)) {
        $sorted = @($byId[$aid].ToArray() | Sort-Object -Property @{ Expression = { [string](Get-SnapshotProp -Object $_ -Name 'TimeUtc') } })
        [void]$groups.Add([pscustomobject]@{
            ActivityId = $aid
            Events     = $sorted
            FirstTime  = [string](Get-SnapshotProp -Object $sorted[0] -Name 'TimeUtc')
        })
    }
    $ordered = @($groups.ToArray() | Sort-Object -Property FirstTime -Descending)
    if ($ordered.Count -gt $Count) { $ordered = @($ordered[0..($Count - 1)]) }
    return [pscustomobject]@{ Groups = $ordered; Ungrouped = $ungrouped; Scanned = $scanned }
}

function ConvertTo-SnapshotDatumText {
    <# A datum for the connection line: the value, or ? when the event lacks it (never a fabricated number). #>
    [CmdletBinding()]
    param([AllowNull()] $Value)
    if ($null -eq $Value -or ([string]$Value).Length -eq 0) { return '?' }
    return [string]$Value
}

function Format-SnapshotConnectionLine {
    <#
      One connection as one line. Reads ONLY these EventData names: SessionID (66), MonitorNum /
      MonitorWidth / MonitorHeight / MonitorX / MonitorY (168), Version / ClientMode / AvcEnabled /
      ProfileIdNum (162), TransportType (135); 257 counts by presence, 226/107/102/144 by id. The
      test suite pins that list against the function body. ServerName, ConnectionName,
      ChannelName and the client address are never read; an IPv4 literal inside TransportType
      would be masked (defensive -- the datum has never carried one).
    #>
    [CmdletBinding()]
    param($Group)
    $events = @(Get-SnapshotProp -Object $Group -Name 'Events')
    $first = '<no-time>'
    $last = '<no-time>'
    if ($events.Count -gt 0) {
        $t0 = [string](Get-SnapshotProp -Object $events[0] -Name 'TimeUtc')
        $t1 = [string](Get-SnapshotProp -Object $events[$events.Count - 1] -Name 'TimeUtc')
        if ($t0.Length -gt 0) { $first = $t0 }
        if ($t1.Length -gt 0) { $last = $t1 }
    }
    $sessions = New-Object System.Collections.ArrayList
    $monitors = New-Object System.Collections.ArrayList
    $transports = New-Object System.Collections.ArrayList
    $ends = New-Object System.Collections.ArrayList
    $gfx = '<n/a>'
    $advGfx = 'no'
    $ipv4 = '\b(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}\b'
    foreach ($e in $events) {
        $idText = [string](Get-SnapshotProp -Object $e -Name 'Id')
        $xml = [string](Get-SnapshotProp -Object $e -Name 'Xml')
        switch ($idText) {
            '66' {
                $sid = Get-SnapshotEventDataValue -Xml $xml -Name 'SessionID'
                if (-not [string]::IsNullOrEmpty($sid) -and -not $sessions.Contains($sid)) { [void]$sessions.Add($sid) }
            }
            '168' {
                [void]$monitors.Add(('{0}:{1}x{2}@{3},{4}' -f
                    (ConvertTo-SnapshotDatumText (Get-SnapshotEventDataValue -Xml $xml -Name 'MonitorNum')),
                    (ConvertTo-SnapshotDatumText (Get-SnapshotEventDataValue -Xml $xml -Name 'MonitorWidth')),
                    (ConvertTo-SnapshotDatumText (Get-SnapshotEventDataValue -Xml $xml -Name 'MonitorHeight')),
                    (ConvertTo-SnapshotDatumText (Get-SnapshotEventDataValue -Xml $xml -Name 'MonitorX')),
                    (ConvertTo-SnapshotDatumText (Get-SnapshotEventDataValue -Xml $xml -Name 'MonitorY'))))
            }
            '162' {
                $gfx = 'version={0},mode={1},avc={2},profile={3}' -f
                    (ConvertTo-SnapshotDatumText (Get-SnapshotEventDataValue -Xml $xml -Name 'Version')),
                    (ConvertTo-SnapshotDatumText (Get-SnapshotEventDataValue -Xml $xml -Name 'ClientMode')),
                    (ConvertTo-SnapshotDatumText (Get-SnapshotEventDataValue -Xml $xml -Name 'AvcEnabled')),
                    (ConvertTo-SnapshotDatumText (Get-SnapshotEventDataValue -Xml $xml -Name 'ProfileIdNum'))
            }
            '257' { $advGfx = 'yes' }
            '135' {
                $tt = Get-SnapshotEventDataValue -Xml $xml -Name 'TransportType'
                if (-not [string]::IsNullOrEmpty($tt)) {
                    $tt = [string]$tt -replace $ipv4, '<ip>'
                    if (-not $transports.Contains($tt)) { [void]$transports.Add($tt) }
                }
            }
            { @('226', '107', '102', '144') -contains $_ } {
                if (-not $ends.Contains($idText)) { [void]$ends.Add($idText) }
            }
        }
    }
    $sessionText = '<n/a>'
    if ($sessions.Count -gt 0) { $sessionText = ($sessions.ToArray() -join '|') }
    $monText = '<none>'
    if ($monitors.Count -gt 0) { $monText = '[' + ($monitors.ToArray() -join ';') + ']' }
    $trText = '<n/a>'
    if ($transports.Count -gt 0) { $trText = '"' + ($transports.ToArray() -join '|') + '"' }
    $endText = '<none>'
    if ($ends.Count -gt 0) { $endText = ($ends.ToArray() -join ',') }
    return "conn: first=$first last=$last events=$($events.Count) session=$sessionText monitors=$monText gfx=$gfx remoteapp_adv_gfx=$advGfx transport=$trText end=$endText"
}

function ConvertTo-SnapshotValueText {
    <# One registry value as report text: <absent> for null, hex for binary, " | " for arrays. #>
    [CmdletBinding()]
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return '<absent>' }
    if ($Value -is [byte[]]) {
        # Length prefix exact, payload capped at 32 bytes: a snapshot diff needs "changed or
        # not", not an image cache verbatim (dry run 2 met an 800-byte one).
        $shown = $Value
        $tail = ''
        if ($Value.Length -gt 32) { $shown = $Value[0..31]; $tail = '...' }
        $hex = ($shown | ForEach-Object { $_.ToString('x2') }) -join ''
        return ('bytes[{0}]:{1}{2}' -f $Value.Length, $hex, $tail)
    }
    if ($Value -is [array]) {
        return (($Value | ForEach-Object { [string]$_ }) -join ' | ')
    }
    return [string]$Value
}

# -------------------------------------------------------------------------------------------
# Host-side collection (Windows only; never reached under -NoRun)
# -------------------------------------------------------------------------------------------

function Get-SnapshotRegistryValueNames {
    [CmdletBinding()]
    param([string] $Path)
    $props = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $props) { return @() }
    return @($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $_.Name })
}

function Add-SnapshotRegistrySection {
    [CmdletBinding()]
    param($Lines, $KeySpec)
    $path = $KeySpec.Path
    $at = (Get-Date).ToUniversalTime().ToString('o')
    # Get-Item first, not Test-Path: Test-Path folds "no such key" and "access denied" into one
    # false, and a baseline snapshot must not record an unreadable key as unconfigured (r1 I8).
    $item = $null
    try { $item = Get-Item -LiteralPath $path -ErrorAction Stop } catch {
        if ($_.Exception -is [System.Management.Automation.ItemNotFoundException]) {
            [void]$Lines.Add("[reg] $path : <key absent> at=$at")
            [void]$Lines.Add("  cmd: Get-Item -LiteralPath '$path'")
            foreach ($n in $KeySpec.Names) { [void]$Lines.Add("  $n = <absent>") }
        } else {
            [void]$Lines.Add("[reg] $path : <key unreadable " + $_.Exception.GetType().Name + "> at=$at")
            [void]$Lines.Add("  cmd: Get-Item -LiteralPath '$path'")
            foreach ($n in $KeySpec.Names) { [void]$Lines.Add("  $n = <unreadable>") }
        }
        return
    }
    $present = @(Get-SnapshotRegistryValueNames -Path $path)
    $subkeys = @($item.GetSubKeyNames())
    $mode = 'all-values'
    if (-not $KeySpec.AllValues) { $mode = 'pre-registered-names-only' }
    [void]$Lines.Add("[reg] $path : values=$($present.Count) subkeys=$($subkeys.Count) mode=$mode at=$at")
    [void]$Lines.Add("  cmd: Get-Item -LiteralPath '$path'; .GetValue(<name>, `$null, DoNotExpandEnvironmentNames)")
    $reported = New-Object System.Collections.ArrayList
    $toDump = $present
    if (-not $KeySpec.AllValues) {
        $wanted = @($KeySpec.Names | ForEach-Object { $_.ToLowerInvariant() })
        $toDump = @($present | Where-Object { $wanted -contains $_.ToLowerInvariant() })
    }
    foreach ($n in $toDump) {
        # The provider shows the unnamed default value as "(default)"; the API reads it as "".
        $apiName = $n
        if ($n -eq '(default)') { $apiName = '' }
        $v = $item.GetValue($apiName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        [void]$Lines.Add("  $n = " + (ConvertTo-SnapshotValueText -Value $v))
        [void]$reported.Add($n.ToLowerInvariant())
    }
    foreach ($n in $KeySpec.Names) {
        if ($reported -notcontains $n.ToLowerInvariant()) { [void]$Lines.Add("  $n = <absent>") }
    }
    if ($subkeys.Count -gt 0) {
        [void]$Lines.Add('  subkeys: ' + ($subkeys -join ', '))
    }
    # TSAppAllowList\Applications: one line per published program (Name/Path), as the matrix
    # probe reports them -- the enforced/not-enforced state is part of the configuration surface.
    if ($subkeys -contains 'Applications') {
        foreach ($k in @(Get-ChildItem -LiteralPath (Join-Path $path 'Applications') -ErrorAction SilentlyContinue)) {
            [void]$Lines.Add(('  [Applications\{0}] Name={1} Path={2}' -f $k.PSChildName,
                (ConvertTo-SnapshotValueText -Value $k.GetValue('Name', $null)),
                (ConvertTo-SnapshotValueText -Value $k.GetValue('Path', $null))))
        }
    }
}

function Invoke-SnapshotCollection {
    [CmdletBinding()]
    param([string] $OutPath, [int] $MaxEventsPerChannel, [int] $SessionHistoryCount, [int] $ClockChangeCount, [int] $ConnectionDigestCount)

    $L = New-Object System.Collections.ArrayList
    function Write-Checkpoint([string] $Stage) {
        $copy = @($L.ToArray()) + @("CHECKPOINT: $Stage")
        [IO.File]::WriteAllLines($OutPath, [string[]]$copy)
    }

    [void]$L.Add('server-snapshot v1 (paths A + E, read-only)')
    [void]$L.Add('ReadAtUtc: ' + (Get-Date).ToUniversalTime().ToString('o'))
    [void]$L.Add('PSVersion: ' + $PSVersionTable.PSVersion.ToString())
    $sid = '<unknown>'
    try { $sid = (Get-Process -Id $PID -ErrorAction Stop).SessionId } catch { }
    $sn = '<unset>'
    if (Test-Path Env:SESSIONNAME) { $sn = $env:SESSIONNAME }
    [void]$L.Add("SessionId: $sid  SessionName: $sn")
    # First write before anything slow runs: from here on the drive never holds a previous run's
    # complete report under this run's name (r1 B3). A relay job that never starts the script
    # (RAIL exec refused) still leaves the previous file -- the operator removes it before launch.
    Write-Checkpoint 'started'

    # --- winver -------------------------------------------------------------------------------
    [void]$L.Add('')
    [void]$L.Add('== winver')
    try {
        $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $cvNames = @($cv.PSObject.Properties.Name)
        function CvValue([string] $n) { if ($cvNames -contains $n) { return $cv.$n } else { return $null } }
        [void]$L.Add('windows_build: ' + (Format-SnapshotWindowsBuild -CurrentBuild (CvValue 'CurrentBuild') -Ubr (CvValue 'UBR')))
        foreach ($n in @('ProductName', 'DisplayVersion', 'ReleaseId', 'EditionID', 'InstallationType',
                         'CurrentBuild', 'UBR', 'BuildLabEx', 'CurrentMajorVersionNumber', 'CurrentMinorVersionNumber')) {
            [void]$L.Add("  $n = " + (ConvertTo-SnapshotValueText -Value (CvValue $n)))
        }
    } catch {
        [void]$L.Add('windows_build: unknown')
        [void]$L.Add('  CurrentVersion unreadable: ' + $_.Exception.GetType().Name)
    }
    [void]$L.Add('  OSVersion = ' + [Environment]::OSVersion.VersionString + '   (secondary: subject to the .NET Framework compatibility manifest)')

    # --- host_freshness -------------------------------------------------------------------------
    [void]$L.Add('')
    [void]$L.Add('== host_freshness')
    $up = $null
    $os = $null
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $up = ($os.LocalDateTime - $os.LastBootUpTime).TotalSeconds
        [void]$L.Add('  LastBootUpTime(local) = ' + $os.LastBootUpTime.ToString('o'))
        [void]$L.Add('  LocalDateTime = ' + $os.LocalDateTime.ToString('o'))
        [void]$L.Add('  UptimeSeconds = ' + [int][math]::Floor($up))
        [void]$L.Add('  Caption = ' + (ConvertTo-SnapshotValueText -Value $os.Caption))
        [void]$L.Add('  Version = ' + (ConvertTo-SnapshotValueText -Value $os.Version))
        [void]$L.Add('  BuildNumber = ' + (ConvertTo-SnapshotValueText -Value $os.BuildNumber))
    } catch {
        [void]$L.Add('  Win32_OperatingSystem unreadable: ' + $_.Exception.GetType().Name)
    }
    # 32-bit ms since boot; wraps every 24.9 days. Not a cross-check only: when the boot-time
    # clock was wrong (see Select-SnapshotHostFreshnessLabel) it is the truthful source.
    $tickSeconds = [int][math]::Floor([Environment]::TickCount / 1000)
    [void]$L.Add("  TickCountSeconds(32-bit, wraps 24.9d) = $tickSeconds")
    # Clock corrections since boot: Kernel-General 1 (system time changed), newest $ClockChangeCount
    # read (see the parameter for why 5 was too few), with the old->new jump computed from the
    # EventData (ISO stamps; a parse failure leaves delta <unparsed>). Every event read feeds the
    # sum; only the ones that moved the clock are printed (Select-SnapshotClockEventsToPrint).
    $clockJump = $null
    $clockEvents = New-Object System.Collections.ArrayList
    [void]$L.Add((Format-SnapshotClockChangeHeader -Count $ClockChangeCount))
    try {
        $tcs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 1 } -MaxEvents $ClockChangeCount -ErrorAction Stop)
        foreach ($e in $tcs) {
            $x = $e.ToXml()
            $oldT = Get-SnapshotEventDataValue -Xml $x -Name 'OldTime'
            $newT = Get-SnapshotEventDataValue -Xml $x -Name 'NewTime'
            $why = Get-SnapshotEventDataValue -Xml $x -Name 'Reason'
            $delta = ''
            try {
                $inv = [Globalization.CultureInfo]::InvariantCulture
                $rk = [Globalization.DateTimeStyles]::RoundtripKind
                $d = ([DateTime]::Parse($newT, $inv, $rk) - [DateTime]::Parse($oldT, $inv, $rk)).TotalSeconds
                $delta = [int][math]::Round($d)
            } catch { $delta = '<unparsed>' }
            $oldParsed = $null
            try { $oldParsed = [DateTime]::Parse($oldT, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime() } catch { }
            $line = ('    Kernel-General 1 {0} old={1} new={2} delta={3}s reason={4}' -f $e.TimeCreated.ToUniversalTime().ToString('o'), $oldT, $newT, $delta, $why)
            [void]$clockEvents.Add([pscustomobject]@{ Time = $e.TimeCreated; Old = $oldParsed; Delta = $delta; Line = $line })
        }
        $sel = Select-SnapshotClockEventsToPrint -Events @($clockEvents.ToArray()) -Max 10
        foreach ($shownEvent in $sel.Shown) { [void]$L.Add($shownEvent.Line) }
        if ($sel.OmittedZero -gt 0 -or $sel.OmittedBeyondCap -gt 0) {
            [void]$L.Add(('    Kernel-General 1: {0} zero-delta correction(s) and {1} non-zero beyond the 10-line cap read but not shown (all feed the sum)' -f $sel.OmittedZero, $sel.OmittedBeyondCap))
        }
        $bootLocal = $null
        if ($null -ne $os) { $bootLocal = $os.LastBootUpTime }
        $clockJump = Measure-SnapshotClockJump -Events @($clockEvents.ToArray()) -BootTime $bootLocal
        $jumpText = '<none since boot>'
        if ($null -ne $clockJump) { $jumpText = "$clockJump" + 's' }
        [void]$L.Add('  clock_jump_since_boot = ' + $jumpText)
    } catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') {
            [void]$L.Add('    Kernel-General 1: none')
        } else {
            [void]$L.Add('    Kernel-General 1: unreadable ' + $_.Exception.GetType().Name + ' (' + $_.FullyQualifiedErrorId + ')')
        }
    }
    [void]$L.Add('  freshness_consistency = ' + (Get-SnapshotFreshnessConsistency -BootUptimeSeconds $up -TickSeconds $tickSeconds))
    $pick = Select-SnapshotHostFreshnessLabel -BootUptimeSeconds $up -TickSeconds $tickSeconds -ClockJumpSeconds $clockJump
    [void]$L.Add('  host_freshness_boot = ' + (Get-SnapshotHostFreshness -UptimeSeconds $up))
    [void]$L.Add('  host_freshness_tick = ' + (Get-SnapshotHostFreshness -UptimeSeconds $tickSeconds))
    [void]$L.Add('host_freshness: ' + $pick.Label)
    [void]$L.Add('  basis = ' + $pick.Basis)
    [void]$L.Add('  reason = ' + $pick.Reason)
    # Boot/sleep history from the System log (readable by a standard account): Kernel-Boot 27
    # carries BootType (cold boot / fast startup / resume from hibernation); Kernel-Power 42/107
    # are sleep entry / resume. Together they say what the tick-vs-boot gap was.
    [void]$L.Add('  boot history (System log, newest first):')
    foreach ($q in @(
        @{ Label = 'Kernel-Boot 27';    Provider = 'Microsoft-Windows-Kernel-Boot';    Id = 27; Max = 5; BootType = $true },
        @{ Label = 'Kernel-General 12'; Provider = 'Microsoft-Windows-Kernel-General'; Id = 12; Max = 3; BootType = $false },
        @{ Label = 'Kernel-General 13'; Provider = 'Microsoft-Windows-Kernel-General'; Id = 13; Max = 3; BootType = $false },
        # Kernel-Power 42 (entering sleep) / 107 (resumed): read so a sleep can be told apart from
        # a clock correction when boot- and tick-based uptimes disagree. Dry runs 5-7 found none
        # on this host; the gap there was the clock correction the Kernel-General 1 block shows.
        @{ Label = 'Kernel-Power 42';   Provider = 'Microsoft-Windows-Kernel-Power';   Id = 42;  Max = 3; BootType = $false },
        @{ Label = 'Kernel-Power 107';  Provider = 'Microsoft-Windows-Kernel-Power';   Id = 107; Max = 3; BootType = $false })) {
        try {
            $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $q.Provider; Id = $q.Id } -MaxEvents $q.Max -ErrorAction Stop)
            foreach ($e in $evs) {
                $extra = ''
                if ($q.BootType) {
                    $xml = $e.ToXml()
                    $bt = Get-SnapshotBootTypeFromXml -Xml $xml
                    $extra = ' boot_type=' + (Format-SnapshotBootType -BootType $bt)
                    if ($null -eq $bt) {
                        # Unparsed: show the EventData so the next fold can see the real shape.
                        $ed = [regex]::Match($xml, '<EventData>.*?</EventData>', 'Singleline').Value
                        if ($ed.Length -gt 240) { $ed = $ed.Substring(0, 240) + '...' }
                        $extra = $extra + ' eventdata=' + $ed
                    }
                }
                [void]$L.Add(('    {0} {1}{2}' -f $q.Label, $e.TimeCreated.ToUniversalTime().ToString('o'), $extra))
            }
        } catch {
            if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') {
                [void]$L.Add('    ' + $q.Label + ': none')
            } else {
                [void]$L.Add('    ' + $q.Label + ': unreadable ' + $_.Exception.GetType().Name + ' (' + $_.FullyQualifiedErrorId + ')')
            }
        }
    }
    # Session history (LocalSessionManager/Operational, newest $SessionHistoryCount -- see the
    # parameter for why 12 was too short): logon / shell-start / logoff / disconnect / reconnect
    # with the SessionID datum only -- user and client address deliberately NOT read (red line).
    # This is what turns the T6-prime clause (c) "same session" assumption into a measurement:
    # a 24 (disconnect) followed by a 25 (reconnect) on the same SessionID.
    [void]$L.Add((Format-SnapshotSessionHistoryHeader -Count $SessionHistoryCount))
    try {
        $lsm = @(Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' -MaxEvents $SessionHistoryCount -ErrorAction Stop)
        foreach ($e in $lsm) {
            $tc = Get-SnapshotProp -Object $e -Name 'TimeCreated'
            $tcText = $null
            if ($null -ne $tc) { $tcText = $tc.ToUniversalTime().ToString('o') }
            $x = $null
            try { $x = $e.ToXml() } catch { $x = $null }
            [void]$L.Add('    ' + (Format-SnapshotSessionEventLine -TimeUtc $tcText -Id (Get-SnapshotProp -Object $e -Name 'Id') -Xml $x))
        }
    } catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') {
            [void]$L.Add('    lsm: none')
        } else {
            [void]$L.Add('    lsm: unreadable ' + $_.Exception.GetType().Name + ' (' + $_.FullyQualifiedErrorId + ')')
        }
    }
    # Connection digest (RdpCoreTS/Operational grouped by ActivityId -- see the parameter). The
    # host-side record of what a client declared: the requested monitor sizes (168), the graphics
    # capability line (162) and the session the connection was assigned to (66). Only the
    # pre-registered EventData names are read (Format-SnapshotConnectionLine); the client
    # address, ServerName, ConnectionName and ChannelName never are.
    try {
        $core = @(Get-WinEvent -LogName 'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational' -MaxEvents $MaxEventsPerChannel -ErrorAction Stop)
        $items = New-Object System.Collections.ArrayList
        foreach ($e in $core) {
            $tc = Get-SnapshotProp -Object $e -Name 'TimeCreated'
            $tcText = $null
            if ($null -ne $tc) { $tcText = $tc.ToUniversalTime().ToString('o') }
            $x = $null
            try { $x = $e.ToXml() } catch { $x = $null }
            [void]$items.Add([pscustomobject]@{
                ActivityId = [string](Get-SnapshotProp -Object $e -Name 'ActivityId')
                Id         = (Get-SnapshotProp -Object $e -Name 'Id')
                TimeUtc    = $tcText
                Xml        = $x
            })
        }
        $digest = Group-SnapshotConnectionEvents -Events @($items.ToArray()) -Count $ConnectionDigestCount
        [void]$L.Add((Format-SnapshotConnectionDigestHeader -Count $ConnectionDigestCount -Scanned $digest.Scanned))
        foreach ($g in @($digest.Groups)) { [void]$L.Add('    ' + (Format-SnapshotConnectionLine -Group $g)) }
        if (@($digest.Groups).Count -eq 0) { [void]$L.Add('    conn: none') }
        [void]$L.Add('    conn: ungrouped=' + $digest.Ungrouped)
    } catch {
        [void]$L.Add((Format-SnapshotConnectionDigestHeader -Count $ConnectionDigestCount -Scanned 0))
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') {
            [void]$L.Add('    conn: none')
        } else {
            [void]$L.Add('    conn: unreadable ' + $_.Exception.GetType().Name + ' (' + $_.FullyQualifiedErrorId + ')')
        }
    }
    Write-Checkpoint 'winver+freshness'

    # --- E. registry ---------------------------------------------------------------------------
    [void]$L.Add('')
    [void]$L.Add('== E. registry (read-only)')
    foreach ($spec in $script:SnapshotRegistryKeys) {
        try { Add-SnapshotRegistrySection -Lines $L -KeySpec $spec } catch {
            [void]$L.Add("[reg] $($spec.Path) : <error " + $_.Exception.GetType().Name + '>')
        }
    }
    Write-Checkpoint 'registry'

    # --- A. event log channels ---------------------------------------------------------------
    [void]$L.Add('')
    [void]$L.Add('== A. event log channels')
    $allLogs = @()
    $listErr = @()
    try {
        # -Force includes disabled analytic/debug channels in the listing. Channels this account
        # cannot even list raise non-terminating errors; they are collected and COUNTED below
        # (list_failures=), not silently dropped (r1 I7).
        $allLogs = @(Get-WinEvent -ListLog * -Force -ErrorAction SilentlyContinue -ErrorVariable listErr)
    } catch {
        [void]$L.Add('ListLog failed: ' + $_.Exception.GetType().Name)
    }
    [void]$L.Add('cmd: Get-WinEvent -ListLog * -Force   list_failures=' + @($listErr).Count)
    $selected = @(Select-SnapshotLogName -Names @($allLogs | ForEach-Object { $_.LogName }))
    [void]$L.Add("ListLog total=$($allLogs.Count) rds_related=$($selected.Count) keywords=" + ($script:SnapshotKeywords -join ','))
    $providers = @()
    try {
        $providers = @(Get-WinEvent -ListProvider * -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    } catch { }
    $rdsProviders = @(Select-SnapshotLogName -Names $providers)
    [void]$L.Add("ListProvider total=$($providers.Count) rds_related=$($rdsProviders.Count)")
    foreach ($p in $rdsProviders) { [void]$L.Add("  provider: $p") }
    Write-Checkpoint 'channel-list'

    foreach ($name in $selected) {
      try {
        $info = $allLogs | Where-Object { $_.LogName -eq $name } | Select-Object -First 1
        $at = (Get-Date).ToUniversalTime().ToString('o')
        $rc = '<n/a>'
        $rcv = Get-SnapshotProp -Object $info -Name 'RecordCount'
        if ($null -ne $rcv) { $rc = $rcv }
        $logType = [string](Get-SnapshotProp -Object $info -Name 'LogType')
        [void]$L.Add("[channel] $name enabled=$(Get-SnapshotProp -Object $info -Name 'IsEnabled') records=$rc mode=$(Get-SnapshotProp -Object $info -Name 'LogMode') type=$logType at=$at")
        $events = @()
        $readable = 'true'
        # Analytic and Debug channels can only be read oldest-first (Get-WinEvent refuses them
        # otherwise: SpecifyOldestForLog -- every one dry run 2 met came back that way). The
        # window line names the direction, because on an ENABLED analytic channel with more than
        # MaxEventsPerChannel records the scanned slice is the OLD end (r1 I4).
        $oldest = ($logType -eq 'Analytical' -or $logType -eq 'Debug')
        $order = 'newest-first'
        $cmd = "Get-WinEvent -LogName '$name' -MaxEvents $MaxEventsPerChannel"
        if ($oldest) { $order = 'oldest-first'; $cmd = $cmd + ' -Oldest' }
        [void]$L.Add("  cmd: $cmd")
        try {
            if ($oldest) {
                $events = @(Get-WinEvent -LogName $name -MaxEvents $MaxEventsPerChannel -Oldest -ErrorAction Stop)
            } else {
                $events = @(Get-WinEvent -LogName $name -MaxEvents $MaxEventsPerChannel -ErrorAction Stop)
            }
            if ($events.Count -eq 0) { $readable = 'true-empty' }
        } catch {
            # Locale-independent: the "no events" case is told apart by its FullyQualifiedErrorId,
            # not by the (localised) message text. Anything else -- typically
            # UnauthorizedAccessException for a standard account on an Operational channel -- is
            # reported by exception type and error id so the refusal is itself a result.
            if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') {
                $readable = 'true-empty'
            } else {
                $readable = 'false ' + $_.Exception.GetType().Name + ' (' + $_.FullyQualifiedErrorId + ')'
            }
        }
        # Scan text per event: the rendered Message, or the event XML when there is none (r1 B2).
        $texts = New-Object System.Collections.ArrayList
        $noMessage = 0
        foreach ($e in $events) {
            $m = Get-SnapshotProp -Object $e -Name 'Message'
            $x = $null
            if ($null -eq $m -or ([string]$m).Length -eq 0) { $noMessage++; try { $x = $e.ToXml() } catch { $x = $null } }
            [void]$texts.Add((Select-SnapshotScanText -Message $m -Xml $x))
        }
        $hit = Measure-SnapshotKeywordHit -Messages @($texts.ToArray()) -Keywords $script:SnapshotKeywords
        $hit3 = Measure-SnapshotKeywordHit -Messages @($texts.ToArray()) -Keywords @($script:SnapshotKeywords[0..2])
        [void]$L.Add('  ' + (Format-SnapshotScanLine -Readable $readable -Hit $hit -Hit3 $hit3 -NoMessage $noMessage -Keywords $script:SnapshotKeywords))
        if ($events.Count -gt 0) {
            $times = @($events | ForEach-Object { Get-SnapshotProp -Object $_ -Name 'TimeCreated' } | Where-Object { $null -ne $_ } | Sort-Object)
            if ($times.Count -gt 0) {
                [void]$L.Add(('  window: oldest={0} newest={1} order={2} ({3} of {4} records scanned)' -f
                    $times[0].ToUniversalTime().ToString('o'), $times[$times.Count - 1].ToUniversalTime().ToString('o'),
                    $order, $events.Count, $rc))
            } else {
                [void]$L.Add("  window: <no timestamps> order=$order ($($events.Count) of $rc records scanned)")
            }
        }
        # Samples: every event of a channel with at most three (so a lone record -- the one
        # SessionServices/Operational event of 2026-08-21 -- is read, not just counted); otherwise
        # up to five keyword hits.
        $listAll = ($events.Count -le 3)
        $samples = 0
        for ($ei = 0; $ei -lt $events.Count; $ei++) {
            if (-not $listAll -and $samples -ge 5) { break }
            $e = $events[$ei]
            $text = [string]$texts[$ei]
            $isHit = $false
            foreach ($k in $script:SnapshotKeywords) {
                if ($text.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $isHit = $true; break }
            }
            if (-not $listAll -and -not $isHit) { continue }
            $flat = ($text -replace '\r?\n', ' / ')
            if ($flat.Length -gt 200) { $flat = $flat.Substring(0, 200) + '...' }
            $tc = Get-SnapshotProp -Object $e -Name 'TimeCreated'
            $tcText = '<no-time>'
            if ($null -ne $tc) { $tcText = $tc.ToUniversalTime().ToString('o') }
            $tag = 'event'
            if ($isHit) { $tag = 'hit' }
            [void]$L.Add(('  {0}: {1} id={2} provider={3} :: {4}' -f $tag, $tcText, (Get-SnapshotProp -Object $e -Name 'Id'), (Get-SnapshotProp -Object $e -Name 'ProviderName'), $flat))
            $samples++
        }
      } catch {
        # One channel must not take the rest of the report (and RESULT: DONE) with it (r1 I9).
        [void]$L.Add("  <error " + $_.Exception.GetType().Name + ': ' + ($_.Exception.Message -replace '\r?\n', ' ') + '>')
      }
      Write-Checkpoint "channel $name"
    }

    [void]$L.Add('')
    [void]$L.Add('RESULT: DONE')
    [IO.File]::WriteAllLines($OutPath, [string[]]@($L.ToArray()))
}

if (-not $NoRun) {
    Invoke-SnapshotCollection -OutPath $OutPath -MaxEventsPerChannel $MaxEventsPerChannel -SessionHistoryCount $SessionHistoryCount -ClockChangeCount $ClockChangeCount -ConnectionDigestCount $ConnectionDigestCount
}
