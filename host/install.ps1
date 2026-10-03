#Requires -Version 7.5
<#
  Installiert den Collector für den aktuellen Benutzer (keine Admin-Rechte nötig):
  - kopiert collector.ps1 nach %USERPROFILE%\.usage-display\
  - legt den Task "Claude Usage Display" an (Start bei Anmeldung, unsichtbar)
    und startet ihn
  - meldet die Claude-CLI an, falls nötig (Browser-Login, einmalig)
  Mehrfach ausführen ist unschädlich (aktualisiert Script und Task).
  -LocalLabel / -RemoteLabel: eigene Titel für Seite 1 (dieser Rechner, Standard "Lokal")
  und Seite 2 (Sessions anderer Rechner, Standard "Remote"), max. 14 Zeichen.
  Sie werden in config.json gespeichert und bleiben bei späteren Installationen erhalten.
  -Port: fester COM-Port des Displays (z. B. COM7) statt der automatischen Suche, ebenfalls
  in config.json; -Port '' schaltet wieder auf automatisch.
#>
param([switch]$NoLogin, [string]$RemoteLabel, [string]$LocalLabel, [string]$Port)

$ErrorActionPreference = 'Stop'
$TaskName = 'Claude Usage Display'
$DataDir = Join-Path $env:USERPROFILE '.usage-display'
$Collector = Join-Path $DataDir 'collector.ps1'
$ConfigFile = Join-Path $DataDir 'config.json'

$Port = $Port.Trim().ToUpperInvariant()
if ($Port -and $Port -notmatch '^COM\d+$') { throw "Ungueltiger Port '$Port' (z. B. COM7, leer = automatisch)" }

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'collector.ps1'), (Join-Path $PSScriptRoot 'claude-cli.ps1') $DataDir -Force
Write-Host "Collector kopiert nach $Collector"

if ($PSBoundParameters.ContainsKey('RemoteLabel') -or $PSBoundParameters.ContainsKey('LocalLabel') -or
  $PSBoundParameters.ContainsKey('Port')) {
  $cfg = [ordered]@{ remoteLabel = ''; localLabel = ''; port = '' }
  if (Test-Path $ConfigFile) {
    $old = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $cfg.remoteLabel = [string]$old.remoteLabel
    $cfg.localLabel = [string]$old.localLabel
    $cfg.port = [string]$old.port
  }
  if ($PSBoundParameters.ContainsKey('RemoteLabel')) { $cfg.remoteLabel = $RemoteLabel }
  if ($PSBoundParameters.ContainsKey('LocalLabel')) { $cfg.localLabel = $LocalLabel }
  if ($PSBoundParameters.ContainsKey('Port')) { $cfg.port = $Port }
  foreach ($l in $cfg.remoteLabel, $cfg.localLabel) {
    if ($l.Length -gt 14) { Write-Warning "Seitentitel '$l' hat mehr als 14 Zeichen und wird auf dem Display gekuerzt." }
  }
  $cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding utf8
  $p = if ($cfg.port) { $cfg.port } else { 'automatisch' }
  Write-Host "Einstellungen gespeichert: Lokal='$($cfg.localLabel)', Remote='$($cfg.remoteLabel)', Port: $p"
}
. (Join-Path $PSScriptRoot 'claude-cli.ps1')

$pwsh = (Get-Process -Id $PID).Path
# PowerShell aus dem Microsoft Store liegt in einem versionierten Ordner, der mit jedem Update
# wechselt: dann den App-Alias nehmen.
if ($pwsh -like '*\WindowsApps\*') { $pwsh = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe' }
$user = "$env:USERDOMAIN\$env:USERNAME"
# conhost --headless: kein Konsolenfenster, auch kein kurzes Aufblitzen bei der Anmeldung.
$action = New-ScheduledTaskAction -Execute (Join-Path $env:windir 'System32\conhost.exe') `
  -Argument "--headless `"$pwsh`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Collector`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
  -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
  -Settings $settings -Description 'Sendet den Claude-Usage-Stand an das USB-Display.' -Force | Out-Null
Write-Host "Task '$TaskName' angelegt (Start bei Anmeldung)"

if (-not $NoLogin) {
  $exe = Find-ClaudeExe
  if (-not $exe) { throw 'Claude-CLI nicht gefunden (Claude Desktop installiert?)' }
  $status = & $exe auth status | ConvertFrom-Json
  if ($status.loggedIn) {
    Write-Host "Claude-CLI ist angemeldet ($($status.authMethod))"
  } else {
    Write-Host 'Claude-CLI ist nicht angemeldet - Browser-Login startet ...'
    & $exe auth login --claudeai
  }
}

# Laufende Instanz beenden, damit die neue Version startet.
Stop-ScheduledTask -TaskName $TaskName
Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" |
  Where-Object { $_.CommandLine -like "*$Collector*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Seconds 1
Start-ScheduledTask -TaskName $TaskName
Write-Host "Collector gestartet. Log: $(Join-Path $DataDir 'collector.log')"
