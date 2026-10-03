# Findet die Claude-CLI. Bevorzugt eine eigenständige Installation, sonst die
# neueste von der Desktop-App mitgebrachte Version, zuletzt WinGet bzw. PATH.
# Die Desktop-App ist ein MSIX-Paket: Ihr %APPDATA% liegt für Prozesse außerhalb
# der App (z. B. den Taskplaner) unter %LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming.
function Find-ClaudeExe {
  $standalone = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
  if (Test-Path $standalone) { return $standalone }
  $patterns = @(
    (Join-Path $env:APPDATA 'Claude\claude-code\*\*\claude.exe'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Claude_*\LocalCache\Roaming\Claude\claude-code\*\*\claude.exe')
  )
  $newest = Get-ChildItem $patterns -ErrorAction SilentlyContinue |
    Sort-Object { try { [version]$_.Directory.Parent.Name } catch { [version]'0.0' } } -Descending |
    Select-Object -First 1
  if ($newest) { return $newest.FullName }
  $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\claude.exe'
  if (Test-Path $winget) { return $winget }
  return (Get-Command claude.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}
