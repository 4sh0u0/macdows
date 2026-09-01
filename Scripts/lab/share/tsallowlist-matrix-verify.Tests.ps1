#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test suite for tsallowlist-matrix-verify.ps1's decision logic.

.DESCRIPTION
    Runs on macOS under PowerShell 7 (and on the host under Windows PowerShell 5.1) with no
    external dependencies. Self-contained assertion harness, exit code propagated: 0 when every
    case passes, 1 otherwise. Style follows Tools/host-agent/MacdowsHostAgent.Tests.ps1.

    The whole enforced/not-enforced judgement lives in Get-MatrixVerdict, a pure function over
    (registry snapshot, /v1/apps response). That is what is driven here with fixtures, so the
    acceptance criteria can be exercised without a Windows host, without the registry and
    without a running agent.

    Fixture paths use the %SystemRoot% form and the literal C:\Windows. No host names, no
    addresses, nothing account-specific appears in this file.

.EXAMPLE
    pwsh -NoProfile -File ./tsallowlist-matrix-verify.Tests.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'tsallowlist-matrix-verify.ps1') -NoRun

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

function New-Section { param([string] $Name) Write-Host ''; Write-Host "== $Name" }

function Write-ResponderDiagnostics {
    <#
      Surfaces a failure that happened inside a background [PowerShell] runspace, so a broken
      test FIXTURE cannot be misread as a failure of the code under test.

      Every one-shot HTTP server in this file runs on a [PowerShell] instance via BeginInvoke.
      If AcceptTcpClient or the socket write throws in there, the client side sees only a
      timeout or a refused connection -- which points the reader at Invoke-MatrixRequest, the
      one place the bug is not.

      BOTH streams have to be checked, and this is the part that is easy to get wrong: a
      TERMINATING error (a throw, and everything the socket calls raise) does NOT appear in
      Streams.Error at all. It sets InvocationStateInfo.State = Failed and parks the exception
      in InvocationStateInfo.Reason, leaving Streams.Error empty. Only non-terminating errors
      (Write-Error) land in Streams.Error. Checking just the error stream -- the obvious
      implementation -- therefore reports nothing for exactly the failures worth reporting.
      Measured, not assumed: a throwing runspace gives Streams.Error.Count = 0, State = Failed.

      Deliberately does NOT call EndInvoke(): that rethrows the runspace's exception into the
      caller, which would turn a fixture problem into a test failure and change pass/fail
      semantics. This is diagnostics only -- it prints and returns.
    #>
    param($PowerShellInstance)

    try {
        if ($null -eq $PowerShellInstance) { return }
        $info = $PowerShellInstance.InvocationStateInfo
        # .Reason is populated only on failure, so a null check is the state check.
        if ($null -ne $info -and $null -ne $info.Reason) {
            Write-Host "       responder runspace FAILED: $($info.Reason.Message)"
        }
        if ($PowerShellInstance.Streams.Error.Count -gt 0) {
            Write-Host "       responder runspace error: $($PowerShellInstance.Streams.Error[0])"
        }
    } catch { }
}

# -------------------------------------------------------------------------------------------
# Fixtures
# -------------------------------------------------------------------------------------------

$script:SysRoot = 'C:\Windows'

function New-PublishedEntry {
    param([string] $Key, [string] $Name, [string] $Path, $Cls)
    return [pscustomobject]@{
        key                = $Key
        name               = $Name
        path               = $Path
        commandLineSetting = $Cls
        iconPath           = $Path
        iconIndex          = 0
        iconPng            = $null
    }
}

function New-AgentEntry {
    param([string] $Id, [string] $Path, [bool] $InTs)
    return [pscustomobject]@{
        id            = $Id
        name          = $Id
        path          = $Path
        args          = @()
        inTsAllowList = $InTs
        iconPng       = $null
    }
}

# The four applications Set-TsAllowListMatrix.ps1 -Mode Enforce publishes. Registry Path values
# keep the %SystemRoot% token, exactly as that script writes them.
function New-EnforcedPublished {
    return @(
        (New-PublishedEntry -Key 'winver'     -Name 'winver'     -Path '%SystemRoot%\System32\winver.exe' -Cls 0),
        (New-PublishedEntry -Key 'logoff'     -Name 'logoff'     -Path '%SystemRoot%\System32\logoff.exe' -Cls 0),
        (New-PublishedEntry -Key 'notepad'    -Name 'notepad'    -Path '%SystemRoot%\System32\notepad.exe' -Cls 1),
        (New-PublishedEntry -Key 'powershell' -Name 'powershell' -Path '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe' -Cls 1)
    )
}

# What the agent reports for its own allowlist. Paths are already expanded (the agent resolves
# %SystemRoot% at load time) - the mismatch in shape between the two sides is the point.
# 'powershell' is absent because the agent refuses shells and script hosts.
function New-EnforcedAgentList {
    param([bool] $CharmapInTs = $false)
    return @(
        (New-AgentEntry -Id 'winver'  -Path 'C:\Windows\System32\winver.exe'  -InTs $true),
        (New-AgentEntry -Id 'logoff'  -Path 'C:\Windows\System32\logoff.exe'  -InTs $true),
        (New-AgentEntry -Id 'notepad' -Path 'C:\Windows\System32\notepad.exe' -InTs $true),
        (New-AgentEntry -Id 'charmap' -Path 'C:\Windows\System32\charmap.exe' -InTs $CharmapInTs)
    )
}

function New-RegistryApps {
    param($Published)
    return @($Published | ForEach-Object {
        [pscustomobject]@{
            key                = $_.key
            name               = $_.name
            path               = $_.path
            commandLineSetting = $_.commandLineSetting
        }
    })
}

function New-Snapshot {
    param($FDisabled, $Policy = 0, $TsHive = $null, $Applications = @())
    return [pscustomobject]@{
        fDisabledAllowList  = $FDisabled
        policyAllowUnlisted = $Policy
        tsAllowUnlisted     = $TsHive
        applications        = @($Applications)
    }
}

function New-Apps {
    param($TsDisabled, $Published = @(), $AgentList = @())
    return [pscustomobject]@{
        tsAllowListDisabled = $TsDisabled
        published           = @($Published)
        agentAllowlist      = @($AgentList)
    }
}

