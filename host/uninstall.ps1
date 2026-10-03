#Requires -Version 7.5
<#
  Macht install.ps1 rückgängig: Task entfernen, Collector beenden,
  %USERPROFILE%\.usage-display (Script, Log, latest.json, Verlauf, config.json) löschen.
  -Logout          meldet zusätzlich die Claude-CLI ab (claude auth logout)
  -RemovePlatformIO löscht zusätzlich %USERPROFILE%\.platformio (Build-Werkzeuge)
  Die Firmware bleibt auf dem Display; Original wiederherstellen: siehe README.
#>
param([switch]$Logout, [switch]$RemovePlatformIO)

$ErrorActionPreference = 'Stop'
$TaskName = 'Claude Usage Display'
$DataDir = Join-Path $env:USERPROFILE '.usage-display'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $TaskName
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Write-Host "Task '$TaskName' entfernt"
}

Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" |
  Where-Object { $_.CommandLine -like '*\.usage-display\collector.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "Collector beendet (PID $($_.ProcessId))" }
Start-Sleep -Milliseconds 500

if (Test-Path $DataDir) {
  Remove-Item $DataDir -Recurse -Force
  Write-Host "$DataDir geloescht"
}

if ($Logout) {
  . (Join-Path $PSScriptRoot 'claude-cli.ps1')
  $exe = Find-ClaudeExe
  if ($exe) { & $exe auth logout; Write-Host 'Claude-CLI abgemeldet' }
}

if ($RemovePlatformIO) {
  $pio = Join-Path $env:USERPROFILE '.platformio'
  if (Test-Path $pio) { Remove-Item $pio -Recurse -Force; Write-Host "$pio geloescht" }
}

Write-Host 'Fertig.'
