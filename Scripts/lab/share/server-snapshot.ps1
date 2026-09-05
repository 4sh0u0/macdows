<#
.SYNOPSIS
    READ-ONLY server-side snapshot for the scaled-map memo's paths A + E, run on the host by the
    lab relay (jobs/server-snapshot.env -> powershell.exe -File \\tsclient\lab\server-snapshot.ps1).

.DESCRIPTION
    Standard lab account, no elevation, nothing written on the host. One report goes back over
    the redirected drive; it is rewritten at three checkpoints (after winver/freshness, after the
    registry section, at the end) so a relay TIMEOUT still leaves the sections that finished --
    the same shape tsallowlist-matrix-verify.ps1 uses and for the same reason.

    What it collects (docs/upgrade-gate/2026-09-scaledmap-next-step.md section 3, rows A and E):

      winver / host_freshness  -- the two matrix fields (docs/matrix/format.md section 2.1) that
                                  every live-host env record must carry: windows_build as
                                  10.0.<CurrentBuild>.<UBR> from HKLM CurrentVersion, and
                                  host_freshness from Win32_OperatingSystem.LastBootUpTime.
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
                                  the newest events of every readable channel scanned for the
                                  pre-registered keywords (graphics / scal / gfx, plus surface),
                                  with counts per keyword and up to five sample hits.

    Deliberately NOT written into the report: $env:COMPUTERNAME and $env:USERNAME. Event
    messages and registry values are copied verbatim, so the report may still carry host
    identifiers -- it lives under .build/lab-runtime/ (git-ignored) and only counts, ids and
    build strings are transcribed into docs.

    Windows PowerShell 5.1 notes: no ??, no ternary, no -Parallel; [Environment]::TickCount64
    does not exist on .NET Framework, so the boot-time cross-check uses the 32-bit TickCount and
    says so.

.PARAMETER NoRun
    Define the functions but do not touch the host. Used by server-snapshot.Tests.ps1 to
    dot-source the pure helpers and drive them with fixtures on macOS.
#>

