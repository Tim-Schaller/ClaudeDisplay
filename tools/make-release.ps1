#Requires -Version 7.5
<#
  Baut ein Release nach dist\ (nicht im Repo):
  - alle Firmware-Varianten, zusammengeführt zu Images, die an 0x0 geflasht werden
    (Bootloader 0x1000, Partitionen 0x8000, boot_app0 0xE000, App 0x10000)
  - ClaudeDisplay-Setup-v<Version>.zip: Setup.cmd, Uninstall.cmd, README.txt, LICENSE,
    setup\Setup.ps1, firmware\claude-display-<panel>.bin, host\*.ps1
  Bricht ab, wenn ein Image den Benutzernamen oder einen lokalen Pfad enthält.
  Version = FW_VERSION aus firmware\src\app\main.cpp. -Pio: Pfad zu pio.exe.
#>
param([string]$Pio)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Fw = Join-Path $Repo 'firmware'
$Dist = Join-Path $Repo 'dist'
$Version = [regex]::Match((Get-Content (Join-Path $Fw 'src\app\main.cpp') -Raw), 'FW_VERSION = "([^"]+)"').Groups[1].Value
if (-not $Version) { throw 'FW_VERSION nicht gefunden' }
if (-not $Pio) { $Pio = (Get-Command pio -ErrorAction SilentlyContinue).Source }
if (-not $Pio) { $Pio = Join-Path $env:USERPROFILE '.platformio\penv\Scripts\pio.exe' }
$Core = if ($env:PLATFORMIO_CORE_DIR) { $env:PLATFORMIO_CORE_DIR } else { Join-Path $env:USERPROFILE '.platformio' }
$BootApp0 = Join-Path $Core 'packages\framework-arduinoespressif32\tools\partitions\boot_app0.bin'
$Images = [ordered]@{
  'app'          = 'claude-display-st7789'
  'app-ili9341'  = 'claude-display-ili9341'
  'test-st7789'  = 'test-st7789'
  'test-ili9341' = 'test-ili9341'
}

Write-Host "Release v$Version"
& $Pio run -d $Fw @($Images.Keys | ForEach-Object { '-e'; $_ })
if ($LASTEXITCODE) { throw 'Build fehlgeschlagen' }

if (Test-Path $Dist) { Remove-Item $Dist -Recurse -Force }
New-Item -ItemType Directory -Path $Dist | Out-Null
$forbidden = @($env:USERNAME, $env:USERPROFILE, $Repo) | Where-Object { $_ } |
  ForEach-Object { $_; $_.Replace('\', '/') } | Select-Object -Unique

Push-Location $Fw
try {
  foreach ($e in $Images.Keys) {
    $build = Join-Path $Fw ".pio\build\$e"
    $out = Join-Path $Dist "$($Images[$e])-v$Version.bin"
    & $Pio pkg exec -p tool-esptoolpy -- esptool.py --chip esp32 merge_bin -o $out `
      --flash_mode dio --flash_freq 40m --flash_size 4MB `
      0x1000 (Join-Path $build 'bootloader.bin') 0x8000 (Join-Path $build 'partitions.bin') `
      0xe000 $BootApp0 0x10000 (Join-Path $build 'firmware.bin')
    if ($LASTEXITCODE) { throw "merge_bin fehlgeschlagen ($e)" }
    $text = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($out))
    foreach ($f in $forbidden) {
      if ($text.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "$out enthält einen lokalen Pfad/Namen ('$f') - Release abgebrochen"
      }
    }
  }
} finally { Pop-Location }

# Setup-ZIP zusammenstellen
$stage = Join-Path $Dist "ClaudeDisplay-Setup-v$Version"
New-Item -ItemType Directory -Path (Join-Path $stage 'setup'), (Join-Path $stage 'firmware'), (Join-Path $stage 'host') | Out-Null
Copy-Item (Join-Path $Repo 'setup\Setup.cmd'), (Join-Path $Repo 'setup\Uninstall.cmd'),
  (Join-Path $Repo 'setup\README.txt'), (Join-Path $Repo 'LICENSE') $stage
Copy-Item (Join-Path $Repo 'setup\Setup.ps1') (Join-Path $stage 'setup')
Copy-Item (Join-Path $Repo 'host\*.ps1') (Join-Path $stage 'host')
foreach ($panel in 'st7789', 'ili9341') {
  Copy-Item (Join-Path $Dist "claude-display-$panel-v$Version.bin") (Join-Path $stage "firmware\claude-display-$panel.bin")
}
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath "$stage.zip"
Remove-Item $stage -Recurse -Force

Get-ChildItem $Dist | ForEach-Object {
  '{0,-40} {1,9:N0} Byte  sha256 {2}' -f $_.Name, $_.Length, (Get-FileHash $_.FullName).Hash.Substring(0, 16).ToLower()
}
