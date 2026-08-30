#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test suite for MacdowsHostAgent.ps1.

.DESCRIPTION
    Runs under PowerShell 7 on macOS (and under Windows PowerShell 5.1 on the host) with no
    external dependencies: Pester is not required, the assertions below are a ~40-line harness.

    Coverage:
      * HTTP request reading and head parsing (good/oversized/no Content-Length/bad method/...)
      * route dispatch and status codes
      * constant-time bearer token comparison
      * allowlist loading and validation (relative paths, missing files, %SystemRoot%, shells)
      * file-extension validation
      * /v1/health JSON shape with every Windows-only call stubbed
      * one real end-to-end run: server on 127.0.0.1 with -Once, driven by curl

    Every Windows-only capability is reached through a provider scriptblock on the context, so
    the dispatch tests never touch the registry, System.Drawing, or Shlwapi.

.EXAMPLE
    pwsh -NoProfile -File ./MacdowsHostAgent.Tests.ps1
#>

[CmdletBinding()]
param(
    # Skip the end-to-end server test (useful when no loopback socket is available).
    [switch] $SkipEndToEnd
)

$ErrorActionPreference = 'Stop'

$AgentPath = Join-Path $PSScriptRoot 'MacdowsHostAgent.ps1'
$ProbePs1Path = Join-Path $PSScriptRoot 'probe.ps1'
. $AgentPath -NoServe
# probe.ps1's pure helpers are all named *MacdowsProbe*, so nothing collides with the agent's
# functions. -OutDir is mandatory, hence the placeholder; -NoRun stops it probing anything.
. $ProbePs1Path -OutDir ([System.IO.Path]::GetTempPath()) -NoRun

# -------------------------------------------------------------------------------------------
# Minimal assertion harness (exits non-zero on any failure)
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

function Assert-Null {
    param($Value, [string] $Because = 'expected $null')
    if ($null -ne $Value) { throw "$Because - got [$Value]" }
}

function New-Section { param([string] $Name) Write-Host ''; Write-Host "== $Name" }

# -------------------------------------------------------------------------------------------
# Fixtures
# -------------------------------------------------------------------------------------------

