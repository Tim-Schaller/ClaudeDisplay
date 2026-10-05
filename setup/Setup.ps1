<#
  Claude-Usage-Display: Einrichtung in einem Schritt (aus dem Release-ZIP, Setup.cmd).
  - prüft Claude Desktop und PowerShell 7 (bietet die Installation an)
  - findet das CYD am USB-Port
  - lädt das offizielle esptool von Espressif (feste Version, SHA256 geprüft)
  - sichert auf Wunsch die Original-Firmware und flasht die Anzeige-Firmware
    (ST7789, bei falschem Bild ILI9341)
  - installiert den Hintergrunddienst (host\install.ps1, mit Claude-Login)
  Läuft mit Windows PowerShell 5.1, damit es auch ohne PowerShell 7 startet.
  Parameter für Wiederholungen/Tests: -Port COMx, -Variant st7789|ili9341, -NoBackup,
  -SkipFlash, -Yes (alle Fragen mit Ja beantworten).
#>
param([string]$Port, [ValidateSet('', 'st7789', 'ili9341')][string]$Variant = '',
  [switch]$NoBackup, [switch]$SkipFlash, [switch]$Yes)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$EsptoolVersion = '4.12.0'
$EsptoolUrl = "https://github.com/espressif/esptool/releases/download/v$EsptoolVersion/esptool-v$EsptoolVersion-windows-amd64.zip"
$EsptoolSha256 = '42fddc5e6a05716868ad77fb43acbf53be041f97abed87ff850df1dc88140889'
$UsbIds = @('VID_1A86&PID_7523', 'VID_1A86&PID_7522', 'VID_1A86&PID_55D4', 'VID_10C4&PID_EA60')
$TaskName = 'Claude Usage Display'
$Work = Join-Path $env:TEMP 'ClaudeDisplaySetup'

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Fail([string]$Text) { Write-Host $Text -ForegroundColor Red; exit 1 }

function Confirm-Step([string]$Question) {
  if ($Yes) { return $true }
  $a = Read-Host "$Question [Y/n]"
  return ($a -eq '' -or $a -match '^[YyJj]')
}

function Find-CydPorts {
  $present = [IO.Ports.SerialPort]::GetPortNames()
  foreach ($id in $UsbIds) {
    foreach ($key in Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\USB\$id" -ErrorAction SilentlyContinue) {
      $name = (Get-ItemProperty (Join-Path $key.PSPath 'Device Parameters') -ErrorAction SilentlyContinue).PortName
      if ($name -and $present -contains $name) { $name }
    }
  }
}

