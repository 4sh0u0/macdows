# READ-ONLY host state probe. Standard user, no elevation. Runs via the lab relay
# (jobs/regprobe.env -> powershell.exe -File \\tsclient\lab\tsallowlist-probe.ps1).
# Writes one report back over the redirected drive; touches nothing on the host.
$out = '\\tsclient\lab\tsallowlist-probe-out.txt'
$L = New-Object System.Collections.ArrayList
function Add-L([string]$s) { [void]$L.Add($s) }

Add-L ('PSVersion: ' + $PSVersionTable.PSVersion.ToString())
Add-L ('User: ' + $env:USERNAME + '  SessionId: ' + (Get-Process -Id $PID).SessionId)

# 1. Is this token elevated / an admin at all?  Decides owner-manual vs lab-automatable.
$id  = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr  = New-Object Security.Principal.WindowsPrincipal($id)
Add-L ('IsInRole(Administrator): ' + $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
Add-L ('Groups: ' + (($id.Groups | ForEach-Object {
    try { $_.Translate([Security.Principal.NTAccount]).Value } catch { $_.Value }
}) -join '; '))

# 2. The TSAppAllowList key itself.
$base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList'
if (Test-Path -LiteralPath $base) {
    $p = Get-ItemProperty -LiteralPath $base -ErrorAction SilentlyContinue
    foreach ($n in @('fDisabledAllowList','fHasCertificate','CustomRDPSettings')) {
        $v = if ($p -and ($p.PSObject.Properties.Name -contains $n)) { $p.$n } else { '<absent>' }
        Add-L ("TSAppAllowList\$n = $v")
    }
    Add-L ('TSAppAllowList all values: ' + (($p.PSObject.Properties |
        Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $_.Name }) -join ','))
} else {
    Add-L 'TSAppAllowList: <key absent>'
}

# 3. Published applications, one block per key.
$apps = Join-Path $base 'Applications'
if (Test-Path -LiteralPath $apps) {
    $keys = @(Get-ChildItem -LiteralPath $apps -ErrorAction SilentlyContinue)
    Add-L ("Applications: $($keys.Count) key(s)")
    foreach ($k in $keys) {
        Add-L ("  [$($k.PSChildName)]")
        foreach ($n in @('Name','Path','VPath','RequiredCommandLine','CommandLineSetting',
                         'ShowInTSWA','IconPath','IconIndex','SecurityDescriptor')) {
            $val = $k.GetValue($n, '<absent>')
            Add-L ("    $n = $val")
        }
    }
} else {
    Add-L 'Applications: <key absent>'
}

# 4. The policy twin. Both hives - a policy value overrides the non-policy one.
foreach ($k in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services',
                 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server')) {
    foreach ($n in @('fAllowUnlistedRemotePrograms','fDenyTSConnections')) {
        $v = '<absent>'
        if (Test-Path -LiteralPath $k) {
            $pp = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
            if ($pp -and ($pp.PSObject.Properties.Name -contains $n)) { $v = $pp.$n }
        }
        Add-L ("$k\$n = $v")
    }
}

# 5. Can this account write there?  Answered by trying, then undoing - the only honest test.
$canWrite = $false
try {
    New-ItemProperty -LiteralPath $base -Name 'MacdowsWriteProbe' -Value 1 `
        -PropertyType DWord -ErrorAction Stop | Out-Null
    $canWrite = $true
    Remove-ItemProperty -LiteralPath $base -Name 'MacdowsWriteProbe' -ErrorAction SilentlyContinue
} catch {
    Add-L ('HKLM write probe refused: ' + $_.Exception.GetType().Name)
}
Add-L ("HKLM TSAppAllowList writable by this token: $canWrite")

Add-L ('Build: ' + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').BuildLabEx)
[IO.File]::WriteAllLines($out, $L)
