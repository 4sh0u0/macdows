#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test suite for Set-TsAllowListMatrix.ps1's Backup-State clobber guards.

.DESCRIPTION
    Requires PowerShell 7 or newer, and says so by refusing to run below it (see the version
    gate under the param block). Unlike its sibling tsallowlist-matrix-verify.Tests.ps1 this
    suite is NOT runnable under Windows PowerShell 5.1: the PS7-only-syntax detector further
    down asserts on TokenKind members (QuestionQuestion, QuestionQuestionEquals, QuestionMark,
    QuestionDot, QuestionLBracket) that 5.1 does not have, and positive-controls itself against
    bait using ?? / ??= / ?: / ?. / ?[ that 5.1's tokeniser has no production for. Under 5.1
    that case cannot pass however the rest of the suite behaves, so a 5.1 run would put a red
    FAIL next to an elevated-write interlock at exactly the moment an operator is deciding
    whether to trust it. Refusing up front is the honest answer -- review-H-r1 H1, 2026-09-01.

    NB the requirement being tested is unaffected: the SHIPPED SCRIPT must stay 5.1-clean (it
    is run from an elevated Windows PowerShell console), and that is what the detector checks.
    Only this harness needs 7.

    Otherwise dependency-free -- no Pester, no registry, no Windows, no host, no network. Style
    follows tsallowlist-matrix-verify.Tests.ps1 (Test-Case harness, exit code propagated:
    0 when every case passes, 1 when a case fails, 3 when the version gate refuses).

    WHY THIS FILE EXISTS
    Backup-State is the only elevated-write interlock the lab has. It refuses to run when
    exporting would destroy the record of the host's real prior configuration -- and it has to
    refuse in exactly the cells where something pristine would be lost and in no others, because
    over-refusal breaks the ordinary Restore -> Enforce cycle. That is a three-dimensional truth
    table (registry state x backup-file x marker-file) which cannot be walked on a Mac and cannot
    be walked on Windows either without an elevated console and a willingness to lose the very
    snapshot under test. Three separate sessions (implementer + two reviewers, 2026-09-01) each
    built a throwaway harness to check it and each threw the harness away. This file is that
    harness, kept.

    HOW THE REAL CODE GETS UNDER TEST (no copy, no seam)
    Set-TsAllowListMatrix.ps1 cannot be dot-sourced here: -Mode is Mandatory, the top level
    checks for an administrator token via [Security.Principal.WindowsIdentity] (which throws
    PlatformNotSupportedException off Windows), and it then writes HKLM. So instead of a -NoRun
    switch like tsallowlist-matrix-verify.ps1 carries, this suite lifts the code out by AST:

        Parser::ParseFile  ->  FindAll(FunctionDefinitionAst named 'Backup-State')
                           ->  Invoke-Expression $fn.Extent.Text

    plus the same treatment for the eight top-level variable assignments the function reads
    ($ErrorActionPreference, $TsKey, $TsKeyPS, $PolKeyPS, $Backup, $Marker, $PolBak,
    $ScriptPath). The function body executed by every case below is therefore the *shipped* text,
    byte for byte -- edit the guard and these cases re-test the edit; delete the guard and they
    fail. No logic from the script under test is restated in this file, and the AST-lift
    integrity section proves that mechanically rather than promising it.

    DELIBERATELY NO SEAM WAS ADDED to Set-TsAllowListMatrix.ps1. A -NoRun switch is the right
    answer for the verify script (which is *organised* as functions-then-run and is dot-sourced
    wholesale); here it would have to sit above an elevation check whose only purpose is to stop
    exactly this kind of non-elevated entry, and it would still leave the Windows-only type
    reference on the top-level path. AST-lift needs nothing from the script, so the script under
    test is unmodified by this work and remains verifiable by hash (last case in this file).

    THE STUB SURFACE, AND ONE TRAP WORTH NAMING
    Test-Path / Get-ItemProperty / Get-Content / Set-Content / Remove-Item / New-Item /
    Join-Path / Write-Host / reg.exe are shadowed by functions declared inside
    Invoke-BackupState (functions beat cmdlets and applications in command resolution, and
    PowerShell's dynamic scoping makes them visible to the lifted body called from there). They
    are torn down when Invoke-BackupState returns, so every case gets a clean world.

    The trap, hit independently by a reviewer building the same kind of stub: $Backup's file path
    ends in "TSAppAllowList.backup.reg", so it *contains* the registry key name. A stub that
    classifies paths by substring will confuse the backup file with the registry key and get
    every key-absent cell wrong in both directions. These stubs resolve paths by exact match
    against a declared universe of the five paths the function touches, and throw on anything
    else -- so the suite fails loudly if the script grows a new path rather than silently
    answering "does not exist" for it.

    Join-Path is stubbed with Windows semantics because macOS PowerShell resolves 'C:\...' as a
    drive and refuses. That keeps the default -BackupDir C:\macdows-matrix, and the Windows-shaped
    paths an operator actually reads in the refusal messages, under test.

    STRICT MODE. The lifted body runs with Set-StrictMode -Off, matching Windows PowerShell 5.1's
    default in the elevated console this script is run from; the suite itself runs under 2.0. A
    dedicated section re-runs representative cells under 2.0 as hygiene, so the difference is
    measured rather than assumed.

    No host names, no addresses, no credentials, nothing account-specific appears in this file.
    Fixture paths are the script's own default C:\macdows-matrix and the HKLM key it manages.

.EXAMPLE
    pwsh -NoProfile -File ./Set-TsAllowListMatrix.Tests.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ===========================================================================================
# Version gate -- fail closed, never silently
# ===========================================================================================
# This harness needs PowerShell 7+ (see .DESCRIPTION). Exit 3 rather than 0: a run that tested
# nothing must never be mistakable for a pass, which is the whole failure mode this file exists
# to remove. Exit 3 rather than 1 so a runner can tell "could not run here" from "a guard cell
# regressed" -- the same split run-matrix.sh already uses for its own gate.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "Set-TsAllowListMatrix.Tests.ps1 REFUSES to run on PowerShell $($PSVersionTable.PSVersion)."
    Write-Host '  This suite requires PowerShell 7 or newer. Its PS7-only-syntax detector asserts on'
    Write-Host '  TokenKind members (QuestionQuestion, QuestionDot, ...) that Windows PowerShell 5.1'
    Write-Host '  does not have, so a 5.1 run would report a false FAIL against the Enforce guard.'
    Write-Host '  The script UNDER TEST is and must remain 5.1-clean -- only this harness needs 7.'
    Write-Host '  Run it with:  pwsh -NoProfile -File ./Set-TsAllowListMatrix.Tests.ps1'
    exit 3
}

# ===========================================================================================
# AST lift -- the code under test is read out of the shipped file, never copied into this one
# ===========================================================================================

$script:Src = Join-Path $PSScriptRoot 'Set-TsAllowListMatrix.ps1'
if (-not (Test-Path -LiteralPath $script:Src)) {
    throw "cannot find the script under test at $($script:Src)"
}
$script:SrcHashBefore = (Get-FileHash -LiteralPath $script:Src -Algorithm SHA256).Hash

$script:Tokens = $null
$script:ParseErrors = $null
$script:SrcAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $script:Src, [ref]$script:Tokens, [ref]$script:ParseErrors)

if ($script:ParseErrors.Count -ne 0) {
    foreach ($e in $script:ParseErrors) { Write-Host "  parse error: $($e.Message)" }
    throw "$($script:Src) does not parse -- refusing to test a file the engine cannot read"
}

