<#
.SYNOPSIS
    Windows-side acceptance run for the Macdows host-agent prototype (W7).

.DESCRIPTION
    The in-session counterpart of probe.sh. It runs *inside* the user's Windows session and
    talks to the agent over loopback, which is the production posture and which sidesteps
    Windows Defender Firewall entirely: a non-admin user cannot create an inbound rule, so a
    LAN probe from the Mac is likely to be blocked, while a loopback probe never leaves the
    host.

    In the lab this is launched as a RemoteApp with both the script and the output directory on
    redirected drives, so the results land on the Mac without any inbound connection:

        powershell.exe -File \\tsclient\macdows\probe.ps1 -OutDir \\tsclient\lab\out

    Writes health.json, apps.json, assoc.json, launch.json, icon-0.png and result.txt to
    -OutDir, and *always* finishes by writing a DONE marker there (including on failure) so
    the Mac side can tell "finished and failed" from "still running or died". Exits non-zero if
    any capability check failed.

    The bearer token is read from the token file and used only as a request header. It is never
    printed, never written to any output file, and never logged.

    Windows PowerShell 5.1 compatible.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\probe.ps1 -OutDir C:\Temp\macdows-probe

.EXAMPLE
    powershell.exe -File \\tsclient\macdows\probe.ps1 -OutDir \\tsclient\lab\out -LaunchId charmap
#>

