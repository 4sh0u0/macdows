<#
.SYNOPSIS
    TSAppAllowList enforced-mode acceptance, run on the host by the lab relay.

.DESCRIPTION
    READ-ONLY with respect to host state. Runs as the standard lab account inside the RDP
    session (jobs/matrix-verify.env -> powershell.exe -File \\tsclient\lab\...). It never
    writes to HKLM and never elevates; the account cannot anyway.

    What it does:
      1. Snapshots the TSAppAllowList registry state (fDisabledAllowList, the two
         fAllowUnlistedRemotePrograms hives, and every Applications\* key).
      2. Copies the host-agent out of \\tsclient\lab\host-agent into %TEMP%, writes a
         throwaway allowlist.json naming the four published programs plus charmap.exe (the
         negative control, deliberately NOT published), and starts the agent on loopback with
         a random port and a token file inside that same temp directory.
      3. GETs /v1/apps with the bearer token and checks the agent's view against the registry.
      4. Stops the agent, deletes the temp directory, and writes the report back over the
         redirected drive. The last line is always RESULT: PASS | FAIL | PRECONDITION.

    The report is written THREE times, each write overwriting the last: a checkpoint after the
    registry snapshot, a second after the agent is up, and the real verdict at the end. The
    share only exists while the relay holds the connection, so a job that overruns its TIMEOUT
    is killed with whatever was last written still on the drive. Writing once at the end meant
    an overrun produced no file at all -- "no report" and no way to tell how far it got.

    Footprint on the host: %TEMP%\macdows-matrix-agent and the agent process it starts.
    Both are cleaned up by this script's own finally block on every path it controls. The one
    path it does not control is the relay closing the connection first (job TIMEOUT): the
    session is torn down mid-run, the finally never executes, and the temp directory is left
    behind along with a possibly still-running agent. Both are transient -- the next run
    deletes the directory before staging, and the agent dies with the session -- but "nothing
    left behind" is only true of a run that finishes.

    PRECONDITION is the expected, successful outcome while fDisabledAllowList is 1: the
    allow list is not enforced, so there is no enforced-mode behaviour to accept yet. Putting
    the host into enforced mode is Set-TsAllowListMatrix.ps1 -Mode Enforce, which needs an
    elevated console and is therefore an owner-manual step.

    Windows PowerShell 5.1 notes that shaped this file:
      * `curl` is an alias for Invoke-WebRequest, so the HTTP call goes through
        System.Net.WebClient (the same choice Tools/host-agent/probe.ps1 makes).
      * `Get-Content -Raw` on a zero-byte file yields AutomationNull rather than '', and a
        [string] cast does not convert it. The token is read with [IO.File]::ReadAllText,
        which sidesteps that entirely and returns '' for an empty file.
      * `Start-Process -PassThru` only reports ExitCode/HasExited while the returned handle is
        still held, so $proc stays in scope for the whole run.
      * A .NET method that throws arrives in `catch` wrapped in MethodInvocationException, so
        the original exception is one InnerException down. `$_.Exception.Response` after a
        failed GetResponse() therefore does not exist -- and under StrictMode reading it is a
        terminating error inside the handler meant to report the first one. See
        Close-MatrixErrorResponse.
      * No PowerShell 7 syntax: no ??, no ternary, no -Parallel.

.PARAMETER NoRun
    Define the functions but do not touch the host. Used by tsallowlist-matrix-verify.Tests.ps1
    to dot-source the decision logic and drive it with fixtures on macOS.
#>

[CmdletBinding()]
param(
    [string] $SharePath = '\\tsclient\lab',
    [string] $OutPath = '\\tsclient\lab\tsallowlist-matrix-out.txt',
    [int] $StartupTimeoutSeconds = 40,
    # Aggregate wall clock for the /v1/apps call including retries, checked between attempts.
    # Each individual request additionally carries its own hard timeout (see
    # Invoke-MatrixRequest), which is what actually stops a wedged request -- the aggregate
    # bound alone cannot interrupt a call already in flight. Both together keep the HTTP phase
    # well inside the relay job's TIMEOUT, so a stuck agent still leaves a report behind
    # rather than a killed session.
    [int] $HttpTimeoutSeconds = 30,
    [switch] $NoRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# The four programs Set-TsAllowListMatrix.ps1 -Mode Enforce publishes. charmap.exe is
# deliberately absent from that set: it is the negative control that must come back
# RAIL_EXEC_E_NOT_IN_ALLOWLIST over RAIL and inTsAllowList=false through /v1/apps.
$script:MatrixExpectedPublished = @('winver', 'logoff', 'notepad', 'powershell')

# Every id written into the throwaway allowlist.json.
$script:MatrixAllowlistIds = @('winver', 'logoff', 'notepad', 'powershell', 'charmap')

# ids expected to survive the agent's own load-time validation. 'powershell' is expected to be
# REJECTED: MacdowsHostAgent.ps1 refuses shells and script hosts by basename, which is the
# property the prototype exists to demonstrate. Its rejection is reported as INFO, not FAIL --
# but it still belongs in the file, because a run where powershell was silently *accepted*
# would be a real regression and this is where it would show up.
$script:MatrixExpectedAllowlistIds = @('winver', 'logoff', 'notepad', 'charmap')
$script:MatrixExpectedRejectedIds = @('powershell')

# -------------------------------------------------------------------------------------------
# Pure helpers (no host state; exercised off-Windows by the test suite)
# -------------------------------------------------------------------------------------------

function Get-MatrixProp {
    <#
      StrictMode-safe property read that works for both [pscustomobject] (what
      ConvertFrom-Json hands back) and [hashtable] (what the fixtures find convenient).
      Returns -Default when the member is absent rather than throwing.
    #>
    [CmdletBinding()]
    param($Object, [string] $Name, $Default = $null)

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    try {
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $Default }
        return $prop.Value
    } catch {
        return $Default
    }
}