# The function under test.
$script:BackupStateAst = @($script:SrcAst.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
        ($n.Name -eq 'Backup-State')
    }, $true))
if ($script:BackupStateAst.Count -ne 1) {
    throw "expected exactly one Backup-State function in the script under test, found $($script:BackupStateAst.Count)"
}
$script:BackupStateAst = $script:BackupStateAst[0]
$script:BackupStateText = $script:BackupStateAst.Extent.Text

# The top-level assignments Backup-State reads. Lifted rather than restated so that renaming a
# path, changing the key, or reworking the $ScriptPath fallback re-tests itself here.
$script:PreambleNames = @('ErrorActionPreference', 'TsKey', 'TsKeyPS', 'PolKeyPS',
    'Backup', 'Marker', 'PolBak', 'ScriptPath')

$script:PreambleAsts = @($script:SrcAst.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and
        ($n.Left -is [System.Management.Automation.Language.VariableExpressionAst])
    }, $true) | Where-Object {
        if ($script:PreambleNames -notcontains $_.Left.VariablePath.UserPath) { return $false }
        # Top level only -- a same-named assignment inside a function is not the preamble.
        $p = $_.Parent
        while ($null -ne $p) {
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false }
            $p = $p.Parent
        }
        return $true
    })

$script:PreambleText = ($script:PreambleAsts | ForEach-Object { $_.Extent.Text }) -join "`n"

# ===========================================================================================
# Assertion harness (same shape as tsallowlist-matrix-verify.Tests.ps1)
# ===========================================================================================

$script:TestTotal = 0
$script:TestFailed = 0
$script:AssertTotal = 0
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
    $script:AssertTotal++
    if (-not $Condition) { throw $Because }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Because = '')
    $script:AssertTotal++
    if ($Expected -ne $Actual) {
        $msg = "expected [$Expected] but got [$Actual]"
        if ($Because) { $msg = "$Because - $msg" }
        throw $msg
    }
}

function Assert-Text {
    param([string] $Haystack, [string] $Needle, [string] $Because = '')
    $script:AssertTotal++
    if ($null -eq $Haystack -or -not $Haystack.Contains($Needle)) {
        $msg = "expected the text to contain [$Needle]"
        if ($Because) { $msg = "$Because - $msg" }
        throw $msg
    }
}

function Assert-NoText {
    param([string] $Haystack, [string] $Needle, [string] $Because = '')
    $script:AssertTotal++
    if ($null -ne $Haystack -and $Haystack.Contains($Needle)) {
        $msg = "expected the text NOT to contain [$Needle]"
        if ($Because) { $msg = "$Because - $msg" }
        throw $msg
    }
}

function New-Section { param([string] $Name) Write-Host ''; Write-Host "== $Name" }

# ===========================================================================================
# Fixtures
# ===========================================================================================

