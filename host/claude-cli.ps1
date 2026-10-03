# Findet die Claude-CLI. Bevorzugt eine eigenständige Installation, sonst die
# neueste von der Desktop-App mitgebrachte Version, zuletzt WinGet bzw. PATH.
# Die Desktop-App ist ein MSIX-Paket: Ihr %APPDATA% liegt für Prozesse außerhalb
# der App (z. B. den Taskplaner) unter %LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming.
function Find-ClaudeExe {
  $standalone = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
  if (Test-Path $standalone) { return $standalone }
  # claude-code\<Version>\<Hash>\claude.exe; direkt über .NET statt Get-ChildItem mit Platzhaltern
  # (das braucht bei vielen Paketen in Packages 1-3 s).
  $roots = @(Join-Path $env:APPDATA 'Claude\claude-code')
  try {
    foreach ($p in [IO.Directory]::EnumerateDirectories((Join-Path $env:LOCALAPPDATA 'Packages'), 'Claude_*')) {
      $roots += Join-Path $p 'LocalCache\Roaming\Claude\claude-code'
    }
  } catch { }
  $newest = $null
  $newestVer = $null
  foreach ($r in $roots) {
    try {
      foreach ($v in [IO.Directory]::EnumerateDirectories($r)) {
        $ver = [version]'0.0'
        if (-not [version]::TryParse([IO.Path]::GetFileName($v), [ref]$ver)) { $ver = [version]'0.0' }
        if ($newest -and $ver -le $newestVer) { continue }
        try {
          foreach ($h in [IO.Directory]::EnumerateDirectories($v)) {
            $exe = Join-Path $h 'claude.exe'
            if ([IO.File]::Exists($exe)) { $newest = $exe; $newestVer = $ver; break }
          }
        } catch { }  # nur diese Version überspringen
      }
    } catch { }  # Verzeichnis fehlt oder ist nicht lesbar
  }
  if ($newest) { return $newest }
  $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\claude.exe'
  if (Test-Path $winget) { return $winget }
  return (Get-Command claude.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}