function Find-Pwsh7 {
  $candidates = @((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'))
  $cmd = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { $candidates = @($cmd.Source) + $candidates }
  foreach ($c in $candidates) {
    if (-not (Test-Path $c)) { continue }
    $v = & $c -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
    if ($v -and [version]$v -ge [version]'7.5') { return $c }
  }
  return $null
}

function Invoke-Esptool([string[]]$Arguments) {
  & $script:Esptool @Arguments
  if ($LASTEXITCODE -ne 0) { throw "esptool failed (exit code $LASTEXITCODE)" }
}

Write-Host 'Claude-Usage-Display - Setup' -ForegroundColor White
Get-ChildItem $Root -Recurse -File | Unblock-File  # Markierung "aus dem Internet" entfernen

# 1. Claude Desktop (bringt die CLI mit, die der Collector im Hintergrund nutzt)
Write-Step 'Claude Desktop'
. (Join-Path $Root 'host\claude-cli.ps1')
$cli = Find-ClaudeExe
if (-not $cli) {
  Write-Fail ("Claude Desktop not found. Install it from https://claude.ai/download, sign in, " +
    "open the Code tab once, then run Setup again.")
}
Write-Host "found: $cli"

# 2. PowerShell 7 (für den Hintergrunddienst)
Write-Step 'PowerShell 7'
$pwsh = Find-Pwsh7
if (-not $pwsh) {
  $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
  if (-not $winget) { Write-Fail 'PowerShell 7.5+ is missing. Install it from https://aka.ms/powershell and run Setup again.' }
  if (-not (Confirm-Step 'PowerShell 7 is missing. Install it now from the Microsoft Store (no admin rights needed)?')) { exit 1 }
  & $winget.Source install --id 9MZ1SNWT0N5D --source msstore --accept-package-agreements --accept-source-agreements
  $pwsh = Find-Pwsh7
  if (-not $pwsh) { Write-Fail 'PowerShell 7 could not be installed. Please install it from https://aka.ms/powershell.' }
}
Write-Host "found: $pwsh"

if (-not $SkipFlash) {
  # 3. Board suchen; ein laufender Collector gibt den Port vorher frei
  Write-Step 'Display (ESP32 Cheap Yellow Display)'
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName
    for ($i = 0; $i -lt 20; $i++) {
      $running = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" |
        Where-Object { $_.CommandLine -like '*\.usage-display\collector.ps1*' }
      if (-not $running) { break }
      Start-Sleep 1
    }
  }
  if (-not $Port) {
    $ports = @(Find-CydPorts)
    if (-not $ports) {
      Write-Host 'Please plug in the display now with a USB data cable (Ctrl+C to cancel) ...'
      for ($i = 0; $i -lt 180 -and -not $ports; $i++) { Start-Sleep 1; $ports = @(Find-CydPorts) }
      if (-not $ports) {
        Write-Fail ("No display found. Does Device Manager show 'USB-SERIAL CH340' or 'CP210x'? " +
          "If not, install the driver (WCH CH341SER or Silicon Labs CP210x) or try another cable.")
      }
    }
    $Port = $ports[0]
    if ($ports.Count -gt 1) {
      $pick = Read-Host "Several matching devices: $($ports -join ', '). Which port is the display? [$Port]"
      if ($pick) { $Port = $pick.Trim().ToUpperInvariant() }
    }
  }
  Write-Host "Display on $Port"

  # 4. esptool (offizielles Release von Espressif, nur für die Dauer des Setups)
  Write-Step "Downloading esptool $EsptoolVersion"
  New-Item -ItemType Directory -Force -Path $Work | Out-Null
  $zip = Join-Path $Work 'esptool.zip'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $EsptoolUrl -OutFile $zip -UseBasicParsing
  if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $EsptoolSha256) {
    Write-Fail 'esptool checksum does not match - aborting.'
  }
  Expand-Archive $zip -DestinationPath $Work -Force
  $script:Esptool = (Get-ChildItem $Work -Recurse -Filter esptool.exe | Select-Object -First 1).FullName

  # 5. Original-Firmware sichern
  if (-not $NoBackup -and (Confirm-Step 'Back up the board''s original firmware first (recommended, about 2 minutes)?')) {
    Write-Step 'Backing up the original firmware'
    $backupDir = Join-Path $Root 'backup'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $backup = Join-Path $backupDir ('original-firmware-{0:yyyyMMdd-HHmmss}.bin' -f (Get-Date))
    Invoke-Esptool @('--chip', 'esp32', '--port', $Port, '--baud', '460800', 'read_flash', '0', 'ALL', $backup)
    Write-Host "saved: $backup"
  }

  # 6. Firmware flashen; passt das Bild nicht, die andere Panel-Variante
  $variants = if ($Variant) { @($Variant) } else { @('st7789', 'ili9341') }
  $ok = $false
  foreach ($v in $variants) {
    Write-Step "Flashing firmware ($v)"
    $image = Join-Path $Root "firmware\claude-display-$v.bin"
    Invoke-Esptool @('--chip', 'esp32', '--port', $Port, '--baud', '460800', 'write_flash', '0x0', $image)
    Start-Sleep 3
    if (Confirm-Step ("Does the display show a gray circle with '!' and below it 'Waiting for data' " +
          "on a BLACK background, readable and not mirrored? (If it has gone dark, tap it.)")) { $ok = $true; break }
  }
  if (-not $ok) {
    Write-Host ('Neither variant fits. The firmware can be adjusted with build flags (inversion, ' +
      'red/blue, rotation), see the README on GitHub, section "Determine the panel type".') -ForegroundColor Yellow
    exit 1
  }
}

# 7. Hintergrunddienst installieren (inkl. einmaligem Claude-Login)
Write-Step 'Installing the background service'
& $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'host\install.ps1')
if ($LASTEXITCODE -ne 0) { Write-Fail 'Installing the background service failed (see above).' }

if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }
Write-Host ''
Write-Host 'Done! Within a few seconds the display shows your Claude usage.' -ForegroundColor Green
Write-Host 'Tap a session on the display to open it in Claude Desktop; swipe sideways to switch pages. To uninstall: Uninstall.cmd'
