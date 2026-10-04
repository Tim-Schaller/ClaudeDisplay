#Requires -Version 7.5
<#
  Selbst-Update, vom Collector gestartet, wenn man am Display das Update-Banner (zweimal)
  antippt. Läuft losgelöst vom Taskplaner-Task:
  - lädt das Setup-ZIP des Releases und prüft es gegen die SHA256-Summe aus der GitHub-API
  - lädt das offizielle esptool von Espressif (feste Version, SHA256 geprüft)
  - hält den Collector an, flasht die Firmware für den Panel-Typ des Displays
  - installiert den neuen Collector (install.ps1 -NoLogin; config.json bleibt erhalten)
  Schlägt etwas fehl, läuft der bisherige Collector weiter. Protokoll: update.log im
  Datenordner. -ZipPath: lokales ZIP statt Download (zum Testen; die Summe muss trotzdem passen).
#>
param(
  [Parameter(Mandatory)][string]$Version,
  [string]$Url = '',
  [Parameter(Mandatory)][string]$Sha256,
  [Parameter(Mandatory)][string]$Port,
  [Parameter(Mandatory)][ValidateSet('st7789', 'ili9341')][string]$Panel,
  [string]$ZipPath = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$TaskName = 'Claude Usage Display'
$DataDir = Join-Path $env:USERPROFILE '.usage-display'
$Log = Join-Path $DataDir 'update.log'
$UrlPrefix = 'https://github.com/Tim-Schaller/ClaudeDisplay/releases/download/'
$EsptoolVersion = '4.12.0'
$EsptoolUrl = "https://github.com/espressif/esptool/releases/download/v$EsptoolVersion/esptool-v$EsptoolVersion-windows-amd64.zip"
$EsptoolSha256 = '42fddc5e6a05716868ad77fb43acbf53be041f97abed87ff850df1dc88140889'

function Write-UpdateLog([string]$Message) {
  try { Add-Content -Path $Log -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) -Encoding utf8 } catch { }
}

function Test-Sha256([string]$File, [string]$Expected) {
  return (Get-FileHash $File -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Expected.ToLowerInvariant()
}

function Stop-Collector {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" |
    Where-Object { $_.CommandLine -like '*\.usage-display\collector.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2  # Port freigeben lassen
}

$work = Join-Path ([IO.Path]::GetTempPath()) "claude-display-update-$PID"
$stopped = $false
try {
  Write-UpdateLog "Update to v$Version started (port $Port, panel $Panel)"
  if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "invalid version '$Version'" }
  if ($Port -notmatch '^COM\d+$') { throw "invalid port '$Port'" }
  $Sha256 = $Sha256 -replace '^sha256:', ''
  if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'missing or invalid SHA256' }
  if (-not $ZipPath -and -not $Url.StartsWith($UrlPrefix)) { throw "unexpected download URL '$Url'" }

  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $zip = Join-Path $work 'setup.zip'
  if ($ZipPath) {
    Copy-Item -LiteralPath $ZipPath -Destination $zip
  } else {
    Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing
  }
  if (-not (Test-Sha256 $zip $Sha256)) { throw 'setup ZIP checksum does not match' }
  $setup = Join-Path $work 'setup'
  Expand-Archive -LiteralPath $zip -DestinationPath $setup -Force
  $image = Join-Path $setup "firmware\claude-display-$Panel.bin"
  $install = Join-Path $setup 'host\install.ps1'
  foreach ($f in $image, $install) { if (-not (Test-Path -LiteralPath $f)) { throw "missing in the ZIP: $f" } }

  $ez = Join-Path $work 'esptool.zip'
  Invoke-WebRequest -Uri $EsptoolUrl -OutFile $ez -UseBasicParsing
  if (-not (Test-Sha256 $ez $EsptoolSha256)) { throw 'esptool checksum does not match' }
  Expand-Archive -LiteralPath $ez -DestinationPath (Join-Path $work 'esptool') -Force
  $esptool = (Get-ChildItem (Join-Path $work 'esptool') -Recurse -Filter esptool.exe | Select-Object -First 1).FullName
  if (-not $esptool) { throw 'esptool.exe not found in its ZIP' }
  Write-UpdateLog 'Download and checksums OK'

  Write-UpdateLog 'Stopping the collector'
  $stopped = $true  # schon vorher: schlägt das Anhalten halb fehl, startet finally den Task neu
  Stop-Collector

  # Erst schnell, beim zweiten Versuch langsam (manche USB-Kabel/Ports schaffen 460800 nicht).
  $flashed = $false
  foreach ($baud in '460800', '115200') {
    Write-UpdateLog "Flashing $Panel firmware on $Port at $baud baud"
    $out = & $esptool --chip esp32 --port $Port --baud $baud write_flash 0x0 $image 2>&1
    $code = $LASTEXITCODE
    $out | Where-Object { "$_" -notmatch '^Writing at|^\s*$' } | ForEach-Object { Write-UpdateLog "  esptool: $_" }
    if ($code -eq 0) { $flashed = $true; break }
    Write-UpdateLog "esptool failed (exit code $code)"
  }
  if (-not $flashed) { throw 'flashing failed' }

  Write-UpdateLog 'Installing the new collector'
  $out = & $install -NoLogin *>&1
  $out | ForEach-Object { Write-UpdateLog "  install: $_" }
  $stopped = $false  # install.ps1 hat den Task neu gestartet
  Write-UpdateLog "Update to v$Version finished"
} catch {
  Write-UpdateLog "Update failed: $($_.Exception.Message)"
} finally {
  if ($stopped) {
    Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-UpdateLog 'Previous collector restarted'
  }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