[CmdletBinding()]
param(
    # Where the JSON artifacts, icon-0.png, result.txt and the DONE marker are written.
    # May be a redirected drive such as \\tsclient\lab\out.
    [Parameter(Mandatory = $true)]
    [string] $OutDir,

    # Agent port.
    [int] $Port = 47615,

    # Token file written by the agent at startup.
    [string] $TokenPath,

    # Allowlist id to proxy-launch. Default: the first agentAllowlist entry whose
    # inTsAllowList is false, i.e. a program provably not reachable through RAIL.
    [string] $LaunchId,

    # Define the functions but do not run the probe (for dot-sourcing from tests).
    [switch] $NoRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:MacdowsProbeVersion = '0.1.0'
$script:MacdowsProbeTimeoutSeconds = 20
$script:MacdowsProbePngMagic = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

# Every file this probe writes into -OutDir. Cleared at the start of a run so a failing run
# cannot leave a previous run's artifacts sitting next to a fresh verdict.
$script:MacdowsProbeArtifacts = @(
    'health.json', 'apps.json', 'assoc.json', 'launch.json', 'icon-0.png', 'result.txt', 'DONE'
)

# ---------------------------------------------------------------------------------------------
# Pure helpers (no I/O, no network - unit-tested on macOS)
# ---------------------------------------------------------------------------------------------

function Format-MacdowsProbeResult {
    <# One result line. PASS/FAIL is the first token so the Mac side can grep for it. #>
    [CmdletBinding()]
    param([bool] $Ok, [string] $Capability, [string] $Detail)

    $status = 'FAIL'
    if ($Ok) { $status = 'PASS' }
    return ('{0}  {1,-14} {2}' -f $status, $Capability, $Detail)
}

function Format-MacdowsProbeInfo {
    [CmdletBinding()]
    param([string] $Text)
    return ('      {0}' -f $Text)
}

function Test-MacdowsProbePngMagic {
    <# True only if the buffer opens with the 8-byte PNG signature. #>
    [CmdletBinding()]
    param([byte[]] $Bytes)

    if ($null -eq $Bytes) { return $false }
    if ($Bytes.Length -lt $script:MacdowsProbePngMagic.Length) { return $false }
    for ($i = 0; $i -lt $script:MacdowsProbePngMagic.Length; $i++) {
        if ($Bytes[$i] -ne $script:MacdowsProbePngMagic[$i]) { return $false }
    }
    return $true
}

function Get-MacdowsProbeEntryList {
    <#
      Normalises a JSON array property. Windows PowerShell 5.1's ConvertTo-Json can collapse a
      one-element array into a bare object, so a host with exactly one RemoteApp must not be
      mistaken for a malformed response.

      Contract: this emits zero or more items to the pipeline, so **every caller must wrap the
      call in @()**. Returning an array directly is not an option - PowerShell unrolls it, and
      the `,@()` trick to prevent that yields an array-inside-an-array here, which silently
      turns an empty list into a one-element one.
    #>
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-MacdowsProbeProperty {
    <# StrictMode-safe property read: $null instead of an exception when absent. #>
    [CmdletBinding()]
    param($InputObject, [string] $Name)

    if ($null -eq $InputObject) { return $null }
    try {
        if (@($InputObject.PSObject.Properties.Name) -notcontains $Name) { return $null }
        return $InputObject.$Name
    } catch {
        # Not an object with named properties (a bare array or scalar slipped through).
        return $null
    }
}

function Select-MacdowsProbeLaunchId {
    <#
      Default launch target: the first agent-allowlist entry that is NOT published as a
      RemoteApp. That is the entry whose launch actually demonstrates capability 2.
    #>
    [CmdletBinding()]
    param($Apps)

    $entries = @(Get-MacdowsProbeEntryList -Value (Get-MacdowsProbeProperty -InputObject $Apps -Name 'agentAllowlist'))
    foreach ($entry in $entries) {
        $inTs = Get-MacdowsProbeProperty -InputObject $entry -Name 'inTsAllowList'
        $id = Get-MacdowsProbeProperty -InputObject $entry -Name 'id'
        if ($inTs -eq $false -and -not [string]::IsNullOrWhiteSpace([string]$id)) {
            return [string]$id
        }
    }
    return $null
}

function Select-MacdowsProbeIcon {
    <# First non-null iconPng in the response, published entries first. #>
    [CmdletBinding()]
    param($Apps)

    $published = @(Get-MacdowsProbeEntryList -Value (Get-MacdowsProbeProperty -InputObject $Apps -Name 'published'))
    $allowed = @(Get-MacdowsProbeEntryList -Value (Get-MacdowsProbeProperty -InputObject $Apps -Name 'agentAllowlist'))

    foreach ($entry in (@($published) + @($allowed))) {
        $png = Get-MacdowsProbeProperty -InputObject $entry -Name 'iconPng'
        if (-not [string]::IsNullOrWhiteSpace([string]$png)) {
            $label = Get-MacdowsProbeProperty -InputObject $entry -Name 'name'
            if ([string]::IsNullOrWhiteSpace([string]$label)) {
                $label = Get-MacdowsProbeProperty -InputObject $entry -Name 'id'
            }
            return [pscustomobject]@{ Base64 = [string]$png; Source = [string]$label }
        }
    }
    return $null
}

function Get-MacdowsProbeSessionId {
    <#
      The session this probe is running in. Worth reporting: TCP loopback is machine-wide but
      window stations are per-session, so a probe in session B can talk to an agent in session A
      and every HTTP check will pass while the proxy-launched window appears in session A -
      i.e. somewhere nobody is watching. Comparing this with the agent's own sessionId turns
      that silent mismatch into a visible line.
    #>
    [CmdletBinding()]
    param()
    try {
        return (Get-Process -Id $PID).SessionId
    } catch {
        return $null
    }
}

function Get-MacdowsProbeDefaultTokenPath {
    [CmdletBinding()]
    param()
    $root = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($root)) {
        # Off-Windows fallback, so the test suite can drive this script on macOS.
        $root = Join-Path $HOME '.local/share'
    }
    return (Join-Path (Join-Path (Join-Path $root 'Macdows') 'host-agent') 'token')
}

# ---------------------------------------------------------------------------------------------
# I/O
# ---------------------------------------------------------------------------------------------

function Invoke-MacdowsProbeRequest {
    <#
      One HTTP request via System.Net.WebClient. WebClient rather than Invoke-WebRequest for two
      reasons: Proxy can be set to $null outright (a configured system proxy must never sit
      between us and 127.0.0.1), and there is no dependency on 5.1's response parsing.
      A non-2xx status raises WebException, so the status code is recovered from the response.
    #>
    [CmdletBinding()]
    param(
        [string] $Uri,
        [string] $Token,
        [string] $Method = 'GET',
        [string] $Body
    )

    $client = New-Object System.Net.WebClient
    try {
        $client.Proxy = $null
        $client.Encoding = [System.Text.Encoding]::UTF8
        $client.Headers.Add('Authorization', "Bearer $Token")

        $content = ''
        if ($Method -eq 'POST') {
            $client.Headers.Add('Content-Type', 'application/json')
            $content = $client.UploadString($Uri, 'POST', $Body)
        } else {
            $content = $client.DownloadString($Uri)
        }
        return [pscustomobject]@{ Ok = $true; Status = 200; Content = $content; Error = $null }
    } catch [System.Net.WebException] {
        $status = 0
        $content = ''
        $response = $_.Exception.Response
        if ($null -ne $response) {
            try { $status = [int]$response.StatusCode } catch { $status = 0 }
            try {
                $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
                try { $content = $reader.ReadToEnd() } finally { $reader.Close() }
            } catch { }
        }
        # NB: the message carries the URI, never the Authorization header.
        return [pscustomobject]@{ Ok = $false; Status = $status; Content = $content; Error = $_.Exception.Message }
    } catch {
        return [pscustomobject]@{ Ok = $false; Status = 0; Content = ''; Error = $_.Exception.Message }
    } finally {
        try { $client.Dispose() } catch { }
    }
}

function Clear-MacdowsProbeArtifacts {
    <#
      Deletes this probe's own artifacts from -OutDir before a run.

      apps.json / assoc.json / launch.json / health.json / icon-0.png are written only on
      success and nothing used to clear them, so a failing run left a previous run's artifacts
      beside a fresh 'DONE ... failures=3' - and a reader picking files off the redirected
      drive has no way to tell. probe.sh already removed the stale icon for this reason.
      DONE is cleared too: while a run is in flight, last run's marker claiming the probe
      finished is exactly the wrong thing to leave lying around.

      A file that cannot be removed (locked, read-only) is not fatal - the run is still worth
      doing - so this returns the names it could not remove and lets the caller report them.

      Contract: this emits zero or more names to the pipeline, so callers must wrap the call
      in @() (same reason as Get-MacdowsProbeEntryList above).
    #>
    [CmdletBinding()]
    param([string] $OutDir)

    $stuck = New-Object System.Collections.ArrayList
    foreach ($name in $script:MacdowsProbeArtifacts) {
        $path = Join-Path $OutDir $name
        try {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }
        } catch {
            [void]$stuck.Add($name)
        }
    }
    return $stuck.ToArray()
}