function Expand-MatrixToken {
    <#
      Case-insensitive literal token substitution. The iteration cap is there because a -Value
      that itself contains -Token would otherwise loop forever; no caller does that, and the
      cap means a future one gets a wrong answer instead of a hang.
    #>
    [CmdletBinding()]
    param([string] $Text, [string] $Token, [string] $Value)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $guard = 0
    $idx = $Text.IndexOf($Token, [System.StringComparison]::OrdinalIgnoreCase)
    while ($idx -ge 0 -and $guard -lt 16) {
        $Text = $Text.Substring(0, $idx) + $Value + $Text.Substring($idx + $Token.Length)
        $guard++
        $idx = $Text.IndexOf($Token, [System.StringComparison]::OrdinalIgnoreCase)
    }
    return $Text
}

function ConvertTo-MatrixComparablePath {
    <#
      Normalises a Windows path for equality comparison: strips quotes/whitespace, resolves
      %SystemRoot% and %windir% against the supplied root, unifies separators, collapses
      repeats (keeping a leading UNC '\\'), drops a trailing separator, lower-cases.

      Deliberately an INDEPENDENT reimplementation of the agent's own
      ConvertTo-MacdowsComparablePath rather than a call into it. This script exists to check
      the agent's inTsAllowList answer; reusing the agent's normaliser would make a bug in
      that normaliser invisible to exactly the assertion meant to catch it.
    #>
    [CmdletBinding()]
    param([string] $Path, [string] $SystemRoot)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $result = $Path.Trim().Trim('"').Trim()

    $root = ''
    if (-not [string]::IsNullOrWhiteSpace($SystemRoot)) { $root = $SystemRoot.TrimEnd('\', '/') }
    if (-not [string]::IsNullOrEmpty($root)) {
        $result = Expand-MatrixToken -Text $result -Token '%SystemRoot%' -Value $root
        $result = Expand-MatrixToken -Text $result -Token '%windir%' -Value $root
    }

    $result = $result.Replace('/', '\')
    $isUnc = $result.StartsWith('\\')
    while ($result.Contains('\\')) { $result = $result.Replace('\\', '\') }
    if ($isUnc) { $result = '\' + $result }
    if ($result.Length -gt 1) { $result = $result.TrimEnd('\') }
    return $result.ToLowerInvariant()
}

function ConvertTo-MatrixArray {
    <#
      Coerces a value into an array with no null elements.

      Needed because @($null) is an array of length ONE, not zero: a JSON null where a list was
      expected, or a null slot inside a list, would otherwise be counted as a real entry and
      fail an emptiness or set-equality check for a reason that has nothing to do with the host.
    #>
    [CmdletBinding()]
    param($Value)
    # `return ,$x` throughout: a bare `return @()` emits NO objects, so the caller's variable
    # ends up $null and reading .Count on it is a terminating error under StrictMode. The comma
    # wraps the array in a one-element outer array, which the output pipeline unrolls back into
    # the array itself -- the standard way to return an array from PowerShell intact.
    if ($null -eq $Value) { return , @() }
    return , @(@($Value) | Where-Object { $null -ne $_ })
}

function New-MatrixSink {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        Lines    = (New-Object System.Collections.ArrayList)
        Failures = 0
    }
}

function Add-MatrixInfo {
    [CmdletBinding()]
    param($Sink, [string] $Text)
    [void]$Sink.Lines.Add("INFO $Text")
}

function Add-MatrixAssert {
    <#
      One assertion, one line: "ASSERT <name>: PASS|FAIL <detail>". The detail is written for
      both outcomes so a PASS line still carries the evidence it passed on.
    #>
    [CmdletBinding()]
    param($Sink, [string] $Name, [bool] $Ok, [string] $Detail = '')

    $verdict = 'FAIL'
    if ($Ok) { $verdict = 'PASS' }
    [void]$Sink.Lines.Add(("ASSERT {0}: {1} {2}" -f $Name, $verdict, $Detail).TrimEnd())
    if (-not $Ok) { $Sink.Failures = $Sink.Failures + 1 }
}

function Format-MatrixSet {
    [CmdletBinding()]
    param($Items)
    $arr = @($Items | Where-Object { $null -ne $_ -and "$_" -ne '' } | Sort-Object)
    if ($arr.Count -eq 0) { return '{}' }
    return '{' + ($arr -join ',') + '}'
}

function Get-MatrixSnapshotInfoLines {
    <#
      The registry snapshot rendered as INFO lines.

      Shared by Get-MatrixVerdict and by the post-snapshot checkpoint write, so a run killed by
      a relay timeout still leaves the registry state on the drive -- that is the half of the
      evidence the lab cannot re-read without spending another connection.
    #>
    [CmdletBinding()]
    param($Snapshot)

    $fd = Get-MatrixProp -Object $Snapshot -Name 'fDisabledAllowList'
    $pol = Get-MatrixProp -Object $Snapshot -Name 'policyAllowUnlisted'
    $tsh = Get-MatrixProp -Object $Snapshot -Name 'tsAllowUnlisted'
    $regApps = ConvertTo-MatrixArray (Get-MatrixProp -Object $Snapshot -Name 'applications')

    $fdText = '<absent>'
    if ($null -ne $fd) { $fdText = "$fd" }
    $polText = '<absent>'
    if ($null -ne $pol) { $polText = "$pol" }
    $tsText = '<absent>'
    if ($null -ne $tsh) { $tsText = "$tsh" }

    $out = New-Object System.Collections.ArrayList
    [void]$out.Add("INFO registry fDisabledAllowList = $fdText")
    [void]$out.Add("INFO registry Policies\...\Terminal Services\fAllowUnlistedRemotePrograms = $polText")
    [void]$out.Add("INFO registry ...\Terminal Server\fAllowUnlistedRemotePrograms = $tsText")
    [void]$out.Add("INFO registry Applications keys = " + (Format-MatrixSet ($regApps | ForEach-Object { Get-MatrixProp -Object $_ -Name 'key' })))
    foreach ($ra in $regApps) {
        $rk = Get-MatrixProp -Object $ra -Name 'key'
        $rn = Get-MatrixProp -Object $ra -Name 'name'
        $rp = Get-MatrixProp -Object $ra -Name 'path'
        $rc = Get-MatrixProp -Object $ra -Name 'commandLineSetting'
        [void]$out.Add("INFO   registry [$rk] Name=$rn Path=$rp CommandLineSetting=$rc")
    }
    # No comma-wrap here, unlike ConvertTo-MatrixArray. This result is composed by callers as
    # @(...) + @(Get-MatrixSnapshotInfoLines ...), and the comma's extra nesting level survives
    # that concatenation: the whole array arrives as ONE element and gets [string]-cast into a
    # single space-joined line. This list is never empty (four lines minimum), so there is no
    # empty-unrolls-to-null hazard to protect against.
    return @($out.ToArray())
}

function Get-MatrixVerdict {
    <#
      THE decision function. Input is a registry snapshot object plus a parsed /v1/apps
      response object; output is the assertion lines and the RESULT word. No I/O, no registry,
      no clock -- so the whole acceptance judgement is testable off-Windows.

      RESULT precedence:
        * fDisabledAllowList == 0 (enforced)  -> PASS when every assertion passed, else FAIL.
        * anything else (1, or the value absent) -> PRECONDITION when every assertion passed,
          FAIL when one did not. "Not enforced" is a precondition that has not been met yet,
          not a failure; but a genuine inconsistency observed while not enforced -- the agent
          disagreeing with the registry, or applications published under a disabled allow
          list -- is still a failure and must not be laundered into PRECONDITION.
    #>
    [CmdletBinding()]
    param(
        $Snapshot,
        $Apps,
        [string] $SystemRoot = 'C:\Windows',
        [string[]] $ExpectedPublished = $script:MatrixExpectedPublished,
        [string[]] $ExpectedAllowlistIds = $script:MatrixExpectedAllowlistIds,
        [string[]] $ExpectedRejectedIds = $script:MatrixExpectedRejectedIds
    )

    $sink = New-MatrixSink

    # ---- inputs, restated in the report so a reader never has to guess what was judged -----
    $fd = Get-MatrixProp -Object $Snapshot -Name 'fDisabledAllowList'
    $polPolicyHive = Get-MatrixProp -Object $Snapshot -Name 'policyAllowUnlisted'
    $polTsHive = Get-MatrixProp -Object $Snapshot -Name 'tsAllowUnlisted'
    $regApps = ConvertTo-MatrixArray (Get-MatrixProp -Object $Snapshot -Name 'applications')

    $fdText = '<absent>'
    if ($null -ne $fd) { $fdText = "$fd" }
    $polText = '<absent>'
    if ($null -ne $polPolicyHive) { $polText = "$polPolicyHive" }
    $tsText = '<absent>'
    if ($null -ne $polTsHive) { $tsText = "$polTsHive" }

    foreach ($line in (Get-MatrixSnapshotInfoLines -Snapshot $Snapshot)) { [void]$sink.Lines.Add($line) }

    $published = ConvertTo-MatrixArray (Get-MatrixProp -Object $Apps -Name 'published')
    $agentList = ConvertTo-MatrixArray (Get-MatrixProp -Object $Apps -Name 'agentAllowlist')
    $agentTsDisabled = Get-MatrixProp -Object $Apps -Name 'tsAllowListDisabled'

    $agentTsText = '<null>'
    if ($null -ne $agentTsDisabled) { $agentTsText = "$agentTsDisabled" }
    Add-MatrixInfo -Sink $sink -Text "/v1/apps tsAllowListDisabled = $agentTsText"
    Add-MatrixInfo -Sink $sink -Text ("/v1/apps published names = " + (Format-MatrixSet ($published | ForEach-Object { Get-MatrixProp -Object $_ -Name 'name' })))
    Add-MatrixInfo -Sink $sink -Text ("/v1/apps agentAllowlist ids = " + (Format-MatrixSet ($agentList | ForEach-Object { Get-MatrixProp -Object $_ -Name 'id' })))

    # ---- assertion 1: the agent's view of the flag matches the registry --------------------
    # Get-MacdowsTsAllowListDisabled returns $null when the key/value is absent and
    # [bool][int] of the value otherwise, so the expected value is derived the same way.
    $expectedTsDisabled = $null
    if ($null -ne $fd) { $expectedTsDisabled = [bool][int]$fd }
    $expectedText = '<null>'
    if ($null -ne $expectedTsDisabled) { $expectedText = "$expectedTsDisabled" }
    $tsMatches = ($null -eq $expectedTsDisabled -and $null -eq $agentTsDisabled) -or
                 ($null -ne $expectedTsDisabled -and $null -ne $agentTsDisabled -and
                  ([bool]$expectedTsDisabled) -eq ([bool]$agentTsDisabled))
    Add-MatrixAssert -Sink $sink -Name 'tsAllowListDisabled-matches-registry' -Ok $tsMatches `
        -Detail "agent=$agentTsText registry-derived=$expectedText (fDisabledAllowList=$fdText)"

    $enforced = ($null -ne $fd -and [int]$fd -eq 0)

    if (-not $enforced) {
        # ---- not-enforced branch: the only thing to check is that nothing is published ------
        $publishedNames = @($published | ForEach-Object { Get-MatrixProp -Object $_ -Name 'name' })
        Add-MatrixAssert -Sink $sink -Name 'published-empty-while-allowlist-disabled' `
            -Ok ($published.Count -eq 0) `
            -Detail ("count=$($published.Count) names=" + (Format-MatrixSet $publishedNames))

        Add-MatrixInfo -Sink $sink -Text 'allow list is NOT enforced -- enforced-mode assertions were not evaluated'
        Add-MatrixInfo -Sink $sink -Text 'to enforce: run Set-TsAllowListMatrix.ps1 -Mode Enforce from an ELEVATED console on the host'

        $result = 'PRECONDITION'
        if ($sink.Failures -gt 0) { $result = 'FAIL' }
        return [pscustomobject]@{ Lines = @($sink.Lines.ToArray()); Result = $result; Failures = $sink.Failures }
    }

    # ---- enforced branch -------------------------------------------------------------------

    # 2: exactly four published applications.
    Add-MatrixAssert -Sink $sink -Name 'published-count-is-4' -Ok ($published.Count -eq 4) `
        -Detail "count=$($published.Count)"

    # 3: the published NAME set equals the expected set, compared in both directions. A
    # one-directional check passes a superset, which is precisely the state (an extra
    # publication left over from an earlier run) that would make the negative control lie.
    $publishedNames = @($published | ForEach-Object { Get-MatrixProp -Object $_ -Name 'name' } |
        Where-Object { $null -ne $_ -and "$_" -ne '' })
    $missing = @($ExpectedPublished | Where-Object { $publishedNames -notcontains $_ })
    $unexpected = @($publishedNames | Where-Object { $ExpectedPublished -notcontains $_ })
    Add-MatrixAssert -Sink $sink -Name 'published-name-set-equals-expected' `
        -Ok ($missing.Count -eq 0 -and $unexpected.Count -eq 0) `
        -Detail ("expected=" + (Format-MatrixSet $ExpectedPublished) +
                 " actual=" + (Format-MatrixSet $publishedNames) +
                 " missing=" + (Format-MatrixSet $missing) +
                 " unexpected=" + (Format-MatrixSet $unexpected))

    # 4: the registry snapshot this script read and the set the agent enumerated agree. They
    # are two independent reads of the same key; a disagreement means one of them is wrong.
    $regKeys = @($regApps | ForEach-Object { Get-MatrixProp -Object $_ -Name 'key' } |
        Where-Object { $null -ne $_ -and "$_" -ne '' })
    $agentKeys = @($published | ForEach-Object { Get-MatrixProp -Object $_ -Name 'key' } |
        Where-Object { $null -ne $_ -and "$_" -ne '' })
    $regOnly = @($regKeys | Where-Object { $agentKeys -notcontains $_ })
    $agentOnly = @($agentKeys | Where-Object { $regKeys -notcontains $_ })
    Add-MatrixAssert -Sink $sink -Name 'registry-and-agent-published-agree' `
        -Ok ($regOnly.Count -eq 0 -and $agentOnly.Count -eq 0) `
        -Detail ("registry=" + (Format-MatrixSet $regKeys) + " agent=" + (Format-MatrixSet $agentKeys) +
                 " registry-only=" + (Format-MatrixSet $regOnly) + " agent-only=" + (Format-MatrixSet $agentOnly))

    # 5: positive control. This script reached the host as a RemoteApp launched through
    # powershell.exe WITH arguments, so the run existing at all already proves the positive
    # side. The registry assertion below is the static half of the same claim: powershell must
    # be published with CommandLineSetting=1 (any command line allowed), or a future run with
    # different arguments would be refused for a reason unrelated to the allow list.
    $psEntry = @($published | Where-Object { (Get-MatrixProp -Object $_ -Name 'name') -eq 'powershell' })
    $psCls = $null
    if ($psEntry.Count -gt 0) { $psCls = Get-MatrixProp -Object $psEntry[0] -Name 'commandLineSetting' }
    $psClsText = '<absent>'
    if ($null -ne $psCls) { $psClsText = "$psCls" }
    Add-MatrixAssert -Sink $sink -Name 'positive-control-powershell-published-cls1' `
        -Ok ($psEntry.Count -eq 1 -and $null -ne $psCls -and [int]$psCls -eq 1) `
        -Detail "entries=$($psEntry.Count) commandLineSetting=$psClsText (this script ran as that RemoteApp)"

    # 6: the policy twin. fDisabledAllowList=0 alone does not enforce anything if
    # fAllowUnlistedRemotePrograms is 1 -- the door stays open and the negative control would
    # launch. Set-TsAllowListMatrix.ps1 -Mode Enforce closes it; this is the read-back.
    $polOpen = @()
    if ($null -ne $polPolicyHive -and [int]$polPolicyHive -eq 1) { $polOpen += 'Policies-hive' }
    if ($null -ne $polTsHive -and [int]$polTsHive -eq 1) { $polOpen += 'TerminalServer-hive' }
    Add-MatrixAssert -Sink $sink -Name 'policy-fAllowUnlistedRemotePrograms-closed' `
        -Ok ($polOpen.Count -eq 0) `
        -Detail ("policies-hive=$polText terminal-server-hive=$tsText open=" + (Format-MatrixSet $polOpen))

    # 7: the agent loaded the allowlist entries we expect it to load.
    $agentIds = @($agentList | ForEach-Object { Get-MatrixProp -Object $_ -Name 'id' } |
        Where-Object { $null -ne $_ -and "$_" -ne '' })
    $idsMissing = @($ExpectedAllowlistIds | Where-Object { $agentIds -notcontains $_ })
    # Both directions. A one-directional "everything expected is present" check passes an agent
    # that also loaded something nobody put in the file. The known-rejected ids are excluded
    # from 'unexpected' on purpose: agent-allowlist-rejects-<id> below already reports those,
    # and one fact surfacing as two failures makes triage worse, not better.
    $idsUnexpected = @($agentIds | Where-Object {
        $ExpectedAllowlistIds -notcontains $_ -and $ExpectedRejectedIds -notcontains $_ })
    Add-MatrixAssert -Sink $sink -Name 'agent-allowlist-loaded-expected-ids' `
        -Ok ($idsMissing.Count -eq 0 -and $idsUnexpected.Count -eq 0) `
        -Detail ("expected=" + (Format-MatrixSet $ExpectedAllowlistIds) +
                 " actual=" + (Format-MatrixSet $agentIds) +
                 " missing=" + (Format-MatrixSet $idsMissing) +
                 " unexpected=" + (Format-MatrixSet $idsUnexpected))

    foreach ($rejected in $ExpectedRejectedIds) {
        if ($agentIds -contains $rejected) {
            Add-MatrixAssert -Sink $sink -Name "agent-allowlist-rejects-$rejected" -Ok $false `
                -Detail "'$rejected' was accepted; the agent must refuse shells and script hosts"
        } else {
            Add-MatrixInfo -Sink $sink -Text "agent rejected allowlist id '$rejected' as expected (interpreter deny-list)"
        }
    }

    # 8: the whole point -- inTsAllowList for each loaded entry must equal "this entry's
    # program is in the published set", compared on normalised paths (the registry side
    # commonly still carries %SystemRoot%, the allowlist side was expanded at load).
    $publishedPaths = @{}
    foreach ($p in $published) {
        $np = ConvertTo-MatrixComparablePath -Path ([string](Get-MatrixProp -Object $p -Name 'path')) -SystemRoot $SystemRoot
        if (-not [string]::IsNullOrWhiteSpace($np)) { $publishedPaths[$np] = $true }
    }
    foreach ($entry in $agentList) {
        $id = [string](Get-MatrixProp -Object $entry -Name 'id')
        $rawPath = [string](Get-MatrixProp -Object $entry -Name 'path')
        $reported = Get-MatrixProp -Object $entry -Name 'inTsAllowList'
        $np = ConvertTo-MatrixComparablePath -Path $rawPath -SystemRoot $SystemRoot
        $expected = $publishedPaths.ContainsKey($np)
        $reportedBool = $false
        if ($null -ne $reported) { $reportedBool = [bool]$reported }
        Add-MatrixAssert -Sink $sink -Name "inTsAllowList[$id]" -Ok ($reportedBool -eq $expected) `
            -Detail "reported=$reportedBool expected=$expected path=$rawPath"
    }

    # 9: the negative control, stated on its own so it cannot be lost among the per-entry
    # lines. charmap must be loaded AND must report inTsAllowList=false.
    $charmap = @($agentList | Where-Object { (Get-MatrixProp -Object $_ -Name 'id') -eq 'charmap' })
    $charmapOk = $false
    $charmapDetail = 'charmap is not in the agent allowlist at all'
    if ($charmap.Count -eq 1) {
        $cv = Get-MatrixProp -Object $charmap[0] -Name 'inTsAllowList'
        $cvBool = $false
        if ($null -ne $cv) { $cvBool = [bool]$cv }
        $charmapOk = (-not $cvBool)
        $charmapDetail = "inTsAllowList=$cvBool (must be False -- charmap is deliberately unpublished)"
    } elseif ($charmap.Count -gt 1) {
        $charmapDetail = "charmap appears $($charmap.Count) times in the agent allowlist"
    }
    Add-MatrixAssert -Sink $sink -Name 'negative-control-charmap-not-published' -Ok $charmapOk -Detail $charmapDetail

    $result = 'PASS'
    if ($sink.Failures -gt 0) { $result = 'FAIL' }
    return [pscustomobject]@{ Lines = @($sink.Lines.ToArray()); Result = $result; Failures = $sink.Failures }
}

# -------------------------------------------------------------------------------------------
# Host-side collection (Windows only; never reached under -NoRun)
# -------------------------------------------------------------------------------------------

function Write-MatrixReport {
    <#
      Writes the report, last line "RESULT: <word>". Called more than once per run -- each call
      overwrites the previous file.

      Why overwrite rather than append once at the end: the report lands on \\tsclient\lab,
      which exists only while the relay holds the RDP connection. When a job overruns its
      TIMEOUT the relay kills xfreerdp, the drive goes away mid-run and this script's finally
      never executes. A single end-of-run write therefore produced NO file at all on exactly
      the runs worth diagnosing. Checkpointing means the drive always holds the furthest point
      the run reached, and a completed run overwrites it with the real verdict.
    #>
    [CmdletBinding()]
    param([string] $Path, $Lines, [string] $Result)

    # Flattened one level rather than [string]-casting each element blindly. A nested array
    # would otherwise be cast whole, joining every line it holds into one space-separated
    # line -- silent, and only visible in a report nobody re-reads until it matters.
    $all = New-Object System.Collections.ArrayList
    foreach ($item in @($Lines)) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) { [void]$all.Add($item); continue }
        if ($item -is [System.Collections.IEnumerable]) {
            foreach ($inner in $item) { [void]$all.Add([string]$inner) }
            continue
        }
        [void]$all.Add([string]$item)
    }
    [void]$all.Add('')
    [void]$all.Add("RESULT: $Result")
    [IO.File]::WriteAllLines($Path, [string[]]@($all.ToArray()))
}

function Get-MatrixRegistryValue {
    [CmdletBinding()]
    param([string] $Key, [string] $Name)
    if (-not (Test-Path -LiteralPath $Key)) { return $null }
    $props = Get-ItemProperty -LiteralPath $Key -ErrorAction SilentlyContinue
    if ($null -eq $props) { return $null }
    if (($props.PSObject.Properties.Name) -notcontains $Name) { return $null }
    return $props.$Name
}

function Get-MatrixRegistrySnapshot {
    <#
      Read-only snapshot of everything the verdict depends on. Independent of the agent: this
      is the side of the comparison the agent is being checked against.
    #>
    [CmdletBinding()]
    param()

    $base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList'
    $apps = Join-Path $base 'Applications'

    $entries = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $apps) {
        foreach ($k in @(Get-ChildItem -LiteralPath $apps -ErrorAction SilentlyContinue)) {
            [void]$entries.Add([pscustomobject]@{
                key                = $k.PSChildName
                name               = $k.GetValue('Name', $null)
                path               = $k.GetValue('Path', $null)
                commandLineSetting = $k.GetValue('CommandLineSetting', $null)
            })
        }
    }

    return [pscustomobject]@{
        fDisabledAllowList  = (Get-MatrixRegistryValue -Key $base -Name 'fDisabledAllowList')
        policyAllowUnlisted = (Get-MatrixRegistryValue -Key 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fAllowUnlistedRemotePrograms')
        tsAllowUnlisted     = (Get-MatrixRegistryValue -Key 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server' -Name 'fAllowUnlistedRemotePrograms')
        applications        = @($entries.ToArray())
    }
}

function Join-MatrixPath {
    <#
      Pure string join with a backslash. NOT Join-Path: that cmdlet resolves the leading
      element as a PSDrive, so Join-Path 'C:\Windows' 'System32' throws "Cannot find drive" on
      macOS -- which would put the allowlist builder out of reach of the test suite for no
      reason. Nothing here needs a provider; it needs two strings and a separator.
    #>
    [CmdletBinding()]
    param([string] $Parent, [string] $Child)
    return ($Parent.TrimEnd('\', '/') + '\' + $Child.TrimStart('\', '/'))
}

function New-MatrixAllowlistJson {
    <#
      The throwaway agent allowlist: the four published programs by FULL path plus charmap.
      Hand-built rather than ConvertTo-Json because 5.1's serialiser collapses a one-element
      array and its -Depth default has bitten this repo before; the shape here is fixed and
      three lines of string building is easier to be sure about than the serialiser's mood.
    #>
    [CmdletBinding()]
    param([string] $SystemRoot)

    $sys32 = Join-MatrixPath -Parent $SystemRoot -Child 'System32'
    $specs = @(
        @{ id = 'winver';     path = (Join-MatrixPath -Parent $sys32 -Child 'winver.exe') }
        @{ id = 'logoff';     path = (Join-MatrixPath -Parent $sys32 -Child 'logoff.exe') }
        @{ id = 'notepad';    path = (Join-MatrixPath -Parent $sys32 -Child 'notepad.exe') }
        @{ id = 'powershell'; path = (Join-MatrixPath -Parent $sys32 -Child 'WindowsPowerShell\v1.0\powershell.exe') }
        @{ id = 'charmap';    path = (Join-MatrixPath -Parent $sys32 -Child 'charmap.exe') }
    )
    $parts = New-Object System.Collections.ArrayList
    foreach ($s in $specs) {
        # String.Replace, not -replace: the regex operator would take the replacement string's
        # backslashes as escapes and the JSON would come out wrong.
        $escaped = ([string]$s.path).Replace('\', '\\')
        [void]$parts.Add('{"id":"' + $s.id + '","name":"' + $s.id + '","path":"' + $escaped + '","args":[]}')
    }
    return '{"entries":[' + (($parts.ToArray()) -join ',') + ']}'
}

function New-MatrixAgentArgumentList {
    <#
      Builds the argument list handed to Start-Process for the agent.

      Every path is pre-quoted here rather than left to the caller. Start-Process joins
      -ArgumentList with single spaces into ONE command line, so an unquoted
      C:\Users\First Last\... would arrive at the agent as two arguments and -File would be
      given a truncated path. Pure and separate from the launch so the quoting is testable
      off-Windows (see the argv preflight in the test suite).
    #>
    [CmdletBinding()]
    param(
        [string] $AgentScript,
        [string] $AllowlistPath,
        [string] $TokenPath,
        [int] $Port,
        [string] $BindAddress = '127.0.0.1'
    )

    return @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $AgentScript + '"'),
        '-BindAddress', $BindAddress,
        '-Port', "$Port",
        '-AllowlistPath', ('"' + $AllowlistPath + '"'),
        '-TokenPath', ('"' + $TokenPath + '"')
    )
}

function Get-MatrixFreePort {
    [CmdletBinding()]
    param()
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = $probe.LocalEndpoint.Port
    $probe.Stop()
    return $port
}

function Close-MatrixErrorResponse {
    <#
      Closes the HttpWebResponse that a failed request leaves hanging off its WebException.

      Why this is needed at all: on a PROTOCOL error -- 401, 500, anything with a status line --
      HttpWebRequest.GetResponse() throws, and the WebException it throws carries a live
      HttpWebResponse. That response holds one connection out of the ServicePoint pool until it
      is closed or the GC gets to it, and the pool's default limit is 2. Invoke-MatrixRequest
      retries up to ten times; three of those against an agent answering 401 and the remaining
      attempts would be queueing on the connection limit rather than talking to the agent, which
      reads back as "the agent stopped responding" and is not that at all. Nothing else closes
      it: Invoke-MatrixRequest's own $response is assigned on the SUCCESS path only, so on this
      path its finally has nothing to work with.

      Two things make the lookup less obvious than it looks:

        * The exception a catch block sees is NOT the WebException. PowerShell wraps a throwing
          .NET method call in MethodInvocationException, so `$_.Exception.Response` does not
          exist -- and under StrictMode reading an absent property is itself a terminating
          error, raised inside the handler that was supposed to report the original failure.
          The WebException is one InnerException down. Hence the walk.
        * Only a protocol error carries a Response. A timeout or a refused connection sets
          WebException.Status and leaves Response $null, hence the guard.

      Close() rather than Dispose(): identical effect (WebResponse.Dispose disposes by calling
      Close), public since .NET 1.1 so there is no framework-version question on the host, and
      it is the same idiom the success path already uses. Wrapped in try/catch because a
      cleanup that throws would replace the real error with a cleanup error.
    #>
    [CmdletBinding()]
    param($Exception)

    $e = $Exception
    # An InnerException chain cannot be cyclic, so the cap is belt and braces -- but a bounded
    # walk cannot hang whatever a future caller hands in.
    $guard = 0
    # `-is [System.Exception]` is load-bearing, not decoration. The walk below dereferences
    # .InnerException, and under StrictMode reading that off something which is not an exception
    # is a terminating error -- raised inside a catch block, which is the exact failure class
    # this function exists to prevent. The parameter is untyped and named -Exception, so
    # `-Exception $_` reads as the natural call and $_ in a catch is an ErrorRecord, which has
    # no InnerException. Typing the parameter would not help: a binding failure throws at the
    # call site, still inside the catch. Guarding here makes "never throws" structural rather
    # than dependent on every caller passing $_.Exception. NOTE the trade: a caller who passes
    # the ErrorRecord gets a silent no-op (a leak) instead of an error. The one call site passes
    # $_.Exception and is pinned by the tests; a second call site should unwrap before calling.
    while ($null -ne $e -and $e -is [System.Exception] -and $guard -lt 8) {
        if ($e -is [System.Net.WebException]) {
            $resp = $e.Response
            if ($null -ne $resp) { try { $resp.Close() } catch { } }
            return
        }
        $e = $e.InnerException
        $guard++
    }
}

function Invoke-MatrixRequest {
    <#
      One GET with a real per-request timeout.

      NOT `curl`: in Windows PowerShell 5.1 that name is an alias for Invoke-WebRequest, which
      takes entirely different parameters.

      NOT WebClient either, which is what this used to be. WebClient exposes no timeout: it
      inherits HttpWebRequest's ~100 second default, so a single wedged request could burn
      most of a 120 second relay job on its own and the caller's aggregate deadline -- only
      consulted BETWEEN attempts -- would never get a turn to stop it. The outcome was the one
      the deadline existed to prevent: the session killed mid-request, no report.

      HttpWebRequest directly, rather than a WebClient subclass overriding GetWebRequest: the
      subclass needs Add-Type to compile C# on the host, and adding a compile step (and its
      failure modes) to buy back a property this class already exposes is a poor trade.
      Everything used here is .NET Framework 4.8 / PowerShell 5.1 native.

      Proxy is disabled outright: a configured system proxy must never sit between us and
      127.0.0.1.
    #>
    [CmdletBinding()]
    param([string] $Uri, [string] $Token, [int] $TimeoutSeconds = 15)

    $response = $null
    try {
        $request = [System.Net.WebRequest]::Create($Uri)
        $request.Method = 'GET'
        $request.Proxy = $null
        $request.Timeout = $TimeoutSeconds * 1000
        if ($request -is [System.Net.HttpWebRequest]) {
            # Bounds the response-body read too; .Timeout alone covers only the connect and
            # the wait for the response headers.
            $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        }
        $request.Headers.Add('Authorization', "Bearer $Token")

        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try {
            $content = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
        return [pscustomobject]@{ Ok = $true; Content = $content; Error = $null }
    } catch {
        # Bound to a local first: everything below has to keep working after a function call,
        # and $_ is the handler's variable rather than a value that travels with it.
        $err = $_
        # A protocol error (401/500/...) arrives here with a live HttpWebResponse attached to
        # the WebException, holding a pooled connection that the finally below cannot reach --
        # $response is only ever assigned on the success path. Return contract unchanged.
        Close-MatrixErrorResponse -Exception $err.Exception
        # The message carries the URI; the Authorization header is never in it.
        return [pscustomobject]@{ Ok = $false; Content = ''; Error = $err.Exception.Message }
    } finally {
        if ($null -ne $response) { try { $response.Close() } catch { } }
    }
}

function Invoke-MatrixVerify {
    [CmdletBinding()]
    param(
        [string] $SharePath,
        [string] $OutPath,
        [int] $StartupTimeoutSeconds,
        [int] $HttpTimeoutSeconds = 30,
        # How the registry snapshot is obtained. A scriptblock for the same reason
        # MacdowsHostAgent.ps1 reaches every Windows-only call through a provider: it is the
        # one seam that lets the collection path -- checkpoints, cleanup, the report contract --
        # be exercised off-Windows, where HKLM: does not exist and the real call throws
        # immediately. Production never passes it.
        [scriptblock] $SnapshotProvider
    )

    if ($null -eq $SnapshotProvider) { $SnapshotProvider = { Get-MatrixRegistrySnapshot } }

    $L = New-Object System.Collections.ArrayList
    function Add-L([string] $s) { [void]$L.Add($s) }

    $tmp = Join-Path $env:TEMP 'macdows-matrix-agent'
    $proc = $null            # held for the whole run: 5.1 needs the handle for HasExited/ExitCode
    $stdoutPath = Join-Path $tmp 'agent-stdout.txt'
    $stderrPath = Join-Path $tmp 'agent-stderr.txt'
    $result = 'FAIL'
    $snapshot = $null

    try {
        Add-L ('tsallowlist-matrix-verify  ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        Add-L ('PSVersion: ' + $PSVersionTable.PSVersion.ToString())
        Add-L ('User: ' + $env:USERNAME + '  SessionId: ' + (Get-Process -Id $PID).SessionId)
        Add-L ''

        $snapshot = & $SnapshotProvider

        # Checkpoint #1. The registry half of the evidence is now known and is the half the
        # Mac side cannot recover without spending another relay connection. Put it on the
        # drive before doing anything slow.
        Write-MatrixReport -Path $OutPath -Lines (@($L.ToArray()) + @(Get-MatrixSnapshotInfoLines -Snapshot $snapshot)) `
            -Result 'FAIL incomplete-at-registry-snapshot -- checkpoint only; the run was cut short before the agent was staged (relay TIMEOUT?)'

        # -- stage a private copy of the agent under %TEMP% ---------------------------------
        # A UNC working directory trips PS 5.1 path resolution, which is why the host-agent
        # suite copies local before running; the same applies here.
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
        [void](New-Item -ItemType Directory -Force -Path $tmp)
        # -Recurse as well as the wildcard: Tools/host-agent is flat today, but a copy that
        # silently skips a future subdirectory would fail later as a missing-file mystery.
        Copy-Item (Join-Path (Join-Path $SharePath 'host-agent') '*') $tmp -Force -Recurse

        $agentScript = Join-Path $tmp 'MacdowsHostAgent.ps1'
        if (-not (Test-Path -LiteralPath $agentScript -PathType Leaf)) {
            throw "host-agent not staged: $agentScript is missing (is \\tsclient\lab\host-agent present?)"
        }

        $allowlistPath = Join-Path $tmp 'matrix-allowlist.json'
        $json = New-MatrixAllowlistJson -SystemRoot $env:SystemRoot
        [IO.File]::WriteAllText($allowlistPath, $json, (New-Object System.Text.UTF8Encoding($false)))

        $tokenPath = Join-Path $tmp 'token'
        $port = Get-MatrixFreePort
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        Add-L "agent: staged in $tmp, loopback port $port"

        $argList = New-MatrixAgentArgumentList -AgentScript $agentScript `
            -AllowlistPath $allowlistPath -TokenPath $tokenPath -Port $port -BindAddress '127.0.0.1'
        $proc = Start-Process -FilePath $psExe -ArgumentList $argList -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if ($null -eq $proc) {
            # -PassThru returning nothing would make every later $proc.HasExited a StrictMode
            # error inside the wait loop, reported as an unrelated property fault. Say it here.
            throw 'Start-Process -PassThru returned no process handle for the agent'
        }

        # -- wait for the token, which the agent writes only AFTER it holds the port --------
        # (host-agent review finding M1: bind first, then write. So a readable token file is
        # proof the listener is up, and waiting on the file is the correct readiness signal.)
        # [IO.File]::ReadAllText rather than Get-Content -Raw: on a zero-byte file -Raw yields
        # AutomationNull, which a [string] cast does not turn into '' and only `$null -eq`
        # detects. ReadAllText returns '' and the IsNullOrWhiteSpace test below just works.
        $token = $null
        $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if ($proc.HasExited) { break }
            if ([IO.File]::Exists($tokenPath)) {
                $candidate = ''
                try { $candidate = [IO.File]::ReadAllText($tokenPath) } catch { $candidate = '' }
                if ($null -ne $candidate) { $candidate = $candidate.Trim() }
                if (-not [string]::IsNullOrWhiteSpace($candidate)) { $token = $candidate; break }
            }
            Start-Sleep -Milliseconds 200
        }

        if ($proc.HasExited) {
            throw "agent exited during startup with code $($proc.ExitCode) -- see the agent stdout/stderr tail below"
        }
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "agent did not publish a token within ${StartupTimeoutSeconds}s"
        }
        Add-L 'agent: token published (value not recorded)'

        # Checkpoint #2. The agent is listening; everything after this is the HTTP call and the
        # verdict. If the relay kills the session during those, this is what survives.
        Write-MatrixReport -Path $OutPath -Lines (@($L.ToArray()) + @(Get-MatrixSnapshotInfoLines -Snapshot $snapshot)) `
            -Result 'FAIL incomplete-at-agent-start -- checkpoint only; the agent was up but /v1/apps did not complete (relay TIMEOUT?)'

        # -- GET /v1/apps -------------------------------------------------------------------
        $uri = "http://127.0.0.1:$port/v1/apps"
        # Bounded by BOTH an attempt count and a wall clock. The attempt count alone bounds
        # nothing useful: each WebClient call carries its own connect/read timeout, so ten
        # attempts against a wedged agent can outlast the relay's own TIMEOUT and turn a
        # diagnosable failure into a killed session with no report.
        $response = $null
        $httpDeadline = (Get-Date).AddSeconds($HttpTimeoutSeconds)
        $attempt = 0
        $perRequestTimeout = [Math]::Max(5, [Math]::Min(15, $HttpTimeoutSeconds))
        while ($true) {
            $attempt++
            $response = Invoke-MatrixRequest -Uri $uri -Token $token -TimeoutSeconds $perRequestTimeout
            if ($response.Ok) { break }
            if ($attempt -ge 10 -or (Get-Date) -ge $httpDeadline) { break }
            Start-Sleep -Milliseconds 300
        }
        Add-L "agent: /v1/apps attempts=$attempt"
        if (-not $response.Ok) { throw "GET /v1/apps failed: $($response.Error)" }
        Add-L "agent: GET /v1/apps ok ($($response.Content.Length) bytes)"
        Add-L ''

        $apps = ConvertFrom-Json $response.Content

        $verdict = Get-MatrixVerdict -Snapshot $snapshot -Apps $apps -SystemRoot $env:SystemRoot
        foreach ($line in $verdict.Lines) { Add-L $line }
        $result = $verdict.Result
    } catch {
        # Never a bare throw: a run that produces no report is indistinguishable from a run
        # that never happened, and the Mac side has nothing to parse.
        # Flattened to one line: the report's contract is that its LAST line is
        # "RESULT: ...", and a multi-line exception message pasted in raw would push the word
        # RESULT into the middle of the file and leave the Mac side parsing prose.
        $flat = ([string]$_.Exception.Message) -replace '\s+', ' '
        $flat = $flat.Trim()
        # Get-MatrixVerdict never ran, so nothing else will put the registry state in the
        # report -- and that state is the expensive half to re-acquire (it costs a relay
        # connection). If it was read before the throw, keep it.
        if ($null -ne $snapshot) {
            Add-L ''
            foreach ($line in (Get-MatrixSnapshotInfoLines -Snapshot $snapshot)) { Add-L $line }
        }
        Add-L ''
        Add-L ("EXCEPTION " + $_.Exception.GetType().Name + ': ' + $flat)
        $result = "FAIL $flat"
    } finally {
        # -- stop the agent (the handle is what makes ExitCode/HasExited readable in 5.1) ----
        if ($null -ne $proc) {
            $stopped = $false
            try {
                if (-not $proc.HasExited) {
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                    [void]$proc.WaitForExit(5000)
                }
                $stopped = $proc.HasExited
            } catch { }
            Add-L ''
            Add-L "agent: stopped=$stopped"
        }

        # Read the agent's own output BEFORE the temp directory goes away. The allowlist load
        # result lives here, which is how a rejected entry is explained rather than guessed at.
        foreach ($pair in @(@('stdout', $stdoutPath), @('stderr', $stderrPath))) {
            $label = $pair[0]
            $path = $pair[1]
            if ([IO.File]::Exists($path)) {
                $text = ''
                try { $text = [IO.File]::ReadAllText($path) } catch { $text = '' }
                if ($null -eq $text) { $text = '' }
                $body = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
                if ($body.Count -gt 0) {
                    Add-L "agent ${label}:"
                    foreach ($line in ($body | Select-Object -Last 20)) {
                        # The agent prints its token on stdout exactly once. It must not travel
                        # back over the redirected drive.
                        if ($line -match '^\s*token:\s') { Add-L '  token: <redacted>' }
                        else { Add-L "  $line" }
                    }
                }
            }
        }

        try { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp } catch { }
        $left = (Test-Path -LiteralPath $tmp)
        Add-L "temp cleaned: $(-not $left)"

        # Final write. Overwrites whichever checkpoint was last on the drive.
        Write-MatrixReport -Path $OutPath -Lines @($L.ToArray()) -Result $result
    }
}

if (-not $NoRun) {
    Invoke-MatrixVerify -SharePath $SharePath -OutPath $OutPath `
        -StartupTimeoutSeconds $StartupTimeoutSeconds -HttpTimeoutSeconds $HttpTimeoutSeconds
}
