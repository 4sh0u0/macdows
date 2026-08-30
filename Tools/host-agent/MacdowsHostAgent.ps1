<#
.SYNOPSIS
    Macdows host-agent feasibility prototype (Phase 2 work item W7).

.DESCRIPTION
    A small HTTP agent that runs inside the user's Windows RDP session and answers three
    questions the RDP/RAIL wire cannot:

      1. Which RemoteApps are published (TSAppAllowList) and what do their icons look like?
      2. Can we launch a program that is NOT published as a RemoteApp (proxied launch)?
      3. Which executable would open a given file extension for this user (.pdf)?

    Trust model: loopback TCP + a per-launch bearer token + a static allowlist of programs.
    The agent never accepts a path, command line, or arguments from a request, never writes
    to the registry, never elevates, and never installs anything.

    Target runtime is Windows PowerShell 5.1 / .NET Framework 4.8 on the host. The file also
    loads under PowerShell 7 on macOS so its pure parts can be unit-tested there; every
    Windows-only call is isolated behind a small function that degrades to $null off-Windows.

    Prototype only. Not a product. See README.md and adr/0012 for context.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\MacdowsHostAgent.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\MacdowsHostAgent.ps1 -AllowlistPath .\allowlist.json -Verbose
#>

[CmdletBinding()]
param(
    # TCP port to listen on.
    [int] $Port = 47615,

    # Address to bind. Default is loopback: reachable only from inside the RDP session.
    # Binding anything else is a prototype-only deviation (see README) and prints a warning.
    [string] $BindAddress = '127.0.0.1',

    # Agent allowlist (the only programs /v1/launch can ever start).
    [string] $AllowlistPath,

    # Where the per-launch token is written. Defaults to %LOCALAPPDATA%\Macdows\host-agent\token.
    [string] $TokenPath,

    # Serve exactly one connection and exit. Used by the test suite.
    [switch] $Once,

    # Define functions but do not start the server (for dot-sourcing from tests).
    [switch] $NoServe
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:MacdowsAgentName = 'macdows-host-agent'
$script:MacdowsAgentVersion = '0.1.0'
$script:MacdowsMaxRequestBytes = 65536      # 64 KiB
$script:MacdowsSocketTimeoutMs = 5000       # per-connection read/write timeout
$script:MacdowsConnectionDeadlineSeconds = 15  # absolute per-connection deadline (see Test-MacdowsDeadlineExceeded)
$script:MacdowsMaxHeaderCount = 64
$script:MacdowsMaxHeaderLineLength = 8192

# Basenames we refuse to put behind /v1/launch even if the operator lists them. A shell or a
# script host would turn the fixed-path allowlist back into arbitrary command execution,
# which is exactly the property this prototype is meant to demonstrate we can avoid.
$script:MacdowsInterpreterDenyList = @(
    'cmd', 'powershell', 'powershell_ise', 'pwsh', 'wscript', 'cscript', 'mshta',
    'rundll32', 'regsvr32', 'msbuild', 'installutil', 'sh', 'bash', 'zsh'
)

# ---------------------------------------------------------------------------------------------
# Platform helpers
# ---------------------------------------------------------------------------------------------

function Test-MacdowsIsWindows {
    <#
      Windows PowerShell 5.1 has no $IsWindows automatic variable and only ever runs on Windows,
      so the absence of the variable is itself the answer.
    #>
    [CmdletBinding()]
    param()
    $v = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $v) { return $true }
    return [bool]$v.Value
}

function Get-MacdowsProperty {
    <#
      StrictMode-safe field read that works for both a dictionary (what the association probes
      return) and a PSCustomObject (what a test or ConvertFrom-Json may inject). Missing field
      yields $null instead of an exception.
    #>
    [CmdletBinding()]
    param($InputObject, [string] $Name)

    if ($null -eq $InputObject) { return $null }
    try {
        if ($InputObject -is [System.Collections.IDictionary]) {
            if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
            return $null
        }
        if (@($InputObject.PSObject.Properties.Name) -notcontains $Name) { return $null }
        return $InputObject.$Name
    } catch {
        return $null
    }
}

function Write-MacdowsLine {
    # Startup banner / operational log. Goes to stdout so `-RedirectStandardOutput` captures it.
    [CmdletBinding()]
    param([string] $Message)
    [Console]::Out.WriteLine($Message)
    [Console]::Out.Flush()
}

# ---------------------------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------------------------

function New-MacdowsToken {
    <#
      32 random bytes as lowercase hex. RandomNumberGenerator::Create() returns an
      RNGCryptoServiceProvider on .NET Framework 4.8 and the platform CSPRNG on .NET 8;
      using the factory keeps the same call site valid on both runtimes.
    #>
    [CmdletBinding()]
    param([int] $ByteCount = 32)
    $bytes = New-Object 'byte[]' $ByteCount
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        if ($rng -is [System.IDisposable]) { $rng.Dispose() }
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

function Get-MacdowsDefaultTokenPath {
    [CmdletBinding()]
    param()
    $root = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($root)) {
        # Off-Windows fallback so the test suite has somewhere to put the file.
        $root = Join-Path $HOME '.local/share'
    }
    return (Join-Path (Join-Path (Join-Path $root 'Macdows') 'host-agent') 'token')
}

function Protect-MacdowsTokenFile {
    <#
      Best-effort restrictive permissions on the token file.

      On Windows the default %LOCALAPPDATA% ACL already excludes other standard accounts, but
      that protection comes from inheritance rather than from anything this script does - and
      -TokenPath can point anywhere. So the DACL is replaced outright with a protected one
      granting only the identity the agent runs as. Everything Windows-only (Get-Acl/Set-Acl,
      WindowsIdentity, FileSystemAccessRule) sits inside the Windows branch and is resolved at
      run time, so pwsh on macOS never touches any of it.

      Off-Windows (the ~/.local/share fallback, which exists only so the test suite has
      somewhere to put the file) the equivalent is chmod 600.

      Returns $true when the permissions were tightened, $false when they were left alone.
      Never throws: failing to tighten an ACL must not stop the agent from starting.
    #>
    [CmdletBinding()]
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    if (Test-MacdowsIsWindows) {
        try {
            $sid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User
            # A FileSecurity built here, NOT one read back with Get-Acl. A descriptor read off
            # an NTFS file carries the SACL control bits (SE_SACL_PRESENT / SE_SACL_AUTO_INHERITED
            # are set on essentially every file), so writing that same descriptor back asks
            # Windows to set the audit section too - which requires SeSecurityPrivilege, a
            # privilege an ordinary interactive/RDP account does not hold. The first live
            # Windows PowerShell 5.1 run failed exactly there: "The process does not possess the
            # 'SeSecurityPrivilege' privilege which is required for this operation".
            #
            # A fresh FileSecurity starts with nothing modified, and File.SetAccessControl
            # persists ONLY the sections that were modified on the object. Touching just the
            # access rules therefore writes just the DACL: no owner, no group, no SACL, no
            # privilege beyond the WRITE_DAC the file's owner already has.
            $acl = New-Object System.Security.AccessControl.FileSecurity
            # (protect, preserveInheritance = $false): drop every inherited ACE instead of
            # copying it in, so what is left is only what this function puts there.
            $acl.SetAccessRuleProtection($true, $false)
            # A default-constructed descriptor is NOT empty: when CommonSecurityDescriptor is
            # handed a null DACL it synthesises DiscretionaryAcl.CreateAllowEveryoneFullAccess,
            # and that ACE is explicit, so SetAccessRuleProtection does not remove it. Adding a
            # rule on top of it would publish a token file readable by every account on the
            # host - the exact opposite of the point. Clear the rules first, by SID so no
            # account-name translation is attempted, then add the single ACE we want.
            foreach ($existing in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
                [void]$acl.RemoveAccessRuleAll($existing)
            }
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, 'FullControl', 'None', 'None', 'Allow')
            $acl.SetAccessRule($rule)
            [System.IO.File]::SetAccessControl($Path, $acl)
            return $true
        } catch {
            # Not fatal: on a share or a redirected profile this can legitimately fail, and
            # the inherited %LOCALAPPDATA% ACL is still the default protection.
            Write-Verbose "could not set an explicit DACL on the token file: $($_.Exception.Message)"
            return $false
        }
    }

    try {
        # Native call, so no dependency on a .NET API that does not exist on 5.1. This branch
        # is unreachable on the host.
        & chmod 600 $Path 2>$null
        return $true
    } catch {
        Write-Verbose "could not chmod the token file: $($_.Exception.Message)"
        return $false
    }
}

function Save-MacdowsToken {
    <#
      Writes the token and returns the path it actually landed on. That return value is what the
      caller passes on as -TokenPath, so anchoring the path here anchors the whole lifecycle.
    #>
    [CmdletBinding()]
    param([string] $Token, [string] $Path)

    # Said plainly, once, here. GetFullPath('') raises ArgumentException and GetFullPath($null)
    # ArgumentNullException, both naming a parameter the caller of this function never saw; a
    # caller that forgot -TokenPath deserves to be told that rather than shown a .NET stack.
    # (For pathological non-empty input the two runtimes disagree - .NET Framework 4.8 rejects
    # '*' and '?' outright and enforces MAX_PATH, .NET on PowerShell 7 accepts both and lets
    # the filesystem answer - but either way the call throws for input this function cannot
    # use, and only the message text differs. Nothing here depends on which one raised it.)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'token path is required' }

    # A relative -TokenPath is resolved by two different roots below: [IO.File]::WriteAllText
    # uses [Environment]::CurrentDirectory (the process working directory) while Test-Path and
    # Remove-Item -LiteralPath use $PWD (the PowerShell location). In a session where those two
    # differ - which is the normal state after Set-Location - the file would be written in one
    # place and the chmod/DACL and the removal would look in another and silently do nothing.
    # Resolving once, against the same root WriteAllText uses, keeps every later step pointed at
    # the file that was actually written.
    $Path = [System.IO.Path]::GetFullPath($Path)

    # Split-Path returns '' for a bare filename such as -TokenPath token; creating '' fails.
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
        # Directory.CreateDirectory rather than New-Item: New-Item has no -LiteralPath (not
        # even on PowerShell 7), so a -TokenPath containing '[', ']' or '*' would be glob-
        # expanded. The .NET call treats the string literally and is idempotent.
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    [System.IO.File]::WriteAllText($Path, $Token, (New-Object System.Text.UTF8Encoding($false)))
    [void](Protect-MacdowsTokenFile -Path $Path)
    return $Path
}