function Invoke-Verdict {
    param($Snapshot, $Apps)
    return (Get-MatrixVerdict -Snapshot $Snapshot -Apps $Apps -SystemRoot $script:SysRoot)
}

function Get-AssertLine {
    param($Verdict, [string] $Name)
    $prefix = "ASSERT ${Name}:"
    $hit = @($Verdict.Lines | Where-Object { $_.StartsWith($prefix) })
    if ($hit.Count -ne 1) { throw "expected exactly one '$prefix' line, found $($hit.Count)" }
    return $hit[0]
}

function Assert-AssertPassed {
    param($Verdict, [string] $Name)
    $line = Get-AssertLine -Verdict $Verdict -Name $Name
    Assert-True ($line -match ": PASS(\s|$)") "expected $Name to PASS; got: $line"
}

function Assert-AssertFailed {
    param($Verdict, [string] $Name)
    $line = Get-AssertLine -Verdict $Verdict -Name $Name
    Assert-True ($line -match ": FAIL(\s|$)") "expected $Name to FAIL; got: $line"
}

# -------------------------------------------------------------------------------------------
New-Section 'path normalisation'
# -------------------------------------------------------------------------------------------

Test-Case 'resolves %SystemRoot% and lower-cases' {
    Assert-Equal 'c:\windows\system32\winver.exe' `
        (ConvertTo-MatrixComparablePath -Path '%SystemRoot%\System32\winver.exe' -SystemRoot 'C:\Windows')
}

Test-Case 'resolves %windir% case-insensitively' {
    Assert-Equal 'c:\windows\system32\winver.exe' `
        (ConvertTo-MatrixComparablePath -Path '%WINDIR%\System32\winver.exe' -SystemRoot 'C:\Windows')
}

Test-Case 'the two sides of the comparison normalise to the same string' {
    $a = ConvertTo-MatrixComparablePath -Path '%SystemRoot%\System32\notepad.exe' -SystemRoot 'C:\Windows'
    $b = ConvertTo-MatrixComparablePath -Path 'C:\Windows\System32\notepad.exe' -SystemRoot 'C:\Windows'
    Assert-Equal $a $b
}

Test-Case 'strips quotes, unifies separators, collapses repeats, drops a trailing separator' {
    Assert-Equal 'c:\windows\system32\notepad.exe' `
        (ConvertTo-MatrixComparablePath -Path '  "C:/Windows//System32\notepad.exe"  ' -SystemRoot 'C:\Windows')
}

Test-Case 'a UNC prefix survives the collapse' {
    Assert-Equal '\\server\share\app.exe' `
        (ConvertTo-MatrixComparablePath -Path '\\server\share\app.exe' -SystemRoot 'C:\Windows')
}

Test-Case 'an empty or whitespace path normalises to the empty string' {
    Assert-Equal '' (ConvertTo-MatrixComparablePath -Path '   ' -SystemRoot 'C:\Windows')
    Assert-Equal '' (ConvertTo-MatrixComparablePath -Path $null -SystemRoot 'C:\Windows')
}

# -------------------------------------------------------------------------------------------
New-Section 'enforced mode - the happy path'
# -------------------------------------------------------------------------------------------

