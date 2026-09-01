# lab tray driver (authorized e2e lab, owner's own test host): create one real
# notification-area icon in the session so the client side can assert its NSStatusItem
# shows the real icon bitmap (adr/0013 acceptance) AND, since the W6 click lane landed
# (adr/0014), observe ClientNotifyEvent delivery: the RDP server posts the notify
# message to this icon's owner window as the shell callback message, WinForms routes it
# to MouseDown/MouseUp -- each handler appends a marker line the readback connection
# copies out. Send != delivery is exactly the gap this file closes (adr/0014 §6).
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$dir = Join-Path $env:USERPROFILE 'macdows-lab'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$marker = Join-Path $dir 'click-marker.txt'
Remove-Item -Force -ErrorAction SilentlyContinue $marker
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = [System.Drawing.SystemIcons]::Information
$ni.Text = 'macdows-tray-lab'
$ni.add_MouseDown({ param($s, $e)
    [IO.File]::AppendAllText($marker, ('down ' + $e.Button + ' ' + (Get-Date -Format o) + "`r`n"))
})
$ni.add_MouseUp({ param($s, $e)
    [IO.File]::AppendAllText($marker, ('up ' + $e.Button + ' ' + (Get-Date -Format o) + "`r`n"))
})
$ni.Visible = $true
# 12s, not longer: the smoke harness's finish() battery runs ~30s in and its existing
# liveCount == creates - deletes formula gate (post-teardown liveCount is always 0)
# requires the delete to have been OBSERVED before shutdown -- so this driver must
# dispose while the harness is still connected (connect+launch overhead eats ~5-8s).
# Start-Sleep would starve the message loop and the callback would NEVER dispatch --
# the shell posts the notify message to this script's hidden owner window, and only a
# pumping loop delivers it to the handlers above. DoEvents every 50ms is the pump.
$deadline = (Get-Date).AddSeconds(12)
while ((Get-Date) -lt $deadline) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 50
}
$ni.Visible = $false
$ni.Dispose()