function Remove-MacdowsTokenFile {
    <#
      The token is per-launch, so it is spent the moment the agent stops. Leaving the file
      behind means a stale token sits in %LOCALAPPDATA% indefinitely, and while the agent is
      not running another local process can bind the port and be handed that token by a probe.

      -Token makes the removal an ownership check rather than a blind delete (review finding
      N3): the default token path is shared by every agent this user starts, so an agent that
      is shutting down must only take away the file that still holds ITS token. If another
      agent has since written its own token there, the file belongs to that agent and is left
      alone. A file that cannot be read is also left alone - a delete on a guess is exactly
      what the check exists to prevent.

      Passing no -Token skips the check and deletes unconditionally, which is the old
      behaviour; the agent itself always passes one.

      Returns $true when a file was actually removed. Never throws.
    #>
    [CmdletBinding()]
    param([string] $Path, [string] $Token)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        # [System.IO.File] for all three steps rather than a mix of Test-Path/Remove-Item and
        # ReadAllText. The cmdlets resolve a relative path against $PWD (the PowerShell
        # location) while the .NET calls resolve against [Environment]::CurrentDirectory (the
        # process working directory), and when those two differ the function would check one
        # file, read a second and delete a third. One root throughout means the file it
        # confirms is the file it deletes. Every caller inside the agent passes the absolute
        # path Save-MacdowsToken returned, so this is about not splitting the function against
        # itself when someone hands it a relative one.
        if (-not [System.IO.File]::Exists($Path)) { return $false }
        if (-not [string]::IsNullOrEmpty($Token)) {
            $current = $null
            try {
                $current = [System.IO.File]::ReadAllText($Path)
            } catch {
                Write-Verbose "could not read the token file '$Path' to confirm ownership: $($_.Exception.Message)"
                return $false
            }
            if ($null -ne $current) { $current = $current.Trim() }
            if ($current -cne $Token) {
                Write-Verbose "token file '$Path' holds another agent's token; leaving it in place"
                return $false
            }
        }
        # Review finding Q1: on Windows, File.Delete throws UnauthorizedAccessException for a
        # file carrying the read-only attribute, where the old Remove-Item -Force cleared it
        # first. Best-effort attribute reset in its own try so an odd filesystem cannot turn
        # the delete into a silent no-op; keeping File.Delete preserves M4's single-root
        # property (Remove-Item resolves against $PWD, everything here resolves against
        # Environment.CurrentDirectory).
        try { [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::Normal) } catch { }
        [System.IO.File]::Delete($Path)
        return $true
    } catch {
        Write-Verbose "could not remove the token file '$Path': $($_.Exception.Message)"
        return $false
    }
}

function Test-MacdowsTokenMatch {
    <#
      Constant-time comparison: always walks the longer of the two buffers and folds the
      length difference into the accumulator, so neither length nor first-mismatch position
      is observable through timing.
    #>
    [CmdletBinding()]
    param([string] $Expected, [string] $Provided)

    if ([string]::IsNullOrEmpty($Expected)) { return $false }
    if ($null -eq $Provided) { $Provided = '' }

    $e = [System.Text.Encoding]::UTF8.GetBytes($Expected)
    $p = [System.Text.Encoding]::UTF8.GetBytes($Provided)
    $max = [Math]::Max($e.Length, $p.Length)
    $diff = $e.Length -bxor $p.Length
    for ($i = 0; $i -lt $max; $i++) {
        $eb = 0
        if ($i -lt $e.Length) { $eb = $e[$i] }
        $pb = 0
        if ($i -lt $p.Length) { $pb = $p[$i] }
        $diff = $diff -bor ($eb -bxor $pb)
    }
    return ($diff -eq 0)
}

# ---------------------------------------------------------------------------------------------
# Allowlist
# ---------------------------------------------------------------------------------------------

function Expand-MacdowsStringToken {
    <#
      Case-insensitive literal token replacement. Done by hand rather than with -replace or
      Regex.Replace because both give '$' and '\' special meaning in the replacement text,
      and a Windows path is exactly the kind of string that trips over that.
    #>
    [CmdletBinding()]
    param([string] $Text, [string] $Token, [string] $Value)

    $out = $Text
    $from = 0
    while ($from -le $out.Length) {
        $idx = $out.IndexOf($Token, $from, [System.StringComparison]::OrdinalIgnoreCase)
        if ($idx -lt 0) { break }
        $out = $out.Substring(0, $idx) + $Value + $out.Substring($idx + $Token.Length)
        # Resume past the substituted text so a value containing the token cannot loop forever.
        $from = $idx + $Value.Length
    }
    return $out
}