Test-Case 'a fully correct enforced host is PASS' {
    $pub = New-EnforcedPublished
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Policy 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList))
    Assert-Equal 'PASS' $v.Result "lines:`n$($v.Lines -join "`n")"
    Assert-Equal 0 $v.Failures
}

Test-Case 'the enforced happy path passes every named assertion' {
    $pub = New-EnforcedPublished
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Policy 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList))
    foreach ($name in @(
        'tsAllowListDisabled-matches-registry',
        'published-count-is-4',
        'published-name-set-equals-expected',
        'registry-and-agent-published-agree',
        'positive-control-powershell-published-cls1',
        'policy-fAllowUnlistedRemotePrograms-closed',
        'agent-allowlist-loaded-expected-ids',
        'inTsAllowList[winver]',
        'inTsAllowList[logoff]',
        'inTsAllowList[notepad]',
        'inTsAllowList[charmap]',
        'negative-control-charmap-not-published')) {
        Assert-AssertPassed -Verdict $v -Name $name
    }
}

Test-Case 'inTsAllowList is judged across the %SystemRoot% / expanded-path mismatch' {
    # The registry side carries the token, the agent side does not. A naive string compare
    # would call every published program "not published" and turn the matrix into a false
    # negative; this is the case that pins the normalisation into the acceptance.
    $pub = New-EnforcedPublished
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList))
    Assert-AssertPassed -Verdict $v -Name 'inTsAllowList[winver]'
    Assert-True ((Get-AssertLine -Verdict $v -Name 'inTsAllowList[winver]') -match 'expected=True')
}

# -------------------------------------------------------------------------------------------
New-Section 'enforced mode - set equality in both directions'
# -------------------------------------------------------------------------------------------

Test-Case 'one published application missing is FAIL' {
    $pub = @((New-EnforcedPublished) | Where-Object { $_.name -ne 'notepad' })
    $agent = @((New-EnforcedAgentList) | Where-Object { $_.id -ne 'notepad' })
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList $agent)
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'published-count-is-4'
    Assert-AssertFailed -Verdict $v -Name 'published-name-set-equals-expected'
    Assert-True ((Get-AssertLine -Verdict $v -Name 'published-name-set-equals-expected') -match 'missing=\{notepad\}')
}

Test-Case 'one EXTRA published application is FAIL (the reverse direction)' {
    # A superset passes a one-directional "everything expected is present" check. It must not:
    # an extra publication left behind by an earlier run is exactly what would let the negative
    # control launch and report a green matrix on a host that is not in the state under test.
    $pub = @(New-EnforcedPublished) + @(New-PublishedEntry -Key 'charmap' -Name 'charmap' -Path '%SystemRoot%\System32\charmap.exe' -Cls 0)
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList -CharmapInTs $true))
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'published-count-is-4'
    Assert-AssertFailed -Verdict $v -Name 'published-name-set-equals-expected'
    Assert-True ((Get-AssertLine -Verdict $v -Name 'published-name-set-equals-expected') -match 'unexpected=\{charmap\}')
    Assert-AssertFailed -Verdict $v -Name 'negative-control-charmap-not-published'
}

Test-Case 'a same-size but different name set is FAIL' {
    $pub = @((New-EnforcedPublished) | Where-Object { $_.name -ne 'winver' }) +
           @(New-PublishedEntry -Key 'calc' -Name 'calc' -Path '%SystemRoot%\System32\calc.exe' -Cls 0)
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList))
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertPassed -Verdict $v -Name 'published-count-is-4'
    Assert-AssertFailed -Verdict $v -Name 'published-name-set-equals-expected'
}

# -------------------------------------------------------------------------------------------
New-Section 'enforced mode - the negative control'
# -------------------------------------------------------------------------------------------

Test-Case 'charmap reporting inTsAllowList=true is FAIL' {
    $pub = New-EnforcedPublished
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList -CharmapInTs $true))
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'negative-control-charmap-not-published'
    Assert-AssertFailed -Verdict $v -Name 'inTsAllowList[charmap]'
}

Test-Case 'charmap missing from the agent allowlist entirely is FAIL' {
    $pub = New-EnforcedPublished
    $agent = @((New-EnforcedAgentList) | Where-Object { $_.id -ne 'charmap' })
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList $agent)
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'negative-control-charmap-not-published'
    Assert-AssertFailed -Verdict $v -Name 'agent-allowlist-loaded-expected-ids'
}

Test-Case 'a published program reporting inTsAllowList=false is FAIL' {
    $pub = New-EnforcedPublished
    $agent = @(
        (New-AgentEntry -Id 'winver'  -Path 'C:\Windows\System32\winver.exe'  -InTs $false),
        (New-AgentEntry -Id 'logoff'  -Path 'C:\Windows\System32\logoff.exe'  -InTs $true),
        (New-AgentEntry -Id 'notepad' -Path 'C:\Windows\System32\notepad.exe' -InTs $true),
        (New-AgentEntry -Id 'charmap' -Path 'C:\Windows\System32\charmap.exe' -InTs $false)
    )
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList $agent)
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'inTsAllowList[winver]'
    Assert-AssertPassed -Verdict $v -Name 'negative-control-charmap-not-published'
}

Test-Case 'the agent accepting powershell into its allowlist is FAIL' {
    $pub = New-EnforcedPublished
    $agent = @(New-EnforcedAgentList) +
             @(New-AgentEntry -Id 'powershell' -Path 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -InTs $true)
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList $agent)
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'agent-allowlist-rejects-powershell'
}

# -------------------------------------------------------------------------------------------
New-Section 'enforced mode - the surrounding state'
# -------------------------------------------------------------------------------------------

Test-Case 'fAllowUnlistedRemotePrograms=1 in the policy hive is FAIL' {
    # fDisabledAllowList=0 does not enforce anything while the policy twin says "allow
    # unlisted". Without this the negative control would launch and the matrix would be
    # measuring nothing.
    $pub = New-EnforcedPublished
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Policy 1 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList))
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'policy-fAllowUnlistedRemotePrograms-closed'
}

Test-Case 'fAllowUnlistedRemotePrograms=1 in the Terminal Server hive is FAIL' {
    $pub = New-EnforcedPublished
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Policy 0 -TsHive 1 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList))
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'policy-fAllowUnlistedRemotePrograms-closed'
}

Test-Case 'both fAllowUnlistedRemotePrograms values absent is fine' {
    $pub = New-EnforcedPublished
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Policy $null -TsHive $null -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList))
    Assert-AssertPassed -Verdict $v -Name 'policy-fAllowUnlistedRemotePrograms-closed'
    Assert-Equal 'PASS' $v.Result
}

Test-Case 'powershell published with CommandLineSetting=0 fails the positive control' {
    $pub = @((New-EnforcedPublished) | Where-Object { $_.name -ne 'powershell' }) +
           @(New-PublishedEntry -Key 'powershell' -Name 'powershell' -Path '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe' -Cls 0)
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList))
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'positive-control-powershell-published-cls1'
}

Test-Case 'the registry snapshot and the agent enumeration disagreeing is FAIL' {
    $pub = New-EnforcedPublished
    $reg = @((New-RegistryApps $pub) | Where-Object { $_.key -ne 'logoff' })
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications $reg) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList))
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'registry-and-agent-published-agree'
    Assert-True ((Get-AssertLine -Verdict $v -Name 'registry-and-agent-published-agree') -match 'agent-only=\{logoff\}')
}

Test-Case 'an UNEXPECTED extra id in the agent allowlist is FAIL (the reverse direction)' {
    $pub = New-EnforcedPublished
    $agent = @(New-EnforcedAgentList) +
             @(New-AgentEntry -Id 'calc' -Path 'C:\Windows\System32\calc.exe' -InTs $false)
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList $agent)
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'agent-allowlist-loaded-expected-ids'
    Assert-True ((Get-AssertLine -Verdict $v -Name 'agent-allowlist-loaded-expected-ids') -match 'unexpected=\{calc\}')
}

Test-Case 'a known-rejected id does not also count as unexpected' {
    # powershell appearing is a real failure, but it is agent-allowlist-rejects-powershell's
    # failure. Counting it twice would make the reader chase two findings for one fact.
    $pub = New-EnforcedPublished
    $agent = @(New-EnforcedAgentList) +
             @(New-AgentEntry -Id 'powershell' -Path 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -InTs $true)
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList $agent)
    Assert-AssertFailed -Verdict $v -Name 'agent-allowlist-rejects-powershell'
    Assert-AssertPassed -Verdict $v -Name 'agent-allowlist-loaded-expected-ids'
    Assert-True ((Get-AssertLine -Verdict $v -Name 'agent-allowlist-loaded-expected-ids') -match 'unexpected=\{\}')
}

# -------------------------------------------------------------------------------------------
New-Section 'not enforced - PRECONDITION'
# -------------------------------------------------------------------------------------------

Test-Case 'fDisabledAllowList=1 with nothing published is PRECONDITION, not FAIL' {
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 1 -Policy 1) `
                        -Apps (New-Apps -TsDisabled $true)
    Assert-Equal 'PRECONDITION' $v.Result "lines:`n$($v.Lines -join "`n")"
    Assert-Equal 0 $v.Failures
    Assert-AssertPassed -Verdict $v -Name 'tsAllowListDisabled-matches-registry'
    Assert-AssertPassed -Verdict $v -Name 'published-empty-while-allowlist-disabled'
}

Test-Case 'the enforced-mode assertions are not evaluated while not enforced' {
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 1 -Policy 1) -Apps (New-Apps -TsDisabled $true)
    foreach ($absent in @('published-count-is-4', 'published-name-set-equals-expected',
                          'negative-control-charmap-not-published')) {
        Assert-True (@($v.Lines | Where-Object { $_.StartsWith("ASSERT ${absent}:") }).Count -eq 0) `
            "'$absent' must not be evaluated while the allow list is disabled"
    }
}

