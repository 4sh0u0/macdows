# lab staging (authorized e2e lab, owner's own test host): one connection prepares every
# input-scenario asset -- cmdmap seed text, empty IME target file, and the tray-driver
# script copied onto the host so window-smoke can launch it by plain path (no quoting
# through the RemoteApp argument string). Done marker goes back via the redirected drive.
$dir = Join-Path $env:USERPROFILE 'macdows-lab'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
# Win11 Notepad restores UNSAVED tab buffers across sessions -- a prior run's dirty
# buffer would resurrect on the next launch and corrupt the round-trip baseline, so
# staging purges the tab-state cache (test host, notepad not running post-logoff).
Remove-Item -Force -Recurse -ErrorAction SilentlyContinue `
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState\TabState\*')
[IO.File]::WriteAllText((Join-Path $dir 'cmdmap-seed.txt'), 'macdows-cmdmap-7f3a')
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $dir 'ime-seed.txt')
New-Item -ItemType File -Path (Join-Path $dir 'ime-seed.txt') | Out-Null
Copy-Item '\\tsclient\lab\tray-driver.ps1' (Join-Path $dir 'tray-driver.ps1') -Force
# W6 click lane: a stale click marker from a previous run must never masquerade as
# this run's delivery evidence.
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $dir 'click-marker.txt')
$lines = @(
    'cmdmap-seed bytes: ' + (Get-Item (Join-Path $dir 'cmdmap-seed.txt')).Length
    'ime-seed bytes: ' + (Get-Item (Join-Path $dir 'ime-seed.txt')).Length
    'tray-driver present: ' + (Test-Path (Join-Path $dir 'tray-driver.ps1'))
)
[IO.File]::WriteAllLines('\\tsclient\lab\stage.done', $lines)