function Save-MacdowsProbeText {
    [CmdletBinding()]
    param([string] $Path, [string] $Text)
    if ($null -eq $Text) { $Text = '' }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-MacdowsProbe {
    <#
      Runs the three capability checks and returns the number of failures. Always writes
      result.txt and a DONE marker into -OutDir, including when a check throws.
    #>
    [CmdletBinding()]
    param(
        [string] $OutDir,
        [int] $Port,
        [string] $TokenPath,
        [string] $LaunchId
    )

    $lines = New-Object System.Collections.ArrayList
    $failures = 0

    function Add-Line {
        param([string] $Text)
        [void]$lines.Add($Text)
        Write-Host $Text
    }
    function Add-Result {
        param([bool] $Ok, [string] $Capability, [string] $Detail)
        Add-Line (Format-MacdowsProbeResult -Ok $Ok -Capability $Capability -Detail $Detail)
        if (-not $Ok) { $script:MacdowsProbeFailureCount++ }
    }

    $script:MacdowsProbeFailureCount = 0
    $base = "http://127.0.0.1:$Port"

    try {
        # Creating -OutDir belongs INSIDE the try. If it throws - an unwritable or unavailable
        # \\tsclient\... share is exactly the case worth worrying about - the catch below
        # reports it in the probe's own voice instead of letting a raw PowerShell error record
        # escape before the finally that owns the DONE contract has run. A DONE marker is
        # genuinely impossible when its directory does not exist, but the failure still has to
        # be reported by the probe rather than by the runtime.
        #
        # Directory.CreateDirectory rather than New-Item: New-Item has no -LiteralPath (not
        # even on PowerShell 7), so an -OutDir containing '[', ']' or '*' would be glob-
        # expanded. The .NET call treats the string literally and is idempotent.
        if (-not (Test-Path -LiteralPath $OutDir)) {
            [void][System.IO.Directory]::CreateDirectory($OutDir)
        }

        Add-Line (Format-MacdowsProbeInfo -Text "macdows host-agent probe $($script:MacdowsProbeVersion) -> $base")

        # Before anything is written: a failing run must not leave the previous run's
        # artifacts next to a fresh verdict.
        $stale = @(Clear-MacdowsProbeArtifacts -OutDir $OutDir)
        if ($stale.Count -gt 0) {
            Add-Line (Format-MacdowsProbeInfo -Text ("could not clear stale artifact(s): {0}" -f ($stale -join ', ')))
        }

        # -- token ------------------------------------------------------------------------
        $token = $null
        if (Test-Path -LiteralPath $TokenPath) {
            # Get-Content -Raw on a zero-byte file emits NOTHING - an empty pipeline result,
            # not '' and not $null - on Windows PowerShell 5.1 and on PowerShell 7 alike. A
            # [string] cast does not rescue it either: casting a literal $null does give '',
            # but casting "no output" yields no output, so .Trim() still throws and the
            # "no token at ..." message below becomes unreachable. Only an explicit test for
            # null works. Get-Content (not [IO.File]::ReadAllText) so that a relative
            # -TokenPath resolves against the same location as the Test-Path above.
            $token = Get-Content -LiteralPath $TokenPath -Raw
            if ($null -eq $token) { $token = '' }
            $token = $token.Trim()
        }
        if ([string]::IsNullOrWhiteSpace($token)) {
            # Report the path, never the value.
            Add-Line (Format-MacdowsProbeInfo -Text "no token at $TokenPath - is the agent running?")
        }

        # -- health (informational; a failure here shows up in all three capability lines) --
        $health = Invoke-MacdowsProbeRequest -Uri "$base/v1/health" -Token $token
        if ($health.Ok) {
            Save-MacdowsProbeText -Path (Join-Path $OutDir 'health.json') -Text $health.Content
            $healthObj = ConvertFrom-Json $health.Content
            Add-Line (Format-MacdowsProbeInfo -Text ("health: agent={0} version={1} user={2} session={3} tsAllowListDisabled={4} bind={5}" -f `
                (Get-MacdowsProbeProperty -InputObject $healthObj -Name 'agent'),
                (Get-MacdowsProbeProperty -InputObject $healthObj -Name 'version'),
                (Get-MacdowsProbeProperty -InputObject $healthObj -Name 'user'),
                (Get-MacdowsProbeProperty -InputObject $healthObj -Name 'sessionId'),
                (Get-MacdowsProbeProperty -InputObject $healthObj -Name 'tsAllowListDisabled'),
                (Get-MacdowsProbeProperty -InputObject $healthObj -Name 'bind')))

            # A session mismatch still passes every HTTP check but puts any launched window in
            # the agent's session, not this one. Say so loudly rather than leaving it implicit.
            $probeSession = Get-MacdowsProbeSessionId
            $agentSession = Get-MacdowsProbeProperty -InputObject $healthObj -Name 'sessionId'
            Add-Line (Format-MacdowsProbeInfo -Text ("probe session={0}, agent session={1}" -f $probeSession, $agentSession))
            if ($null -ne $probeSession -and $null -ne $agentSession -and [string]$probeSession -ne [string]$agentSession) {
                Add-Line (Format-MacdowsProbeInfo -Text 'WARNING: agent is in a different session - a launched window will appear there, not here')
            }
        } else {
            Add-Line (Format-MacdowsProbeInfo -Text "health: unreachable (HTTP $($health.Status))")
        }

        # -- capability 1: published apps + icon ------------------------------------------
        $appsObj = $null
        $apps = Invoke-MacdowsProbeRequest -Uri "$base/v1/apps" -Token $token
        if (-not $apps.Ok) {
            Add-Result -Ok $false -Capability 'apps+icon' -Detail "GET /v1/apps (HTTP $($apps.Status))"
        } else {
            Save-MacdowsProbeText -Path (Join-Path $OutDir 'apps.json') -Text $apps.Content
            $appsObj = ConvertFrom-Json $apps.Content
            $published = @(Get-MacdowsProbeEntryList -Value (Get-MacdowsProbeProperty -InputObject $appsObj -Name 'published'))
            $allowed = @(Get-MacdowsProbeEntryList -Value (Get-MacdowsProbeProperty -InputObject $appsObj -Name 'agentAllowlist'))
            Add-Line (Format-MacdowsProbeInfo -Text ("tsAllowListDisabled={0}  published={1}  agentAllowlist={2}" -f `
                (Get-MacdowsProbeProperty -InputObject $appsObj -Name 'tsAllowListDisabled'), $published.Count, $allowed.Count))
            foreach ($entry in $allowed) {
                Add-Line (Format-MacdowsProbeInfo -Text ("allowlist: {0} inTsAllowList={1}" -f `
                    (Get-MacdowsProbeProperty -InputObject $entry -Name 'id'),
                    (Get-MacdowsProbeProperty -InputObject $entry -Name 'inTsAllowList')))
            }

            $icon = Select-MacdowsProbeIcon -Apps $appsObj
            if ($null -eq $icon) {
                Add-Result -Ok $false -Capability 'apps+icon' -Detail 'GET /v1/apps (no entry carried an iconPng)'
            } else {
                $bytes = $null
                try {
                    $bytes = [Convert]::FromBase64String($icon.Base64)
                } catch {
                    $bytes = $null
                }
                if ($null -eq $bytes) {
                    Add-Result -Ok $false -Capability 'apps+icon' -Detail 'GET /v1/apps (iconPng is not valid base64)'
                } elseif (-not (Test-MacdowsProbePngMagic -Bytes $bytes)) {
                    Add-Result -Ok $false -Capability 'apps+icon' -Detail 'GET /v1/apps (decoded icon is not a PNG)'
                } else {
                    $iconPath = Join-Path $OutDir 'icon-0.png'
                    [System.IO.File]::WriteAllBytes($iconPath, $bytes)
                    Add-Line (Format-MacdowsProbeInfo -Text ("first icon from '{0}' -> icon-0.png ({1} bytes)" -f $icon.Source, $bytes.Length))
                    Add-Result -Ok $true -Capability 'apps+icon' -Detail 'GET /v1/apps'
                }
            }
        }

        # -- capability 2: proxied launch --------------------------------------------------
        $targetId = $LaunchId
        if ([string]::IsNullOrWhiteSpace($targetId)) {
            $targetId = Select-MacdowsProbeLaunchId -Apps $appsObj
        }
        if ([string]::IsNullOrWhiteSpace($targetId)) {
            Add-Result -Ok $false -Capability 'launch' -Detail 'POST /v1/launch (no allowlist entry outside TSAppAllowList; pass -LaunchId)'
        } else {
            $payload = ConvertTo-Json -InputObject @{ id = $targetId } -Compress
            $launch = Invoke-MacdowsProbeRequest -Uri "$base/v1/launch" -Token $token -Method 'POST' -Body $payload
            if (-not $launch.Ok) {
                Add-Result -Ok $false -Capability 'launch' -Detail "POST /v1/launch (id=$targetId, HTTP $($launch.Status))"
            } else {
                Save-MacdowsProbeText -Path (Join-Path $OutDir 'launch.json') -Text $launch.Content
                $launchObj = ConvertFrom-Json $launch.Content
                $newPid = Get-MacdowsProbeProperty -InputObject $launchObj -Name 'pid'
                $gotId = [string](Get-MacdowsProbeProperty -InputObject $launchObj -Name 'id')
                if ($gotId -ne $targetId) {
                    Add-Result -Ok $false -Capability 'launch' -Detail "POST /v1/launch (agent answered for id '$gotId')"
                } elseif ($null -eq $newPid -or [int]$newPid -le 0) {
                    Add-Result -Ok $false -Capability 'launch' -Detail "POST /v1/launch (id=$targetId, no usable pid)"
                } else {
                    Add-Line (Format-MacdowsProbeInfo -Text ("launched id={0} pid={1} path={2}" -f $gotId, $newPid,
                        (Get-MacdowsProbeProperty -InputObject $launchObj -Name 'path')))
                    Add-Result -Ok $true -Capability 'launch' -Detail "POST /v1/launch (id=$targetId)"
                }
            }
        }

        # -- capability 3: file association ------------------------------------------------
        $assoc = Invoke-MacdowsProbeRequest -Uri "$base/v1/assoc?ext=.pdf" -Token $token
        if (-not $assoc.Ok) {
            Add-Result -Ok $false -Capability 'assoc' -Detail "GET /v1/assoc?ext=.pdf (HTTP $($assoc.Status))"
        } else {
            Save-MacdowsProbeText -Path (Join-Path $OutDir 'assoc.json') -Text $assoc.Content
            $assocObj = ConvertFrom-Json $assoc.Content
            $exe = Get-MacdowsProbeProperty -InputObject $assocObj -Name 'executable'
            $cmd = Get-MacdowsProbeProperty -InputObject $assocObj -Name 'command'
            Add-Line (Format-MacdowsProbeInfo -Text ("assoc source={0} executable={1}" -f `
                (Get-MacdowsProbeProperty -InputObject $assocObj -Name 'source'), $exe))
            if ([string]::IsNullOrWhiteSpace([string]$exe) -and [string]::IsNullOrWhiteSpace([string]$cmd)) {
                Add-Result -Ok $false -Capability 'assoc' -Detail 'GET /v1/assoc?ext=.pdf (no executable and no command)'
            } else {
                Add-Result -Ok $true -Capability 'assoc' -Detail 'GET /v1/assoc?ext=.pdf'
            }
        }
    } catch {
        Add-Line (Format-MacdowsProbeInfo -Text "probe aborted: $($_.Exception.Message)")
        $script:MacdowsProbeFailureCount++
    } finally {
        $failures = $script:MacdowsProbeFailureCount

        # result.txt and the DONE marker are written even when the run fell over, so the Mac
        # side can distinguish "finished and failed" from "never finished".
        try {
            Save-MacdowsProbeText -Path (Join-Path $OutDir 'result.txt') -Text (($lines -join "`r`n") + "`r`n")
        } catch {
            Write-Host (Format-MacdowsProbeInfo -Text "could not write result.txt: $($_.Exception.Message)")
        }
        try {
            $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            Save-MacdowsProbeText -Path (Join-Path $OutDir 'DONE') -Text ("probe finished {0} failures={1}`r`n" -f $stamp, $failures)
        } catch {
            Write-Host (Format-MacdowsProbeInfo -Text "could not write DONE marker: $($_.Exception.Message)")
        }
    }

    return $failures
}

# ---------------------------------------------------------------------------------------------
# Entry point (skipped when dot-sourced or when -NoRun is passed)
# ---------------------------------------------------------------------------------------------

if (-not $NoRun -and $MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($TokenPath)) {
        $TokenPath = Get-MacdowsProbeDefaultTokenPath
    }
    $failed = Invoke-MacdowsProbe -OutDir $OutDir -Port $Port -TokenPath $TokenPath -LaunchId $LaunchId
    Write-Host ''
    if ($failed -gt 0) {
        Write-Host "$failed capability check(s) failed. Artifacts in $OutDir"
        exit 1
    }
    Write-Host "all capability checks passed. Artifacts in $OutDir"
    exit 0
}