Test-Case 'the key being absent altogether is PRECONDITION' {
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled $null -Policy $null) `
                        -Apps (New-Apps -TsDisabled $null)
    Assert-Equal 'PRECONDITION' $v.Result
    Assert-AssertPassed -Verdict $v -Name 'tsAllowListDisabled-matches-registry'
}

Test-Case 'applications published while the allow list is disabled is FAIL, not PRECONDITION' {
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 1 -Applications (New-RegistryApps (New-EnforcedPublished))) `
                        -Apps (New-Apps -TsDisabled $true -Published (New-EnforcedPublished))
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'published-empty-while-allowlist-disabled'
}

# -------------------------------------------------------------------------------------------
New-Section 'agent / registry consistency on the flag itself'
# -------------------------------------------------------------------------------------------

Test-Case 'agent says disabled while the registry says enforced is FAIL' {
    $pub = New-EnforcedPublished
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $true -Published $pub -AgentList (New-EnforcedAgentList))
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'tsAllowListDisabled-matches-registry'
}

Test-Case 'agent says enforced while the registry says disabled is FAIL, not PRECONDITION' {
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 1) -Apps (New-Apps -TsDisabled $false)
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'tsAllowListDisabled-matches-registry'
}

Test-Case 'agent reporting null while the registry has a value is FAIL' {
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 1) -Apps (New-Apps -TsDisabled $null)
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'tsAllowListDisabled-matches-registry'
}

# -------------------------------------------------------------------------------------------
New-Section 'input shapes'
# -------------------------------------------------------------------------------------------

Test-Case 'a /v1/apps response missing agentAllowlist does not throw' {
    # ConvertFrom-Json only produces the members the JSON carried. Under StrictMode a naive
    # $Apps.agentAllowlist would be a terminating error, and the report would be a bare
    # exception rather than a verdict.
    $pub = New-EnforcedPublished
    $apps = [pscustomobject]@{ tsAllowListDisabled = $false; published = $pub }
    $v = Get-MatrixVerdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                           -Apps $apps -SystemRoot $script:SysRoot
    Assert-Equal 'FAIL' $v.Result
    Assert-AssertFailed -Verdict $v -Name 'agent-allowlist-loaded-expected-ids'
}

Test-Case 'a null published list is treated as empty, not as one entry' {
    # @($null).Count is 1. Left unhandled, a JSON null here would report one published
    # application on a host that publishes none, and PRECONDITION would come back FAIL.
    $apps = [pscustomobject]@{ tsAllowListDisabled = $true; published = $null; agentAllowlist = $null }
    $v = Get-MatrixVerdict -Snapshot (New-Snapshot -FDisabled 1) -Apps $apps -SystemRoot $script:SysRoot
    Assert-Equal 'PRECONDITION' $v.Result "lines:`n$($v.Lines -join "`n")"
    Assert-True ((Get-AssertLine -Verdict $v -Name 'published-empty-while-allowlist-disabled') -match 'count=0')
}

Test-Case 'null elements inside the published list are ignored' {
    $pub = @(New-EnforcedPublished) + @($null)
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps (New-EnforcedPublished))) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList))
    Assert-AssertPassed -Verdict $v -Name 'published-count-is-4'
    Assert-Equal 'PASS' $v.Result
}

Test-Case 'a hashtable snapshot is accepted as readily as a pscustomobject' {
    $pub = New-EnforcedPublished
    $snap = @{
        fDisabledAllowList  = 0
        policyAllowUnlisted = 0
        tsAllowUnlisted     = $null
        applications        = (New-RegistryApps $pub)
    }
    $v = Get-MatrixVerdict -Snapshot $snap -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList)) `
                           -SystemRoot $script:SysRoot
    Assert-Equal 'PASS' $v.Result
}

Test-Case 'every emitted line is either INFO or a well-formed ASSERT' {
    $pub = New-EnforcedPublished
    $v = Invoke-Verdict -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)) `
                        -Apps (New-Apps -TsDisabled $false -Published $pub -AgentList (New-EnforcedAgentList))
    foreach ($line in $v.Lines) {
        Assert-True ($line -match '^(INFO |ASSERT [^:]+: (PASS|FAIL))') "malformed report line: $line"
    }
}

# -------------------------------------------------------------------------------------------
New-Section 'allowlist JSON and argv construction'
# -------------------------------------------------------------------------------------------

Test-Case 'the throwaway allowlist names all five programs by full path' {
    $json = New-MatrixAllowlistJson -SystemRoot 'C:\Windows'
    $doc = ConvertFrom-Json $json
    $ids = @($doc.entries | ForEach-Object { $_.id })
    Assert-Equal 5 $ids.Count
    foreach ($id in @('winver', 'logoff', 'notepad', 'powershell', 'charmap')) {
        Assert-True ($ids -contains $id) "'$id' must be in the throwaway allowlist"
    }
}

Test-Case 'allowlist paths are absolute, backslash-escaped and carry no leftover token' {
    $json = New-MatrixAllowlistJson -SystemRoot 'C:\Windows'
    Assert-True ($json -notmatch '%[A-Za-z0-9_()]+%') "the agent rejects an unresolved token; json: $json"
    $doc = ConvertFrom-Json $json
    foreach ($e in $doc.entries) {
        Assert-True ($e.path -match '^[A-Za-z]:\\') "path must be absolute: $($e.path)"
        Assert-True ($e.path -match '\.exe$') "path must be a program: $($e.path)"
        Assert-True ($e.path -notmatch '\\\\') "path must not contain a doubled separator: $($e.path)"
    }
}

Test-Case 'charmap is in the allowlist but is NOT one of the published programs' {
    $doc = ConvertFrom-Json (New-MatrixAllowlistJson -SystemRoot 'C:\Windows')
    $ids = @($doc.entries | ForEach-Object { $_.id })
    Assert-True ($ids -contains 'charmap') 'charmap is the negative control and must be offered to the agent'
    Assert-True (@('winver', 'logoff', 'notepad', 'powershell') -notcontains 'charmap') `
        'charmap must never be in the expected published set'
}