# What reg.exe export writes: UTF-16LE with a BOM in reality, decoded text here, CRLF line
# endings and the dword form the guard's $bakEnforced regex looks for.
function New-BackupFileContent {
    param([string] $Dword = '00000001')
    return ("Windows Registry Editor Version 5.00`r`n`r`n" +
            "[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList]`r`n" +
            "`"fDisabledAllowList`"=dword:$Dword`r`n")
}

# The pristine case: a snapshot of a host that was NOT enforced when it was taken.
$script:PristineBackup = New-BackupFileContent -Dword '00000001'
# The deadlock population (F6): the backup itself records enforced state, so "restore first"
# would send the operator round in a circle.
$script:EnforcedBackup = New-BackupFileContent -Dword '00000000'

function New-World {
    <#
      A whole world for one run of Backup-State, in flags. Concrete paths are resolved inside
      Invoke-BackupState from the LIFTED preamble, so nothing here has to know them.
    #>
    param(
        [ValidateSet('key-absent', 'fd-absent', 'fd-1', 'fd-0', 'fd-sz0', 'fd-bin0', 'fd-junk')]
        [string] $Key = 'key-absent',
        [switch] $HasBackup,
        [switch] $HasMarker,
        [string] $BackupContent = $script:PristineBackup,
        [switch] $BackupReadThrows,
        [ValidateSet('absent', 'no-value', '0', '1')]
        [string] $Policy = 'absent',
        [int] $RegExitCode = 0
    )
    return [pscustomobject]@{
        Key              = $Key
        HasBackup        = [bool]$HasBackup
        HasMarker        = [bool]$HasMarker
        BackupContent    = $BackupContent
        BackupReadThrows = [bool]$BackupReadThrows
        Policy           = $Policy
        RegExitCode      = $RegExitCode
    }
}

function Invoke-BackupState {
    <#
      Runs the REAL, AST-lifted Backup-State against a stubbed registry/file surface and
      returns everything a case might want to assert on. -Body overrides the lifted text, which
      is how the mutation-discrimination cases run a deliberately weakened guard.

      Every harness-local variable is h-prefixed so it cannot collide with the lifted body's
      own names ($cur, $alreadyEnforced, $pristineExists, $records, $bakEnforced, $msg, $pol, $p).
    #>
    param(
        [Parameter(Mandatory)] $World,
        [string] $Body,
        [string] $BackupDirValue = 'C:\macdows-matrix',
        [string] $CommandPath = 'C:\macdows-matrix\Set-TsAllowListMatrix.ps1',
        [switch] $Strict
    )

    # Production fidelity: Windows PowerShell 5.1 in an elevated console has no strict mode.
    # -Strict exists only for the hygiene section further down.
    if ($Strict) { Set-StrictMode -Version 2.0 } else { Set-StrictMode -Off }

    $hRec = New-Object System.Collections.ArrayList
    $hOut = New-Object System.Collections.ArrayList
    $hFiles = @{}
    $hReg = @{}
    $hUniverse = @{}
    $hWorld = $World
    $global:LASTEXITCODE = 0

    # -- Join-Path first: the lifted preamble needs it, and macOS refuses 'C:\...' otherwise.
    function Join-Path {
        param([Parameter(Position = 0)][string] $Path, [Parameter(Position = 1)][string] $ChildPath)
        return ($Path.TrimEnd('\') + '\' + $ChildPath)
    }

    # -- The lifted preamble, evaluated here so $Backup/$Marker/$PolBak/$ScriptPath are the
    #    script's own expressions of $BackupDir and $PSCommandPath, not this file's guesses.
    $BackupDir = $BackupDirValue
    $PSCommandPath = $CommandPath
    Invoke-Expression $script:PreambleText

    $hUniverse[$TsKeyPS] = 'registry'
    $hUniverse[$PolKeyPS] = 'registry'
    $hUniverse[$Backup] = 'file'
    $hUniverse[$Marker] = 'file'
    $hUniverse[$PolBak] = 'file'

    switch ($hWorld.Key) {
        'key-absent' { }
        'fd-absent' { $hReg[$TsKeyPS] = [ordered]@{} }
        'fd-1' { $hReg[$TsKeyPS] = [ordered]@{ fDisabledAllowList = 1 } }
        'fd-0' { $hReg[$TsKeyPS] = [ordered]@{ fDisabledAllowList = 0 } }
        'fd-sz0' { $hReg[$TsKeyPS] = [ordered]@{ fDisabledAllowList = '0' } }
        'fd-bin0' { $hReg[$TsKeyPS] = [ordered]@{ fDisabledAllowList = [byte[]]@(0) } }
        'fd-junk' { $hReg[$TsKeyPS] = [ordered]@{ fDisabledAllowList = 'yes' } }
    }
    switch ($hWorld.Policy) {
        'absent' { }
        'no-value' { $hReg[$PolKeyPS] = [ordered]@{} }
        '0' { $hReg[$PolKeyPS] = [ordered]@{ fAllowUnlistedRemotePrograms = 0 } }
        '1' { $hReg[$PolKeyPS] = [ordered]@{ fAllowUnlistedRemotePrograms = 1 } }
    }
    if ($hWorld.HasBackup) { $hFiles[$Backup] = $hWorld.BackupContent }
    if ($hWorld.HasMarker) { $hFiles[$Marker] = 'TSAppAllowList did not exist before this run' }

    $hFilesBefore = @{}
    foreach ($hK in $hFiles.Keys) { $hFilesBefore[$hK] = $hFiles[$hK] }

    # -- Stubs. Exact-path resolution against $hUniverse; anything unknown is a harness failure,
    #    not a silent "false". See the trap note in the file header.
    function Resolve-HarnessPath {
        param([string] $Given, [string] $Caller, [string] $Kind)
        if (-not $hUniverse.ContainsKey($Given)) {
            throw ("harness: $Caller was called on [$Given], which is not one of the five paths " +
                   'this suite models. The script under test grew a new path -- update ' +
                   'Set-TsAllowListMatrix.Tests.ps1 rather than widening the stub.')
        }
        if ($Kind -and $hUniverse[$Given] -ne $Kind) {
            throw "harness: $Caller was called on a $($hUniverse[$Given]) path [$Given], expected a $Kind path"
        }
        return $Given
    }

    # NB every stub below carries a [Parameter()] attribute, which makes it an ADVANCED function
    # -- so it inherits the common parameters and must NOT declare -ErrorAction itself. Doing so
    # raises "a parameter with the name 'ErrorAction' was defined multiple times" on every call,
    # which surfaces as a throw from inside the guard and looks exactly like a refusal. Measured
    # the hard way; left as a note so the next editor does not re-add them.
    function Test-Path {
        param([Parameter(Position = 0)][string] $Path, [string] $LiteralPath,
              [string] $PathType)
        $t = $LiteralPath
        if (-not $t) { $t = $Path }
        [void]$hRec.Add("Test-Path|$t")
        [void](Resolve-HarnessPath -Given $t -Caller 'Test-Path' -Kind '')
        return ($hReg.ContainsKey($t) -or $hFiles.ContainsKey($t))
    }

    function Get-ItemProperty {
        param([Parameter(Position = 0)][string] $Path, [string] $LiteralPath,
              [string] $Name)
        $t = $LiteralPath
        if (-not $t) { $t = $Path }
        [void]$hRec.Add("Get-ItemProperty|$t")
        [void](Resolve-HarnessPath -Given $t -Caller 'Get-ItemProperty' -Kind 'registry')
        # -ErrorAction SilentlyContinue on a missing key emits nothing, so the caller sees $null.
        if (-not $hReg.ContainsKey($t)) { return }
        # The registry provider always returns the PS* noise properties, so a key with no values
        # is still a truthy object. That distinction is load-bearing for the fd-absent cells.
        $o = [ordered]@{
            PSPath       = "Microsoft.PowerShell.Core\Registry::$t"
            PSParentPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE'
            PSChildName  = 'TSAppAllowList'
            PSDrive      = 'HKLM'
            PSProvider   = 'Microsoft.PowerShell.Core\Registry'
        }
        foreach ($hK in $hReg[$t].Keys) { $o[$hK] = $hReg[$t][$hK] }
        return [pscustomobject]$o
    }

    function Get-Content {
        param([Parameter(Position = 0)][string] $Path, [string] $LiteralPath,
              [switch] $Raw, [int] $TotalCount)
        $t = $LiteralPath
        if (-not $t) { $t = $Path }
        [void]$hRec.Add("Get-Content|$t")
        [void](Resolve-HarnessPath -Given $t -Caller 'Get-Content' -Kind 'file')
        if ($hWorld.BackupReadThrows -and $t -eq $Backup) {
            throw (New-Object System.IO.IOException 'simulated corrupt/unreadable backup file')
        }
        if (-not $hFiles.ContainsKey($t)) {
            throw "Cannot find path '$t' because it does not exist."
        }
        return $hFiles[$t]
    }

    function Set-Content {
        param([Parameter(Position = 0)][string] $Path, [string] $LiteralPath,
              [Parameter(Position = 1)] $Value, [switch] $Force)
        $t = $LiteralPath
        if (-not $t) { $t = $Path }
        [void]$hRec.Add("Set-Content|$t|$Value")
        [void](Resolve-HarnessPath -Given $t -Caller 'Set-Content' -Kind 'file')
        $hFiles[$t] = [string]$Value
    }

    function Remove-Item {
        param([Parameter(Position = 0)][string] $Path, [string] $LiteralPath,
              [switch] $Force, [switch] $Recurse)
        $t = $LiteralPath
        if (-not $t) { $t = $Path }
        [void]$hRec.Add("Remove-Item|$t")
        [void](Resolve-HarnessPath -Given $t -Caller 'Remove-Item' -Kind 'file')
        if ($hFiles.ContainsKey($t)) { $hFiles.Remove($t) }
    }

    function New-Item {
        param([Parameter(Position = 0)][string] $Path, [string] $LiteralPath,
              [string] $ItemType, [switch] $Force, $Value)
        $t = $LiteralPath
        if (-not $t) { $t = $Path }
        [void]$hRec.Add("New-Item|$t")
        # This was the one stub that skipped the path universe, so it silently accepted anything
        # -- contrary to the "throw on anything else" discipline the header advertises, and the
        # bypass a future New-Item in Backup-State would have slipped through. review-H-r1 H4.
        # -Kind '' because a directory is neither of the two modelled kinds; membership of the
        # universe is what is being enforced here.
        [void](Resolve-HarnessPath -Given $t -Caller 'New-Item' -Kind '')
    }

    function Write-Host {
        param([Parameter(Position = 0, ValueFromRemainingArguments = $true)] $Object,
              $ForegroundColor, [switch] $NoNewline)
        [void]$hOut.Add(($Object -join ' '))
    }

    function reg.exe {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest)
        [void]$hRec.Add("reg.exe|$($Rest -join '|')")
        $global:LASTEXITCODE = $hWorld.RegExitCode
        if ($hWorld.RegExitCode -eq 0 -and $Rest.Count -ge 3 -and $Rest[0] -eq 'export') {
            # A successful export creates the file, holding whatever the registry says NOW --
            # which is the whole hazard the guard exists to prevent.
            $hDword = $null
            if ($hReg.ContainsKey($TsKeyPS) -and $hReg[$TsKeyPS].Contains('fDisabledAllowList')) {
                $hV = $hReg[$TsKeyPS]['fDisabledAllowList']
                if ($hV -is [int]) { $hDword = '{0:x8}' -f $hV }
                elseif ($hV -is [string] -and $hV -match '^\d+$') { $hDword = '{0:x8}' -f [int]$hV }
                elseif ($hV -is [byte[]]) { $hDword = '{0:x8}' -f [int]$hV[0] }
            }
            if ($hDword) { $hFiles[$Rest[2]] = (New-BackupFileContent -Dword $hDword) }
            else { $hFiles[$Rest[2]] = "Windows Registry Editor Version 5.00`r`n" }
        }
    }

    # -- The code under test.
    $hBody = $Body
    if (-not $hBody) { $hBody = $script:BackupStateText }
    Invoke-Expression $hBody

    $hThrew = $false
    $hMessage = $null
    try {
        Backup-State
    } catch {
        $hThrew = $true
        $hMessage = $_.Exception.Message
    }

    # Every STUBBED command that changes state. New-ItemProperty / Remove-ItemProperty used to
    # appear here too and were phantoms -- neither has a stub, so naming them implied a coverage
    # that did not exist. The real protection against the guard growing such a call is the
    # command-surface pin in the AST-lift integrity section, which fails loudly. review-H-r1 H4.
    $hMutations = @($hRec | Where-Object {
            $_ -match '^(reg\.exe|Remove-Item|Set-Content|New-Item)\|'
        })

    return [pscustomobject]@{
        Threw       = $hThrew
        Message     = $hMessage
        Calls       = @($hRec)
        Mutations   = $hMutations
        Console     = ($hOut -join "`n")
        Files       = $hFiles
        FilesBefore = $hFilesBefore
        TsKey       = $TsKey
        TsKeyPS     = $TsKeyPS
        PolKeyPS    = $PolKeyPS
        Backup      = $Backup
        Marker      = $Marker
        PolBak      = $PolBak
        ScriptPath  = $ScriptPath
        BackupDir   = $BackupDir
    }
}