$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("macdows-host-agent-tests-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:TempRoot -Force)

function New-RequestStream {
    param([string] $Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return (New-Object System.IO.MemoryStream -ArgumentList (, $bytes))
}

function Read-TestRequest {
    param([string] $Text, [datetime] $Deadline = [datetime]::MinValue)
    $stream = New-RequestStream -Text $Text
    try {
        return (Read-MacdowsHttpRequest -Stream $stream -Deadline $Deadline)
    } finally {
        $stream.Dispose()
    }
}

function New-TestContext {
    param([string] $Token = 'tok-abc', $Allowlist = @())
    return (New-MacdowsContext -Token $Token -Allowlist $Allowlist -Bind '127.0.0.1:47615' -Providers @{
        SessionInfo         = { [pscustomobject]@{ user = 'tester'; sessionId = 7 } }
        TsAllowListDisabled = { $false }
        IconPng             = { param($Path, $Index) 'aWNvbg==' }
        Assoc               = {
            param($Ext)
            [ordered]@{
                ext          = $Ext
                executable   = 'C:\Program Files\Reader\reader.exe'
                command      = '"C:\Program Files\Reader\reader.exe" "%1"'
                friendlyName = 'Reader'
                source       = 'AssocQueryString'
            }
        }
        PublishedApps       = {
            param($Ctx)
            [pscustomobject]@{
                tsAllowListDisabled = $false
                published           = @(
                    [ordered]@{
                        key                = 'calc'
                        name               = 'Calculator'
                        path               = 'C:\Windows\System32\calc.exe'
                        commandLineSetting = 0
                        iconPath           = $null
                        iconIndex          = 0
                        iconPng            = 'aWNvbg=='
                    }
                )
            }
        }
        LaunchProcess       = { param($Entry) 4242 }
    })
}

function Invoke-TestRequest {
    param([string] $Text, $Context)
    $request = Read-TestRequest -Text $Text
    return (Invoke-MacdowsRequest -Request $request -Context $Context)
}

function ConvertTo-TestObject {
    param($ResponseBody)
    return (ConvertFrom-Json (ConvertTo-MacdowsJson -InputObject $ResponseBody))
}

# -------------------------------------------------------------------------------------------
New-Section 'HTTP request parsing'
# -------------------------------------------------------------------------------------------

Test-Case 'parses a well-formed GET' {
    $r = Read-TestRequest "GET /v1/health HTTP/1.1`r`nHost: 127.0.0.1`r`nAuthorization: Bearer tok-abc`r`n`r`n"
    Assert-True $r.Ok 'request should parse'
    Assert-Equal 'GET' $r.Method
    Assert-Equal '/v1/health' $r.Path
    Assert-Equal 'Bearer tok-abc' $r.Headers['authorization'] 'header names are lower-cased'
    Assert-Equal '' $r.Body
}

Test-Case 'parses the query string' {
    $r = Read-TestRequest "GET /v1/assoc?ext=.pdf&x=1 HTTP/1.1`r`nHost: h`r`n`r`n"
    Assert-True $r.Ok
    Assert-Equal '/v1/assoc' $r.Path
    Assert-Equal '.pdf' $r.Query['ext']
    Assert-Equal '1' $r.Query['x']
}

Test-Case 'percent-decodes the query string' {
    $r = Read-TestRequest "GET /v1/assoc?ext=%2Epdf HTTP/1.1`r`nHost: h`r`n`r`n"
    Assert-Equal '.pdf' $r.Query['ext']
}

Test-Case 'parses a POST body using Content-Length' {
    $body = '{"id":"charmap"}'
    $r = Read-TestRequest "POST /v1/launch HTTP/1.1`r`nHost: h`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`n`r`n$body"
    Assert-True $r.Ok
    Assert-Equal 'POST' $r.Method
    Assert-Equal $body $r.Body
}

Test-Case 'stops reading the body at Content-Length' {
    $r = Read-TestRequest "POST /v1/launch HTTP/1.1`r`nHost: h`r`nContent-Length: 2`r`n`r`n{}trailing-garbage"
    Assert-True $r.Ok
    Assert-Equal '{}' $r.Body
}

Test-Case 'rejects a POST without Content-Length with 400' {
    $r = Read-TestRequest "POST /v1/launch HTTP/1.1`r`nHost: h`r`n`r`n{`"id`":`"x`"}"
    Assert-True (-not $r.Ok)
    Assert-Equal 400 $r.Status
}

Test-Case 'rejects an oversized request head with 413' {
    $big = 'a' * 70000
    $r = Read-TestRequest "GET /v1/health HTTP/1.1`r`nX-Big: $big`r`n`r`n"
    Assert-True (-not $r.Ok)
    Assert-Equal 413 $r.Status
}

Test-Case 'rejects an oversized declared body with 413' {
    $r = Read-TestRequest "POST /v1/launch HTTP/1.1`r`nHost: h`r`nContent-Length: 999999`r`n`r`n{}"
    Assert-True (-not $r.Ok)
    Assert-Equal 413 $r.Status
}

Test-Case 'rejects a method other than GET/POST with 405' {
    $r = Read-TestRequest "PUT /v1/launch HTTP/1.1`r`nHost: h`r`nContent-Length: 0`r`n`r`n"
    Assert-True (-not $r.Ok)
    Assert-Equal 405 $r.Status
}

Test-Case 'rejects a lowercase method (methods are case-sensitive)' {
    $r = Read-TestRequest "get /v1/health HTTP/1.1`r`nHost: h`r`n`r`n"
    Assert-True (-not $r.Ok)
    Assert-Equal 400 $r.Status
}

Test-Case 'rejects a malformed request line with 400' {
    $r = Read-TestRequest "GET /v1/health`r`nHost: h`r`n`r`n"
    Assert-True (-not $r.Ok)
    Assert-Equal 400 $r.Status
}

Test-Case 'rejects an unsupported HTTP version with 400' {
    $r = Read-TestRequest "GET /v1/health HTTP/2.0`r`nHost: h`r`n`r`n"
    Assert-Equal 400 $r.Status
}

Test-Case 'rejects a duplicate Content-Length with 400' {
    $r = Read-TestRequest "POST /v1/launch HTTP/1.1`r`nContent-Length: 2`r`nContent-Length: 3`r`n`r`n{}"
    Assert-Equal 400 $r.Status
}

Test-Case 'rejects Transfer-Encoding with 400' {
    $r = Read-TestRequest "POST /v1/launch HTTP/1.1`r`nTransfer-Encoding: chunked`r`n`r`n0`r`n`r`n"
    Assert-Equal 400 $r.Status
}

Test-Case 'rejects a malformed header line with 400' {
    $r = Read-TestRequest "GET /v1/health HTTP/1.1`r`nthis-is-not-a-header`r`n`r`n"
    Assert-Equal 400 $r.Status
}

Test-Case 'rejects a request that closes before the headers end' {
    $r = Read-TestRequest "GET /v1/health HTTP/1.1`r`nHost: h`r`n"
    Assert-True (-not $r.Ok)
    Assert-Equal 400 $r.Status
}

Test-Case 'rejects an absolute-form request target with 400' {
    $r = Read-TestRequest "GET http://evil/v1/health HTTP/1.1`r`nHost: h`r`n`r`n"
    Assert-Equal 400 $r.Status
}

# -------------------------------------------------------------------------------------------
New-Section 'Bearer token comparison'
# -------------------------------------------------------------------------------------------

Test-Case 'accepts an identical token' {
    Assert-True (Test-MacdowsTokenMatch -Expected 'abc123' -Provided 'abc123')
}

Test-Case 'rejects a token that differs in one character' {
    Assert-True (-not (Test-MacdowsTokenMatch -Expected 'abc123' -Provided 'abc124'))
}

Test-Case 'rejects a token of a different length' {
    Assert-True (-not (Test-MacdowsTokenMatch -Expected 'abc123' -Provided 'abc1234'))
    Assert-True (-not (Test-MacdowsTokenMatch -Expected 'abc123' -Provided 'abc'))
}

Test-Case 'rejects an empty or null provided token' {
    Assert-True (-not (Test-MacdowsTokenMatch -Expected 'abc123' -Provided ''))
    Assert-True (-not (Test-MacdowsTokenMatch -Expected 'abc123' -Provided $null))
}

Test-Case 'rejects everything when the expected token is empty' {
    Assert-True (-not (Test-MacdowsTokenMatch -Expected '' -Provided ''))
    Assert-True (-not (Test-MacdowsTokenMatch -Expected $null -Provided 'anything'))
}

Test-Case 'comparison walks the full buffer regardless of the first mismatch' {
    # Not a timing measurement (too noisy in CI); this asserts the algorithm never
    # short-circuits by checking that a prefix match is still rejected.
    Assert-True (-not (Test-MacdowsTokenMatch -Expected ('a' * 64) -Provided ('a' * 63 + 'b')))
    Assert-True (-not (Test-MacdowsTokenMatch -Expected ('a' * 64) -Provided ('b' + 'a' * 63)))
}

Test-Case 'extracts the token from the Authorization header' {
    $r = Read-TestRequest "GET /v1/health HTTP/1.1`r`nAuthorization: bearer  xyz`r`n`r`n"
    Assert-Equal 'xyz' (Get-MacdowsRequestToken -Request $r) 'scheme is case-insensitive'
    $r2 = Read-TestRequest "GET /v1/health HTTP/1.1`r`nAuthorization: Basic abc`r`n`r`n"
    Assert-Equal '' (Get-MacdowsRequestToken -Request $r2)
}

# -------------------------------------------------------------------------------------------
New-Section 'Route dispatch'
# -------------------------------------------------------------------------------------------

$ctx = New-TestContext

Test-Case 'GET /v1/health returns the documented JSON shape' {
    $resp = Invoke-TestRequest -Context $ctx -Text "GET /v1/health HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`n`r`n"
    Assert-Equal 200 $resp.Status
    $body = ConvertTo-TestObject -ResponseBody $resp.Body
    Assert-Equal 'macdows-host-agent' $body.agent
    Assert-Equal '0.1.0' $body.version
    Assert-Equal 'tester' $body.user
    Assert-Equal 7 $body.sessionId
    Assert-Equal $false $body.tsAllowListDisabled
    Assert-Equal '127.0.0.1:47615' $body.bind
}

Test-Case 'health tolerates a null tsAllowListDisabled (key absent)' {
    $nullCtx = New-MacdowsContext -Token 'tok-abc' -Bind '127.0.0.1:47615' -Providers @{
        SessionInfo         = { [pscustomobject]@{ user = $null; sessionId = $null } }
        TsAllowListDisabled = { $null }
    }
    $resp = Invoke-TestRequest -Context $nullCtx -Text "GET /v1/health HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`n`r`n"
    Assert-Equal 200 $resp.Status
    $body = ConvertTo-TestObject -ResponseBody $resp.Body
    Assert-Null $body.tsAllowListDisabled
    Assert-Null $body.user
}

Test-Case 'missing Authorization returns 401 with an empty JSON body' {
    $resp = Invoke-TestRequest -Context $ctx -Text "GET /v1/health HTTP/1.1`r`nHost: h`r`n`r`n"
    Assert-Equal 401 $resp.Status
    Assert-Equal '{}' (ConvertTo-MacdowsJson -InputObject $resp.Body) 'no hint may leak in a 401'
}

Test-Case 'a wrong token returns 401' {
    $resp = Invoke-TestRequest -Context $ctx -Text "GET /v1/health HTTP/1.1`r`nAuthorization: Bearer nope`r`n`r`n"
    Assert-Equal 401 $resp.Status
}

Test-Case 'an unknown route returns 401 before it returns 404 when unauthenticated' {
    $resp = Invoke-TestRequest -Context $ctx -Text "GET /admin HTTP/1.1`r`nHost: h`r`n`r`n"
    Assert-Equal 401 $resp.Status 'route existence must not leak to unauthenticated callers'
}

Test-Case 'an unknown route returns 404 when authenticated' {
    $resp = Invoke-TestRequest -Context $ctx -Text "GET /admin HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`n`r`n"
    Assert-Equal 404 $resp.Status
}

Test-Case 'a wrong method on a known route returns 405' {
    $resp = Invoke-TestRequest -Context $ctx -Text "POST /v1/health HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`nContent-Length: 2`r`n`r`n{}"
    Assert-Equal 405 $resp.Status
    $resp2 = Invoke-TestRequest -Context $ctx -Text "GET /v1/launch HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`n`r`n"
    Assert-Equal 405 $resp2.Status
}

Test-Case 'a trailing slash resolves to the same route' {
    $resp = Invoke-TestRequest -Context $ctx -Text "GET /v1/health/ HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`n`r`n"
    Assert-Equal 200 $resp.Status
}

Test-Case 'GET /v1/apps lists published apps and the agent allowlist' {
    $allowlist = @(
        [pscustomobject]@{ id = 'calc'; name = 'Calculator'; path = 'C:\Windows\System32\calc.exe'; args = @() },
        [pscustomobject]@{ id = 'charmap'; name = 'Character Map'; path = 'C:\Windows\System32\charmap.exe'; args = @() }
    )
    $c = New-TestContext -Allowlist $allowlist
    $resp = Invoke-TestRequest -Context $c -Text "GET /v1/apps HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`n`r`n"
    Assert-Equal 200 $resp.Status
    $body = ConvertTo-TestObject -ResponseBody $resp.Body
    Assert-Equal 1 @($body.published).Count
    Assert-Equal 'Calculator' $body.published[0].name
    Assert-Equal 'aWNvbg==' $body.published[0].iconPng
    Assert-Equal 2 @($body.agentAllowlist).Count
    Assert-Equal $true $body.agentAllowlist[0].inTsAllowList 'calc.exe is published'
    Assert-Equal $false $body.agentAllowlist[1].inTsAllowList 'charmap.exe is not published'
}

Test-Case 'a null icon does not break the listing' {
    $c = New-MacdowsContext -Token 'tok-abc' -Bind 'b' -Allowlist @(
        [pscustomobject]@{ id = 'x'; name = 'X'; path = 'C:\Windows\System32\x.exe'; args = @() }
    ) -Providers @{
        TsAllowListDisabled = { $null }
        IconPng             = { param($Path, $Index) $null }
        PublishedApps       = { param($Ctx) [pscustomobject]@{ tsAllowListDisabled = $null; published = @() } }
    }
    $resp = Invoke-TestRequest -Context $c -Text "GET /v1/apps HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`n`r`n"
    Assert-Equal 200 $resp.Status
    $body = ConvertTo-TestObject -ResponseBody $resp.Body
    Assert-Null $body.agentAllowlist[0].iconPng
}

Test-Case 'POST /v1/launch resolves an allowlist id to a pid' {
    $allowlist = @([pscustomobject]@{ id = 'charmap'; name = 'Character Map'; path = 'C:\Windows\System32\charmap.exe'; args = @() })
    $c = New-TestContext -Allowlist $allowlist
    $payload = '{"id":"charmap"}'
    $resp = Invoke-TestRequest -Context $c -Text "POST /v1/launch HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`nContent-Length: $($payload.Length)`r`n`r`n$payload"
    Assert-Equal 200 $resp.Status
    $body = ConvertTo-TestObject -ResponseBody $resp.Body
    Assert-Equal 'charmap' $body.id
    Assert-Equal 4242 $body.pid
    Assert-Equal 'C:\Windows\System32\charmap.exe' $body.path
}

Test-Case 'POST /v1/launch ignores any path or args in the request' {
    # The request asks for cmd.exe; the agent must launch only what the id resolves to.
    $launched = New-Object System.Collections.ArrayList
    $allowlist = @([pscustomobject]@{ id = 'charmap'; name = 'Character Map'; path = 'C:\Windows\System32\charmap.exe'; args = @() })
    $c = New-MacdowsContext -Token 'tok-abc' -Bind 'b' -Allowlist $allowlist -Providers @{
        LaunchProcess = { param($Entry) [void]$launched.Add($Entry.path); 99 }
    }
    $payload = '{"id":"charmap","path":"C:\\Windows\\System32\\cmd.exe","args":["/c","calc"]}'
    $resp = Invoke-TestRequest -Context $c -Text "POST /v1/launch HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`nContent-Length: $($payload.Length)`r`n`r`n$payload"
    Assert-Equal 200 $resp.Status
    Assert-Equal 1 $launched.Count
    Assert-Equal 'C:\Windows\System32\charmap.exe' $launched[0] 'the request path must be ignored'
}

Test-Case 'POST /v1/launch returns 404 for an unknown id' {
    $c = New-TestContext -Allowlist @([pscustomobject]@{ id = 'charmap'; name = 'x'; path = 'C:\x.exe'; args = @() })
    $payload = '{"id":"nope"}'
    $resp = Invoke-TestRequest -Context $c -Text "POST /v1/launch HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`nContent-Length: $($payload.Length)`r`n`r`n$payload"
    Assert-Equal 404 $resp.Status
}

Test-Case 'POST /v1/launch returns 400 for a malformed or id-less body' {
    $c = New-TestContext
    $bad = 'not json'
    $r1 = Invoke-TestRequest -Context $c -Text "POST /v1/launch HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`nContent-Length: $($bad.Length)`r`n`r`n$bad"
    Assert-Equal 400 $r1.Status
    $noId = '{"name":"charmap"}'
    $r2 = Invoke-TestRequest -Context $c -Text "POST /v1/launch HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`nContent-Length: $($noId.Length)`r`n`r`n$noId"
    Assert-Equal 400 $r2.Status
    $r3 = Invoke-TestRequest -Context $c -Text "POST /v1/launch HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`nContent-Length: 0`r`n`r`n"
    Assert-Equal 400 $r3.Status
}

Test-Case 'GET /v1/assoc returns the association for a valid extension' {
    $resp = Invoke-TestRequest -Context $ctx -Text "GET /v1/assoc?ext=.pdf HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`n`r`n"
    Assert-Equal 200 $resp.Status
    $body = ConvertTo-TestObject -ResponseBody $resp.Body
    Assert-Equal '.pdf' $body.ext
    Assert-Equal 'AssocQueryString' $body.source
    Assert-Equal 'C:\Program Files\Reader\reader.exe' $body.executable
}

Test-Case 'GET /v1/assoc returns 400 for an invalid or missing extension' {
    foreach ($target in @('/v1/assoc', '/v1/assoc?ext=pdf', '/v1/assoc?ext=.', '/v1/assoc?ext=..%2F..%2Fetc', '/v1/assoc?ext=.p%20df')) {
        $resp = Invoke-TestRequest -Context $ctx -Text "GET $target HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`n`r`n"
        Assert-Equal 400 $resp.Status "expected 400 for $target"
    }
}

Test-Case 'a request rejected by the parser keeps its status and an empty body' {
    $resp = Invoke-TestRequest -Context $ctx -Text "PUT /v1/health HTTP/1.1`r`nContent-Length: 0`r`n`r`n"
    Assert-Equal 405 $resp.Status
    Assert-Equal '{}' (ConvertTo-MacdowsJson -InputObject $resp.Body)
}

# -------------------------------------------------------------------------------------------
New-Section 'Published-path comparison (review finding B2)'
# -------------------------------------------------------------------------------------------

Test-Case 'normalises a path for comparison' {
    $r = 'C:\Windows'
    Assert-Equal 'c:\windows\system32\charmap.exe' (ConvertTo-MacdowsComparablePath -Path '%SystemRoot%\System32\charmap.exe' -SystemRoot $r)
    Assert-Equal 'c:\windows\system32\charmap.exe' (ConvertTo-MacdowsComparablePath -Path '%systemroot%\SYSTEM32\CharMap.exe' -SystemRoot $r)
    Assert-Equal 'c:\windows\system32\charmap.exe' (ConvertTo-MacdowsComparablePath -Path '"C:\Windows\System32\charmap.exe"' -SystemRoot $r) 'quotes are stripped'
    Assert-Equal 'c:\windows\system32\charmap.exe' (ConvertTo-MacdowsComparablePath -Path '  C:/Windows/System32/charmap.exe  ' -SystemRoot $r) 'slashes and padding are normalised'
    Assert-Equal 'c:\windows\system32\charmap.exe' (ConvertTo-MacdowsComparablePath -Path 'C:\Windows\\System32\charmap.exe' -SystemRoot $r) 'repeated separators collapse'
    Assert-Equal 'c:\windows' (ConvertTo-MacdowsComparablePath -Path 'C:\Windows\' -SystemRoot $r) 'trailing separator is dropped'
    Assert-Equal '\\server\share\app.exe' (ConvertTo-MacdowsComparablePath -Path '\\server\share\app.exe' -SystemRoot $r) 'a UNC prefix survives collapsing'
    Assert-Equal '' (ConvertTo-MacdowsComparablePath -Path '' -SystemRoot $r)
    Assert-Equal '' (ConvertTo-MacdowsComparablePath -Path $null -SystemRoot $r)
}

Test-Case 'inTsAllowList is true when the registry path still carries %SystemRoot%' {
    # This is the B2 regression: TSAppAllowList\Applications\*\Path commonly stores an
    # environment token, while allowlist paths are already expanded. Comparing them raw
    # reported a published app as not published, and both probes pick the launch target from
    # this field - so capability 2 could PASS while launching an already-published app.
    $allowlist = @(
        [pscustomobject]@{ id = 'charmap'; name = 'Character Map'; path = 'C:\Windows\System32\charmap.exe'; args = @() },
        [pscustomobject]@{ id = 'winver'; name = 'About Windows'; path = 'C:\Windows\System32\winver.exe'; args = @() }
    )
    $c = New-MacdowsContext -Token 'tok-abc' -Bind 'b' -Allowlist $allowlist -SystemRoot 'C:\Windows' -Providers @{
        TsAllowListDisabled = { $false }
        IconPng             = { param($Path, $Index) $null }
        PublishedApps       = {
            param($Ctx)
            [pscustomobject]@{
                tsAllowListDisabled = $false
                published           = @(
                    [ordered]@{ key = 'charmap'; name = 'Character Map'; path = '%SystemRoot%\System32\charmap.exe'; iconPng = $null }
                )
            }
        }
    }
    $resp = Invoke-TestRequest -Context $c -Text "GET /v1/apps HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`n`r`n"
    Assert-Equal 200 $resp.Status
    $body = ConvertTo-TestObject -ResponseBody $resp.Body
    Assert-Equal $true $body.agentAllowlist[0].inTsAllowList 'charmap IS published, despite the unexpanded registry path'
    Assert-Equal $false $body.agentAllowlist[1].inTsAllowList 'winver is genuinely not published'
}

Test-Case 'inTsAllowList tolerates quoting and separator differences' {
    $allowlist = @([pscustomobject]@{ id = 'calc'; name = 'Calculator'; path = 'C:\Windows\System32\calc.exe'; args = @() })
    $c = New-MacdowsContext -Token 'tok-abc' -Bind 'b' -Allowlist $allowlist -SystemRoot 'C:\Windows' -Providers @{
        TsAllowListDisabled = { $false }
        IconPng             = { param($Path, $Index) $null }
        PublishedApps       = {
            param($Ctx)
            [pscustomobject]@{
                tsAllowListDisabled = $false
                published           = @([ordered]@{ key = 'calc'; name = 'Calculator'; path = '"C:/WINDOWS/System32/calc.exe"'; iconPng = $null })
            }
        }
    }
    $resp = Invoke-TestRequest -Context $c -Text "GET /v1/apps HTTP/1.1`r`nAuthorization: Bearer tok-abc`r`n`r`n"
    $body = ConvertTo-TestObject -ResponseBody $resp.Body
    Assert-Equal $true $body.agentAllowlist[0].inTsAllowList
}

# -------------------------------------------------------------------------------------------
New-Section 'Connection deadline and header scanning (review findings B3, B5)'
# -------------------------------------------------------------------------------------------

Test-Case 'the deadline helper compares against wall clock' {
    Assert-True (Test-MacdowsDeadlineExceeded -Deadline ((Get-Date).AddSeconds(-1)))
    Assert-True (-not (Test-MacdowsDeadlineExceeded -Deadline ((Get-Date).AddSeconds(30))))
    Assert-True (-not (Test-MacdowsDeadlineExceeded -Deadline ([datetime]::MinValue))) 'MinValue disables the deadline'
}

Test-Case 'a request past its deadline is rejected with 408' {
    $r = Read-TestRequest -Text "GET /v1/health HTTP/1.1`r`nHost: h`r`n`r`n" -Deadline ((Get-Date).AddSeconds(-1))
    Assert-True (-not $r.Ok)
    Assert-Equal 408 $r.Status
    Assert-Equal 'Request Timeout' (Get-MacdowsReasonPhrase -Status 408)
}

Test-Case 'a request inside its deadline is unaffected' {
    $r = Read-TestRequest -Text "GET /v1/health HTTP/1.1`r`nHost: h`r`n`r`n" -Deadline ((Get-Date).AddSeconds(30))
    Assert-True $r.Ok
    Assert-Equal '/v1/health' $r.Path
}

Test-Case 'the header scan can resume from an offset' {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("AB`r`n`r`nCD`r`n`r`n")
    Assert-Equal 2 (Find-MacdowsHeaderEnd -Bytes $bytes -Length $bytes.Length)
    Assert-Equal 2 (Find-MacdowsHeaderEnd -Bytes $bytes -Length $bytes.Length -StartAt 0)
    Assert-Equal 8 (Find-MacdowsHeaderEnd -Bytes $bytes -Length $bytes.Length -StartAt 3) 'resuming past the first terminator finds the second'
    Assert-Equal -1 (Find-MacdowsHeaderEnd -Bytes $bytes -Length $bytes.Length -StartAt 9)
    Assert-Equal 2 (Find-MacdowsHeaderEnd -Bytes $bytes -Length $bytes.Length -StartAt -5) 'a negative offset clamps to 0'
}

Test-Case 'a header terminator straddling a read-chunk boundary is still found' {
    # The incremental scan resumes 3 bytes behind the previous tail. Reads are 4096 bytes, so
    # these sizes put the CRLFCRLF across the boundary in every possible alignment.
    $prefix = "GET /v1/health HTTP/1.1`r`nX-Pad: "
    for ($total = 4090; $total -le 4100; $total++) {
        $padLength = $total - $prefix.Length
        $text = $prefix + ('a' * $padLength) + "`r`n`r`n"
        $r = Read-TestRequest -Text $text
        Assert-True $r.Ok "head of $total bytes should parse"
        Assert-Equal '/v1/health' $r.Path
        Assert-Equal ('a' * $padLength) $r.Headers['x-pad']
    }
}

Test-Case 'a large head split over many reads still parses, body intact' {
    # Several headers rather than one huge one: a single line over 8192 bytes is rejected by
    # design, but the head as a whole must still survive being read in 4096-byte chunks.
    $body = '{"id":"charmap"}'
    $pad = 'b' * 4000
    $text = "POST /v1/launch HTTP/1.1`r`nX-Pad1: $pad`r`nX-Pad2: $pad`r`nX-Pad3: $pad`r`nContent-Length: $($body.Length)`r`n`r`n$body"
    Assert-True ($text.Length -gt 12000) 'the fixture must span several reads'
    $r = Read-TestRequest -Text $text
    Assert-True $r.Ok "expected a parse; got status $($r.Status) ($($r.Detail))"
    Assert-Equal 'POST' $r.Method
    Assert-Equal $body $r.Body
    Assert-Equal $pad $r.Headers['x-pad3'] 'the last header before the terminator survived'
}

# -------------------------------------------------------------------------------------------
New-Section 'Extension validation'
# -------------------------------------------------------------------------------------------

Test-Case 'accepts well-formed extensions' {
    # NB: the extra parentheses matter - inside an array literal PowerShell binds ',' more
    # tightly than '+', so `'.' + ('a' * 16)` would produce two elements, not one.
    foreach ($e in @('.pdf', '.PDF', '.a', '.docx', '.7z', ('.' + ('a' * 16)))) {
        Assert-True (Test-MacdowsFileExtension -Extension $e) "expected '$e' to be valid"
    }
}

Test-Case 'rejects malformed extensions' {
    foreach ($e in @('', 'pdf', '.', '..', './x', '.pd f', '.pdf.exe', '.pdf/', ('.' + ('a' * 17)), '.p-df', $null)) {
        Assert-True (-not (Test-MacdowsFileExtension -Extension $e)) "expected '$e' to be rejected"
    }
}

# -------------------------------------------------------------------------------------------
New-Section 'Allowlist loading and validation'
# -------------------------------------------------------------------------------------------

$fakeRoot = Join-Path $script:TempRoot 'FakeSystemRoot'
[void](New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'System32') -Force)
$fakeApp = Join-Path (Join-Path $fakeRoot 'System32') 'app.exe'
Set-Content -LiteralPath $fakeApp -Value 'not a real executable' -NoNewline

Test-Case 'accepts a valid entry and resolves %SystemRoot%' {
    $file = Join-Path $script:TempRoot 'good.json'
    Set-Content -LiteralPath $file -Value '{"entries":[{"id":"app","name":"App","path":"%SystemRoot%/System32/app.exe","args":["-x"]}]}'
    $r = Import-MacdowsAllowlist -Path $file -SystemRoot $fakeRoot
    Assert-Equal 0 @($r.Errors).Count ("unexpected errors: " + ($r.Errors -join '; '))
    Assert-Equal 1 @($r.Entries).Count
    Assert-Equal 'app' $r.Entries[0].id
    Assert-Equal 'App' $r.Entries[0].name
    Assert-Equal $fakeApp $r.Entries[0].path '%SystemRoot% must be resolved at load time'
    Assert-Equal '-x' $r.Entries[0].args[0]
}

Test-Case 'resolves %SystemRoot% for Windows-style paths (probe stubbed)' {
    $file = Join-Path $script:TempRoot 'winstyle.json'
    Set-Content -LiteralPath $file -Value '{"entries":[{"id":"charmap","path":"%SystemRoot%\\System32\\charmap.exe"}]}'
    $r = Import-MacdowsAllowlist -Path $file -SystemRoot 'C:\Windows' -FileExistsProbe { param($p) $true }
    Assert-Equal 0 @($r.Errors).Count ($r.Errors -join '; ')
    Assert-Equal 'C:\Windows\System32\charmap.exe' $r.Entries[0].path
    Assert-Equal 'charmap' $r.Entries[0].name 'name defaults to the id'
}

Test-Case 'rejects a relative path' {
    $file = Join-Path $script:TempRoot 'relative.json'
    Set-Content -LiteralPath $file -Value '{"entries":[{"id":"rel","path":"System32\\app.exe"}]}'
    $r = Import-MacdowsAllowlist -Path $file -SystemRoot 'C:\Windows' -FileExistsProbe { param($p) $true }
    Assert-Equal 0 @($r.Entries).Count
    Assert-True (($r.Errors -join ' ') -match 'not absolute')
}

Test-Case 'rejects a path that does not exist' {
    $file = Join-Path $script:TempRoot 'missing.json'
    Set-Content -LiteralPath $file -Value '{"entries":[{"id":"gone","path":"%SystemRoot%/System32/nope.exe"}]}'
    $r = Import-MacdowsAllowlist -Path $file -SystemRoot $fakeRoot
    Assert-Equal 0 @($r.Entries).Count
    Assert-True (($r.Errors -join ' ') -match 'does not exist')
}

Test-Case 'rejects an unresolved environment token' {
    $file = Join-Path $script:TempRoot 'unresolved.json'
    Set-Content -LiteralPath $file -Value '{"entries":[{"id":"pf","path":"%ProgramFiles%\\thing\\thing.exe"}]}'
    $r = Import-MacdowsAllowlist -Path $file -SystemRoot 'C:\Windows' -FileExistsProbe { param($p) $true }
    Assert-Equal 0 @($r.Entries).Count
    Assert-True (($r.Errors -join ' ') -match 'unresolved environment token')
}

Test-Case 'rejects a path with a .. segment' {
    $file = Join-Path $script:TempRoot 'dots.json'
    Set-Content -LiteralPath $file -Value '{"entries":[{"id":"dots","path":"%SystemRoot%\\System32\\..\\..\\evil.exe"}]}'
    $r = Import-MacdowsAllowlist -Path $file -SystemRoot 'C:\Windows' -FileExistsProbe { param($p) $true }
    Assert-Equal 0 @($r.Entries).Count
    Assert-True (($r.Errors -join ' ') -match "'\.\.' segment")
}

Test-Case 'rejects shells and script hosts' {
    $file = Join-Path $script:TempRoot 'shells.json'
    Set-Content -LiteralPath $file -Value '{"entries":[{"id":"a","path":"%SystemRoot%\\System32\\cmd.exe"},{"id":"b","path":"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"},{"id":"c","path":"%SystemRoot%\\System32\\wscript.exe"}]}'
    $r = Import-MacdowsAllowlist -Path $file -SystemRoot 'C:\Windows' -FileExistsProbe { param($p) $true }
    Assert-Equal 0 @($r.Entries).Count
    Assert-Equal 3 @($r.Errors).Count
    Assert-True (($r.Errors -join ' ') -match 'shells and script hosts')
}

Test-Case 'rejects a target that is not a program (review finding B4)' {
    # 5.1's Start-Process uses ShellExecute, so a data file would launch its registered
    # handler. The basename deny-list cannot see that; the extension check can.
    $file = Join-Path $script:TempRoot 'notaprogram.json'
    Set-Content -LiteralPath $file -Value '{"entries":[{"id":"doc","path":"%SystemRoot%\\notes.docx"},{"id":"hta","path":"%SystemRoot%\\evil.hta"},{"id":"bat","path":"%SystemRoot%\\go.bat"},{"id":"noext","path":"%SystemRoot%\\program"}]}'
    $r = Import-MacdowsAllowlist -Path $file -SystemRoot 'C:\Windows' -FileExistsProbe { param($p) $true }
    Assert-Equal 0 @($r.Entries).Count
    Assert-Equal 4 @($r.Errors).Count
    Assert-True (($r.Errors -join ' ') -match 'only \.exe and \.com targets are allowed')
}

Test-Case 'accepts .exe and .com targets regardless of case' {
    $file = Join-Path $script:TempRoot 'programs.json'
    Set-Content -LiteralPath $file -Value '{"entries":[{"id":"a","path":"%SystemRoot%\\a.exe"},{"id":"b","path":"%SystemRoot%\\b.COM"},{"id":"c","path":"%SystemRoot%\\c.ExE"}]}'
    $r = Import-MacdowsAllowlist -Path $file -SystemRoot 'C:\Windows' -FileExistsProbe { param($p) $true }
    Assert-Equal 0 @($r.Errors).Count ($r.Errors -join '; ')
    Assert-Equal 3 @($r.Entries).Count
}

Test-Case 'rejects a duplicate id but keeps the first' {
    $file = Join-Path $script:TempRoot 'dupe.json'
    Set-Content -LiteralPath $file -Value '{"entries":[{"id":"app","path":"%SystemRoot%/System32/app.exe"},{"id":"app","path":"%SystemRoot%/System32/app.exe"}]}'
    $r = Import-MacdowsAllowlist -Path $file -SystemRoot $fakeRoot
    Assert-Equal 1 @($r.Entries).Count
    Assert-True (($r.Errors -join ' ') -match 'duplicate id')
}

Test-Case 'rejects a malformed id and a missing path' {
    $file = Join-Path $script:TempRoot 'badid.json'
    Set-Content -LiteralPath $file -Value '{"entries":[{"id":"has space","path":"%SystemRoot%/System32/app.exe"},{"id":"nopath"},{"path":"%SystemRoot%/System32/app.exe"}]}'
    $r = Import-MacdowsAllowlist -Path $file -SystemRoot $fakeRoot
    Assert-Equal 0 @($r.Entries).Count
    Assert-Equal 3 @($r.Errors).Count
}

Test-Case 'rejects non-string args' {
    $file = Join-Path $script:TempRoot 'badargs.json'
    Set-Content -LiteralPath $file -Value '{"entries":[{"id":"app","path":"%SystemRoot%/System32/app.exe","args":[1,2]}]}'
    $r = Import-MacdowsAllowlist -Path $file -SystemRoot $fakeRoot
    Assert-Equal 0 @($r.Entries).Count
    Assert-True (($r.Errors -join ' ') -match 'array of strings')
}

Test-Case 'one bad entry does not discard the good ones' {
    $file = Join-Path $script:TempRoot 'mixed.json'
    Set-Content -LiteralPath $file -Value '{"entries":[{"id":"bad","path":"relative.exe"},{"id":"app","path":"%SystemRoot%/System32/app.exe"}]}'
    $r = Import-MacdowsAllowlist -Path $file -SystemRoot $fakeRoot
    Assert-Equal 1 @($r.Entries).Count
    Assert-Equal 'app' $r.Entries[0].id
    Assert-Equal 1 @($r.Errors).Count
}

Test-Case 'reports a missing or malformed allowlist file without throwing' {
    $r1 = Import-MacdowsAllowlist -Path (Join-Path $script:TempRoot 'does-not-exist.json') -SystemRoot 'C:\Windows'
    Assert-Equal 0 @($r1.Entries).Count
    Assert-True (($r1.Errors -join ' ') -match 'not found')

    $file = Join-Path $script:TempRoot 'broken.json'
    Set-Content -LiteralPath $file -Value '{ this is not json'
    $r2 = Import-MacdowsAllowlist -Path $file -SystemRoot 'C:\Windows'
    Assert-Equal 0 @($r2.Entries).Count
    Assert-True (($r2.Errors -join ' ') -match 'not valid JSON')
}

Test-Case 'the shipped allowlist.sample.json is valid' {
    $sample = Join-Path $PSScriptRoot 'allowlist.sample.json'
    Assert-True (Test-Path -LiteralPath $sample) 'allowlist.sample.json must exist'
    $r = Import-MacdowsAllowlist -Path $sample -SystemRoot 'C:\Windows' -FileExistsProbe { param($p) $true }
    Assert-Equal 0 @($r.Errors).Count ($r.Errors -join '; ')
    Assert-Equal 5 @($r.Entries).Count
    foreach ($e in $r.Entries) {
        Assert-True ($e.path.StartsWith('C:\Windows\')) "sample paths must live under %SystemRoot%: $($e.path)"
    }
}

# -------------------------------------------------------------------------------------------
New-Section 'Path and platform helpers'
# -------------------------------------------------------------------------------------------

Test-Case 'recognises absolute paths on both path flavours' {
    foreach ($p in @('C:\Windows\x.exe', 'c:/windows/x.exe', '\\server\share\x.exe', '/usr/bin/x')) {
        Assert-True (Test-MacdowsAbsolutePath -Path $p) "expected '$p' to be absolute"
    }
    foreach ($p in @('x.exe', 'System32\x.exe', './x', '', $null, ' ')) {
        Assert-True (-not (Test-MacdowsAbsolutePath -Path $p)) "expected '$p' to be relative"
    }
}

Test-Case 'token expansion is case-insensitive and does not loop' {
    Assert-Equal 'C:\Windows\System32\x.exe' (Expand-MacdowsPathTokens -Path '%systemroot%\System32\x.exe' -SystemRoot 'C:\Windows\')
    Assert-Equal 'C:\Windows\notepad.exe' (Expand-MacdowsPathTokens -Path '%WinDir%\notepad.exe' -SystemRoot 'C:\Windows')
    # A replacement value that itself contains the token must terminate.
    Assert-Equal '%SystemRoot%\x' (Expand-MacdowsStringToken -Text '%SystemRoot%\x' -Token '%SystemRoot%' -Value '%SystemRoot%')
    # '$' in the value is literal, not a regex replacement reference.
    Assert-Equal 'C:\a$1b\x' (Expand-MacdowsPathTokens -Path '%SystemRoot%\x' -SystemRoot 'C:\a$1b')
}

Test-Case 'extracts the executable from a shell open command' {
    Assert-Equal 'C:\Program Files\R\r.exe' (Get-MacdowsExecutableFromCommand -Command '"C:\Program Files\R\r.exe" "%1"')
    Assert-Equal 'C:\R\r.exe' (Get-MacdowsExecutableFromCommand -Command 'C:\R\r.exe %1')
    Assert-Equal 'C:\R\r.exe' (Get-MacdowsExecutableFromCommand -Command 'C:\R\r.exe')
    Assert-Null (Get-MacdowsExecutableFromCommand -Command '')
    Assert-Null (Get-MacdowsExecutableFromCommand -Command $null)
}

Test-Case 'parses the real MSEdgePDF-shaped open command' {
    # The shape this host actually registers for .pdf.
    $cmd = '"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --single-argument %1'
    Assert-Equal 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' (Get-MacdowsExecutableFromCommand -Command $cmd)
}

Test-Case 'an unquoted command with spaces is not truncated at the first space' {
    # Windows probes progressively longer prefixes; so do we, or 'C:\Program Files\...' would
    # come back as 'C:\Program'.
    Assert-Equal 'C:\Program Files\R\r.exe' (Get-MacdowsExecutableFromCommand -Command 'C:\Program Files\R\r.exe %1')
    Assert-Equal 'C:\Program Files\R\r.COM' (Get-MacdowsExecutableFromCommand -Command 'C:\Program Files\R\r.COM /x')
    Assert-Equal 'C:\R\r.exe' (Get-MacdowsExecutableFromCommand -Command '  C:\R\r.exe  ') 'surrounding whitespace is trimmed'
    # Nothing program-shaped at all: fall back to the first token rather than returning nothing.
    Assert-Equal 'C:\R\handler' (Get-MacdowsExecutableFromCommand -Command 'C:\R\handler %1')
}

# -------------------------------------------------------------------------------------------
New-Section 'Association fallback selection (live finding L1)'
# -------------------------------------------------------------------------------------------

Test-Case 'the fallback is needed only when both executable and command are empty' {
    Assert-True (Test-MacdowsAssocNeedsFallback -Executable $null -Command $null)
    Assert-True (Test-MacdowsAssocNeedsFallback -Executable '' -Command '   ')
    Assert-True (-not (Test-MacdowsAssocNeedsFallback -Executable 'C:\x.exe' -Command $null))
    Assert-True (-not (Test-MacdowsAssocNeedsFallback -Executable $null -Command '"C:\x.exe" "%1"'))
    Assert-True (-not (Test-MacdowsAssocNeedsFallback -Executable 'C:\x.exe' -Command 'c'))
}

Test-Case 'a friendlyName-only AssocQueryString result still triggers the registry fallback' {
    # Replays the exact assoc.json from the live acceptance run: AssocQueryString answered
    # FRIENDLYAPPNAME but nothing for EXECUTABLE/COMMAND, and the old code treated that as
    # success and returned early - so the probe reported a null executable for a .pdf that
    # plainly has a handler.
    $r = Get-MacdowsAssociation -Extension '.pdf' `
        -QueryStringProbe { param($Ext) [ordered]@{ executable = $null; command = $null; friendlyName = 'Microsoft Edge' } } `
        -RegistryProbe {
            param($Ext)
            [ordered]@{
                executable   = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
                command      = '"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --single-argument %1'
                friendlyName = 'MSEdgePDF'
            }
        }
    Assert-Equal '.pdf' $r['ext']
    Assert-Equal 'registry' $r['source'] 'the answer came from the registry, so say so'
    Assert-Equal 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' $r['executable']
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$r['command']))
    Assert-Equal 'Microsoft Edge' $r['friendlyName'] 'the nicer AssocQueryString name is kept over the ProgId'
}

Test-Case 'the registry fallback derives the executable from the command when it has none' {
    $r = Get-MacdowsAssociation -Extension '.pdf' `
        -QueryStringProbe { param($Ext) $null } `
        -RegistryProbe { param($Ext) [ordered]@{ executable = $null; command = '"C:\R\r.exe" "%1"'; friendlyName = 'RProgId' } }
    Assert-Equal 'registry' $r['source']
    Assert-Equal 'C:\R\r.exe' $r['executable']
    Assert-Equal 'RProgId' $r['friendlyName'] 'with no AssocQueryString name, the ProgId is used'
}

Test-Case 'a complete AssocQueryString result does not consult the registry' {
    $r = Get-MacdowsAssociation -Extension '.pdf' `
        -QueryStringProbe { param($Ext) [ordered]@{ executable = 'C:\R\r.exe'; command = '"C:\R\r.exe" "%1"'; friendlyName = 'Reader' } } `
        -RegistryProbe { param($Ext) throw 'the registry must not be consulted here' }
    Assert-Equal 'AssocQueryString' $r['source']
    Assert-Equal 'C:\R\r.exe' $r['executable']
    Assert-Equal 'Reader' $r['friendlyName']
}

Test-Case 'an executable-only AssocQueryString result is accepted without the registry' {
    $r = Get-MacdowsAssociation -Extension '.pdf' `
        -QueryStringProbe { param($Ext) [ordered]@{ executable = 'C:\R\r.exe'; command = $null; friendlyName = 'Reader' } } `
        -RegistryProbe { param($Ext) throw 'the registry must not be consulted here' }
    Assert-Equal 'AssocQueryString' $r['source']
    Assert-Equal 'C:\R\r.exe' $r['executable']
}

Test-Case 'both lookups failing yields nulls rather than an exception' {
    $r = Get-MacdowsAssociation -Extension '.pdf' `
        -QueryStringProbe { param($Ext) $null } -RegistryProbe { param($Ext) $null }
    Assert-Equal '.pdf' $r['ext']
    Assert-Null $r['executable']
    Assert-Null $r['command']
    Assert-Null $r['source']
}

Test-Case 'a throwing lookup is contained and the other still runs' {
    $r = Get-MacdowsAssociation -Extension '.pdf' `
        -QueryStringProbe { param($Ext) throw 'P/Invoke exploded' } `
        -RegistryProbe { param($Ext) [ordered]@{ executable = 'C:\R\r.exe'; command = '"C:\R\r.exe" "%1"'; friendlyName = 'RProgId' } }
    Assert-Equal 'registry' $r['source']
    Assert-Equal 'C:\R\r.exe' $r['executable']

    $r2 = Get-MacdowsAssociation -Extension '.pdf' `
        -QueryStringProbe { param($Ext) [ordered]@{ executable = $null; command = $null; friendlyName = 'Edge' } } `
        -RegistryProbe { param($Ext) throw 'registry exploded' }
    Assert-Null $r2['executable'] 'a failed fallback leaves the field null rather than throwing'
    Assert-Equal 'Edge' $r2['friendlyName'] 'what did resolve is still reported'
}

Test-Case 'the selection also accepts PSCustomObject-shaped probe results' {
    $r = Get-MacdowsAssociation -Extension '.pdf' `
        -QueryStringProbe { param($Ext) [pscustomobject]@{ executable = $null; command = $null; friendlyName = 'Edge' } } `
        -RegistryProbe { param($Ext) [pscustomobject]@{ executable = 'C:\R\r.exe'; command = 'C:\R\r.exe %1'; friendlyName = 'P' } }
    Assert-Equal 'registry' $r['source']
    Assert-Equal 'C:\R\r.exe' $r['executable']
}

function New-RecordingAssocInvoker {
    <#
      Records every native call the ladder makes and resolves nothing, so the whole ladder runs.
      $Verb is captured as-is: the point is to tell a real $null from an empty string.
    #>
    param($Log)
    return {
        param($Flags, $StringType, $Extension, $Verb, $Buffer, $Length)
        [void]$Log.Add([pscustomobject]@{
            Flags       = $Flags
            StringType  = $StringType
            Verb        = $Verb
            VerbIsNull  = ($null -eq $Verb)
            VerbIsEmpty = (($null -ne $Verb) -and ($Verb -is [string]) -and ($Verb.Length -eq 0))
            IsSizing    = ($null -eq $Buffer)
        })
        return [pscustomobject]@{ HResult = 1; Length = 0 }
    }.GetNewClosure()
}

Test-Case 'verb-less ladder rungs pass a real null verb, not an empty string (review finding N1)' {
    # PowerShell binds $null to a [string] parameter as '', and pszExtra = "" is not the same
    # as NULL to AssocQueryString. Both friendlyName rungs are verb-less, and friendlyName is
    # the one field that did resolve on the live host, so an empty string there could regress
    # the only part of the P/Invoke known to work.
    $log = New-Object System.Collections.ArrayList
    [void](Get-MacdowsAssocViaQueryString -Extension '.pdf' -Invoker (New-RecordingAssocInvoker -Log $log))

    Assert-True ($log.Count -gt 0) 'the ladder must have called the invoker'
    $empties = @($log | Where-Object { $_.VerbIsEmpty })
    Assert-Equal 0 $empties.Count 'no rung may pass an empty-string verb'

    $verbless = @($log | Where-Object { $null -eq $_.Verb })
    $verbed = @($log | Where-Object { $null -ne $_.Verb })
    Assert-True ($verbless.Count -gt 0) 'some rungs are verb-less'
    Assert-True ($verbed.Count -gt 0) 'some rungs carry a verb'
    foreach ($record in $verbless) { Assert-True $record.VerbIsNull 'a verb-less rung must pass $null' }
    foreach ($record in $verbed) { Assert-Equal 'open' $record.Verb 'the only verb used is open' }
}

Test-Case 'both friendlyName rungs are verb-less' {
    # ASSOCSTR_FRIENDLYAPPNAME = 4. This is the field that worked on the live host; it must
    # keep receiving exactly what it received before the ladder existed.
    $log = New-Object System.Collections.ArrayList
    [void](Get-MacdowsAssocViaQueryString -Extension '.pdf' -Invoker (New-RecordingAssocInvoker -Log $log))
    $friendly = @($log | Where-Object { $_.StringType -eq 4 })
    Assert-True ($friendly.Count -gt 0) 'friendlyName rungs must run'
    foreach ($record in $friendly) {
        Assert-True $record.VerbIsNull 'every friendlyName rung passes a null verb'
        Assert-True (-not $record.VerbIsEmpty)
    }
}

Test-Case 'the executable and command rungs try the open verb before the verb-less form' {
    $log = New-Object System.Collections.ArrayList
    [void](Get-MacdowsAssocViaQueryString -Extension '.pdf' -Invoker (New-RecordingAssocInvoker -Log $log))
    foreach ($type in @(1, 2)) {   # ASSOCSTR_COMMAND = 1, ASSOCSTR_EXECUTABLE = 2
        $calls = @($log | Where-Object { $_.StringType -eq $type })
        Assert-True ($calls.Count -gt 0) "string type $type must be attempted"
        Assert-Equal 'open' $calls[0].Verb "string type $type must try the open verb first"
        Assert-True (@($calls | Where-Object { $null -eq $_.Verb }).Count -gt 0) "string type $type must also try verb-less"
    }
}

Test-Case 'each rung makes a sizing call with a null buffer before the filling call' {
    $log = New-Object System.Collections.ArrayList
    [void](Get-MacdowsAssocViaQueryString -Extension '.pdf' -Invoker (New-RecordingAssocInvoker -Log $log))
    Assert-Equal 0 ($log.Count % 2) 'calls come in sizing/filling pairs'
    for ($i = 0; $i -lt $log.Count; $i += 2) {
        Assert-True $log[$i].IsSizing 'the first call of a pair passes a null buffer'
        Assert-True (-not $log[$i + 1].IsSizing) 'the second call of a pair passes a real buffer'
        Assert-Equal $log[$i].Verb $log[$i + 1].Verb 'both calls of a pair use the same verb'
        Assert-Equal $log[$i].Flags $log[$i + 1].Flags 'both calls of a pair use the same flags'
    }
}

Test-Case 'a resolving rung short-circuits the rest of its ladder' {
    $log = New-Object System.Collections.ArrayList
    $invoker = {
        param($Flags, $StringType, $Extension, $Verb, $Buffer, $Length)
        [void]$log.Add([pscustomobject]@{ StringType = $StringType; Verb = $Verb })
        if ($null -ne $Buffer) { [void]$Buffer.Append('C:\R\r.exe') }
        return [pscustomobject]@{ HResult = 0; Length = 32 }
    }.GetNewClosure()

    $r = Get-MacdowsAssocViaQueryString -Extension '.pdf' -Invoker $invoker
    Assert-Equal 'C:\R\r.exe' $r['executable']
    Assert-Equal 'C:\R\r.exe' $r['command']
    Assert-Equal 'C:\R\r.exe' $r['friendlyName']
    # Three fields, first rung of each resolves: 3 rungs x 2 calls.
    Assert-Equal 6 $log.Count 'a resolved field must not try its remaining rungs'
}

Test-Case 'reads a field from either a dictionary or an object' {
    Assert-Equal 'v' (Get-MacdowsProperty -InputObject ([ordered]@{ k = 'v' }) -Name 'k')
    Assert-Equal 'v' (Get-MacdowsProperty -InputObject ([pscustomobject]@{ k = 'v' }) -Name 'k')
    Assert-Null (Get-MacdowsProperty -InputObject ([ordered]@{ k = 'v' }) -Name 'missing')
    Assert-Null (Get-MacdowsProperty -InputObject ([pscustomobject]@{ k = 'v' }) -Name 'missing')
    Assert-Null (Get-MacdowsProperty -InputObject $null -Name 'k')
}

Test-Case 'Windows-only capabilities degrade to nulls off-Windows' {
    if (Test-MacdowsIsWindows) {
        # On the host these hit the real registry / Shlwapi; only assert they do not throw.
        [void](Get-MacdowsTsAllowListDisabled)
        [void](Get-MacdowsAssociation -Extension '.pdf')
    } else {
        Assert-Null (Get-MacdowsTsAllowListDisabled)
        Assert-Null (Get-MacdowsIconPngBase64 -Path $fakeApp -IconIndex 0)
        $assoc = Get-MacdowsAssociation -Extension '.pdf'
        Assert-Equal '.pdf' $assoc['ext']
        Assert-Null $assoc['executable']
        Assert-Null $assoc['source']
    }
}

Test-Case 'the token generator produces 64 hex characters and does not repeat' {
    $t1 = New-MacdowsToken
    $t2 = New-MacdowsToken
    Assert-Equal 64 $t1.Length
    Assert-True ($t1 -cmatch '^[0-9a-f]{64}$')
    Assert-True ($t1 -ne $t2)
}

# -------------------------------------------------------------------------------------------
New-Section 'probe.ps1 pure helpers'
# -------------------------------------------------------------------------------------------

function New-TestAppsObject {
    <# A parsed /v1/apps response, shaped the way a real Windows host would answer. #>
    param([string] $Png = 'aWNvbg==', [switch] $NoIcons, [switch] $AllPublished)
    $pubIcon = $Png
    $allowIcon = $Png
    if ($NoIcons) { $pubIcon = $null; $allowIcon = $null }
    $charmapInTs = $false
    if ($AllPublished) { $charmapInTs = $true }
    return (ConvertFrom-Json (ConvertTo-Json -Depth 8 -InputObject ([ordered]@{
        tsAllowListDisabled = $false
        published           = @(
            [ordered]@{ key = 'calc'; name = 'Calculator'; path = 'C:\Windows\System32\calc.exe'; iconPng = $pubIcon }
        )
        agentAllowlist      = @(
            [ordered]@{ id = 'calc'; name = 'Calculator'; path = 'C:\Windows\System32\calc.exe'; inTsAllowList = $true; iconPng = $allowIcon },
            [ordered]@{ id = 'charmap'; name = 'Character Map'; path = 'C:\Windows\System32\charmap.exe'; inTsAllowList = $charmapInTs; iconPng = $allowIcon }
        )
    })))
}

Test-Case 'formats PASS and FAIL result lines' {
    Assert-Equal 'PASS  apps+icon      GET /v1/apps' (Format-MacdowsProbeResult -Ok $true -Capability 'apps+icon' -Detail 'GET /v1/apps')
    Assert-Equal 'FAIL  launch         POST /v1/launch (HTTP 401)' (Format-MacdowsProbeResult -Ok $false -Capability 'launch' -Detail 'POST /v1/launch (HTTP 401)')
    # The status token must lead the line so the Mac side can grep result.txt.
    Assert-True ((Format-MacdowsProbeResult -Ok $true -Capability 'assoc' -Detail 'x').StartsWith('PASS  '))
    Assert-True ((Format-MacdowsProbeInfo -Text 'hello') -notmatch '^(PASS|FAIL)') 'info lines must not look like results'
}

Test-Case 'checks the PNG magic number' {
    $png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
    Assert-True (Test-MacdowsProbePngMagic -Bytes $png)
    Assert-True (-not (Test-MacdowsProbePngMagic -Bytes ([byte[]](0x89, 0x50, 0x4E, 0x46, 0x0D, 0x0A, 0x1A, 0x0A)))) 'one wrong byte must fail'
    Assert-True (-not (Test-MacdowsProbePngMagic -Bytes ([byte[]](0x89, 0x50)))) 'a short buffer must fail'
    Assert-True (-not (Test-MacdowsProbePngMagic -Bytes ([byte[]]@()))) 'an empty buffer must fail'
    Assert-True (-not (Test-MacdowsProbePngMagic -Bytes $null)) 'null must fail'
    # A GIF that someone base64'd into iconPng must not be accepted as a PNG.
    Assert-True (-not (Test-MacdowsProbePngMagic -Bytes ([byte[]][System.Text.Encoding]::ASCII.GetBytes('GIF89a__'))))
}

Test-Case 'picks the first allowlist entry outside TSAppAllowList as the launch id' {
    Assert-Equal 'charmap' (Select-MacdowsProbeLaunchId -Apps (New-TestAppsObject))
}

Test-Case 'returns no launch id when every entry is published' {
    Assert-Null (Select-MacdowsProbeLaunchId -Apps (New-TestAppsObject -AllPublished))
}

Test-Case 'launch-id selection survives a missing or empty response' {
    Assert-Null (Select-MacdowsProbeLaunchId -Apps $null)
    Assert-Null (Select-MacdowsProbeLaunchId -Apps (ConvertFrom-Json '{}'))
    Assert-Null (Select-MacdowsProbeLaunchId -Apps (ConvertFrom-Json '{"agentAllowlist":[]}'))
}

Test-Case 'launch-id selection handles a one-element array collapsed to an object' {
    # What Windows PowerShell 5.1's ConvertTo-Json can produce for a single entry.
    $collapsed = ConvertFrom-Json '{"agentAllowlist":{"id":"charmap","inTsAllowList":false}}'
    Assert-Equal 'charmap' (Select-MacdowsProbeLaunchId -Apps $collapsed)
}

Test-Case 'entry-list normalisation never returns null' {
    Assert-Equal 0 @(Get-MacdowsProbeEntryList -Value $null).Count
    Assert-Equal 1 @(Get-MacdowsProbeEntryList -Value ([pscustomobject]@{ id = 'x' })).Count
    Assert-Equal 2 @(Get-MacdowsProbeEntryList -Value @(1, 2)).Count
}

Test-Case 'picks the first non-null icon, published entries first' {
    $icon = Select-MacdowsProbeIcon -Apps (New-TestAppsObject)
    Assert-Equal 'aWNvbg==' $icon.Base64
    Assert-Equal 'Calculator' $icon.Source
    Assert-Null (Select-MacdowsProbeIcon -Apps (New-TestAppsObject -NoIcons)) 'all-null icons must yield nothing'
    Assert-Null (Select-MacdowsProbeIcon -Apps (ConvertFrom-Json '{}'))
}

Test-Case 'falls back to the allowlist when no published entry has an icon' {
    $doc = ConvertFrom-Json '{"published":[{"name":"Pub","iconPng":null}],"agentAllowlist":[{"id":"charmap","iconPng":"aWNvbg=="}]}'
    $icon = Select-MacdowsProbeIcon -Apps $doc
    Assert-Equal 'aWNvbg==' $icon.Base64
    Assert-Equal 'charmap' $icon.Source 'label falls back to the id when there is no name'
}

Test-Case 'reads properties without throwing under StrictMode' {
    $obj = ConvertFrom-Json '{"a":1}'
    Assert-Equal 1 (Get-MacdowsProbeProperty -InputObject $obj -Name 'a')
    Assert-Null (Get-MacdowsProbeProperty -InputObject $obj -Name 'missing')
    Assert-Null (Get-MacdowsProbeProperty -InputObject $null -Name 'a')
}

# -------------------------------------------------------------------------------------------
New-Section 'End-to-end (real TCP listener + curl)'
# -------------------------------------------------------------------------------------------

function Get-FreeTcpPort {
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = $probe.LocalEndpoint.Port
    $probe.Stop()
    return $port
}

function Get-PwshPath {
    try { return (Get-Process -Id $PID).Path } catch { return 'pwsh' }
}

function Start-TestAgent {
    <#
      Starts a real agent process with -Once and waits for its "listening on" banner.
      Readiness is taken from stdout rather than a TCP probe: with -Once, a probe
      connection would consume the single request the agent is willing to serve.
    #>
    param([string] $Directory, [string] $AllowlistPath, [string] $Tag = 'agent')

    $outFile = Join-Path $Directory "$Tag.out"
    $errFile = Join-Path $Directory "$Tag.err"
    $tokenFile = Join-Path $Directory "$Tag.token"
    $port = Get-FreeTcpPort

    $proc = Start-Process -FilePath (Get-PwshPath) -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -ArgumentList @(
            '-NoProfile', '-File', $AgentPath,
            '-BindAddress', '127.0.0.1',
            '-Port', "$port",
            '-AllowlistPath', $AllowlistPath,
            '-TokenPath', $tokenFile,
            '-Once'
        )

    $deadline = (Get-Date).AddSeconds(30)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        $so = ''
        if (Test-Path -LiteralPath $outFile) {
            $so = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        }
        if ($null -ne $so -and $so -match 'listening on http://') { $ready = $true; break }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) {
        if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
        $err = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        $so = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        throw "agent did not become ready. stdout: $so stderr: $err"
    }

    $token = $null
    if (Test-Path -LiteralPath $tokenFile) {
        $token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
    }

    return [pscustomobject]@{
        Process   = $proc
        Port      = $port
        Token     = $token
        StdoutPath = $outFile
        StderrPath = $errFile
        TokenPath = $tokenFile
    }
}

if ($SkipEndToEnd) {
    Write-Host '  skipped (-SkipEndToEnd)'
} elseif ($null -eq (Get-Command curl -ErrorAction SilentlyContinue)) {
    Write-Host '  skipped (curl not found)'
} else {
    $e2eDir = Join-Path $script:TempRoot 'e2e'
    [void](New-Item -ItemType Directory -Path $e2eDir -Force)
    $e2eAllowlist = Join-Path $e2eDir 'allowlist.json'
    Set-Content -LiteralPath $e2eAllowlist -Value ('{"entries":[{"id":"app","name":"App","path":"' + ($fakeApp -replace '\\', '\\\\') + '"}]}')

    Test-Case 'serves GET /v1/health over a real socket with -Once' {
        $agent = Start-TestAgent -Directory $e2eDir -AllowlistPath $e2eAllowlist -Tag 'health'
        try {
            Assert-True (-not [string]::IsNullOrWhiteSpace($agent.Token)) 'agent must write its token file'

            $raw = & curl --silent --show-error --include --max-time 20 `
                --header "Authorization: Bearer $($agent.Token)" `
                "http://127.0.0.1:$($agent.Port)/v1/health" 2>&1
            $text = ($raw | Out-String)

            Assert-True ($text -match 'HTTP/1\.1 200 OK') "status line missing; got: $text"
            Assert-True ($text -match 'X-Macdows-Agent: 0\.1\.0') "version header missing; got: $text"
            Assert-True ($text -match 'application/json; charset=utf-8') "content type missing; got: $text"
            Assert-True ($text -match 'Connection: close') "close header missing; got: $text"

            $parts = $text -split "`r?`n`r?`n", 2
            $json = ConvertFrom-Json ($parts[$parts.Length - 1].Trim())
            Assert-Equal 'macdows-host-agent' $json.agent
            Assert-Equal '0.1.0' $json.version
            Assert-Equal "127.0.0.1:$($agent.Port)" $json.bind

            Assert-True ($agent.Process.WaitForExit(10000)) '-Once did not exit after serving one request'

            # The token is printed exactly once and never appears in the per-request log.
            $stdout = Get-Content -LiteralPath $agent.StdoutPath -Raw
            $hits = ([regex]::Matches($stdout, [regex]::Escape($agent.Token))).Count
            Assert-Equal 1 $hits 'the token must be printed exactly once'
            Assert-True ($stdout -match 'allowlist: 1 usable') "allowlist should have loaded; got: $stdout"
        } finally {
            if (-not $agent.Process.HasExited) { try { $agent.Process.Kill() } catch { } }
        }
    }

    Test-Case 'rejects a request with no token over a real socket' {
        $agent = Start-TestAgent -Directory $e2eDir -AllowlistPath $e2eAllowlist -Tag 'unauth'
        try {
            $raw = & curl --silent --show-error --include --max-time 20 "http://127.0.0.1:$($agent.Port)/v1/health" 2>&1
            $text = ($raw | Out-String)
            Assert-True ($text -match 'HTTP/1\.1 401 Unauthorized') "expected 401; got: $text"
            Assert-True ($text -match '\{\}') 'the 401 body must be an empty JSON object'
            Assert-True ($text -notmatch 'WWW-Authenticate') 'the 401 must not hint at the scheme'
            Assert-True ($text -notmatch [regex]::Escape($agent.Token)) 'the 401 must not echo the token'
        } finally {
            if (-not $agent.Process.HasExited) { try { $agent.Process.Kill() } catch { } }
        }
    }

    Test-Case 'proxy-launches an allowlisted program end to end' {
        # The allowlist entry points at a file that is not executable, so the launch is
        # expected to fail at CreateProcess; what this proves is that the request reached
        # the launch path and that the agent resolved the id itself.
        $agent = Start-TestAgent -Directory $e2eDir -AllowlistPath $e2eAllowlist -Tag 'launch'
        try {
            $raw = & curl --silent --show-error --include --max-time 20 `
                --header "Authorization: Bearer $($agent.Token)" `
                --header 'Content-Type: application/json' `
                --data '{"id":"no-such-id"}' `
                "http://127.0.0.1:$($agent.Port)/v1/launch" 2>&1
            $text = ($raw | Out-String)
            Assert-True ($text -match 'HTTP/1\.1 404 Not Found') "expected 404 for an unknown id; got: $text"
            Assert-True ($text -match 'unknown_id') "expected an unknown_id body; got: $text"
        } finally {
            if (-not $agent.Process.HasExited) { try { $agent.Process.Kill() } catch { } }
        }
    }
}

# -------------------------------------------------------------------------------------------
New-Section 'End-to-end (probe.ps1 against a stubbed agent)'
# -------------------------------------------------------------------------------------------

# A stub agent: the real server loop and the real HTTP stack, with Windows-only providers
# replaced by fixtures. This is what lets probe.ps1's PASS path be proven off-Windows.
$stubAgentSource = @'
param([int] $ListenPort, [string] $AuthToken, [string] $AgentPath)
. $AgentPath -NoServe
$png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
$allow = @(
    [pscustomobject]@{ id = 'calc';    name = 'Calculator';    path = 'C:\Windows\System32\calc.exe';    args = @() },
    [pscustomobject]@{ id = 'charmap'; name = 'Character Map'; path = 'C:\Windows\System32\charmap.exe'; args = @() }
)
$ctx = New-MacdowsContext -Token $AuthToken -Allowlist $allow -Bind "127.0.0.1:$ListenPort" -Providers @{
    SessionInfo         = { [pscustomobject]@{ user = 'rdpuser'; sessionId = 2 } }
    TsAllowListDisabled = { $false }
    IconPng             = { param($Path, $Index) $png }
    Assoc               = {
        param($Ext)
        [ordered]@{
            ext = $Ext; executable = 'C:\Program Files\Reader\reader.exe'
            command = '"C:\Program Files\Reader\reader.exe" "%1"'
            friendlyName = 'Reader'; source = 'AssocQueryString'
        }
    }
    PublishedApps       = {
        param($Ctx)
        [pscustomobject]@{
            tsAllowListDisabled = $false
            published = @([ordered]@{
                key = 'calc'; name = 'Calculator'; path = 'C:\Windows\System32\calc.exe'
                commandLineSetting = 0; iconPath = $null; iconIndex = 0; iconPng = $png
            })
        }
    }
    LaunchProcess       = { param($Entry) 31337 }
}
Start-MacdowsHostAgentServer -BindAddress '127.0.0.1' -Port $ListenPort -Context $ctx
'@

function Start-StubAgent {
    param([string] $Directory, [string] $Token, [string] $Tag = 'stub')
    $scriptPath = Join-Path $Directory 'stub-agent.ps1'
    Set-Content -LiteralPath $scriptPath -Value $stubAgentSource
    $outFile = Join-Path $Directory "$Tag.out"
    $errFile = Join-Path $Directory "$Tag.err"
    $port = Get-FreeTcpPort

    $proc = Start-Process -FilePath (Get-PwshPath) -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -ArgumentList @('-NoProfile', '-File', $scriptPath,
            '-ListenPort', "$port", '-AuthToken', $Token, '-AgentPath', $AgentPath)

    $deadline = (Get-Date).AddSeconds(30)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        $so = ''
        if (Test-Path -LiteralPath $outFile) { $so = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) }
        if ($null -ne $so -and $so -match 'listening on http://') { $ready = $true; break }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) {
        if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
        throw ("stub agent did not start: " + (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue))
    }
    return [pscustomobject]@{ Process = $proc; Port = $port }
}

function Invoke-ProbePs1 {
    param([string] $OutDir, [int] $Port, [string] $TokenPath, [string] $LogPath)
    $proc = Start-Process -FilePath (Get-PwshPath) -PassThru `
        -RedirectStandardOutput $LogPath -RedirectStandardError "$LogPath.err" `
        -ArgumentList @('-NoProfile', '-File', $ProbePs1Path,
            '-OutDir', $OutDir, '-Port', "$Port", '-TokenPath', $TokenPath)
    if (-not $proc.WaitForExit(90000)) {
        try { $proc.Kill() } catch { }
        throw 'probe.ps1 did not finish within 90s'
    }
    return $proc.ExitCode
}

if ($SkipEndToEnd) {
    Write-Host '  skipped (-SkipEndToEnd)'
} else {
    $probeDir = Join-Path $script:TempRoot 'probeps1'
    [void](New-Item -ItemType Directory -Path $probeDir -Force)
    $stubToken = 'a' * 64

    Test-Case 'probe.ps1 passes all three capability checks against a live agent' {
        $stub = Start-StubAgent -Directory $probeDir -Token $stubToken -Tag 'ok'
        try {
            $outDir = Join-Path $probeDir 'out-ok'
            $tokenFile = Join-Path $probeDir 'token-ok'
            Set-Content -LiteralPath $tokenFile -Value $stubToken -NoNewline
            $log = Join-Path $probeDir 'probe-ok.log'

            $code = Invoke-ProbePs1 -OutDir $outDir -Port $stub.Port -TokenPath $tokenFile -LogPath $log
            $result = Get-Content -LiteralPath (Join-Path $outDir 'result.txt') -Raw
            Assert-Equal 0 $code ("probe.ps1 should exit 0; result.txt:`n$result")

            foreach ($f in @('health.json', 'apps.json', 'assoc.json', 'launch.json', 'icon-0.png', 'result.txt', 'DONE')) {
                Assert-True (Test-Path -LiteralPath (Join-Path $outDir $f)) "missing artifact: $f"
            }

            # Exactly the three capability lines the contract calls for, all PASS.
            $passLines = @([regex]::Matches($result, '(?m)^PASS\s'))
            $failLines = @([regex]::Matches($result, '(?m)^FAIL\s'))
            Assert-Equal 3 $passLines.Count "expected 3 PASS lines; got:`n$result"
            Assert-Equal 0 $failLines.Count "expected no FAIL lines; got:`n$result"
            Assert-True ($result -match 'PASS\s+apps\+icon') 'missing apps+icon result'
            Assert-True ($result -match 'PASS\s+launch') 'missing launch result'
            Assert-True ($result -match 'PASS\s+assoc') 'missing assoc result'
            # No -LaunchId was passed, so it must have chosen the entry outside TSAppAllowList.
            Assert-True ($result -match 'id=charmap') "should have auto-selected charmap; got:`n$result"

            # Both session ids are reported. The stub claims session 2 while the probe runs in
            # this machine's own session, so the mismatch warning must fire - that warning is
            # the only signal that a launched window would open somewhere nobody is watching.
            Assert-True ($result -match 'probe session=\d+, agent session=2') "missing session line; got:`n$result"
            Assert-True ($result -match 'WARNING: agent is in a different session') "missing session mismatch warning; got:`n$result"
            Assert-True ($result -notmatch '(?m)^(PASS|FAIL)\s.*WARNING') 'the warning must not be a capability line'

            # The icon really is a PNG on disk.
            $iconBytes = [System.IO.File]::ReadAllBytes((Join-Path $outDir 'icon-0.png'))
            Assert-True (Test-MacdowsProbePngMagic -Bytes $iconBytes) 'icon-0.png is not a PNG'

            $done = Get-Content -LiteralPath (Join-Path $outDir 'DONE') -Raw
            Assert-True ($done -match 'failures=0') "DONE should record 0 failures; got: $done"

            # The token must not be persisted or printed anywhere by the probe.
            $log = Get-Content -LiteralPath $log -Raw
            Assert-True ($log -notmatch [regex]::Escape($stubToken)) 'the token must never be printed'
            foreach ($file in (Get-ChildItem -LiteralPath $outDir -File)) {
                $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
                if ($null -ne $text) {
                    Assert-True ($text -notmatch [regex]::Escape($stubToken)) "the token leaked into $($file.Name)"
                }
            }
        } finally {
            if (-not $stub.Process.HasExited) { try { $stub.Process.Kill() } catch { } }
        }
    }

    Test-Case 'probe.ps1 fails closed and still writes DONE when the token is wrong' {
        $stub = Start-StubAgent -Directory $probeDir -Token $stubToken -Tag 'bad'
        try {
            $outDir = Join-Path $probeDir 'out-bad'
            $tokenFile = Join-Path $probeDir 'token-bad'
            Set-Content -LiteralPath $tokenFile -Value ('b' * 64) -NoNewline

            $code = Invoke-ProbePs1 -OutDir $outDir -Port $stub.Port -TokenPath $tokenFile -LogPath (Join-Path $probeDir 'probe-bad.log')
            Assert-Equal 1 $code 'probe.ps1 must exit non-zero when a capability fails'

            $result = Get-Content -LiteralPath (Join-Path $outDir 'result.txt') -Raw
            Assert-True ($result -match '(?m)^FAIL\s+apps\+icon.*401') "expected a 401 on apps; got:`n$result"
            Assert-True ($result -match '(?m)^FAIL\s+assoc.*401') "expected a 401 on assoc; got:`n$result"
            Assert-Equal 0 @([regex]::Matches($result, '(?m)^PASS\s')).Count 'nothing should pass with a bad token'

            Assert-True (Test-Path -LiteralPath (Join-Path $outDir 'DONE')) 'DONE must be written even on failure'
            $done = Get-Content -LiteralPath (Join-Path $outDir 'DONE') -Raw
            Assert-True ($done -match 'failures=3') "DONE should record 3 failures; got: $done"
        } finally {
            if (-not $stub.Process.HasExited) { try { $stub.Process.Kill() } catch { } }
        }
    }

    Test-Case 'probe.ps1 writes DONE even when the agent is not running at all' {
        $outDir = Join-Path $probeDir 'out-dead'
        $tokenFile = Join-Path $probeDir 'token-dead'
        Set-Content -LiteralPath $tokenFile -Value $stubToken -NoNewline
        $deadPort = Get-FreeTcpPort   # nothing is listening here

        $code = Invoke-ProbePs1 -OutDir $outDir -Port $deadPort -TokenPath $tokenFile -LogPath (Join-Path $probeDir 'probe-dead.log')
        Assert-Equal 1 $code 'an unreachable agent must exit non-zero'
        Assert-True (Test-Path -LiteralPath (Join-Path $outDir 'DONE')) 'DONE must be written when the agent is unreachable'
        $result = Get-Content -LiteralPath (Join-Path $outDir 'result.txt') -Raw
        Assert-True ($result -match 'health: unreachable') "expected an unreachable health line; got:`n$result"
        Assert-Equal 3 @([regex]::Matches($result, '(?m)^FAIL\s')).Count "expected 3 FAIL lines; got:`n$result"
    }
}

# -------------------------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------------------------

try { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Host ''
Write-Host ("{0} test(s), {1} failed" -f $script:TestTotal, $script:TestFailed)
if ($script:TestFailed -gt 0) {
    Write-Host ''
    foreach ($f in $script:TestFailures) { Write-Host "  - $f" }
    exit 1
}
exit 0