Test-Case 'argv preflight: every path handed to Start-Process is quoted' {
    # Start-Process joins -ArgumentList into ONE command line with single spaces, so a path
    # containing a space would arrive split in two. Checked with a deliberately spacy path.
    $argv = New-MatrixAgentArgumentList -AgentScript 'C:\Temp\dir with space\MacdowsHostAgent.ps1' `
        -AllowlistPath 'C:\Temp\dir with space\matrix-allowlist.json' `
        -TokenPath 'C:\Temp\dir with space\token' -Port 51234 -BindAddress '127.0.0.1'

    Assert-Equal '"C:\Temp\dir with space\MacdowsHostAgent.ps1"' $argv[$argv.IndexOf('-File') + 1]
    Assert-Equal '"C:\Temp\dir with space\matrix-allowlist.json"' $argv[$argv.IndexOf('-AllowlistPath') + 1]
    Assert-Equal '"C:\Temp\dir with space\token"' $argv[$argv.IndexOf('-TokenPath') + 1]
    Assert-Equal '127.0.0.1' $argv[$argv.IndexOf('-BindAddress') + 1]
    Assert-Equal '51234' $argv[$argv.IndexOf('-Port') + 1]
    Assert-True ($argv -contains '-NoProfile') '-NoProfile must be passed'
    Assert-True ($argv -contains 'Bypass') 'the execution policy must be bypassed'
}

Test-Case 'argv preflight under Legacy argument passing produces the identical list' {
    # Global constraint: argv-construction logic is pre-flighted with
    # $PSNativeCommandArgumentPassing='Legacy', which is how Windows PowerShell 5.1 builds a
    # native command line (concatenate and strip quotes). The list is built by this script, not
    # by the parameter binder, so the mode must make no difference - and this is what says so.
    $before = Get-Variable -Name 'PSNativeCommandArgumentPassing' -ValueOnly -ErrorAction SilentlyContinue
    try {
        Set-Variable -Name 'PSNativeCommandArgumentPassing' -Value 'Legacy' -Scope Global
        $a = New-MatrixAgentArgumentList -AgentScript 'C:\Temp\a b\agent.ps1' `
            -AllowlistPath 'C:\Temp\a b\l.json' -TokenPath 'C:\Temp\a b\token' -Port 1 -BindAddress '127.0.0.1'
        Assert-Equal '"C:\Temp\a b\agent.ps1"' $a[$a.IndexOf('-File') + 1]
        Assert-Equal 13 $a.Count
    } finally {
        if ($null -eq $before) {
            Remove-Variable -Name 'PSNativeCommandArgumentPassing' -Scope Global -ErrorAction SilentlyContinue
        } else {
            Set-Variable -Name 'PSNativeCommandArgumentPassing' -Value $before -Scope Global
        }
    }
}

# -------------------------------------------------------------------------------------------
New-Section 'checkpoint reports'
# -------------------------------------------------------------------------------------------

Test-Case 'the snapshot info lines carry the registry state a checkpoint must preserve' {
    $pub = New-EnforcedPublished
    $lines = Get-MatrixSnapshotInfoLines -Snapshot (New-Snapshot -FDisabled 0 -Policy 0 -Applications (New-RegistryApps $pub))
    Assert-True (@($lines | Where-Object { $_ -match 'registry fDisabledAllowList = 0' }).Count -eq 1) `
        'fDisabledAllowList must be in the checkpoint'
    Assert-True (@($lines | Where-Object { $_ -match 'registry Applications keys = \{logoff,notepad,powershell,winver\}' }).Count -eq 1) `
        'the published key set must be in the checkpoint'
    foreach ($line in $lines) { Assert-True ($line.StartsWith('INFO ')) "checkpoint line must be INFO: $line" }
}

Test-Case 'an absent key renders as <absent>, not as an empty string' {
    $lines = Get-MatrixSnapshotInfoLines -Snapshot (New-Snapshot -FDisabled $null -Policy $null)
    Assert-True (@($lines | Where-Object { $_ -match 'fDisabledAllowList = <absent>' }).Count -eq 1)
}

Test-Case 'snapshot info composed the way the checkpoint composes it stays one line per fact' {
    # The end-to-end shape of the checkpoint: compose, write, read the file back, one INFO per
    # line. Note what this does NOT do -- it does not fail on the comma-wrap bug. Both halves of
    # that bug have been fixed and either fix alone is enough to keep this green, so with the
    # defensive flatten in Write-MatrixReport a re-introduced comma-wrap is absorbed before it
    # reaches the file. The two tests below are the ones that fail on it; this one holds the
    # contract the report has to satisfy regardless of how it is produced.
    $f = Join-Path ([IO.Path]::GetTempPath()) ("matrix-ckpt-" + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $composed = @('header') + @(Get-MatrixSnapshotInfoLines -Snapshot (New-Snapshot -FDisabled 1 -Policy 1))
        Write-MatrixReport -Path $f -Lines $composed -Result 'FAIL checkpoint'
        $read = @([IO.File]::ReadAllLines($f))
        $infos = @($read | Where-Object { $_.StartsWith('INFO ') })
        Assert-True ($infos.Count -ge 4) "expected one line per fact, got $($infos.Count): $($read -join ' | ')"
        foreach ($line in $infos) {
            Assert-True (@([regex]::Matches($line, 'INFO ')).Count -eq 1) "two facts collapsed onto one line: $line"
        }
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

Test-Case 'Write-MatrixReport flattens a nested array rather than joining it' {
    # This is the regression test for the SECOND half of the comma-wrap fix: the defensive
    # one-level flatten inside Write-MatrixReport. Delete that flatten and this goes red -- the
    # inner array is [string]-cast whole into 'b c' and two facts land on one line.
    #
    # It feeds a hand-built nested fixture rather than a value some producer returned, and that
    # is the honest shape for it: no producer in this script nests any more (that was the first
    # half of the fix, pinned by the two composition tests below). The flatten is defence
    # against a FUTURE producer that does, so the fixture stands in for that producer.
    #
    # The nested value is built in a VARIABLE and passed by reference to it. Written inline in
    # argument position the binder stringifies the inner array before the function ever sees
    # it, so an inline version would be asserting on PowerShell's argument binding rather than
    # on this function.
    $f = Join-Path ([IO.Path]::GetTempPath()) ("matrix-ckpt-" + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        # Built element by element. Every shorthand for "an array holding an array" either
        # flattens (@('a', @('b','c')) becomes three strings) or over-nests (the unary comma
        # gives an array holding an array holding the array), and an over-nested fixture makes
        # a correct one-level flatten look broken. This is the only unambiguous spelling.
        $nested = New-Object 'object[]' 2
        $nested[0] = 'a'
        $nested[1] = @('b', 'c')
        Assert-Equal 2 $nested.Count 'the fixture must actually be nested for this to test anything'
        Assert-Equal 2 $nested[1].Count 'the inner array must hold exactly the two lines'
        Write-MatrixReport -Path $f -Lines $nested -Result 'PASS'
        $read = @([IO.File]::ReadAllLines($f))
        Assert-Equal 'a' $read[0]
        Assert-Equal 'b' $read[1]
        Assert-Equal 'c' $read[2]
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

Test-Case 'the checkpoint composition holds flat strings before Write-MatrixReport sees them' {
    # THE regression test for the comma-wrap bug, and the only call shape that can fail on it.
    #
    # Get-MatrixSnapshotInfoLines used to `return ,@(...)`. That is invisible to a direct
    # assignment -- `$lines = Get-MatrixSnapshotInfoLines ...` unrolls the outer one-element
    # array and $lines is the flat list of four strings either way. The earlier tests all
    # asserted on exactly that assignment, so not one of them could go red on the bug it was
    # written for. The nesting only appears where production actually consumes the result,
    # inside @(...), because the array subexpression does NOT unroll a second level:
    #     flat        : @(f) -> 4 strings
    #     comma-wrap  : @(f) -> 1 element, itself the array of 4
    # and `@(header) + @(f)` then concatenates that one nested element into the report.
    #
    # The expression below is Invoke-MatrixVerify's checkpoint call verbatim, minus the
    # Write-MatrixReport. Asserting BEFORE the write is the whole point: Write-MatrixReport
    # flattens defensively, so anything asserted after it absorbs this bug and goes quiet.
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add('header')
    $composed = @($L.ToArray()) + @(Get-MatrixSnapshotInfoLines -Snapshot (New-Snapshot -FDisabled 1 -Policy 1))
    Assert-Equal 5 $composed.Count 'one header plus four registry facts, all at the top level'
    foreach ($item in $composed) {
        $t = '<null>'
        if ($null -ne $item) { $t = $item.GetType().Name }
        Assert-True ($item -is [string]) `
            "every element must be a flat [string]; found [$t] -- Get-MatrixSnapshotInfoLines is comma-wrapping its result again"
    }
}