# -- Assertion shorthands over an Invoke-BackupState result -----------------------------------

function Assert-Refused {
    param($R)
    Assert-True $R.Threw 'expected Backup-State to REFUSE (throw)'
    Assert-Text $R.Message 'REFUSING' 'a refusal must say so in its first words'
    Assert-Equal 0 $R.Mutations.Count ("a refusal must mutate nothing; saw: " + ($R.Mutations -join ' ; '))
}

function Assert-Proceeded {
    param($R)
    Assert-True (-not $R.Threw) "expected Backup-State to proceed; it threw: $($R.Message)"
    # EXACTLY one write to $PolBak. This used to be an -or against a literal
    # "Set-Content|$PolBak|<absent>" call, which was strictly weaker than the count test it was
    # or-ed with: two or more $PolBak writes, one of them '<absent>', would have satisfied it.
    # Writing the policy snapshot once is part of what this assertion is for. review-H-r1 H2.
    Assert-Equal 1 @($R.Calls | Where-Object { $_.StartsWith("Set-Content|$($R.PolBak)|") }).Count `
        'every proceeding run records the policy value in $PolBak exactly once'
}

function Assert-TookExportPath {
    param($R)
    Assert-True ($R.Calls -contains "reg.exe|export|$($R.TsKey)|$($R.Backup)|/y") `
        'the key-present path must export the key over the backup with /y'
    Assert-True ($R.Calls -contains "Remove-Item|$($R.Marker)") `
        'the key-present path must clear any stale key-was-absent marker'
    # The mirror of Assert-TookMarkerPath's "no export" clause. Without it, a mutant that both
    # removed AND rewrote the marker on the export path would pass all 17 proceed cells while
    # leaving a marker that lies about the key having been absent. review-H-r1 H5.
    Assert-Equal 0 @($R.Calls | Where-Object { $_.StartsWith("Set-Content|$($R.Marker)|") }).Count `
        'the export path must not write a key-was-absent marker'
    Assert-Text $R.Console 'backed up' 'the export path announces itself'
}

function Assert-TookMarkerPath {
    param($R)
    Assert-True (@($R.Calls | Where-Object { $_.StartsWith("Set-Content|$($R.Marker)|") }).Count -eq 1) `
        'the key-absent path must write the key-was-absent marker'
    Assert-True ($R.Calls -notcontains "reg.exe|export|$($R.TsKey)|$($R.Backup)|/y") `
        'the key-absent path has nothing to export'
    Assert-Text $R.Console 'absent before this run' 'the marker path announces itself'
}

function Assert-FilesUnchanged {
    param($R)
    $script:AssertTotal++
    $before = @($R.FilesBefore.Keys | Sort-Object)
    $after = @($R.Files.Keys | Sort-Object)
    if (($before -join ',') -ne ($after -join ',')) {
        throw "on-disk records changed: before [$($before -join ',')] after [$($after -join ',')]"
    }
    foreach ($k in $R.FilesBefore.Keys) {
        if ($R.FilesBefore[$k] -ne $R.Files[$k]) { throw "content of [$k] changed" }
    }
}

# ===========================================================================================
Write-Host ("Set-TsAllowListMatrix.Tests.ps1 -- driving {0}" -f $script:Src)
Write-Host ("lifted Backup-State from the real file: lines {0}-{1} ({2} chars); preamble: {3} assignments" -f
    $script:BackupStateAst.Extent.StartLineNumber,
    $script:BackupStateAst.Extent.EndLineNumber,
    $script:BackupStateText.Length,
    $script:PreambleAsts.Count)

# -------------------------------------------------------------------------------------------
New-Section 'AST lift integrity -- the real code is what runs, and no copy of it lives here'
# -------------------------------------------------------------------------------------------

Test-Case 'the script under test parses with zero errors' {
    Assert-Equal 0 $script:ParseErrors.Count 'the shipped script must parse'
    Assert-True ($script:Tokens.Count -gt 0) 'the parse produced tokens'
}

Test-Case 'Backup-State was lifted out of the shipped file, guards and all' {
    Assert-True ($script:BackupStateText.StartsWith('function Backup-State')) `
        'the lifted text is the whole function definition'
    Assert-Text $script:BackupStateText 'CLOBBER GUARD' 'the enforced-branch guard is present in the lifted text'
    Assert-Text $script:BackupStateText 'REFUSING to back up' 'the enforced-branch refusal is present'
    Assert-Text $script:BackupStateText 'REFUSING to record' 'the key-absent-branch refusal is present'
}

Test-Case 'this Tests file contains no copy of the guard condition' {
    # The needle is assembled at runtime on purpose: written as one literal it would appear in
    # this file and the check would defeat itself.
    $needle = '$alreadyEnforced' + ' -and ' + '$pristineExists'
    $me = Get-Content -LiteralPath $PSCommandPath -Raw
    Assert-True ($script:BackupStateText.Contains($needle)) 'the shipped guard condition is what was lifted'
    Assert-True (-not $me.Contains($needle)) 'the guard condition must exist only in the script under test'
}

Test-Case 'all eight top-level assignments the guard reads were lifted' {
    Assert-Equal 8 $script:PreambleAsts.Count 'one lifted assignment per name'
    $names = @($script:PreambleAsts | ForEach-Object { $_.Left.VariablePath.UserPath })
    foreach ($n in $script:PreambleNames) {
        Assert-True ($names -contains $n) "the preamble lift must include `$$n"
    }
}

# The token kinds PowerShell 7 introduced. Windows PowerShell 5.1 cannot parse any of them, so
# one of these in the shipped script would fail the owner's elevated console rather than this Mac.
# NAMES MATTER: a typo here silently matches nothing and the check becomes decorative, so the
# case below asserts each name is a real enum member AND positive-controls the filter against a
# snippet that genuinely uses the syntax. (AmpersandAmpersand / PipePipe are NOT the names -- they
# are AndAnd / OrOr. Measured, after writing the wrong ones first.)
$script:Ps7TokenKinds = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionMark',
    'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr')

