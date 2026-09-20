#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test suite for window-loop-start.ps1's argument construction and done-marker grammar.

.DESCRIPTION
    Runs on macOS under PowerShell 7 (Tier 1 runs it on ubuntu-latest's pwsh) with no external
    dependencies. Self-contained assertion harness, exit code propagated: 0 when every case
    passes, 1 otherwise. Style follows window-rects-probe.Tests.ps1.

    window-loop-start.ps1 runs inside one relay connection: it copies the loop and the probe
    onto the host, launches the loop detached and writes a done marker back over the redirected
    drive before that drive goes away. None of that can be exercised here and none of it is; the
    suite dot-sources the script with -NoRun and drives the two pure helpers.

    What IS pinned is the pair of things that cannot be re-tried on the host. First the argument
    list: Start-Process joins -ArgumentList into ONE command line with single spaces, so a path
    containing a space arrives split in two and -File is handed a truncated path -- the loop then
    never starts, and a loop that never started looks exactly like a loop that did not survive
    the disconnect, which is the very question the lane exists to answer. Second the done marker,
    which is the only evidence that distinguishes those two cases and which must carry no path.

    window-rects-probe.ps1 is dot-sourced -NoRun first, because the launcher renders its marker
    with the probe's formatters, exactly as it does on the host.

.EXAMPLE
    pwsh -NoProfile -File ./window-loop-start.Tests.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProbeScriptPath = Join-Path $PSScriptRoot 'window-rects-probe.ps1'
$script:SubjectPath = Join-Path $PSScriptRoot 'window-loop-start.ps1'
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

# A deliberately spacy directory: the failure mode this suite exists for only appears there.
# Concatenated rather than Join-Path'd, because Join-Path resolves the drive qualifier through
# the provider and throws on C:\ from a runner that has no C: drive.
$script:FixtureDir = 'C:\Temp\dir with space'

function New-FixturePath {
    param([string] $Name)
    return ($script:FixtureDir + '\' + $Name)
}

function New-FixtureArgs {
    param([int] $MaxSeconds = 420, [int] $IntervalMs = 250)
    return New-LoopArgumentList `
        -LoopScript (New-FixturePath 'window-loop.ps1') `
        -OutPath (New-FixturePath 'window-loop-out.txt') `
        -SentinelPath (New-FixturePath 'window-loop.stop') `
        -ProbeScript (New-FixturePath 'window-rects-probe.ps1') `
        -MaxSeconds $MaxSeconds -IntervalMs $IntervalMs
}

function New-FixtureStart {
    param([bool] $HeadSeen = $true)
    return [pscustomobject]@{
        Utc         = '2026-09-18T09:00:00.0000000Z'
        ProcessId   = 4242
        MaxSeconds  = 420
        IntervalMs  = 250
        DeadlineUtc = '2026-09-18T09:07:00.0000000Z'
        Staged      = 2
        HeadSeen    = $HeadSeen
    }
}

$script:StartLinePattern = '^\[loop-start\] utc=\S+ pid=\S+ max-seconds=\S+ interval-ms=\S+ deadline-utc=\S+ staged=\S+ head=(true|false)$'

# -------------------------------------------------------------------------------------------
# Pre-registered constants
# -------------------------------------------------------------------------------------------

New-Section 'pre-registered constants'

Test-Case 'the file names are the ones the loop and the collector agree on' {
    # The same literals are pinned in window-loop.Tests.ps1 and window-loop-collect.Tests.ps1.
    # A rename in one file is then red in the other two instead of producing an empty batch.
    Assert-Equal 'macdows-lab' $script:LoopLocalDirName
    Assert-Equal 'window-loop.ps1' $script:LoopScriptName
    Assert-Equal 'window-rects-probe.ps1' $script:LoopProbeName
    Assert-Equal 'window-loop-out.txt' $script:LoopOutName
    Assert-Equal 'window-loop.stop' $script:LoopSentinelName
    Assert-Equal 'window-loop-start.done' $script:LoopStartDoneName
    Assert-Equal 'window-loop-out.prev.txt' $script:LoopOutPrevName
    Assert-Equal 'window-loop.stdout.txt' $script:LoopStdoutName
    Assert-Equal 'window-loop.stderr.txt' $script:LoopStderrName
}

Test-Case 'the liveness poll is bounded at 3 s and polled every 250 ms, well inside the job TIMEOUT of 30 s' {
    # gate r1 B1: the marker has to carry evidence that the child actually began executing, and
    # it has to do so without risking the connection the marker still has to travel over.
    Assert-Equal 3000 $script:LoopStartHeadWaitMs
    Assert-Equal 250 $script:LoopStartHeadPollMs
    Assert-True ($script:LoopStartHeadWaitMs -lt 30000) 'the poll cannot outlast the start job TIMEOUT'
    Assert-Equal '[loop-head] ' $script:LoopHeadPrefix 'the liveness judgement is the sampler own first line'
}

Test-Case 'exactly two files are staged onto the host, and they are the loop and the probe' {
    $staged = @($script:LoopStagedFileNames)
    Assert-Equal 2 $staged.Count
    Assert-Equal $script:LoopScriptName $staged[0]
    Assert-Equal $script:LoopProbeName $staged[1] 'the probe is staged because the loop dot-sources it after the drive is gone'
}

Test-Case 'the share root is the drive the relay redirects, written down once' {
    Assert-Equal '\\tsclient\lab' $script:LoopShareRoot
}

# -------------------------------------------------------------------------------------------
# New-LoopArgumentList
# -------------------------------------------------------------------------------------------

New-Section 'New-LoopArgumentList'

Test-Case 'argv preflight: every path handed to Start-Process is quoted' {
    # Start-Process joins -ArgumentList into ONE command line with single spaces, so an unquoted
    # C:\Temp\dir with space\window-loop.ps1 would arrive as two arguments. Checked with a
    # deliberately spacy path, which is what a real user profile directory can be.
    $argv = New-FixtureArgs
    Assert-Equal '"C:\Temp\dir with space\window-loop.ps1"' $argv[$argv.IndexOf('-File') + 1]
    Assert-Equal '"C:\Temp\dir with space\window-loop-out.txt"' $argv[$argv.IndexOf('-OutPath') + 1]
    Assert-Equal '"C:\Temp\dir with space\window-loop.stop"' $argv[$argv.IndexOf('-SentinelPath') + 1]
    Assert-Equal '"C:\Temp\dir with space\window-rects-probe.ps1"' $argv[$argv.IndexOf('-ProbePath') + 1]
    Assert-True ($argv -contains '-NoProfile') '-NoProfile must be passed'
    Assert-True ($argv -contains 'Bypass') 'the execution policy must be bypassed'
}

Test-Case 'the numbers are passed as bare tokens and the whole list is the documented shape' {
    $argv = New-FixtureArgs -MaxSeconds 30 -IntervalMs 500
    Assert-Equal '30' $argv[$argv.IndexOf('-MaxSeconds') + 1]
    Assert-Equal '500' $argv[$argv.IndexOf('-IntervalMs') + 1]
    Assert-Equal 15 $argv.Count '-NoProfile, -ExecutionPolicy Bypass, and five name/value pairs'
    $joined = ($argv -join ' ')
    Assert-Equal '-NoProfile -ExecutionPolicy Bypass -File "C:\Temp\dir with space\window-loop.ps1" -OutPath "C:\Temp\dir with space\window-loop-out.txt" -SentinelPath "C:\Temp\dir with space\window-loop.stop" -ProbePath "C:\Temp\dir with space\window-rects-probe.ps1" -MaxSeconds 30 -IntervalMs 500' $joined
}

Test-Case 'the quoting is balanced: every path token opens and closes exactly once' {
    $argv = New-FixtureArgs
    $quoted = @($argv | Where-Object { $_ -like '"*' })
    Assert-Equal 4 $quoted.Count 'four paths, four quoted tokens'
    foreach ($q in $quoted) {
        Assert-Equal 2 ([regex]::Matches($q, '"')).Count "[$q] carries exactly two quote characters"
        Assert-Match '^".*"$' $q
    }
}

Test-Case 'argv preflight under Legacy argument passing produces the identical list' {
    # Global constraint: argv-construction logic is pre-flighted with
    # $PSNativeCommandArgumentPassing='Legacy', which is how Windows PowerShell 5.1 builds a
    # native command line (concatenate and strip quotes). The list is built by this script, not
    # by the parameter binder, so the mode must make no difference - and this is what says so.
    $before = Get-Variable -Name 'PSNativeCommandArgumentPassing' -ValueOnly -ErrorAction SilentlyContinue
    try {
        Set-Variable -Name 'PSNativeCommandArgumentPassing' -Value 'Legacy' -Scope Global
        $a = New-FixtureArgs
        Assert-Equal '"C:\Temp\dir with space\window-loop.ps1"' $a[$a.IndexOf('-File') + 1]
        Assert-Equal 15 $a.Count
    } finally {
        if ($null -eq $before) {
            Remove-Variable -Name 'PSNativeCommandArgumentPassing' -Scope Global -ErrorAction SilentlyContinue
        } else {
            Set-Variable -Name 'PSNativeCommandArgumentPassing' -Value $before -Scope Global
        }
    }
}

# -------------------------------------------------------------------------------------------
# Format-LoopStartRow
# -------------------------------------------------------------------------------------------

New-Section 'Format-LoopStartRow'

Test-Case 'the done marker carries the launch facts and nothing else' {
    $line = Format-LoopStartRow -Start (New-FixtureStart)
    Assert-Equal '[loop-start] utc=2026-09-18T09:00:00.0000000Z pid=4242 max-seconds=420 interval-ms=250 deadline-utc=2026-09-18T09:07:00.0000000Z staged=2 head=true' $line
    Assert-Match $script:StartLinePattern $line
}

Test-Case 'head= is the one key that says the child BEGAN EXECUTING, and it is last in the row' {
    # gate r1 B1. Without it the interpretation table reads "marker present + out missing" as
    # "the launch worked, the process did not survive" -- but that combination is reachable from
    # a staged copy that will not run, a leftover lock on the samples file, or a launch the shell
    # refused, none of which say anything about surviving a disconnect. head=false names those.
    $seen = Format-LoopStartRow -Start (New-FixtureStart -HeadSeen $true)
    $unseen = Format-LoopStartRow -Start (New-FixtureStart -HeadSeen $false)
    Assert-Match ' staged=2 head=true$' $seen
    Assert-Match ' staged=2 head=false$' $unseen
    Assert-Match $script:StartLinePattern $seen
    Assert-Match $script:StartLinePattern $unseen
    Assert-True ($seen -ne $unseen) 'the two verdicts are visibly different'
}

Test-Case 'Test-LoopHeadPresent recognises the sampler first line and nothing else' {
    Assert-True (Test-LoopHeadPresent -Lines @('[loop-head] utc=2026-09-18T09:00:00.0000000Z ps=5.1.26200.1 pid=4242 session=3 interval-ms=250 max-seconds=420 deadline-utc=2026-09-18T09:07:00.0000000Z awareness=2 set-via=v2'))
    Assert-True (-not (Test-LoopHeadPresent -Lines @())) 'an empty file is not a head'
    Assert-True (-not (Test-LoopHeadPresent -Lines $null)) 'a missing file is not a head'
    Assert-True (-not (Test-LoopHeadPresent -Lines @('RESULT: FAILED probe/CommandNotFoundException'))) `
        'a run that died before the head is NOT alive-evidence'
    Assert-True (-not (Test-LoopHeadPresent -Lines @(' [loop-head] x'))) 'a leading space is not the grammar'
    Assert-True (-not (Test-LoopHeadPresent -Lines @('[loop-headX] x')))
}

Test-Case 'RED LINE: the done marker carries no path at all -- not a separator anywhere on it' {
    # The marker travels back over the redirected drive and is read by whoever runs the batch.
    # Local paths on the host carry the account name, so the marker names none of them: the pid
    # and the deadline are what a reader needs, and those cannot identify anybody.
    foreach ($line in @((Format-LoopStartRow -Start (New-FixtureStart)), (Format-LoopStartRow -Start $null))) {
        Assert-True (-not $line.Contains('\')) 'no backslash'
        Assert-True (-not ($line -match '(?i)[a-z]:')) 'no drive qualifier'
        Assert-True (-not ($line -match '(?i)users')) 'no profile directory name'
        # n/a is the only token on this line that may carry a separator, and it is a verdict,
        # not a path. Everything else must be free of one.
        $withoutNa = $line.Replace('n/a', 'MISSING')
        Assert-True (-not $withoutNa.Contains('/')) 'no forward slash outside the n/a token'
    }
}

Test-Case 'a marker whose facts are missing keeps the line shape rather than losing a key' {
    # head= is the exception to the n/a rule on this line: it is a judgement the launcher always
    # makes (it either saw the head within the bound or it did not), so a missing record is
    # head=false, never head=n/a. A reader gating on head=true can then never be fooled by an
    # absent field.
    $line = Format-LoopStartRow -Start $null
    Assert-Equal '[loop-start] utc=n/a pid=n/a max-seconds=n/a interval-ms=n/a deadline-utc=n/a staged=n/a head=false' $line
    Assert-Match $script:StartLinePattern $line
}

Test-Case 'staged= is the count that was verified, so a half-copied pair is visible' {
    $s = New-FixtureStart
    $s.Staged = 1
    Assert-Match ' staged=1 head=' (Format-LoopStartRow -Start $s) 'one file of two means the loop will not find the probe'
    $s.Staged = 0
    Assert-Match ' staged=0 head=' (Format-LoopStartRow -Start $s)
}

# -------------------------------------------------------------------------------------------
# Source pins -- properties the offline path cannot observe by running the script
# -------------------------------------------------------------------------------------------

New-Section 'source pins'

$script:SubjectSource = [IO.File]::ReadAllText($script:SubjectPath)

function Get-CodeOnly {
    <#
      The source with its comments removed, for pins that COUNT something. A pin that counts a
      bare name also counts every mention of it in a doc comment, which makes it red -- or worse,
      green -- for the wrong reason (lab lesson, 2026-09-08). Block comments first, then
      line comments. No string in this script contains a #, so the line-comment cut is safe here.
    #>
    param([string] $Text)
    $stripped = [regex]::Replace($Text, '(?s)<#.*?#>', '')
    return [regex]::Replace($stripped, '(?m)#.*$', '')
}

$script:SubjectCode = Get-CodeOnly -Text $script:SubjectSource

Test-Case 'the script takes exactly the three documented parameters' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:SubjectPath, [ref]$null, [ref]$null)
    $params = @($ast.ParamBlock.Parameters)
    $want = @('MaxSeconds', 'IntervalMs', 'NoRun')
    Assert-Equal $want.Count $params.Count
    for ($i = 0; $i -lt $want.Count; $i++) { Assert-Equal $want[$i] $params[$i].Name.VariablePath.UserPath "parameter $i" }
    Assert-Equal 420 $params[0].DefaultValue.Value 'the same default the loop itself carries'
    Assert-Equal 250 $params[1].DefaultValue.Value
}

Test-Case 'the loop is launched in the precedent shape: hidden, -PassThru, both streams redirected' {
    # gate r1 B1(2) / m7. tsallowlist-matrix-verify.ps1:817-823 is the one launch in this repo
    # that has run on the host, and it carries both redirects. Redirection is also what makes
    # PS 5.1 take the CreateProcess path instead of ShellExecuteEx, which is the difference
    # between a child whose startup errors land in a file and one whose refusal is invisible.
    Assert-Match 'Start-Process\s+-FilePath\s+\$psExe\s+-ArgumentList\s+\$argList\s+-PassThru\s+-WindowStyle\s+Hidden\s+`?\s*-RedirectStandardOutput\s+\$stdoutPath\s+-RedirectStandardError\s+\$stderrPath' $script:SubjectCode
    # The CALL shape, not the name: the guard below the launch names Start-Process in its own
    # throw message, and a bare name count would be two for a reason that is not a second launch.
    Assert-Equal 1 ([regex]::Matches($script:SubjectCode, 'Start-Process\s+-FilePath')).Count 'exactly one launch'
}

Test-Case 'both redirect targets are HOST-LOCAL and are NOT quoted' {
    # Two separate rules. (1) Host-local: a handle onto the redirected drive dies with the
    # connection, which is the one thing guaranteed to kill the sampler exactly when the
    # measurement starts -- so both targets are built from $dir, never from the share root.
    # (2) Unquoted: unlike -ArgumentList, which Start-Process joins into one command line,
    # -RedirectStandardOutput is bound as a parameter VALUE; a literal quote becomes part of the
    # file name. Measured on this runner: a quoted target threw DirectoryNotFoundException and
    # created nothing, while the unquoted one wrote its file.
    Assert-Match '(?m)^\s*\$stdoutPath = Join-Path \$dir \$script:LoopStdoutName\s*$' $script:SubjectCode
    Assert-Match '(?m)^\s*\$stderrPath = Join-Path \$dir \$script:LoopStderrName\s*$' $script:SubjectCode
    Assert-Equal 0 ([regex]::Matches($script:SubjectCode, 'RedirectStandard\w+\s+[^$\r\n]')).Count `
        'each redirect takes a bare variable -- no quoting, no inline expression'
    $shareRefs = [regex]::Matches($script:SubjectCode, '\$script:LoopShareRoot')
    foreach ($m in $shareRefs) {
        $line = $script:SubjectCode.Substring($m.Index, [Math]::Min(80, $script:SubjectCode.Length - $m.Index))
        Assert-True (-not ($line -match 'Stdout|Stderr')) 'no redirect target is built from the share root'
    }
}

Test-Case 'the share is named once, as a constant, and is never globbed' {
    # The redirected drive is shared with every other lab lane. This one reads two files and
    # writes one marker, all by exact name; a wildcard here could delete another lane's evidence.
    Assert-True ($script:SubjectSource.Contains("`$script:LoopShareRoot = '\\tsclient\lab'")) 'the share root is a named constant'
    Assert-True (([regex]::Matches($script:SubjectSource, '\$script:LoopShareRoot')).Count -ge 2) 'and every use goes through it'
    Assert-Equal 0 ([regex]::Matches($script:SubjectSource, '\\\*')).Count 'no glob in any path'
}

Test-Case 'RED LINE: the launcher redefines none of the probe helpers and compiles nothing' {
    foreach ($owned in @('ConvertTo-ProbeToken', 'Format-ProbeInt', 'ConvertTo-TitleSha8', 'Invoke-ProbeCall')) {
        Assert-True (-not ($script:SubjectSource -match ('(?m)^\s*function\s+' + [regex]::Escape($owned) + '\b'))) "[$owned] belongs to window-rects-probe.ps1"
    }
    Assert-Equal 0 ([regex]::Matches($script:SubjectSource, 'Add-Type')).Count 'no P/Invoke surface here'
}

Test-Case 'no local shares a name with a probe parameter -- dot-sourcing the probe overwrites those' {
    # Dot-sourcing a script BINDS ITS PARAMETERS into the current scope, and PowerShell variable
    # names are case-insensitive. window-rects-probe.ps1 takes -OutPath, defaulting to
    # \\tsclient\lab\window-rects-out.txt. A local called $outPath in the run function would
    # therefore become that UNC path the instant the probe is dot-sourced -- and the loop would
    # be launched with -OutPath pointing at a drive that disappears with this connection, into
    # the file name the window-rects probe itself uses. Verified by experiment, not assumed.
    # Scoped to the function that dot-sources, because that is exactly where the hazard is: a
    # pure helper's own -OutPath parameter is in a scope the dot-source never enters. So the
    # dot-source is first pinned to live in that one function and nowhere else.
    $dotSources = [regex]::Matches($script:SubjectCode, '(?m)^\s*\.\s+\$probeScript\s+-NoRun\s*$')
    Assert-Equal 1 $dotSources.Count 'the probe is dot-sourced exactly once'
    $from = $script:SubjectCode.IndexOf('function Invoke-WindowLoopStart')
    Assert-True ($from -gt 0 -and $dotSources[0].Index -gt $from) 'and only inside the run function'
    # Cut at the guard: the trailing `if (-not $NoRun)` is script scope, which runs before this
    # function is ever called and is therefore not the scope the dot-source rewrites.
    $to = $script:SubjectCode.LastIndexOf('if (-not $NoRun) {')
    Assert-True ($to -gt $from) 'the guard follows the run function'
    $body = $script:SubjectCode.Substring($from, $to - $from)
    foreach ($taken in @('outPath', 'noRun')) {
        Assert-True (-not ($body -match ('(?i)\$' + $taken + '\b'))) `
            "[`$$taken] is a window-rects-probe.ps1 parameter name; a variable of that name in this scope is overwritten by the dot-source"
    }
}

Test-Case 'the marker is written AFTER the launch, so its pid is the loop that really started' {
    $start = $script:SubjectSource.IndexOf('function Invoke-WindowLoopStart')
    Assert-True ($start -gt 0) 'the run function is present'
    $body = $script:SubjectSource.Substring($start)
    $copy = $body.IndexOf('Copy-Item')
    $launch = $body.IndexOf('Start-Process')
    $poll = $body.IndexOf('Test-LoopHeadPresent')
    $marker = $body.IndexOf('Format-LoopStartRow')
    Assert-True ($copy -gt 0 -and $launch -gt $copy) 'the files are staged before the launch'
    Assert-True ($poll -gt $launch) 'the liveness poll runs after the launch'
    Assert-True ($marker -gt $poll) 'and the marker is rendered after the poll, so head= is a fact'
}

Test-Case 'the liveness poll is bounded by a wall clock, not only by an iteration count' {
    $start = $script:SubjectCode.IndexOf('function Invoke-WindowLoopStart')
    $body = $script:SubjectCode.Substring($start)
    Assert-Match 'AddMilliseconds\(\$script:LoopStartHeadWaitMs\)' $body 'the bound comes from the pinned constant'
    Assert-Equal 1 ([regex]::Matches($body, 'Start-Sleep')).Count 'exactly one sleep, in the one poll loop'
    Assert-Match 'Start-Sleep -Milliseconds \$script:LoopStartHeadPollMs' $body
}

Test-Case 'nothing runs unless -NoRun is absent: the only top-level call is inside that guard' {
    $guard = $script:SubjectSource.LastIndexOf('if (-not $NoRun) {')
    Assert-True ($guard -gt 0) 'the guard is present'
    $tail = $script:SubjectSource.Substring($guard)
    Assert-True ($tail.Contains('Invoke-WindowLoopStart')) 'the run is started inside the guard'
    Assert-True ($tail.Contains('exit 0')) 'the script always exits 0; the relay writes the real rc'
    Assert-Equal 0 ([regex]::Matches($script:SubjectSource, '(?m)^Invoke-WindowLoopStart')).Count 'no unguarded top-level invocation'
}

Test-Case 'the suite itself carries no host identifier' {
    $self = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'window-loop-start.Tests.ps1'))
    Assert-True (-not ($self -match '(?i)\\\\[a-z0-9-]*\\c\$')) 'no administrative share path'
    Assert-True ($self.Contains($script:FixtureDir)) 'the only paths here are the synthetic fixture ones'
}

# -------------------------------------------------------------------------------------------
# Parameter binding
# -------------------------------------------------------------------------------------------

New-Section 'parameter binding'

Test-Case 'dot-sourcing with -NoRun defines the helpers and touches nothing' {
    $ran = $true
    try { & $script:SubjectPath -NoRun } catch { $ran = $false }
    Assert-True $ran '-NoRun must bind and return without launching anything'
    Assert-True ($null -ne (Get-Command New-LoopArgumentList -ErrorAction SilentlyContinue)) 'the helpers are defined'
}

Test-Case 'the two bounds bind alongside -NoRun' {
    $ran = $true
    try { & $script:SubjectPath -NoRun -MaxSeconds 60 -IntervalMs 1000 } catch { $ran = $false }
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