Test-Case 'the checkpoint composition grows one flat string per published application' {
    # Same composition, the populated snapshot. Pins the per-application lines into the same
    # shape guarantee rather than only their count: a count survives the comma-wrap (the outer
    # array is unrolled on assignment) but the element type does not survive the concatenation.
    $pub = New-EnforcedPublished
    $composed = @('header') +
                @(Get-MatrixSnapshotInfoLines -Snapshot (New-Snapshot -FDisabled 0 -Applications (New-RegistryApps $pub)))
    Assert-Equal 9 $composed.Count 'header plus four fixed facts plus one line per published application'
    foreach ($item in $composed) {
        $t = '<null>'
        if ($null -ne $item) { $t = $item.GetType().Name }
        Assert-True ($item -is [string]) "every element must stay a flat [string]; found [$t]"
    }
}

Test-Case 'Write-MatrixReport puts RESULT on the last line' {
    $f = Join-Path ([IO.Path]::GetTempPath()) ("matrix-ckpt-" + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        Write-MatrixReport -Path $f -Lines @('INFO a', 'INFO b') -Result 'PRECONDITION'
        $read = @([IO.File]::ReadAllLines($f))
        Assert-Equal 'RESULT: PRECONDITION' $read[$read.Count - 1]
        Assert-Equal 'INFO a' $read[0]
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

Test-Case 'a later Write-MatrixReport overwrites the earlier checkpoint entirely' {
    # The final verdict must not leave a stale checkpoint RESULT anywhere in the file: the Mac
    # side reads the LAST RESULT line, and a leftover one above it is a trap for a human eye.
    $f = Join-Path ([IO.Path]::GetTempPath()) ("matrix-ckpt-" + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        Write-MatrixReport -Path $f -Lines @('INFO snapshot') -Result 'FAIL incomplete-at-registry-snapshot -- checkpoint only'
        Write-MatrixReport -Path $f -Lines @('INFO snapshot', 'ASSERT x: PASS') -Result 'PASS'
        $text = [IO.File]::ReadAllText($f)
        Assert-True ($text -notmatch 'incomplete-at-registry-snapshot') 'the checkpoint RESULT must be gone'
        $read = @([IO.File]::ReadAllLines($f))
        Assert-Equal 'RESULT: PASS' $read[$read.Count - 1]
        Assert-Equal 1 (@($read | Where-Object { $_.StartsWith('RESULT: ') }).Count) 'exactly one RESULT line'
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

Test-Case 'a checkpoint RESULT starts with FAIL so a truncated run never reads as success' {
    # run-matrix.sh treats anything that is not exactly PASS as a failure, and a human scanning
    # the file needs the same answer. Both checkpoint strings are pinned here.
    foreach ($r in @('FAIL incomplete-at-registry-snapshot -- checkpoint only',
                     'FAIL incomplete-at-agent-start -- checkpoint only')) {
        Assert-True ($r.StartsWith('FAIL')) "a checkpoint RESULT must start with FAIL: $r"
        Assert-True ($r -ne 'PASS') 'a checkpoint RESULT must never be PASS'
    }
}

# -------------------------------------------------------------------------------------------
New-Section 'HTTP request timeout'
# -------------------------------------------------------------------------------------------

Test-Case 'a request to a socket that accepts and never answers times out on OUR bound' {
    # The reason this function is not WebClient any more. WebClient exposes no timeout and
    # inherits HttpWebRequest's ~100s default, which alone could outlast a 120s relay job. The
    # listener below accepts the connection and then says nothing, which is exactly the shape
    # of a wedged agent: only a real per-request timeout ends it.
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-MatrixRequest -Uri "http://127.0.0.1:$port/v1/apps" -Token 'x' -TimeoutSeconds 3
        $sw.Stop()
        Assert-True (-not $r.Ok) 'a black-holed request must not report success'
        Assert-True ($sw.Elapsed.TotalSeconds -lt 30) `
            "must give up on our own bound, not the ~100s default; took $([int]$sw.Elapsed.TotalSeconds)s"
        Assert-True ($r.Content -eq '') 'no content on a failed request'
    } finally {
        try { $listener.Stop() } catch { }
    }
}

Test-Case 'a real GET returns the body and never echoes the token' {
    # The only execution of the rewritten helper's SUCCESS path, so it earns the one-shot
    # server below. [PowerShell]::Create() rather than Task.Run: a thread-pool thread has no
    # PowerShell runspace attached, so a scriptblock handed to Task.Run dies with
    # "There is no Runspace available to run scripts in this thread". A PowerShell instance
    # brings its own.
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $secret = 'tok-' + [guid]::NewGuid().ToString('N')

    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        param($Listener)
        $client = $Listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $buf = New-Object 'byte[]' 4096
            [void]$stream.Read($buf, 0, $buf.Length)
            $body = '{"ok":true}'
            # Byte count, not $body.Length: the header advertises a length and the body goes out
            # as UTF-8 bytes. Equal for ASCII, so this is correct today either way -- but the
            # first non-ASCII fixture would advertise short, the client would block for bytes
            # that never arrive, and the test would fail as a TIMEOUT rather than as an encoding
            # bug. An expensive misread in a file whose whole subject is diagnosing hangs.
            $head = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $([System.Text.Encoding]::UTF8.GetByteCount($body))`r`nConnection: close`r`n`r`n"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($head + $body)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } finally {
            try { $client.Close() } catch { }
        }
    }).AddArgument($listener)
    $handle = $ps.BeginInvoke()

    try {
        $r = Invoke-MatrixRequest -Uri "http://127.0.0.1:$port/v1/apps" -Token $secret -TimeoutSeconds 10
        Assert-True $r.Ok "expected a 200; error was: $($r.Error)"
        Assert-Equal '{"ok":true}' $r.Content
        Assert-True ($r.Content -notmatch [regex]::Escape($secret)) 'the token must never come back in the result'
    } finally {
        try { [void]$handle.AsyncWaitHandle.WaitOne(5000) } catch { }
        Write-ResponderDiagnostics -PowerShellInstance $ps
        try { $ps.Dispose() } catch { }
        try { $listener.Stop() } catch { }
    }
}

Test-Case 'a refused connection fails fast and reports the reason without the token' {
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start(); $dead = $probe.LocalEndpoint.Port; $probe.Stop()
    $secret = 'tok-' + [guid]::NewGuid().ToString('N')
    $r = Invoke-MatrixRequest -Uri "http://127.0.0.1:$dead/v1/apps" -Token $secret -TimeoutSeconds 5
    Assert-True (-not $r.Ok) 'nothing is listening, so this must fail'
    Assert-True (-not [string]::IsNullOrWhiteSpace($r.Error)) 'a failure must carry a reason'
    Assert-True ($r.Error -notmatch [regex]::Escape($secret)) 'the error must never carry the bearer token'
}

# -------------------------------------------------------------------------------------------
New-Section 'HTTP error path and connection hygiene'
# -------------------------------------------------------------------------------------------

function Start-OneShotHttpResponder {
    <#
      Serves exactly ONE request with a canned status line and body, then closes the socket.

      Separate from the inline server in 'a real GET returns the body' above, which stays as it
      is: that one exists to prove the SUCCESS path and reads the request to check the token
      never comes back. This one exists to produce a protocol error, which is the only way to
      get a WebException that carries a live HttpWebResponse.

      [PowerShell]::Create() rather than Task.Run for the same reason as above: a thread-pool
      thread has no runspace and a scriptblock handed to it dies with "There is no Runspace
      available to run scripts in this thread".
    #>
    param($Listener, [int] $StatusCode, [string] $Reason, [string] $Body)

    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        param($L, $Code, $ReasonPhrase, $Payload)
        $client = $L.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $buf = New-Object 'byte[]' 4096
            [void]$stream.Read($buf, 0, $buf.Length)
            # UTF-8 byte count, not $Payload.Length -- see the note on the 200 responder above.
            # This one takes its body from a parameter, so it is the site a future caller is most
            # likely to hand something non-ASCII.
            $head = "HTTP/1.1 $Code $ReasonPhrase`r`nContent-Type: application/json`r`nContent-Length: $([System.Text.Encoding]::UTF8.GetByteCount($Payload))`r`nConnection: close`r`n`r`n"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($head + $Payload)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } finally {
            try { $client.Close() } catch { }
        }
    }).AddArgument($Listener).AddArgument($StatusCode).AddArgument($Reason).AddArgument($Body)

    return [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
}

function Test-DisposedObjectException {
    # ObjectDisposedException arrives wrapped in MethodInvocationException when it comes out of
    # a .NET call made from PowerShell, so the chain has to be walked rather than type-checked.
    param($Exception)
    $e = $Exception
    $guard = 0
    while ($null -ne $e -and $guard -lt 8) {
        if ($e -is [System.ObjectDisposedException]) { return $true }
        $e = $e.InnerException
        $guard++
    }
    return $false
}

Test-Case 'Close-MatrixErrorResponse closes the HttpWebResponse a protocol error leaves behind' {
    # The finding this closes: on a 401/500 the WebException carries a live HttpWebResponse
    # that holds one connection out of the ServicePoint pool (default limit 2) until it is
    # closed or collected. Invoke-MatrixRequest's own $response is assigned on the SUCCESS path
    # only, so its finally never sees this one and ten retries against an agent answering 401
    # would spend most of them queueing on the connection limit.
    #
    # Directly assertable, which is worth saying because it did not look it: the test captures
    # a SECOND reference to the same response before handing the exception to production, and
    # a closed HttpWebResponse answers GetResponseStream() with ObjectDisposedException. Delete
    # the .Close() from Close-MatrixErrorResponse and this goes red.
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $srv = Start-OneShotHttpResponder -Listener $listener -StatusCode 401 -Reason 'Unauthorized' -Body '{"error":"unauthorized"}'
    # Declared BEFORE the try, so the finally can always reference it. The hoist is load-bearing
    # twice over: the WebRequest::Create below runs inside the try and before $captured is
    # assigned, so a throw there would leave the finally reading an uninitialised variable and
    # raising a second StrictMode error on top of the first; and without the finally closing it,
    # a FAILING run of the connection-leak test would itself leak the connection it is about.
    $caught = $null
    $captured = $null
    try {
        # Invoke-MatrixRequest's own request setup, so the exception under test is the one
        # production would catch rather than a lookalike.
        $request = [System.Net.WebRequest]::Create("http://127.0.0.1:$port/v1/apps")
        $request.Method = 'GET'
        $request.Proxy = $null
        $request.Timeout = 10000
        $request.Headers.Add('Authorization', 'Bearer x')

        try {
            [void]$request.GetResponse()
        } catch {
            $caught = $_
            # The same walk production does. Doing it here too is deliberate: if PowerShell ever
            # stopped wrapping, both this and the production helper would have to change, and
            # the test would say so rather than silently passing on a null.
            $w = $caught.Exception
            $g = 0
            while ($null -ne $w -and $g -lt 8) {
                if ($w -is [System.Net.WebException]) { $captured = $w.Response; break }
                $w = $w.InnerException
                $g++
            }
        }

        Assert-True ($null -ne $caught) 'a 401 must throw out of GetResponse()'
        Assert-True ($null -ne $captured) 'the WebException must carry a Response for there to be anything to close'
        Assert-Equal 401 ([int]$captured.StatusCode)

        # The fixture has to start OPEN or the assertion after the call proves nothing.
        $liveBefore = $true
        try { [void]$captured.GetResponseStream() } catch { $liveBefore = $false }
        Assert-True $liveBefore 'the captured response must still be open before production touches it'

        Close-MatrixErrorResponse -Exception $caught.Exception

        $closed = $false
        try { [void]$captured.GetResponseStream() } catch { $closed = Test-DisposedObjectException -Exception $_.Exception }
        Assert-True $closed 'the response must be closed after Close-MatrixErrorResponse, or its pooled connection leaks'
    } finally {
        # Idempotent on the passing path (production already closed it) and the point of the
        # exercise on the failing one: an assertion above throwing must not leave this test
        # holding open the very connection it exists to prove gets released.
        try { if ($null -ne $captured) { $captured.Close() } } catch { }
        try { [void]$srv.Handle.AsyncWaitHandle.WaitOne(5000) } catch { }
        Write-ResponderDiagnostics -PowerShellInstance $srv.PS
        try { $srv.PS.Dispose() } catch { }
        try { $listener.Stop() } catch { }
    }
}

Test-Case 'Close-MatrixErrorResponse is a no-op on every input that carries no Response' {
    # A timeout or a refused connection sets WebException.Status and leaves Response $null, and
    # anything that is not a WebException at all never reaches the property. All of it has to be
    # silent: this runs inside a catch block, and a cleanup that throws would replace the real
    # failure with a cleanup failure in the one report the lab gets back.
    Close-MatrixErrorResponse -Exception (New-Object System.Net.WebException('timed out'))
    Close-MatrixErrorResponse -Exception (New-Object System.InvalidOperationException('not a web error'))
    Close-MatrixErrorResponse -Exception (New-Object System.InvalidOperationException('wrapped', (New-Object System.Net.WebException('inner, no response'))))
    Close-MatrixErrorResponse -Exception $null

    # The NON-exception shapes, which are the ones that make the `-is [System.Exception]` guard
    # in the walk load-bearing rather than decorative. Without it each of these reaches
    # `$e.InnerException` on something that has no such property, and under StrictMode 2.0 that
    # is a terminating error thrown from inside a catch block -- the precise failure this
    # function exists to prevent. The ErrorRecord is not a hypothetical: `-Exception $_` is the
    # natural-looking call, and $_ in a catch is an ErrorRecord, not an Exception.
    $rec = New-Object System.Management.Automation.ErrorRecord(
        (New-Object System.Net.WebException('inside an ErrorRecord')),
        'MatrixTest', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
    Close-MatrixErrorResponse -Exception $rec
    Close-MatrixErrorResponse -Exception 'a plain string'
    Close-MatrixErrorResponse -Exception 42
    Close-MatrixErrorResponse -Exception @{ Response = 'not really' }
    Assert-True $true 'reaching here without a throw is the assertion'
}

Test-Case 'a 401 keeps the error contract intact and never echoes the token' {
    # The integration half: the disposal happens inside the catch, before the return, so this
    # is what says the added call did not disturb the shape the caller depends on.
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $secret = 'tok-' + [guid]::NewGuid().ToString('N')
    $srv = Start-OneShotHttpResponder -Listener $listener -StatusCode 401 -Reason 'Unauthorized' -Body '{"error":"unauthorized"}'
    try {
        $r = Invoke-MatrixRequest -Uri "http://127.0.0.1:$port/v1/apps" -Token $secret -TimeoutSeconds 10
        Assert-True (-not $r.Ok) 'a 401 is not a successful read of /v1/apps'
        Assert-Equal '' $r.Content 'no content on a failed request'
        Assert-True (-not [string]::IsNullOrWhiteSpace($r.Error)) 'a failure must carry a reason'
        Assert-True ($r.Error -match '401') "the reason must name the status; got: $($r.Error)"
        Assert-True ($r.Error -notmatch [regex]::Escape($secret)) 'the error must never carry the bearer token'
    } finally {
        try { [void]$srv.Handle.AsyncWaitHandle.WaitOne(5000) } catch { }
        Write-ResponderDiagnostics -PowerShellInstance $srv.PS
        try { $srv.PS.Dispose() } catch { }
        try { $listener.Stop() } catch { }
    }
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