function Expand-MacdowsPathTokens {
    <#
      Resolves %SystemRoot% / %windir% against an explicit root instead of the process
      environment, so the resolution is deterministic and testable off-Windows.
    #>
    [CmdletBinding()]
    param([string] $Path, [string] $SystemRoot)

    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ([string]::IsNullOrEmpty($SystemRoot)) { return $Path }

    $trimmed = $SystemRoot.TrimEnd('\', '/')
    $result = Expand-MacdowsStringToken -Text $Path -Token '%SystemRoot%' -Value $trimmed
    $result = Expand-MacdowsStringToken -Text $result -Token '%windir%' -Value $trimmed
    return $result
}

function ConvertTo-MacdowsComparablePath {
    <#
      Normalises a Windows path for equality comparison: strips quotes and whitespace, resolves
      %SystemRoot%/%windir% against the supplied root and any remaining %TOKEN% against the
      process environment, unifies separators, collapses repeats, drops a trailing separator,
      and lower-cases.

      This exists because the two sides of the inTsAllowList comparison arrive in different
      shapes. Allowlist paths are expanded at load time, but TSAppAllowList\Applications\*\Path
      values are commonly stored with an environment token still in them
      (%SystemRoot%\system32\..., %SystemDrive%\...). Comparing those raw would report a
      published application as not published, and both probes pick the launch target from that
      field - which would turn a capability-2 PASS into a false positive.

      %SystemRoot% is resolved from an explicit root rather than the environment so the Windows
      behaviour stays deterministic and testable off-Windows.
    #>
    [CmdletBinding()]
    param([string] $Path, [string] $SystemRoot)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }

    $result = $Path.Trim().Trim('"').Trim()
    $result = Expand-MacdowsPathTokens -Path $result -SystemRoot $SystemRoot
    try {
        $result = [Environment]::ExpandEnvironmentVariables($result)
    } catch {
        # Leave the token in place; an unresolved token simply will not match anything.
    }

    $result = $result.Replace('/', '\')
    # Collapse repeated separators, preserving a leading UNC '\\'.
    $isUnc = $result.StartsWith('\\')
    while ($result.Contains('\\')) { $result = $result.Replace('\\', '\') }
    if ($isUnc) { $result = '\' + $result }

    if ($result.Length -gt 1) { $result = $result.TrimEnd('\') }
    return $result.ToLowerInvariant()
}

function Test-MacdowsAbsolutePath {
    <#
      Windows drive path, UNC path, or POSIX path. [IO.Path]::IsPathRooted is not usable here:
      on Unix it reports 'C:\Windows\x.exe' as relative, which would make the Windows rules
      untestable on macOS.
    #>
    [CmdletBinding()]
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return [bool]($Path -match '^([A-Za-z]:[\\/]|\\\\|/)')
}

function ConvertTo-MacdowsWindowsSeparator {
    <#
      Canonicalises the separators of a Windows path to '\'.

      Win32 accepts '/' in most places, so an allowlist entry written as C:/Tools/app.exe or a
      %SystemRoot%/System32/app.exe still opens - but the resolved path is not only compared,
      it is handed to Start-Process and published in /v1/apps, so what gets recorded should
      look like a Windows path rather than like whatever the operator happened to type. The
      first live 5.1 run surfaced this as a resolved path reading
      C:\...\FakeSystemRoot/System32/app.exe.

      Only drive-rooted and UNC paths are touched. A POSIX path is returned untouched: on Unix
      '\' is an ordinary filename character, and the test suite runs off-Windows against real
      files under the system temp directory.
    #>
    [CmdletBinding()]
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ($Path -match '^([A-Za-z]:[\\/]|\\\\)') { return $Path.Replace('/', '\') }
    return $Path
}

function Test-MacdowsInterpreterPath {
    [CmdletBinding()]
    param([string] $Path)
    $leaf = $Path -replace '^.*[\\/]', ''
    $stem = $leaf -replace '\.[^.]*$', ''
    return ($script:MacdowsInterpreterDenyList -contains $stem.ToLowerInvariant())
}

function Import-MacdowsAllowlist {
    <#
      Loads and validates the agent allowlist. Returns .Entries (accepted) and .Errors
      (human-readable rejection reasons); a bad entry never takes the whole file down.
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [string] $SystemRoot,
        # Test hook: file-existence probe, so validation can be exercised without real files.
        [scriptblock] $FileExistsProbe
    )

    $entries = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    if ($null -eq $FileExistsProbe) {
        $FileExistsProbe = { param($p) Test-Path -LiteralPath $p -PathType Leaf }
    }

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        [void]$errors.Add("allowlist file not found: $Path")
        return [pscustomobject]@{ Entries = @(); Errors = @($errors.ToArray()) }
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    $doc = $null
    try {
        $doc = ConvertFrom-Json $raw
    } catch {
        [void]$errors.Add("allowlist is not valid JSON: $($_.Exception.Message)")
        return [pscustomobject]@{ Entries = @(); Errors = @($errors.ToArray()) }
    }

    $items = @()
    if ($doc -is [System.Array]) {
        $items = @($doc)
    } elseif ($null -ne $doc -and ($doc.PSObject.Properties.Name -contains 'entries')) {
        $items = @($doc.entries)
    } else {
        [void]$errors.Add("allowlist must be a JSON array or an object with an 'entries' array")
        return [pscustomobject]@{ Entries = @(); Errors = @($errors.ToArray()) }
    }

    $seen = @{}
    $index = -1
    foreach ($item in $items) {
        $index++
        $label = "entry[$index]"
        if ($null -eq $item) { [void]$errors.Add("${label}: is null"); continue }

        $names = @($item.PSObject.Properties.Name)
        $id = $null
        if ($names -contains 'id') { $id = [string]$item.id }
        if ([string]::IsNullOrWhiteSpace($id)) { [void]$errors.Add("${label}: missing 'id'"); continue }
        $label = "entry '$id'"
        if ($id -notmatch '^[A-Za-z0-9._-]{1,64}$') {
            [void]$errors.Add("${label}: id must match ^[A-Za-z0-9._-]{1,64}$"); continue
        }
        if ($seen.ContainsKey($id)) { [void]$errors.Add("${label}: duplicate id"); continue }

        $rawPath = $null
        if ($names -contains 'path') { $rawPath = [string]$item.path }
        if ([string]::IsNullOrWhiteSpace($rawPath)) { [void]$errors.Add("${label}: missing 'path'"); continue }

        # Canonicalise separators before every check below, so the '..' rule, the existence
        # probe, the recorded path and the path Start-Process is later given are all the same
        # string in the same shape.
        $resolved = ConvertTo-MacdowsWindowsSeparator -Path (Expand-MacdowsPathTokens -Path $rawPath -SystemRoot $SystemRoot)
        if ($resolved -match '%[A-Za-z0-9_()]+%') {
            [void]$errors.Add("${label}: unresolved environment token in path"); continue
        }
        if (-not (Test-MacdowsAbsolutePath -Path $resolved)) {
            [void]$errors.Add("${label}: path is not absolute: $rawPath"); continue
        }
        if ($resolved -match '(^|[\\/])\.\.([\\/]|$)') {
            [void]$errors.Add("${label}: path contains a '..' segment"); continue
        }
        if (Test-MacdowsInterpreterPath -Path $resolved) {
            [void]$errors.Add("${label}: shells and script hosts are not allowed"); continue
        }
        # In Windows PowerShell 5.1, Start-Process -FilePath without redirection uses
        # ShellExecute, so a non-program target (a .docx, a .hta) would launch that file type's
        # registered handler instead. Requiring a program extension is what makes "this agent
        # can only ever start a fixed list of programs" actually hold - the basename deny-list
        # above does not constrain a data file at all.
        if ($resolved -notmatch '\.(?i:exe|com)$') {
            [void]$errors.Add("${label}: only .exe and .com targets are allowed"); continue
        }
        if (-not (& $FileExistsProbe $resolved)) {
            [void]$errors.Add("${label}: file does not exist: $resolved"); continue
        }

        $argList = @()
        if ($names -contains 'args' -and $null -ne $item.args) {
            $badArg = $false
            foreach ($a in @($item.args)) {
                if ($a -isnot [string]) { $badArg = $true; break }
                $argList += $a
            }
            if ($badArg) { [void]$errors.Add("${label}: 'args' must be an array of strings"); continue }
        }

        $displayName = $id
        if ($names -contains 'name' -and -not [string]::IsNullOrWhiteSpace([string]$item.name)) {
            $displayName = [string]$item.name
        }

        $seen[$id] = $true
        [void]$entries.Add([pscustomobject]@{
            id   = $id
            name = $displayName
            path = $resolved
            args = @($argList)
        })
    }

    return [pscustomobject]@{ Entries = @($entries.ToArray()); Errors = @($errors.ToArray()) }
}

# ---------------------------------------------------------------------------------------------
# HTTP: parsing
# ---------------------------------------------------------------------------------------------

function Get-MacdowsReasonPhrase {
    [CmdletBinding()]
    param([int] $Status)
    switch ($Status) {
        200 { return 'OK' }
        400 { return 'Bad Request' }
        401 { return 'Unauthorized' }
        404 { return 'Not Found' }
        405 { return 'Method Not Allowed' }
        408 { return 'Request Timeout' }
        413 { return 'Payload Too Large' }
        500 { return 'Internal Server Error' }
        default { return 'Error' }
    }
}

function New-MacdowsBadRequest {
    [CmdletBinding()]
    param([int] $Status, [string] $Detail)
    Write-Verbose "request rejected ($Status): $Detail"
    return [pscustomobject]@{
        Ok      = $false
        Status  = $Status
        Detail  = $Detail
        Method  = $null
        Target  = $null
        Path    = $null
        Query   = @{}
        Headers = @{}
        Body    = ''
    }
}

function Test-MacdowsDeadlineExceeded {
    <#
      Absolute per-connection deadline. The socket timeout is per-read and every byte received
      resets it, so a client that trickles data is never timed out by the socket alone - and the
      accept loop is single-threaded, so one such connection would block every other request.
    #>
    [CmdletBinding()]
    param([datetime] $Deadline)

    if ($null -eq $Deadline -or $Deadline -eq [datetime]::MinValue) { return $false }
    return ((Get-Date) -gt $Deadline)
}

function Find-MacdowsHeaderEnd {
    <#
      -StartAt lets the caller resume the scan just behind the previous tail instead of
      restarting at index 0 on every read, which is what makes reading a large head linear
      rather than quadratic.
    #>
    [CmdletBinding()]
    param([byte[]] $Bytes, [int] $Length, [int] $StartAt = 0)
    $from = $StartAt
    if ($from -lt 0) { $from = 0 }
    for ($i = $from; $i -le ($Length - 4); $i++) {
        if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10 -and $Bytes[$i + 2] -eq 13 -and $Bytes[$i + 3] -eq 10) {
            return $i
        }
    }
    return -1
}

function ConvertFrom-MacdowsQueryString {
    [CmdletBinding()]
    param([string] $QueryString)
    $result = @{}
    if ([string]::IsNullOrEmpty($QueryString)) { return $result }
    foreach ($pair in ($QueryString -split '&')) {
        if ([string]::IsNullOrEmpty($pair)) { continue }
        $eq = $pair.IndexOf('=')
        if ($eq -lt 0) {
            $k = $pair
            $v = ''
        } else {
            $k = $pair.Substring(0, $eq)
            $v = $pair.Substring($eq + 1)
        }
        try {
            $k = [System.Uri]::UnescapeDataString($k.Replace('+', ' '))
            $v = [System.Uri]::UnescapeDataString($v.Replace('+', ' '))
        } catch {
            # Malformed percent-encoding: keep the raw text; route validation rejects it anyway.
        }
        if (-not $result.ContainsKey($k)) { $result[$k] = $v }
    }
    return $result
}

function ConvertFrom-MacdowsHttpHead {
    <#
      Parses the request head (everything before the blank line). Accepts only GET and POST,
      only HTTP/1.x, and only well-formed header lines. Anything else is rejected here so the
      route layer never sees a half-understood request.
    #>
    [CmdletBinding()]
    param([string] $HeadText)

    $lines = $HeadText -split "`r`n"
    if ($lines.Count -lt 1 -or [string]::IsNullOrWhiteSpace($lines[0])) {
        return (New-MacdowsBadRequest -Status 400 -Detail 'empty request line')
    }

    $requestLine = $lines[0]
    if ($requestLine.Length -gt $script:MacdowsMaxHeaderLineLength) {
        return (New-MacdowsBadRequest -Status 400 -Detail 'request line too long')
    }
    $parts = $requestLine -split ' '
    if ($parts.Count -ne 3) {
        return (New-MacdowsBadRequest -Status 400 -Detail 'malformed request line')
    }
    $method = $parts[0]
    $target = $parts[1]
    $version = $parts[2]

    if ($version -notmatch '^HTTP/1\.[01]$') {
        return (New-MacdowsBadRequest -Status 400 -Detail 'unsupported HTTP version')
    }
    if ($method -cnotmatch '^[A-Z]{3,10}$') {
        return (New-MacdowsBadRequest -Status 400 -Detail 'malformed method')
    }
    if ($method -cne 'GET' -and $method -cne 'POST') {
        return (New-MacdowsBadRequest -Status 405 -Detail "method not allowed: $method")
    }
    if (-not $target.StartsWith('/')) {
        return (New-MacdowsBadRequest -Status 400 -Detail 'request target must be an origin-form path')
    }

    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($line.Length -gt $script:MacdowsMaxHeaderLineLength) {
            return (New-MacdowsBadRequest -Status 400 -Detail 'header line too long')
        }
        if ($line[0] -eq ' ' -or $line[0] -eq "`t") {
            return (New-MacdowsBadRequest -Status 400 -Detail 'obsolete header line folding')
        }
        $colon = $line.IndexOf(':')
        if ($colon -lt 1) {
            return (New-MacdowsBadRequest -Status 400 -Detail 'malformed header line')
        }
        $name = $line.Substring(0, $colon).Trim().ToLowerInvariant()
        $value = $line.Substring($colon + 1).Trim()
        if ($name -notmatch '^[A-Za-z0-9!#$%&''*+\-.^_`|~]+$') {
            return (New-MacdowsBadRequest -Status 400 -Detail 'malformed header name')
        }
        if ($headers.ContainsKey($name)) {
            # Duplicate Content-Length is a request-smuggling primitive; refuse outright.
            return (New-MacdowsBadRequest -Status 400 -Detail "duplicate header: $name")
        }
        $headers[$name] = $value
        if ($headers.Count -gt $script:MacdowsMaxHeaderCount) {
            return (New-MacdowsBadRequest -Status 400 -Detail 'too many headers')
        }
    }

    if ($headers.ContainsKey('transfer-encoding')) {
        return (New-MacdowsBadRequest -Status 400 -Detail 'transfer-encoding is not supported')
    }

    $path = $target
    $queryString = ''
    $q = $target.IndexOf('?')
    if ($q -ge 0) {
        $path = $target.Substring(0, $q)
        $queryString = $target.Substring($q + 1)
    }
    try {
        $path = [System.Uri]::UnescapeDataString($path)
    } catch {
        return (New-MacdowsBadRequest -Status 400 -Detail 'malformed percent-encoding in path')
    }
    $path = $path.TrimEnd('/')
    if ([string]::IsNullOrEmpty($path)) { $path = '/' }

    return [pscustomobject]@{
        Ok      = $true
        Status  = 200
        Detail  = $null
        Method  = $method
        Target  = $target
        Path    = $path
        Query   = (ConvertFrom-MacdowsQueryString -QueryString $queryString)
        Headers = $headers
        Body    = ''
    }
}

function Read-MacdowsHttpRequest {
    <#
      Reads one request off a stream. Takes any System.IO.Stream so the tests can drive it
      from a MemoryStream; the server passes a NetworkStream whose timeouts are already set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [System.IO.Stream] $Stream,
        [int] $MaxRequestBytes = 0,
        # Absolute wall-clock deadline for the whole request. [datetime]::MinValue disables it.
        [datetime] $Deadline = [datetime]::MinValue
    )

    if ($MaxRequestBytes -le 0) { $MaxRequestBytes = $script:MacdowsMaxRequestBytes }

    $chunk = New-Object 'byte[]' 4096
    $acc = New-Object System.IO.MemoryStream
    $headerEnd = -1
    $scannedTo = 0
    try {
        while ($true) {
            if (Test-MacdowsDeadlineExceeded -Deadline $Deadline) {
                return (New-MacdowsBadRequest -Status 408 -Detail 'request deadline exceeded while reading headers')
            }
            # GetBuffer() + an explicit length avoids copying the whole accumulator on every
            # read; the scan resumes 3 bytes behind the previous tail so a CRLFCRLF straddling
            # a chunk boundary is still found.
            $bytes = $acc.GetBuffer()
            $have = [int]$acc.Length
            $headerEnd = Find-MacdowsHeaderEnd -Bytes $bytes -Length $have -StartAt ([Math]::Max(0, $scannedTo - 3))
            if ($headerEnd -ge 0) { break }
            $scannedTo = $have
            if ($have -ge $MaxRequestBytes) {
                return (New-MacdowsBadRequest -Status 413 -Detail 'request head exceeds size limit')
            }
            $read = 0
            try {
                $read = $Stream.Read($chunk, 0, $chunk.Length)
            } catch {
                return (New-MacdowsBadRequest -Status 400 -Detail 'read failed or timed out')
            }
            if ($read -le 0) {
                return (New-MacdowsBadRequest -Status 400 -Detail 'connection closed before end of headers')
            }
            $acc.Write($chunk, 0, $read)
        }

        # Re-fetch: the last Write may have reallocated the backing buffer.
        $all = $acc.GetBuffer()
        $total = [int]$acc.Length
        if ($total -gt $MaxRequestBytes) {
            return (New-MacdowsBadRequest -Status 413 -Detail 'request exceeds size limit')
        }
        $headText = [System.Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
        $request = ConvertFrom-MacdowsHttpHead -HeadText $headText
        if (-not $request.Ok) { return $request }

        $bodyStart = $headerEnd + 4
        $bodyHave = $total - $bodyStart
        $contentLength = 0

        if ($request.Headers.ContainsKey('content-length')) {
            $clText = $request.Headers['content-length']
            $parsed = 0
            if (-not [int]::TryParse($clText, [ref]$parsed) -or $parsed -lt 0) {
                return (New-MacdowsBadRequest -Status 400 -Detail 'malformed Content-Length')
            }
            $contentLength = $parsed
        } elseif ($request.Method -ceq 'POST') {
            return (New-MacdowsBadRequest -Status 400 -Detail 'POST requires Content-Length')
        }

        if (($bodyStart + $contentLength) -gt $MaxRequestBytes) {
            return (New-MacdowsBadRequest -Status 413 -Detail 'request body exceeds size limit')
        }

        $bodyBuf = New-Object System.IO.MemoryStream
        if ($bodyHave -gt 0) {
            $take = [Math]::Min($bodyHave, $contentLength)
            if ($take -gt 0) { $bodyBuf.Write($all, $bodyStart, $take) }
        }
        while ($bodyBuf.Length -lt $contentLength) {
            if (Test-MacdowsDeadlineExceeded -Deadline $Deadline) {
                $bodyBuf.Dispose()
                return (New-MacdowsBadRequest -Status 408 -Detail 'request deadline exceeded while reading body')
            }
            $want = [Math]::Min($chunk.Length, ($contentLength - $bodyBuf.Length))
            $read = 0
            try {
                $read = $Stream.Read($chunk, 0, $want)
            } catch {
                return (New-MacdowsBadRequest -Status 400 -Detail 'body read failed or timed out')
            }
            if ($read -le 0) {
                return (New-MacdowsBadRequest -Status 400 -Detail 'connection closed before end of body')
            }
            $bodyBuf.Write($chunk, 0, $read)
        }

        $bodyBytes = $bodyBuf.ToArray()
        $request.Body = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
        $bodyBuf.Dispose()
        return $request
    } finally {
        $acc.Dispose()
    }
}

function Write-MacdowsHttpResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [System.IO.Stream] $Stream,
        [int] $Status,
        [string] $Json
    )
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $Status " + (Get-MacdowsReasonPhrase -Status $Status) + "`r`n")
    [void]$sb.Append("Content-Type: application/json; charset=utf-8`r`n")
    [void]$sb.Append("Content-Length: $($bodyBytes.Length)`r`n")
    [void]$sb.Append("Cache-Control: no-store`r`n")
    [void]$sb.Append("X-Macdows-Agent: $($script:MacdowsAgentVersion)`r`n")
    [void]$sb.Append("Connection: close`r`n")
    [void]$sb.Append("`r`n")
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $Stream.Write($headBytes, 0, $headBytes.Length)
    $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $Stream.Flush()
}

# ---------------------------------------------------------------------------------------------
# Windows-only capability functions (each degrades to nulls off-Windows)
# ---------------------------------------------------------------------------------------------

function Get-MacdowsSessionInfo {
    [CmdletBinding()]
    param()
    $user = $env:USERNAME
    if ([string]::IsNullOrWhiteSpace($user)) { $user = $env:USER }
    if ([string]::IsNullOrWhiteSpace($user)) { $user = $null }
    $sessionId = $null
    try {
        $sessionId = (Get-Process -Id $PID).SessionId
    } catch {
        $sessionId = $null
    }
    return [pscustomobject]@{ user = $user; sessionId = $sessionId }
}

function Get-MacdowsTsAllowListDisabled {
    <#
      fDisabledAllowList on the TSAppAllowList key: 1 means "all applications allowed"
      (the allow list is not enforced). Returns $null when the key or value is absent,
      which is also what the caller gets off-Windows.
    #>
    [CmdletBinding()]
    param()
    if (-not (Test-MacdowsIsWindows)) { return $null }
    try {
        $base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList'
        if (-not (Test-Path -LiteralPath $base)) { return $null }
        $props = Get-ItemProperty -LiteralPath $base -ErrorAction Stop
        if (($props.PSObject.Properties.Name) -notcontains 'fDisabledAllowList') { return $null }
        return [bool][int]$props.fDisabledAllowList
    } catch {
        Write-Verbose "fDisabledAllowList read failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-MacdowsIconPngBase64 {
    <#
      Extracts an icon and re-encodes it as PNG. Tries ExtractIconEx first when an explicit
      icon index is given (it can return the 32x32 large icon from a multi-icon resource),
      then falls back to ExtractAssociatedIcon, then to loading a .ico directly. Any failure
      yields $null so one unreadable icon never fails the whole listing.
    #>
    [CmdletBinding()]
    param([string] $Path, [int] $IconIndex = 0)

    if (-not (Test-MacdowsIsWindows)) { return $null }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $expanded = $Path
    try { $expanded = [Environment]::ExpandEnvironmentVariables($Path) } catch { }
    if (-not (Test-Path -LiteralPath $expanded -PathType Leaf)) { return $null }

    $icon = $null
    $ownsIcon = $false
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        if (-not ([System.Management.Automation.PSTypeName]'Macdows.IconNative').Type) {
            Add-Type -Namespace 'Macdows' -Name 'IconNative' -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern int ExtractIconEx(string lpszFile, int nIconIndex, out IntPtr phiconLarge, out IntPtr phiconSmall, int nIcons);

[DllImport("user32.dll")]
public static extern bool DestroyIcon(IntPtr hIcon);
'@ -ErrorAction Stop
        }

        if ($expanded -match '\.ico$') {
            $icon = New-Object System.Drawing.Icon($expanded)
            $ownsIcon = $true
        } else {
            $large = [IntPtr]::Zero
            $small = [IntPtr]::Zero
            $count = [Macdows.IconNative]::ExtractIconEx($expanded, $IconIndex, [ref]$large, [ref]$small, 1)
            if ($count -gt 0 -and $large -ne [IntPtr]::Zero) {
                try {
                    # FromHandle does not own the handle; Clone() copies the image data so the
                    # handle can be destroyed immediately below.
                    $icon = [System.Drawing.Icon]([System.Drawing.Icon]::FromHandle($large).Clone())
                    $ownsIcon = $true
                } finally {
                    [void][Macdows.IconNative]::DestroyIcon($large)
                    if ($small -ne [IntPtr]::Zero) { [void][Macdows.IconNative]::DestroyIcon($small) }
                }
            } else {
                if ($small -ne [IntPtr]::Zero) { [void][Macdows.IconNative]::DestroyIcon($small) }
                $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($expanded)
                $ownsIcon = $true
            }
        }

        if ($null -eq $icon) { return $null }

        $bitmap = $icon.ToBitmap()
        try {
            $ms = New-Object System.IO.MemoryStream
            try {
                $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                return [Convert]::ToBase64String($ms.ToArray())
            } finally {
                $ms.Dispose()
            }
        } finally {
            $bitmap.Dispose()
        }
    } catch {
        Write-Verbose "icon extraction failed for '$Path': $($_.Exception.Message)"
        return $null
    } finally {
        if ($ownsIcon -and $null -ne $icon) {
            try { $icon.Dispose() } catch { }
        }
    }
}

function ConvertTo-MacdowsPublishedEntry {
    <#
      Reads one TSAppAllowList\Applications\* key into the shape /v1/apps publishes.

      Split out of the enumeration loop so that a single unreadable or oddly-typed key can be
      caught per entry (review finding B6) instead of aborting the listing, and so that the
      behaviour is testable off-Windows against a stand-in key object: anything exposing
      PSChildName and GetValue(name) will do.
    #>
    [CmdletBinding()]
    param($Key, $Context)

    $name = $Key.GetValue('Name')
    $path = $Key.GetValue('Path')
    $cls = $Key.GetValue('CommandLineSetting')
    $iconPath = $Key.GetValue('IconPath')
    $iconIndex = $Key.GetValue('IconIndex')
    if ($null -eq $iconIndex) { $iconIndex = 0 }

    $iconSource = $iconPath
    if ([string]::IsNullOrWhiteSpace($iconSource)) {
        $iconSource = $path
        $iconIndex = 0
    }
    $png = Invoke-MacdowsProvider -Context $Context -Name 'IconPng' -Arguments @($iconSource, [int]$iconIndex)

    return [ordered]@{
        key                = $Key.PSChildName
        name               = $name
        path               = $path
        commandLineSetting = $cls
        iconPath           = $iconPath
        iconIndex          = [int]$iconIndex
        iconPng            = $png
    }
}

function New-MacdowsSkippedPublishedEntry {
    <#
      Placeholder for a key that could not be read. Same field set as a real entry so a
      consumer does not have to special-case it, plus a readError saying what went wrong.
      Reported rather than dropped: a key that exists but cannot be read is information.

      -Reason is a fixed phrase plus an exception type, never exception text: this string is
      published in /v1/apps and lands in the probe's apps.json, which on the host is written
      to a redirected drive (review finding N5).
    #>
    [CmdletBinding()]
    param([string] $Key, [string] $Reason)

    return [ordered]@{
        key                = $Key
        name               = $null
        path               = $null
        commandLineSetting = $null
        iconPath           = $null
        iconIndex          = 0
        iconPng            = $null
        readError          = $Reason
    }
}

function ConvertTo-MacdowsPublishedList {
    <#
      Turns registry keys into published entries, one try/catch per key.

      Review finding B6: with a single try/catch around the whole loop, one malformed key
      (an IconIndex that is not a number, a value that cannot be read) silently truncated the
      listing at that point - every key after it disappeared with no indication that anything
      was missing. Icons already degrade per entry; keys now do too.
    #>
    [CmdletBinding()]
    param($Keys, $Context)

    $published = New-Object System.Collections.ArrayList
    foreach ($key in @($Keys)) {
        if ($null -eq $key) { continue }
        $childName = '(unknown)'
        try { $childName = [string]$key.PSChildName } catch { }
        try {
            [void]$published.Add((ConvertTo-MacdowsPublishedEntry -Key $key -Context $Context))
        } catch {
            # The exception message routinely quotes the value that failed - a bad IconIndex
            # reports as Cannot convert value "<the registry data>" to type ... - and this
            # string is published verbatim in /v1/apps. Only the exception TYPE crosses that
            # boundary (review finding N5); it still separates a malformed value from an
            # access-denied read, which is all a caller can act on. The full message goes to
            # the verbose stream, which stays on the host.
            $errorType = 'Exception'
            try { $errorType = $_.Exception.GetType().Name } catch { }
            Write-Verbose "published key '$childName' could not be read: $($_.Exception.Message)"
            [void]$published.Add((New-MacdowsSkippedPublishedEntry -Key $childName -Reason "value read failed ($errorType)"))
        }
    }
    return @($published.ToArray())
}

function Get-MacdowsPublishedApps {
    <#
      Enumerates HKLM\...\Terminal Server\TSAppAllowList\Applications\*, i.e. the RemoteApps
      this host publishes. Read-only.
    #>
    [CmdletBinding()]
    param($Context)

    $tsDisabled = Invoke-MacdowsProvider -Context $Context -Name 'TsAllowListDisabled'

    if (-not (Test-MacdowsIsWindows)) {
        return [pscustomobject]@{ tsAllowListDisabled = $tsDisabled; published = @() }
    }

    $keys = @()
    try {
        $appsKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList\Applications'
        if (Test-Path -LiteralPath $appsKey) {
            $keys = @(Get-ChildItem -LiteralPath $appsKey -ErrorAction Stop)
        }
    } catch {
        # Only the enumeration itself is fatal to the listing now; a bad individual key is not.
        Write-Verbose "TSAppAllowList enumeration failed: $($_.Exception.Message)"
        $keys = @()
    }

    return [pscustomobject]@{
        tsAllowListDisabled = $tsDisabled
        published           = @(ConvertTo-MacdowsPublishedList -Keys $keys -Context $Context)
    }
}

# The real native call, kept in one place so it can be replaced wholesale in tests. Returns
# the HRESULT and the (possibly updated) character count; the [ref] never crosses the boundary.
$script:MacdowsAssocInvoker = {
    param($Flags, $StringType, $Extension, $Verb, $Buffer, $Length)
    $len = [uint32]$Length
    $hr = [Macdows.AssocNative]::AssocQueryString($Flags, $StringType, $Extension, $Verb, $Buffer, [ref]$len)
    return [pscustomobject]@{ HResult = $hr; Length = $len }
}

function Get-MacdowsAssocString {
    <#
      One AssocQueryString lookup, using the documented two-call sizing convention: call once
      with a NULL buffer and pcchOut = 0 to learn the required character count, then allocate
      and call again. S_FALSE (1) is a success here, not a failure - the sizing call returns it
      by design, and some string types return it from the filling call too.

      Accepting S_FALSE from the *filling* call is a deliberate trade (review finding D2). The
      documented meaning of S_FALSE there is "the buffer was too small", so in principle a
      truncated string can be returned rather than nothing. Taking it anyway is the right call
      for this prototype: the buffer is sized by the preceding sizing call and most rungs pass
      ASSOCF_NOTRUNCATE (which asks the API to fail rather than truncate), while treating
      S_FALSE as a failure would throw away real answers from the string types that return it
      routinely. A truncated path is visible in the probe output; a silently dropped one is not.

      $Verb is deliberately UNTYPED. PowerShell binds $null to a [string] parameter as an empty
      string, and pszExtra = "" is not the same thing as pszExtra = NULL to AssocQueryString -
      declaring it [string] would silently turn every verb-less rung of the ladder into an
      empty-string call, including both friendlyName rungs, which are the ones known to work on
      the live host. It is normalised back to a real $null below.
    #>
    [CmdletBinding()]
    param([int] $Flags, [int] $StringType, [string] $Extension, $Verb, [scriptblock] $Invoker)

    if ($null -eq $Invoker) { $Invoker = $script:MacdowsAssocInvoker }

    $verbArg = $null
    if (-not [string]::IsNullOrEmpty([string]$Verb)) { $verbArg = [string]$Verb }

    # First call: NULL buffer and pcchOut = 0, which returns S_FALSE plus the required length.
    $len = [uint32]0
    try {
        $sized = & $Invoker $Flags $StringType $Extension $verbArg $null ([uint32]0)
        if ($null -ne $sized) {
            $sizedLength = Get-MacdowsProperty -InputObject $sized -Name 'Length'
            if ($null -ne $sizedLength) { $len = [uint32]$sizedLength }
        }
    } catch {
        $len = [uint32]0
    }
    # Sizing call refused or returned something absurd: use a generous fixed buffer instead.
    if ($len -eq 0 -or $len -gt 32768) { $len = [uint32]4096 }

    $buf = New-Object System.Text.StringBuilder ([int]$len)
    $filled = & $Invoker $Flags $StringType $Extension $verbArg $buf $len
    if ($null -eq $filled) { return $null }
    $hr = [int](Get-MacdowsProperty -InputObject $filled -Name 'HResult')
    if (($hr -eq 0 -or $hr -eq 1) -and $buf.Length -gt 0) { return $buf.ToString() }
    return $null
}

function Get-MacdowsAssocViaQueryString {
    <#
      Shlwapi!AssocQueryString for the three strings we report.

      Each string type is tried through a small ladder of flag/verb combinations, strictest
      first. This is deliberate: on a Windows 11 25H2 host where .pdf resolves to Microsoft Edge,
      the flagless verb-less form returned FRIENDLYAPPNAME but nothing at all for EXECUTABLE and
      COMMAND (live finding L1). Those two are verb-sensitive - the docs describe pszExtra as the
      verb for exactly these - so 'open' is tried before the verb-less form, and ASSOCF_NOTRUNCATE
      / ASSOCF_REMAPRUNDLL / ASSOCF_INIT_IGNOREUNKNOWN are applied before the bare call.

      Returns $null only when the lookup could not be attempted at all - off-Windows, or when
      the P/Invoke would not compile. When the ladder ran but resolved nothing it returns the
      ordered dictionary with all three fields $null, NOT $null (review finding D3): the caller
      handles both shapes, and the difference is "we could not ask" versus "we asked and got
      nothing".

      -Invoker replaces the native call outright, which is what lets the ladder (and the verb
      each rung passes) be asserted off-Windows.
    #>
    [CmdletBinding()]
    param([string] $Extension, [scriptblock] $Invoker)

    if ($null -eq $Invoker) {
        if (-not (Test-MacdowsIsWindows)) { return $null }
        try {
            if (-not ([System.Management.Automation.PSTypeName]'Macdows.AssocNative').Type) {
                Add-Type -Namespace 'Macdows' -Name 'AssocNative' -MemberDefinition @'
[DllImport("Shlwapi.dll", CharSet = CharSet.Unicode, SetLastError = false)]
public static extern int AssocQueryString(int flags, int str, string pszAssoc, string pszExtra, System.Text.StringBuilder pszOut, ref uint pcchOut);
'@ -ErrorAction Stop
            }
        } catch {
            Write-Verbose "AssocQueryString P/Invoke unavailable: $($_.Exception.Message)"
            return $null
        }
    }

    # ASSOCSTR_COMMAND = 1, ASSOCSTR_EXECUTABLE = 2, ASSOCSTR_FRIENDLYAPPNAME = 4
    $ASSOCSTR_COMMAND = 1
    $ASSOCSTR_EXECUTABLE = 2
    $ASSOCSTR_FRIENDLYAPPNAME = 4
    # ASSOCF_NONE = 0, ASSOCF_NOTRUNCATE = 0x20, ASSOCF_REMAPRUNDLL = 0x80,
    # ASSOCF_INIT_IGNOREUNKNOWN = 0x400
    $NONE = 0
    $NOTRUNCATE = 0x20
    $REMAPRUNDLL = 0x80
    $IGNOREUNKNOWN = 0x400

    $ladders = [ordered]@{
        executable   = @(
            @{ Flags = ($NOTRUNCATE -bor $REMAPRUNDLL -bor $IGNOREUNKNOWN); Verb = 'open'; Type = $ASSOCSTR_EXECUTABLE },
            @{ Flags = ($NOTRUNCATE -bor $REMAPRUNDLL); Verb = 'open'; Type = $ASSOCSTR_EXECUTABLE },
            @{ Flags = ($NOTRUNCATE -bor $REMAPRUNDLL); Verb = $null; Type = $ASSOCSTR_EXECUTABLE },
            @{ Flags = $NONE; Verb = $null; Type = $ASSOCSTR_EXECUTABLE }
        )
        command      = @(
            @{ Flags = ($NOTRUNCATE -bor $IGNOREUNKNOWN); Verb = 'open'; Type = $ASSOCSTR_COMMAND },
            @{ Flags = $NOTRUNCATE; Verb = 'open'; Type = $ASSOCSTR_COMMAND },
            @{ Flags = $NOTRUNCATE; Verb = $null; Type = $ASSOCSTR_COMMAND },
            @{ Flags = $NONE; Verb = $null; Type = $ASSOCSTR_COMMAND }
        )
        friendlyName = @(
            @{ Flags = $NOTRUNCATE; Verb = $null; Type = $ASSOCSTR_FRIENDLYAPPNAME },
            @{ Flags = $NONE; Verb = $null; Type = $ASSOCSTR_FRIENDLYAPPNAME }
        )
    }

    $out = [ordered]@{ executable = $null; command = $null; friendlyName = $null }
    foreach ($field in @($ladders.Keys)) {
        foreach ($attempt in $ladders[$field]) {
            $value = $null
            try {
                $value = Get-MacdowsAssocString -Flags $attempt.Flags -StringType $attempt.Type `
                    -Extension $Extension -Verb $attempt.Verb -Invoker $Invoker
            } catch {
                Write-Verbose "AssocQueryString($field) threw: $($_.Exception.Message)"
                $value = $null
            }
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $out[$field] = $value
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$out[$field])) {
            Write-Verbose "AssocQueryString returned nothing for '$Extension' $field"
        }
    }

    return $out
}

function Get-MacdowsAssocViaRegistry {
    <#
      Registry walk: HKCU UserChoice ProgId, else HKCR\<ext> default ProgId, then
      HKCR\<ProgId>\shell\open\command. Read-only. Returns $null off-Windows or when no
      command could be found.
    #>
    [CmdletBinding()]
    param([string] $Extension)

    if (-not (Test-MacdowsIsWindows)) { return $null }

    try {
        $progId = $null
        $userChoice = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$Extension\UserChoice"
        if (Test-Path -LiteralPath $userChoice) {
            $props = Get-ItemProperty -LiteralPath $userChoice -ErrorAction Stop
            if (($props.PSObject.Properties.Name) -contains 'ProgId') { $progId = [string]$props.ProgId }
        }
        if ([string]::IsNullOrWhiteSpace($progId)) {
            $classKey = "Registry::HKEY_CLASSES_ROOT\$Extension"
            if (Test-Path -LiteralPath $classKey) {
                $progId = [string](Get-ItemProperty -LiteralPath $classKey -ErrorAction Stop).'(default)'
            }
        }
        if ([string]::IsNullOrWhiteSpace($progId)) {
            Write-Verbose "no ProgId found for '$Extension'"
            return $null
        }

        $cmdKey = "Registry::HKEY_CLASSES_ROOT\$progId\shell\open\command"
        if (-not (Test-Path -LiteralPath $cmdKey)) {
            Write-Verbose "no shell\open\command under ProgId '$progId'"
            return $null
        }
        $command = [string](Get-ItemProperty -LiteralPath $cmdKey -ErrorAction Stop).'(default)'
        if ([string]::IsNullOrWhiteSpace($command)) { return $null }

        return [ordered]@{
            executable   = (Get-MacdowsExecutableFromCommand -Command $command)
            command      = $command
            friendlyName = $progId
        }
    } catch {
        Write-Verbose "registry association lookup failed for '$Extension': $($_.Exception.Message)"
        return $null
    }
}

function Test-MacdowsAssocNeedsFallback {
    <#
      The registry fallback must run whenever BOTH the executable and the command are empty,
      no matter what else came back.

      Live finding L1: on a real host AssocQueryString answered FRIENDLYAPPNAME ('Microsoft
      Edge') while returning nothing for EXECUTABLE and COMMAND. The previous code treated
      "any field resolved" as success and returned early, so the fallback never ran and the
      probe reported a null executable for a .pdf that plainly has a handler. A friendly name
      alone does not answer the question this route exists to answer.
    #>
    [CmdletBinding()]
    param([string] $Executable, [string] $Command)

    return ([string]::IsNullOrWhiteSpace($Executable) -and [string]::IsNullOrWhiteSpace($Command))
}

function Get-MacdowsAssociation {
    <#
      Which executable opens <ext> for this user. AssocQueryString first (it honours the HKCU
      UserChoice hash), then the registry walk whenever that failed to produce a program.

      The two lookups are injectable so the selection logic can be tested off-Windows against
      the exact payloads a real host produced.
    #>
    [CmdletBinding()]
    param(
        [string] $Extension,
        [scriptblock] $QueryStringProbe,
        [scriptblock] $RegistryProbe
    )

    if ($null -eq $QueryStringProbe) { $QueryStringProbe = { param($Ext) Get-MacdowsAssocViaQueryString -Extension $Ext } }
    if ($null -eq $RegistryProbe) { $RegistryProbe = { param($Ext) Get-MacdowsAssocViaRegistry -Extension $Ext } }

    $result = [ordered]@{
        ext          = $Extension
        executable   = $null
        command      = $null
        friendlyName = $null
        source       = $null
    }

    $primary = $null
    try {
        $primary = & $QueryStringProbe $Extension
    } catch {
        Write-Verbose "AssocQueryString probe failed for '$Extension': $($_.Exception.Message)"
    }
    if ($null -ne $primary) {
        foreach ($field in @('executable', 'command', 'friendlyName')) {
            $value = Get-MacdowsProperty -InputObject $primary -Name $field
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $result[$field] = [string]$value }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$result['executable']) -or
            -not [string]::IsNullOrWhiteSpace([string]$result['command'])) {
            $result['source'] = 'AssocQueryString'
        }
    }

    if (Test-MacdowsAssocNeedsFallback -Executable ([string]$result['executable']) -Command ([string]$result['command'])) {
        Write-Verbose "AssocQueryString produced no program for '$Extension'; falling back to the registry"
        $fallback = $null
        try {
            $fallback = & $RegistryProbe $Extension
        } catch {
            Write-Verbose "registry probe failed for '$Extension': $($_.Exception.Message)"
        }
        if ($null -ne $fallback) {
            $command = [string](Get-MacdowsProperty -InputObject $fallback -Name 'command')
            $executable = [string](Get-MacdowsProperty -InputObject $fallback -Name 'executable')
            if ([string]::IsNullOrWhiteSpace($executable) -and -not [string]::IsNullOrWhiteSpace($command)) {
                $executable = [string](Get-MacdowsExecutableFromCommand -Command $command)
            }
            if (-not [string]::IsNullOrWhiteSpace($command) -or -not [string]::IsNullOrWhiteSpace($executable)) {
                $result['command'] = $command
                $result['executable'] = $executable
                # Keep the friendly name AssocQueryString gave us - it is nicer than the ProgId.
                if ([string]::IsNullOrWhiteSpace([string]$result['friendlyName'])) {
                    $result['friendlyName'] = [string](Get-MacdowsProperty -InputObject $fallback -Name 'friendlyName')
                }
                $result['source'] = 'registry'
            }
        }
    }

    return $result
}

function Get-MacdowsExecutableFromCommand {
    <# Pulls the program out of a shell\open\command string: '"C:\a b\x.exe" "%1"' -> 'C:\a b\x.exe'. #>
    [CmdletBinding()]
    param([string] $Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $trimmed = $Command.Trim()
    if ($trimmed.StartsWith('"')) {
        $end = $trimmed.IndexOf('"', 1)
        if ($end -gt 1) { return $trimmed.Substring(1, $end - 1) }
        return $null
    }
    # Unquoted. Windows itself probes progressively longer prefixes, so prefer the longest one
    # ending in a program extension: 'C:\Program Files\R\r.exe %1' must not become 'C:\Program'.
    $accumulated = ''
    foreach ($part in ($trimmed -split ' ')) {
        if ($accumulated -eq '') { $accumulated = $part } else { $accumulated = "$accumulated $part" }
        if ($accumulated -match '\.(?i:exe|com)$') { return $accumulated }
    }
    $space = $trimmed.IndexOf(' ')
    if ($space -lt 0) { return $trimmed }
    return $trimmed.Substring(0, $space)
}

function Start-MacdowsAllowlistProcess {
    <#
      Launches an already-validated allowlist entry. The path and arguments come from the
      config file only; nothing here is ever taken from the request. No shell, no cmd /c.

      Caveat for whoever adds an argument to allowlist.json: Windows PowerShell 5.1 joins
      -ArgumentList with single spaces and does NOT quote the elements, so an element that
      itself contains a space arrives at the target as two arguments (PowerShell 7 changed
      this). Nothing in the sample allowlist is affected - every entry ships "args": [] - but
      a path argument would need the quotes written into the element itself. This is not
      worked around here because a hand-rolled quoter is easy to get subtly wrong, and the
      prototype has no argument to pass.
    #>
    [CmdletBinding()]
    param($Entry)
    $proc = $null
    if ($null -ne $Entry.args -and @($Entry.args).Count -gt 0) {
        $proc = Start-Process -FilePath $Entry.path -ArgumentList @($Entry.args) -PassThru
    } else {
        $proc = Start-Process -FilePath $Entry.path -PassThru
    }
    if ($null -eq $proc) { return $null }
    return $proc.Id
}

# ---------------------------------------------------------------------------------------------
# Context and routing
# ---------------------------------------------------------------------------------------------

function New-MacdowsContext {
    <#
      Bundles everything a request handler may touch. Providers are scriptblocks so the tests
      can replace every Windows-only call with a stub.
    #>
    [CmdletBinding()]
    param(
        [string] $Token,
        [object[]] $Allowlist = @(),
        [string] $Bind = '127.0.0.1:47615',
        [hashtable] $Providers,
        # Used to resolve %SystemRoot% when comparing published paths against allowlist paths.
        # Explicit rather than read from the environment so tests can pin it off-Windows.
        [string] $SystemRoot = $env:SystemRoot
    )

    $defaults = @{
        SessionInfo         = { Get-MacdowsSessionInfo }
        TsAllowListDisabled = { Get-MacdowsTsAllowListDisabled }
        IconPng             = { param($Path, $Index) Get-MacdowsIconPngBase64 -Path $Path -IconIndex $Index }
        Assoc               = { param($Ext) Get-MacdowsAssociation -Extension $Ext }
        LaunchProcess       = { param($Entry) Start-MacdowsAllowlistProcess -Entry $Entry }
    }
    # PublishedApps needs the context back so it can reach the IconPng provider.
    $defaults['PublishedApps'] = { param($Ctx) Get-MacdowsPublishedApps -Context $Ctx }

    if ($null -ne $Providers) {
        foreach ($k in $Providers.Keys) { $defaults[$k] = $Providers[$k] }
    }

    return [pscustomobject]@{
        Token      = $Token
        Allowlist  = @($Allowlist)
        Bind       = $Bind
        Version    = $script:MacdowsAgentVersion
        SystemRoot = $SystemRoot
        Providers  = $defaults
    }
}

function Invoke-MacdowsProvider {
    [CmdletBinding()]
    param($Context, [string] $Name, [object[]] $Arguments = @())
    $sb = $Context.Providers[$Name]
    if ($null -eq $sb) { throw "no provider registered for '$Name'" }
    return (& $sb @Arguments)
}

function New-MacdowsResponse {
    [CmdletBinding()]
    param([int] $Status, $Body)
    if ($null -eq $Body) { $Body = [ordered]@{} }
    return [pscustomobject]@{ Status = $Status; Body = $Body }
}

function Test-MacdowsFileExtension {
    [CmdletBinding()]
    param([string] $Extension)
    if ([string]::IsNullOrEmpty($Extension)) { return $false }
    return [bool]($Extension -match '^\.[A-Za-z0-9]{1,16}$')
}

function Get-MacdowsRequestToken {
    [CmdletBinding()]
    param($Request)
    if (-not $Request.Headers.ContainsKey('authorization')) { return '' }
    $value = [string]$Request.Headers['authorization']
    if ($value -match '^[Bb][Ee][Aa][Rr][Ee][Rr][ \t]+(\S+)$') { return $Matches[1] }
    return ''
}

function Invoke-MacdowsRequest {
    <#
      Authenticate, then dispatch. Authentication runs before routing so an unauthenticated
      caller cannot even probe which routes exist.
    #>
    [CmdletBinding()]
    param($Request, $Context)

    if (-not $Request.Ok) {
        return (New-MacdowsResponse -Status $Request.Status -Body ([ordered]@{}))
    }

    $provided = Get-MacdowsRequestToken -Request $Request
    if (-not (Test-MacdowsTokenMatch -Expected $Context.Token -Provided $provided)) {
        return (New-MacdowsResponse -Status 401 -Body ([ordered]@{}))
    }

    switch ($Request.Path) {

        '/v1/health' {
            if ($Request.Method -cne 'GET') { return (New-MacdowsResponse -Status 405 -Body ([ordered]@{ error = 'method_not_allowed' })) }
            $session = Invoke-MacdowsProvider -Context $Context -Name 'SessionInfo'
            $tsDisabled = Invoke-MacdowsProvider -Context $Context -Name 'TsAllowListDisabled'
            return (New-MacdowsResponse -Status 200 -Body ([ordered]@{
                agent               = $script:MacdowsAgentName
                version             = $Context.Version
                user                = $session.user
                sessionId           = $session.sessionId
                tsAllowListDisabled = $tsDisabled
                bind                = $Context.Bind
            }))
        }

        '/v1/apps' {
            if ($Request.Method -cne 'GET') { return (New-MacdowsResponse -Status 405 -Body ([ordered]@{ error = 'method_not_allowed' })) }
            $apps = Invoke-MacdowsProvider -Context $Context -Name 'PublishedApps' -Arguments @($Context)

            # Both sides go through the same normaliser: the registry side commonly still
            # carries %SystemRoot%/%SystemDrive%, the allowlist side was expanded at load.
            $publishedPaths = @{}
            foreach ($p in @($apps.published)) {
                $pp = ConvertTo-MacdowsComparablePath -Path ([string]$p.path) -SystemRoot $Context.SystemRoot
                if (-not [string]::IsNullOrWhiteSpace($pp)) {
                    $publishedPaths[$pp] = $true
                }
            }

            $agentList = New-Object System.Collections.ArrayList
            foreach ($entry in @($Context.Allowlist)) {
                $inTs = $publishedPaths.ContainsKey(
                    (ConvertTo-MacdowsComparablePath -Path ([string]$entry.path) -SystemRoot $Context.SystemRoot))
                $png = Invoke-MacdowsProvider -Context $Context -Name 'IconPng' -Arguments @($entry.path, 0)
                [void]$agentList.Add([ordered]@{
                    id            = $entry.id
                    name          = $entry.name
                    path          = $entry.path
                    args          = @($entry.args)
                    inTsAllowList = $inTs
                    iconPng       = $png
                })
            }

            return (New-MacdowsResponse -Status 200 -Body ([ordered]@{
                tsAllowListDisabled = $apps.tsAllowListDisabled
                published           = @($apps.published)
                agentAllowlist      = @($agentList.ToArray())
            }))
        }

        '/v1/launch' {
            if ($Request.Method -cne 'POST') { return (New-MacdowsResponse -Status 405 -Body ([ordered]@{ error = 'method_not_allowed' })) }
            if ([string]::IsNullOrWhiteSpace($Request.Body)) {
                return (New-MacdowsResponse -Status 400 -Body ([ordered]@{ error = 'empty_body' }))
            }
            $parsed = $null
            try {
                $parsed = ConvertFrom-Json $Request.Body
            } catch {
                return (New-MacdowsResponse -Status 400 -Body ([ordered]@{ error = 'malformed_json' }))
            }
            if ($null -eq $parsed -or $parsed -is [System.Array] -or
                (@($parsed.PSObject.Properties.Name) -notcontains 'id')) {
                return (New-MacdowsResponse -Status 400 -Body ([ordered]@{ error = 'missing_id' }))
            }
            $id = [string]$parsed.id
            if ([string]::IsNullOrWhiteSpace($id)) {
                return (New-MacdowsResponse -Status 400 -Body ([ordered]@{ error = 'missing_id' }))
            }

            $entry = $null
            foreach ($candidate in @($Context.Allowlist)) {
                if ($candidate.id -ceq $id) { $entry = $candidate; break }
            }
            if ($null -eq $entry) {
                return (New-MacdowsResponse -Status 404 -Body ([ordered]@{ error = 'unknown_id' }))
            }

            try {
                $newPid = Invoke-MacdowsProvider -Context $Context -Name 'LaunchProcess' -Arguments @($entry)
            } catch {
                Write-Verbose "launch failed for '$id': $($_.Exception.Message)"
                return (New-MacdowsResponse -Status 500 -Body ([ordered]@{ error = 'launch_failed' }))
            }
            if ($null -eq $newPid) {
                return (New-MacdowsResponse -Status 500 -Body ([ordered]@{ error = 'launch_failed' }))
            }

            return (New-MacdowsResponse -Status 200 -Body ([ordered]@{
                id   = $entry.id
                pid  = [int]$newPid
                path = $entry.path
            }))
        }

        '/v1/assoc' {
            if ($Request.Method -cne 'GET') { return (New-MacdowsResponse -Status 405 -Body ([ordered]@{ error = 'method_not_allowed' })) }
            $ext = $null
            if ($Request.Query.ContainsKey('ext')) { $ext = [string]$Request.Query['ext'] }
            if (-not (Test-MacdowsFileExtension -Extension $ext)) {
                return (New-MacdowsResponse -Status 400 -Body ([ordered]@{ error = 'invalid_ext' }))
            }
            $assoc = Invoke-MacdowsProvider -Context $Context -Name 'Assoc' -Arguments @($ext)
            return (New-MacdowsResponse -Status 200 -Body $assoc)
        }

        default {
            return (New-MacdowsResponse -Status 404 -Body ([ordered]@{ error = 'not_found' }))
        }
    }
}

function ConvertTo-MacdowsJson {
    [CmdletBinding()]
    param($InputObject)
    # -InputObject (not the pipeline) so single-element arrays are not unrolled on PS 5.1.
    return (ConvertTo-Json -InputObject $InputObject -Depth 8 -Compress)
}

# ---------------------------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------------------------

function Invoke-MacdowsConnection {
    [CmdletBinding()]
    param($Client, $Context)

    $stream = $null
    try {
        $Client.ReceiveTimeout = $script:MacdowsSocketTimeoutMs
        $Client.SendTimeout = $script:MacdowsSocketTimeoutMs
        $stream = $Client.GetStream()
        if ($stream.CanTimeout) {
            $stream.ReadTimeout = $script:MacdowsSocketTimeoutMs
            $stream.WriteTimeout = $script:MacdowsSocketTimeoutMs
        }

        # Absolute deadline, stamped when the connection is accepted: the socket timeout
        # alone cannot stop a client that trickles bytes forever.
        $deadline = (Get-Date).AddSeconds($script:MacdowsConnectionDeadlineSeconds)
        $request = Read-MacdowsHttpRequest -Stream $stream -Deadline $deadline
        $response = Invoke-MacdowsRequest -Request $request -Context $Context
        $json = ConvertTo-MacdowsJson -InputObject $response.Body
        Write-MacdowsHttpResponse -Stream $stream -Status $response.Status -Json $json

        # Never log request bodies or the token; method, path and status only.
        $method = '-'
        $path = '-'
        if ($request.Ok) { $method = $request.Method; $path = $request.Path }
        Write-Verbose "$method $path -> $($response.Status)"
    } catch {
        Write-Verbose "connection error: $($_.Exception.Message)"
    } finally {
        if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
        try { $Client.Close() } catch { }
    }
}

function New-MacdowsBoundListener {
    <#
      Parses the bind address, creates the listener and takes the port. Split out of the serve
      loop so a caller can find out whether the port is available BEFORE it writes anything to
      disk (see Invoke-MacdowsHostAgentMain).

      Throws on every failure - a malformed address, a port outside 0-65535, a port already in
      use - and owns nothing when it does: no token has been created at this point, so there is
      nothing to clean up and no finally to arm.
    #>
    [CmdletBinding()]
    param([string] $BindAddress, [int] $Port)

    $ip = [System.Net.IPAddress]::Parse($BindAddress)
    $listener = New-Object System.Net.Sockets.TcpListener($ip, $Port)
    # ExclusiveAddressUse keeps another local process from stealing the port. It is a
    # Windows socket option; on Unix (test runs only) the setter is not supported.
    try {
        $listener.ExclusiveAddressUse = $true
    } catch {
        Write-Verbose "ExclusiveAddressUse unavailable on this platform: $($_.Exception.Message)"
    }
    $listener.Start()
    return $listener
}

function Start-MacdowsHostAgentServer {
    [CmdletBinding()]
    param(
        # An already-bound listener from New-MacdowsBoundListener.
        $Listener,
        $Context,
        # Human-readable "address:port", used for the banner only. The listener already knows
        # what it bound; this is what the operator asked for.
        [string] $Bind,
        [switch] $Once
    )

    # No token lifecycle in here. The caller that creates the token owns removing it
    # (Invoke-MacdowsHostAgentMain), which is what lets the token be written only after the
    # port is actually held - see the note there.
    Write-MacdowsLine "listening on http://$Bind/  (Ctrl+C to stop)"
    try {
        while ($true) {
            # Poll instead of blocking in AcceptTcpClient so Ctrl+C stays responsive.
            if (-not $Listener.Pending()) {
                Start-Sleep -Milliseconds 50
                continue
            }
            $client = $Listener.AcceptTcpClient()
            Invoke-MacdowsConnection -Client $client -Context $Context
            if ($Once) { break }
        }
    } finally {
        try { $Listener.Stop() } catch { }
    }
}

function Invoke-MacdowsHostAgentMain {
    [CmdletBinding()]
    param(
        [string] $BindAddress,
        [int] $Port,
        [string] $AllowlistPath,
        [string] $TokenPath,
        [switch] $Once
    )

    Write-MacdowsLine "$($script:MacdowsAgentName) $($script:MacdowsAgentVersion) (feasibility prototype - not for production)"

    if ($BindAddress -ne '127.0.0.1' -and $BindAddress -ne '::1') {
        Write-MacdowsLine ''
        Write-MacdowsLine '*********************************************************************'
        Write-MacdowsLine "*  WARNING: binding $BindAddress - NOT loopback.                     "
        Write-MacdowsLine '*  Anyone who can reach this address and guess/see the token can     '
        Write-MacdowsLine '*  list apps and start allowlisted programs in your session.         '
        Write-MacdowsLine '*  This is a prototype-only lab deviation. Do not leave it running.  '
        Write-MacdowsLine '*********************************************************************'
        Write-MacdowsLine ''
    }

    $loaded = Import-MacdowsAllowlist -Path $AllowlistPath -SystemRoot $env:SystemRoot
    foreach ($e in $loaded.Errors) { Write-MacdowsLine "allowlist: $e" }
    Write-MacdowsLine "allowlist: $(@($loaded.Entries).Count) usable entr(y/ies) from $AllowlistPath"

    # Take the port BEFORE writing anything (review finding M1). The token path is shared by
    # every agent this user starts, so a second agent launched by mistake on a port that is
    # already taken used to overwrite the running agent's token file and only then discover it
    # could not bind. It cleaned up its own write, which left the healthy agent running with no
    # token file at all. Binding first means a start that cannot succeed never touches the
    # disk: nothing is written, so nothing is clobbered and there is nothing to clean up.
    #
    # This is also why there is no try/finally around the bind: at this point the process owns
    # no resource whose release matters. If it throws, the agent exits non-zero having changed
    # nothing.
    $bind = "${BindAddress}:$Port"
    $listener = New-MacdowsBoundListener -BindAddress $BindAddress -Port $Port

    # From here on a token file may exist, so the removal has to be armed. Both variables are
    # declared before the try because StrictMode makes reading an unassigned variable an error,
    # and the finally must be able to run even when Save-MacdowsToken is what threw.
    $token = $null
    $savedTo = $null
    try {
        $token = New-MacdowsToken
        $savedTo = Save-MacdowsToken -Token $token -Path $TokenPath
        # The one and only time the token is printed. It is never written to the request log.
        # Printed after the bind, so a token on stdout means a listening agent.
        Write-MacdowsLine "token: $token"
        Write-MacdowsLine "token file: $savedTo"

        $context = New-MacdowsContext -Token $token -Allowlist @($loaded.Entries) -Bind $bind
        Start-MacdowsHostAgentServer -Listener $listener -Context $context -Bind $bind -Once:$Once
    } finally {
        # PowerShell runs finally on Ctrl+C as well as on a normal exit, so this covers the
        # ordinary way the agent is stopped. It is still best-effort: a killed process leaves
        # the file behind, which is why the README says to treat the token as spent regardless.
        # -Token makes it an ownership check: only a file still holding THIS token is removed,
        # so a later agent's file is never taken away (review finding N3).
        if (Remove-MacdowsTokenFile -Path $savedTo -Token $token) {
            Write-MacdowsLine "token file removed: $savedTo"
        }
        # Review finding Q2: on the save-throws path Start-MacdowsHostAgentServer (whose own
        # finally stops the listener) is never reached, so release the bound socket here too.
        # Stop() is idempotent, so the double call on the normal path is harmless.
        try { $listener.Stop() } catch { }
    }
}

# ---------------------------------------------------------------------------------------------
# Entry point (skipped when dot-sourced or when -NoServe is passed)
# ---------------------------------------------------------------------------------------------

if (-not $NoServe -and $MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($AllowlistPath)) {
        $AllowlistPath = Join-Path $PSScriptRoot 'allowlist.json'
    }
    if ([string]::IsNullOrWhiteSpace($TokenPath)) {
        $TokenPath = Get-MacdowsDefaultTokenPath
    }
    Invoke-MacdowsHostAgentMain -BindAddress $BindAddress -Port $Port `
        -AllowlistPath $AllowlistPath -TokenPath $TokenPath -Once:$Once
}
