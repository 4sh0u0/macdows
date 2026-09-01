# lab readback (authorized e2e lab, owner's own test host): copy whatever the input
# scenarios saved back to the Mac via the redirected drive, then write a done marker.
$dir = Join-Path $env:USERPROFILE 'macdows-lab'
Copy-Item (Join-Path $dir 'cmdmap-seed.txt') '\\tsclient\lab\cmdmap-out.txt' -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $dir 'ime-seed.txt') '\\tsclient\lab\ime-out.txt' -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $dir 'click-marker.txt') '\\tsclient\lab\click-marker-out.txt' -Force -ErrorAction SilentlyContinue
[IO.File]::WriteAllText('\\tsclient\lab\readback.done', 'ok')