Test-Case 'the PS7-only-syntax detector is real: every kind exists and the filter fires on bait' {
    # The list must match a SECOND, literal copy of itself. Without this, deleting a name from
    # $script:Ps7TokenKinds left the bait check comparing 6 == 6 and both halves still said 'ok'
    # while the shipped-script scan quietly stopped looking for that operator. Typos were pinned;
    # narrowing was not, and this case exists precisely because a filter rotted into a no-op
    # once already. Two places have to agree, on purpose. review-H-r1 H3.
    $mustBe = @('AndAnd', 'OrOr', 'QuestionDot', 'QuestionLBracket', 'QuestionMark',
        'QuestionQuestion', 'QuestionQuestionEquals')
    Assert-Equal $mustBe.Count $script:Ps7TokenKinds.Count 'a kind was added to or dropped from the filter list'
    $drift = @(Compare-Object -ReferenceObject $mustBe -DifferenceObject @($script:Ps7TokenKinds))
    Assert-Equal 0 $drift.Count ('the filter list drifted from the expected set: ' +
        (@($drift | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join ', '))

    $known = [enum]::GetNames([System.Management.Automation.Language.TokenKind])
    foreach ($k in $script:Ps7TokenKinds) {
        Assert-True ($known -contains $k) "[$k] is not a TokenKind member -- the filter would never match"
    }
    # ?. and ?[ need the braced form to tokenise as null-conditional; unbraced, '$d?' is just a
    # variable named 'd?'. The bait uses the form the tokeniser actually recognises.
    $bait = '$a = $b ?? 1; $c ??= 2; $e = $f ? 1 : 2; ${g}?.h; ${i}?[0]; j && k; l || m'
    $bt = $null
    $be = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($bait, [ref]$bt, [ref]$be)
    $caught = @($bt | Where-Object { $script:Ps7TokenKinds -contains $_.Kind.ToString() } |
        ForEach-Object { $_.Kind.ToString() } | Sort-Object -Unique)
    Assert-Equal $script:Ps7TokenKinds.Count $caught.Count `
        ("the filter must catch all seven on bait; caught: " + ($caught -join ', '))
}

Test-Case 'the shipped script carries no PowerShell 7-only syntax (5.1 must still run it)' {
    $hits = @($script:Tokens | Where-Object { $script:Ps7TokenKinds -contains $_.Kind.ToString() })
    Assert-Equal 0 $hits.Count ("PS7-only operator token(s) found: " +
        (@($hits | ForEach-Object { "$($_.Text) at line $($_.Extent.StartLineNumber)" }) -join ', '))
    $src = Get-Content -LiteralPath $script:Src -Raw
    foreach ($bad in @('-Parallel', '$PSStyle', '-AsHashtable', 'Get-Error')) {
        Assert-NoText $src $bad "PS7-only construct [$bad] would break Windows PowerShell 5.1"
    }
}

Test-Case 'no -NoRun-style seam was needed or added to the script under test' {
    # Recorded as a case, not a comment: if a future edit adds a seam, this fails and whoever
    # added it has to come here and justify it (and prove the no-seam-taken path is unchanged).
    $src = Get-Content -LiteralPath $script:Src -Raw
    Assert-NoText $src 'NoRun' 'the AST-lift technique needs no seam; the script stays untouched'
    Assert-Text $src 'IsInRole' 'the elevation check is still the first thing the top level does'
}

# Every command the stub surface shadows, plus the one real cmdlet the guard may legitimately
# reach (Out-Null, which touches nothing). The pin below keeps this list and the guard honest
# about each other.
$script:StubbedCommands = @('Test-Path', 'Get-ItemProperty', 'Get-Content', 'Set-Content',
    'Remove-Item', 'New-Item', 'Join-Path', 'Write-Host', 'reg.exe', 'Out-Null')

Test-Case 'the guard calls nothing this suite has not stubbed' {
    # The path universe fails loudly when the guard grows a new PATH; nothing failed when it
    # grew a new COMMAND. An un-stubbed New-ItemProperty added to Backup-State later would reach
    # the real cmdlet -- harmless on macOS, a genuine HKLM write in the elevated console this
    # guard is actually run from. review-H-r1 H4.
    $cmds = @($script:BackupStateAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst]
            }, $true) | ForEach-Object {
            $name = $_.GetCommandName()
            # A null name means a dynamic invocation (& $var). That is drift too, and it must
            # show up in the unstubbed list rather than being filtered quietly away.
            if ($name) { $name } else { '<dynamic invocation>' }
        } | Sort-Object -Unique)
    Assert-True ($cmds.Count -gt 0) 'the lifted body does call commands -- an empty set would mean the walk broke'
    $un = @($cmds | Where-Object { $script:StubbedCommands -notcontains $_ })
    Assert-Equal 0 $un.Count ("the guard grew an UNSTUBBED command: " + ($un -join ', ') +
        ' -- it would reach the real system. Stub it before widening $script:StubbedCommands.')
}

Test-Case 'the stub trap: the backup file path contains the registry key name, yet resolves apart' {
    # A reviewer building this kind of stub hit this: $Backup ends in TSAppAllowList.backup.reg,
    # so substring classification confuses it with the registry key and gets every key-absent
    # cell wrong in both directions. Exact-path resolution is what makes the suite trustworthy.
    $r = Invoke-BackupState -World (New-World -Key 'key-absent' -HasBackup)
    Assert-True ($r.Backup.Contains('TSAppAllowList')) 'the trap is real: the file path contains the key name'
    Assert-True ($r.Backup -ne $r.TsKeyPS) 'file path and registry path are different strings'
    $paths = @($r.TsKeyPS, $r.PolKeyPS, $r.Backup, $r.Marker, $r.PolBak)
    Assert-Equal 5 (@($paths | Sort-Object -Unique)).Count 'the five modelled paths are pairwise distinct'
    Assert-Refused $r
}

# -------------------------------------------------------------------------------------------
New-Section 'guard truth table -- 28 reachable cells (registry state x backup x marker)'
# -------------------------------------------------------------------------------------------

# EVERY EXPECTATION BELOW IS LITERAL DATA, never computed from the guard's own condition --
# a computed column would just be a second copy of the code under test.
#
#   Expect: 'refuse' | 'export' (key-present branch) | 'marker' (key-absent branch)
$script:TruthTable = @(
    # --- key ABSENT: the marker branch, and F2's refusal --------------------------------------
    @{ Key = 'key-absent'; B = $false; M = $false; Expect = 'marker'; Why = 'legitimate first-ever Enforce: nothing to export, nothing at risk' }
    @{ Key = 'key-absent'; B = $false; M = $true;  Expect = 'marker'; Why = 'marker-path Restore -> Enforce; the marker is simply rewritten' }
    @{ Key = 'key-absent'; B = $true;  M = $false; Expect = 'refuse'; Why = 'F2: a true backup would be deleted and replaced by a false "key was absent" marker' }
    @{ Key = 'key-absent'; B = $true;  M = $true;  Expect = 'refuse'; Why = 'F2, with a marker alongside the surviving backup' }

    # --- key present, the value is not there at all -------------------------------------------
    @{ Key = 'fd-absent'; B = $false; M = $false; Expect = 'export'; Why = 'not enforced by any reading; the export IS pristine state' }
    @{ Key = 'fd-absent'; B = $false; M = $true;  Expect = 'export'; Why = 'stale marker is cleared, then exported' }
    @{ Key = 'fd-absent'; B = $true;  M = $false; Expect = 'export'; Why = 'overwriting the backup is safe: current state is the pristine state' }
    @{ Key = 'fd-absent'; B = $true;  M = $true;  Expect = 'export'; Why = 'same, with both records present' }

    # --- fd = 1 (DWord): explicitly NOT enforced ----------------------------------------------
    @{ Key = 'fd-1'; B = $false; M = $false; Expect = 'export'; Why = 'the ordinary first run' }
    @{ Key = 'fd-1'; B = $false; M = $true;  Expect = 'export'; Why = 'stale marker from an earlier key-absent era; not enforced, so safe' }
    @{ Key = 'fd-1'; B = $true;  M = $false; Expect = 'export'; Why = 'THE Restore -> Enforce CYCLE: this must keep working' }
    @{ Key = 'fd-1'; B = $true;  M = $true;  Expect = 'export'; Why = 'Restore -> Enforce with both records on disk' }

    # --- fd = 0 (DWord): ENFORCED. Refuse wherever a pristine record would be destroyed --------
    @{ Key = 'fd-0'; B = $false; M = $false; Expect = 'export'; Why = 'first-ever run on a host somebody else left enforced; nothing pristine to lose' }
    @{ Key = 'fd-0'; B = $false; M = $true;  Expect = 'refuse'; Why = 'F1: the double-Enforce on a key-absent host -- the marker is the only pristine record' }
    @{ Key = 'fd-0'; B = $true;  M = $false; Expect = 'refuse'; Why = 'the original hazard: the export would clobber the pre-enforce snapshot' }
    @{ Key = 'fd-0'; B = $true;  M = $true;  Expect = 'refuse'; Why = 'both records at risk' }

    # --- fd = '0' as REG_SZ: a hand-edited hive still reads as enforced ------------------------
    @{ Key = 'fd-sz0'; B = $false; M = $false; Expect = 'export'; Why = 'enforced but nothing pristine on disk' }
    @{ Key = 'fd-sz0'; B = $false; M = $true;  Expect = 'refuse'; Why = 'string comparison catches the odd hive on the marker too' }
    @{ Key = 'fd-sz0'; B = $true;  M = $false; Expect = 'refuse'; Why = 'string comparison catches the odd hive' }
    @{ Key = 'fd-sz0'; B = $true;  M = $true;  Expect = 'refuse'; Why = 'string comparison, both records' }

    # --- fd = single zero byte as REG_BINARY: deliberate fail-safe over-trigger ----------------
    @{ Key = 'fd-bin0'; B = $false; M = $false; Expect = 'export'; Why = 'over-trigger costs nothing when there is nothing to protect' }
    @{ Key = 'fd-bin0'; B = $false; M = $true;  Expect = 'refuse'; Why = '[string][byte[]]@(0) is "0" -- refusing too often is the safe direction' }
    @{ Key = 'fd-bin0'; B = $true;  M = $false; Expect = 'refuse'; Why = 'same, against a surviving backup' }
    @{ Key = 'fd-bin0'; B = $true;  M = $true;  Expect = 'refuse'; Why = 'same, both records' }

    # --- fd = non-numeric REG_SZ: the guard must not crash on the input it exists to inspect ---
    @{ Key = 'fd-junk'; B = $false; M = $false; Expect = 'export'; Why = 'not enforced by any reading; an [int] cast here would have thrown' }
    @{ Key = 'fd-junk'; B = $false; M = $true;  Expect = 'export'; Why = 'no cast throw, marker cleared' }
    @{ Key = 'fd-junk'; B = $true;  M = $false; Expect = 'export'; Why = 'no cast throw, backup overwritten' }
    @{ Key = 'fd-junk'; B = $true;  M = $true;  Expect = 'export'; Why = 'no cast throw, both records present' }
)

$script:CellRefuse = 0
$script:CellProceed = 0
foreach ($row in $script:TruthTable) {
    $label = '{0,-10} | backup={1,-5} | marker={2,-5} -> {3}' -f $row.Key, $row.B, $row.M, $row.Expect.ToUpper()
    if ($row.Expect -eq 'refuse') { $script:CellRefuse++ } else { $script:CellProceed++ }
    Test-Case $label {
        $r = Invoke-BackupState -World (New-World -Key $row.Key -HasBackup:$row.B -HasMarker:$row.M)
        if ($row.Expect -eq 'refuse') {
            Assert-Refused $r
            Assert-FilesUnchanged $r
        } elseif ($row.Expect -eq 'export') {
            Assert-Proceeded $r
            Assert-TookExportPath $r
        } else {
            Assert-Proceeded $r
            Assert-TookMarkerPath $r
        }
    }
}

Test-Case "the table walks all 28 reachable cells: $($script:CellRefuse) refuse, $($script:CellProceed) proceed" {
    Assert-Equal 28 $script:TruthTable.Count '7 registry states x 2 backup states x 2 marker states'
    Assert-Equal 11 $script:CellRefuse 'eleven cells destroy something pristine'
    Assert-Equal 17 $script:CellProceed 'seventeen cells are safe and must not be blocked'
    $seen = @($script:TruthTable | ForEach-Object { '{0}/{1}/{2}' -f $_.Key, $_.B, $_.M })
    Assert-Equal 28 (@($seen | Sort-Object -Unique)).Count 'no duplicated cell, no missing cell'
}

# -------------------------------------------------------------------------------------------
New-Section 'refusal messages -- name what is actually on disk, and give advice that works'
# -------------------------------------------------------------------------------------------

Test-Case 'refusal names the backup when only the backup is on disk' {
    $r = Invoke-BackupState -World (New-World -Key 'fd-0' -HasBackup)
    Assert-Refused $r
    Assert-Text $r.Message $r.Backup 'the message names the record at risk'
    Assert-NoText $r.Message $r.Marker 'it must not name a record that does not exist'
    Assert-Text $r.Message 'fDisabledAllowList=0' 'it says why it thinks the host is enforced'
}

Test-Case 'refusal names the marker when only the marker is on disk (the F1 cell)' {
    $r = Invoke-BackupState -World (New-World -Key 'fd-0' -HasMarker)
    Assert-Refused $r
    Assert-Text $r.Message $r.Marker 'the marker is the pristine record here'
    Assert-NoText $r.Message $r.Backup 'there is no backup to name'
}

Test-Case 'refusal names both records, comma-joined, when both are on disk' {
    $r = Invoke-BackupState -World (New-World -Key 'fd-0' -HasBackup -HasMarker)
    Assert-Refused $r
    Assert-Text $r.Message ($r.Backup + ', ' + $r.Marker) 'both records, in the order the script lists them'
}

Test-Case 'a pristine backup gets the restore-first advice' {
    $r = Invoke-BackupState -World (New-World -Key 'fd-0' -HasBackup -BackupContent $script:PristineBackup)
    Assert-Refused $r
    Assert-Text $r.Message 'restore first, then enforce again' 'the backup predates enforcement, so Restore works'
    Assert-NoText $r.Message 'will NOT' 'the deadlock wording belongs to the other branch'
}

Test-Case 'F6 deadlock variant: a backup that itself records enforced state changes the advice' {
    $r = Invoke-BackupState -World (New-World -Key 'fd-0' -HasBackup -BackupContent $script:EnforcedBackup)
    Assert-Refused $r
    Assert-Text $r.Message 'will NOT' 'Restore would re-import enforced state and land right back here'
    Assert-Text $r.Message 'nothing pristine left to protect' 'it says why restoring is pointless'
    Assert-Text $r.Message 'delete' 'it names the deliberate re-baseline as the way out'
    Assert-NoText $r.Message 'restore first, then enforce again' 'it must not send the operator round in a circle'
}

Test-Case 'F6 fail-soft: an unreadable backup still REFUSES, and degrades to generic advice' {
    # The refusal itself must never depend on being able to read the backup. Only the wording does.
    $r = Invoke-BackupState -World (New-World -Key 'fd-0' -HasBackup -BackupReadThrows)
    Assert-Refused $r
    Assert-Text $r.Message 'restore first, then enforce again' 'unknown content must not claim knowledge it lacks'
    Assert-NoText $r.Message 'will NOT' 'it must not assert the backup is enforced when it could not read it'
    Assert-True (@($r.Calls | Where-Object { $_ -eq "Get-Content|$($r.Backup)" }).Count -eq 1) `
        'the read was attempted and the throw was caught inside the guard'
}

Test-Case 'F7: the pasted commands survive a BackupDir containing a space' {
    $dir = 'C:\lab dir\macdows matrix'
    $r = Invoke-BackupState -World (New-World -Key 'fd-0' -HasBackup) -BackupDirValue $dir
    Assert-Refused $r
    Assert-Text $r.Message ("& '$($r.ScriptPath)' -Mode Restore -BackupDir '$dir'") 'restore command is paste-able'
    Assert-Text $r.Message ("& '$($r.ScriptPath)' -Mode Enforce -BackupDir '$dir'") 'enforce command is paste-able'
}

Test-Case '$ScriptPath falls back to a bare filename when $PSCommandPath is empty' {
    $r = Invoke-BackupState -World (New-World -Key 'fd-0' -HasBackup) -CommandPath ''
    Assert-Refused $r
    Assert-Equal 'Set-TsAllowListMatrix.ps1' $r.ScriptPath 'the pasted-into-a-console fallback'
    Assert-Text $r.Message "& 'Set-TsAllowListMatrix.ps1' -Mode Restore" 'the fallback still produces a runnable line'
}

Test-Case 'F2 refusal names the surviving backup and tells the operator to finish the restore' {
    $r = Invoke-BackupState -World (New-World -Key 'key-absent' -HasBackup)
    Assert-Refused $r
    Assert-Text $r.Message 'REFUSING to record TSAppAllowList as absent' 'the key-absent branch has its own refusal'
    Assert-Text $r.Message $r.Backup 'it names the backup that would have been deleted'
    Assert-Text $r.Message 'Finish the restore first' 'it names the credible route out'
    Assert-Text $r.Message ("& '$($r.ScriptPath)' -Mode Restore -BackupDir '$($r.BackupDir)'") 'paste-able there too'
}

Test-Case 'refusals leave the marker and the backup byte-identical on disk' {
    $r = Invoke-BackupState -World (New-World -Key 'fd-0' -HasBackup -HasMarker)
    Assert-Refused $r
    Assert-FilesUnchanged $r
    Assert-Equal $script:PristineBackup $r.Files[$r.Backup] 'the pre-enforce snapshot is untouched'
}

# -------------------------------------------------------------------------------------------
New-Section 'lifecycle -- the runs that MUST NOT be blocked'
# -------------------------------------------------------------------------------------------

Test-Case 'key-ABSENT first Enforce proceeds and records "the key was absent"' {
    $r = Invoke-BackupState -World (New-World -Key 'key-absent')
    Assert-Proceeded $r
    Assert-TookMarkerPath $r
    Assert-True ($r.Files.ContainsKey($r.Marker)) 'the marker is now on disk'
    Assert-Text $r.Files[$r.Marker] 'did not exist before this run' 'and says what it means'
    Assert-True (-not $r.Files.ContainsKey($r.Backup)) 'no backup was invented'
}

Test-Case 'fresh after a backup-path Restore: fd is back to 1, so Enforce proceeds' {
    # Restore re-imported the snapshot, so the key reads its pre-lab value again. The backup is
    # still on disk -- and that combination must NOT be refused, or the lab locks itself out.
    $r = Invoke-BackupState -World (New-World -Key 'fd-1' -HasBackup)
    Assert-Proceeded $r
    Assert-TookExportPath $r
    Assert-Text $r.Files[$r.Backup] 'dword:00000001' 'the refreshed export still records the not-enforced state'
}

Test-Case 'fresh after a marker-path Restore: the key is absent again, so Enforce proceeds' {
    $r = Invoke-BackupState -World (New-World -Key 'key-absent' -HasMarker)
    Assert-Proceeded $r
    Assert-TookMarkerPath $r
    Assert-True ($r.Files.ContainsKey($r.Marker)) 'the marker is rewritten, not deleted'
}

Test-Case 'the enforced-branch guard is the FIRST act in the branch' {
    # Placement is the whole safety property: a guard that runs after Remove-Item or after the
    # export protects nothing. Measured, not read: on a refusing cell the only calls made are
    # the reads the guard itself performs.
    $r = Invoke-BackupState -World (New-World -Key 'fd-0' -HasBackup -HasMarker)
    Assert-Refused $r
    foreach ($c in $r.Calls) {
        Assert-True ($c.StartsWith('Test-Path|') -or $c.StartsWith('Get-ItemProperty|') -or
                     $c.StartsWith('Get-Content|')) "a refusing run performed a non-read call: $c"
    }
    Assert-Equal '' $r.Console 'a refusing run announces nothing -- it never got that far'
}

Test-Case 'a proceeding run protects $PolBak too, which the export guard also covers' {
    # $PolBak is overwritten unconditionally at the end of the function, so a second Enforce
    # would have replaced the saved policy value with the 0 the first Enforce wrote. Refusing at
    # the top of the branch is what stops that, one file over from the named hazard.
    $refused = Invoke-BackupState -World (New-World -Key 'fd-0' -HasBackup -Policy '0')
    Assert-Refused $refused
    Assert-True (-not $refused.Files.ContainsKey($refused.PolBak)) '$PolBak was never written on the refusal'
}

# -------------------------------------------------------------------------------------------
New-Section 'policy snapshot ($PolBak) on the proceeding paths'
# -------------------------------------------------------------------------------------------

foreach ($pol in @(
        @{ V = 'absent';   Expect = '<absent>'; Why = 'the policy key does not exist' },
        @{ V = 'no-value'; Expect = '<absent>'; Why = 'the key exists but carries no fAllowUnlistedRemotePrograms' },
        @{ V = '0';        Expect = '0';        Why = 'already closed' },
        @{ V = '1';        Expect = '1';        Why = 'open -- the value Restore has to put back' }
    )) {
    Test-Case ("policy {0,-8} -> `$PolBak records '{1}'  ({2})" -f $pol.V, $pol.Expect, $pol.Why) {
        $r = Invoke-BackupState -World (New-World -Key 'fd-1' -Policy $pol.V)
        Assert-Proceeded $r
        Assert-Equal $pol.Expect $r.Files[$r.PolBak] 'the saved policy value is what Restore will read back'
        Assert-Text $r.Console 'fAllowUnlistedRemotePrograms was' 'and it is announced'
    }
}

# -------------------------------------------------------------------------------------------
New-Section 'export failure'
# -------------------------------------------------------------------------------------------

Test-Case 'a non-zero reg export exit code aborts before anything claims success' {
    $r = Invoke-BackupState -World (New-World -Key 'fd-1' -RegExitCode 1)
    Assert-True $r.Threw 'a failed export must not be swallowed'
    Assert-Text $r.Message 'reg export failed (1)' 'and must name the exit code'
    Assert-True (-not $r.Files.ContainsKey($r.PolBak)) 'the policy snapshot is not written after a failed export'
    Assert-NoText $r.Console 'backed up' 'nothing announces a backup that did not happen'
}

# -------------------------------------------------------------------------------------------
New-Section 'strict-mode hygiene (the body normally runs with 5.1 defaults, i.e. no strict mode)'
# -------------------------------------------------------------------------------------------

Test-Case 'the refusing path is clean under Set-StrictMode -Version 2.0' {
    $r = Invoke-BackupState -World (New-World -Key 'fd-0' -HasBackup -HasMarker) -Strict
    Assert-Refused $r
    Assert-NoText $r.Message 'not been set' 'no uninitialised-variable error masquerading as a refusal'
}

Test-Case 'the export path is clean under Set-StrictMode -Version 2.0' {
    $r = Invoke-BackupState -World (New-World -Key 'fd-1' -Policy '1') -Strict
    Assert-Proceeded $r
    Assert-TookExportPath $r
}

Test-Case 'the marker path is clean under Set-StrictMode -Version 2.0' {
    $r = Invoke-BackupState -World (New-World -Key 'key-absent') -Strict
    Assert-Proceeded $r
    Assert-TookMarkerPath $r
}

# -------------------------------------------------------------------------------------------
New-Section 'mutation discrimination -- proof these cases would catch the guard being weakened'
# -------------------------------------------------------------------------------------------

function New-MutantBody {
    <#
      Rewrites ONE AST node inside the lifted Backup-State text and returns the mutated body.
      Fails loudly -- never silently skips -- if the target does not match exactly once, if the
      mutant stops parsing, if the text that had to disappear survived, or if nothing changed.
      All four mean this Tests file needs updating, not that the script is fine.
    #>
    param(
        [Parameter(Mandatory)][scriptblock] $Predicate,
        [Parameter(Mandatory)][AllowEmptyString()][string] $NewText,
        [string] $MustVanish
    )
    $nodes = @($script:BackupStateAst.FindAll($Predicate, $true))
    if ($nodes.Count -ne 1) {
        throw "mutation target matched $($nodes.Count) AST nodes, expected exactly 1 -- update this Tests file"
    }
    $base = $script:BackupStateAst.Extent.StartOffset
    $s = $nodes[0].Extent.StartOffset - $base
    $e = $nodes[0].Extent.EndOffset - $base
    $mut = $script:BackupStateText.Substring(0, $s) + $NewText + $script:BackupStateText.Substring($e)
    if ($mut -eq $script:BackupStateText) { throw 'the mutation changed nothing' }
    $tk = $null
    $er = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($mut, [ref]$tk, [ref]$er)
    if ($er.Count -ne 0) { throw "the mutant does not parse: $($er[0].Message)" }
    if ($MustVanish -and $mut.Contains($MustVanish)) { throw "the mutation did not remove [$MustVanish]" }
    return $mut
}

function Test-AssignmentTo {
    param([string] $Name)
    return {
        param($n)
        ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and
        ($n.Left -is [System.Management.Automation.Language.VariableExpressionAst]) -and
        ($n.Left.VariablePath.UserPath -eq $Name)
    }.GetNewClosure()
}

Test-Case 'mutant A: drop the marker half of $pristineExists -> the F1 cell stops refusing' {
    $mut = New-MutantBody -Predicate (Test-AssignmentTo 'pristineExists') `
        -NewText '$pristineExists = (Test-Path -LiteralPath $Backup)' `
        -MustVanish '-or (Test-Path -LiteralPath $Marker)'
    $world = { New-World -Key 'fd-0' -HasMarker }

    $real = Invoke-BackupState -World (& $world)
    Assert-Refused $real

    $bad = Invoke-BackupState -World (& $world) -Body $mut
    Assert-True (-not $bad.Threw) 'without the marker half the guard is not armed -- the pin bites'
    Assert-True ($bad.Calls -contains "Remove-Item|$($bad.Marker)") 'the mutant deletes the only pristine record'
    Assert-Text $bad.Files[$bad.Backup] 'dword:00000000' `
        'and writes a backup OF ENFORCED STATE, which Restore would later re-import as "prior configuration"'
}

Test-Case 'mutant B: remove the key-absent refusal -> a true backup is replaced by a false marker' {
    $mut = New-MutantBody -Predicate {
        param($n)
        if ($n -isnot [System.Management.Automation.Language.IfStatementAst]) { return $false }
        # Match on the if whose own THEN block IS the refusal. A plain
        # Extent.Text.Contains('REFUSING to record') matches two nodes -- the enclosing
        # if/else's extent covers its else branch, where this refusal lives -- and
        # New-MutantBody then rightly refuses to guess which one was meant.
        return $n.Clauses[0].Item2.Extent.Text.Contains('REFUSING to record')
    } -NewText '' -MustVanish 'REFUSING to record'
    $world = { New-World -Key 'key-absent' -HasBackup }

    $real = Invoke-BackupState -World (& $world)
    Assert-Refused $real
    Assert-True ($real.Files.ContainsKey($real.Backup)) 'the real code keeps the backup'

    $bad = Invoke-BackupState -World (& $world) -Body $mut
    Assert-True (-not $bad.Threw) 'without the guard the key-absent branch runs straight through -- the pin bites'
    Assert-True (-not $bad.Files.ContainsKey($bad.Backup)) 'the mutant deletes the true record of the prior configuration'
    Assert-True ($bad.Files.ContainsKey($bad.Marker)) 'and replaces it with a marker claiming the key never existed'
}

Test-Case 'mutant C: drop the enforced test -> the Restore -> Enforce cycle deadlocks' {
    # The other direction, and the one an over-eager "just refuse if a backup exists" fix would
    # produce: the guard must not fire when the host is not enforced, or the lab can never
    # re-enforce after a Restore.
    $mut = New-MutantBody -Predicate (Test-AssignmentTo 'alreadyEnforced') `
        -NewText '$alreadyEnforced = ($null -ne $cur)' `
        -MustVanish "[string]`$cur.fDisabledAllowList -eq '0'"
    $world = { New-World -Key 'fd-1' -HasBackup }

    $real = Invoke-BackupState -World (& $world)
    Assert-Proceeded $real
    Assert-TookExportPath $real

    $bad = Invoke-BackupState -World (& $world) -Body $mut
    Assert-True $bad.Threw 'the over-broad mutant refuses a perfectly safe run -- the pin bites'
    Assert-Text $bad.Message 'REFUSING to back up' 'and it refuses for the wrong reason'
}

# -------------------------------------------------------------------------------------------
New-Section 'this suite is read-only against the script under test'
# -------------------------------------------------------------------------------------------

Test-Case 'Set-TsAllowListMatrix.ps1 is byte-identical after the whole run' {
    $after = (Get-FileHash -LiteralPath $script:Src -Algorithm SHA256).Hash
    Assert-Equal $script:SrcHashBefore $after 'mutants are built in memory; the shipped file is never written'
}

# -------------------------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------------------------

Write-Host ''
Write-Host ("{0} test(s), {1} failed, {2} assertion(s)" -f
    $script:TestTotal, $script:TestFailed, $script:AssertTotal)
if ($script:TestFailed -gt 0) {
    Write-Host ''
    foreach ($f in $script:TestFailures) { Write-Host "  - $f" }
    exit 1
}
exit 0
