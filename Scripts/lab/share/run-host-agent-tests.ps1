# lab host-agent 5.1 acceptance (authorized e2e lab, owner's own test host): copy the
# suite local (UNC cwd trips PS 5.1 path resolution), run it under the session's REAL
# Windows PowerShell 5.1 with the verbose stream merged (the DACL branch reports
# failure only via Write-Verbose), and ship the full transcript back over the drive.
$src = '\\tsclient\lab\host-agent'
$dst = Join-Path $env:USERPROFILE 'macdows-lab\host-agent'
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $dst
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item (Join-Path $src '*') $dst -Force
$out = '\\tsclient\lab\host-agent-tests-out.txt'
$lines = @('PSVersion(outer): ' + $PSVersionTable.PSVersion.ToString())
$suite = Join-Path $dst 'MacdowsHostAgent.Tests.ps1'
$result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$VerbosePreference='Continue'; `$PSVersionTable.PSVersion.ToString(); & '$suite'" *>&1
$code = $LASTEXITCODE
foreach ($r in $result) { $lines += $r.ToString() }
$lines += 'EXITCODE: ' + $code
[IO.File]::WriteAllLines($out, $lines)