[CmdletBinding()]
param(
    [string] $OutPath = '\\tsclient\lab\server-snapshot-out.txt',
    # Newest events read per readable channel. Bounded so the whole scan stays inside the relay
    # job's TIMEOUT even on a channel with years of history.
    [int] $MaxEventsPerChannel = 500,
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
# Connections), and the bare tokens RemoteFX / Rdms / RDP for channels named by those alone.
# RdpCore is not listed: every RdpCore* channel is a RemoteDesktopServices-* channel and RDP
# covers a bare one. Dwm is deliberately NOT included (a DWM channel exists on every desktop
# and says nothing about the RDP graphics pipeline).
$script:SnapshotChannelPattern = 'TerminalServices|Remote-?Desktop|Remote-?App|RemoteFX|Rdms|RDP'

# Registry keys read for path E. Every value present under each key is reported; Names lists
# the pre-registered names that are additionally reported as <absent> when not set, so the
# report shape does not depend on what the host happens to have configured.
$script:SnapshotRegistryKeys = @(
    [pscustomobject]@{
        Path  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
        Names = @('fAllowUnlistedRemotePrograms', 'fEnableRemoteFXAdvancedRemoteApp',
                  'fEnableVirtualGraphics', 'bEnumerateHWBeforeSW', 'AVC444ModePreferred',
                  'AVCHardwareEncodePreferred', 'fEnableWddmDriver', 'MaxMonitors',
                  'MaxXResolution', 'MaxYResolution', 'ColorDepth', 'ImageQuality',
                  'VisualExperiencePolicy', 'DWMFRAMEINTERVAL', 'SelectTransport',
                  'fDisableClip', 'fNoRemoteDesktopWallpaper', 'fDenyTSConnections')
    },
    [pscustomobject]@{
        Path  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server'
        Names = @('fAllowUnlistedRemotePrograms', 'fDenyTSConnections')
    },
    [pscustomobject]@{
        Path  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList'
        Names = @('fDisabledAllowList', 'fHasCertificate', 'CustomRDPSettings')
    },
    [pscustomobject]@{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        Names = @('fDenyTSConnections', 'fSingleSessionPerUser', 'TSUserEnabled')
    },
    [pscustomobject]@{
        Path  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        Names = @('UserAuthentication', 'SecurityLayer', 'MinEncryptionLevel', 'ColorDepth',
                  'MaxMonitors', 'MaxXResolution', 'MaxYResolution', 'fEnableWinStation',
                  'SelectTransport', 'fInheritColorDepth')
    },
    [pscustomobject]@{
        Path  = 'HKCU:\Control Panel\Desktop'
        Names = @('LogPixels', 'Win8DpiScaling', 'DpiScalingVer')
    }
)

# -------------------------------------------------------------------------------------------
# Pure helpers (no host state; exercised off-Windows by the test suite)
# -------------------------------------------------------------------------------------------

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

function ConvertTo-SnapshotValueText {
    <# One registry value as report text: <absent> for null, hex for binary, " | " for arrays. #>
    [CmdletBinding()]
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return '<absent>' }
    if ($Value -is [byte[]]) {
        $hex = ($Value | ForEach-Object { $_.ToString('x2') }) -join ''
        return ('bytes[{0}]:{1}' -f $Value.Length, $hex)
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
    if (-not (Test-Path -LiteralPath $path)) {
        [void]$Lines.Add("[reg] $path : <key absent>")
        foreach ($n in $KeySpec.Names) { [void]$Lines.Add("  $n = <absent>") }
        return
    }
    $item = $null
    try { $item = Get-Item -LiteralPath $path -ErrorAction Stop } catch {
        [void]$Lines.Add("[reg] $path : <unreadable " + $_.Exception.GetType().Name + '>')
        return
    }
    $present = @(Get-SnapshotRegistryValueNames -Path $path)
    $subkeys = @($item.GetSubKeyNames())
    [void]$Lines.Add("[reg] $path : values=$($present.Count) subkeys=$($subkeys.Count)")
    $reported = New-Object System.Collections.ArrayList
    foreach ($n in $present) {
        $v = $item.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
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
    param([string] $OutPath, [int] $MaxEventsPerChannel)

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
    [void]$L.Add('  OSVersion = ' + [Environment]::OSVersion.VersionString)

    # --- host_freshness -------------------------------------------------------------------------
    [void]$L.Add('')
    [void]$L.Add('== host_freshness')
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $up = ($os.LocalDateTime - $os.LastBootUpTime).TotalSeconds
        [void]$L.Add('host_freshness: ' + (Get-SnapshotHostFreshness -UptimeSeconds $up))
        [void]$L.Add('  LastBootUpTime(local) = ' + $os.LastBootUpTime.ToString('o'))
        [void]$L.Add('  LocalDateTime = ' + $os.LocalDateTime.ToString('o'))
        [void]$L.Add('  UptimeSeconds = ' + [int][math]::Floor($up))
        [void]$L.Add('  Caption = ' + (ConvertTo-SnapshotValueText -Value $os.Caption))
        [void]$L.Add('  Version = ' + (ConvertTo-SnapshotValueText -Value $os.Version))
        [void]$L.Add('  BuildNumber = ' + (ConvertTo-SnapshotValueText -Value $os.BuildNumber))
    } catch {
        [void]$L.Add('host_freshness: unknown')
        [void]$L.Add('  Win32_OperatingSystem unreadable: ' + $_.Exception.GetType().Name)
    }
    # 32-bit ms since boot; wraps every 24.9 days, so it is a cross-check, not the source.
    [void]$L.Add('  TickCountSeconds(32-bit, wraps 24.9d) = ' + [int][math]::Floor([Environment]::TickCount / 1000))
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
    try {
        # -Force includes disabled analytic/debug channels in the listing. Channels this account
        # may not even list are skipped by SilentlyContinue and counted below by their absence.
        $allLogs = @(Get-WinEvent -ListLog * -Force -ErrorAction SilentlyContinue)
    } catch {
        [void]$L.Add('ListLog failed: ' + $_.Exception.GetType().Name)
    }
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
        $info = $allLogs | Where-Object { $_.LogName -eq $name } | Select-Object -First 1
        $rc = '<n/a>'
        if ($null -ne $info.RecordCount) { $rc = $info.RecordCount }
        [void]$L.Add("[channel] $name enabled=$($info.IsEnabled) records=$rc mode=$($info.LogMode) type=$($info.LogType)")
        $events = @()
        $readable = 'true'
        try {
            $events = @(Get-WinEvent -LogName $name -MaxEvents $MaxEventsPerChannel -ErrorAction Stop)
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
        $hit = Measure-SnapshotKeywordHit -Messages @($events | ForEach-Object { $_.Message }) -Keywords $script:SnapshotKeywords
        [void]$L.Add("  readable=$readable " + (Format-SnapshotKeywordHitLine -Hit $hit -Keywords $script:SnapshotKeywords))
        $samples = 0
        foreach ($e in $events) {
            if ($samples -ge 5) { break }
            $msg = $e.Message
            if ($null -eq $msg) { continue }
            $isHit = $false
            foreach ($k in $script:SnapshotKeywords) {
                if ($msg.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $isHit = $true; break }
            }
            if (-not $isHit) { continue }
            $flat = ($msg -replace '\r?\n', ' / ')
            if ($flat.Length -gt 200) { $flat = $flat.Substring(0, 200) + '...' }
            [void]$L.Add(('  hit: {0} id={1} provider={2} :: {3}' -f $e.TimeCreated.ToUniversalTime().ToString('o'), $e.Id, $e.ProviderName, $flat))
            $samples++
        }
        Write-Checkpoint "channel $name"
    }

    [void]$L.Add('')
    [void]$L.Add('RESULT: DONE')
    [IO.File]::WriteAllLines($OutPath, [string[]]@($L.ToArray()))
}

if (-not $NoRun) {
    Invoke-SnapshotCollection -OutPath $OutPath -MaxEventsPerChannel $MaxEventsPerChannel
}
