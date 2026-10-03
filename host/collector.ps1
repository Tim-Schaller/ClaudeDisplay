#Requires -Version 7.5
<#
  Collector für das Claude-Usage-Display (Dauerprozess, wird per Taskplaner gestartet).

  - Holt alle 2 Minuten den 5h-/7d-Verbrauch über die Claude-CLI (Control-Request
    "get_usage" im Headless-Modus, derselbe Weg wie die Desktop-App). Das verbraucht
    kein Kontingent; Anmeldung und Token-Refresh erledigt die CLI selbst.
  - Schreibt den Stand atomar nach %USERPROFILE%\.usage-display\latest.json und rechnet
    die Prognose (f, e) ab Fensterbeginn hoch.
  - Sammelt die Sessions: lokal aus der CLI-Registry (alle 2 s) und der Desktop-App
    (alle 10 s), Remote-Sessions anderer Rechner (Remote Control) über die API (alle 30 s,
    asynchron). Optionale eigene Seitentitel in config.json (remoteLabel, localLabel).
  - Bildschirmsperre (LogonUI.exe läuft) schaltet das Display dunkel.
  - Findet das Display per USB-VID/PID (CH340, CH9102 oder CP2102) oder nimmt den festen Port
    aus config.json ("port"). Ein Port gilt erst als Display, wenn das Board antwortet (ack
    oder hello binnen 6 s); sonst wird er wieder geschlossen und 10 min übersprungen.
  - Hält den Port offen und sendet als NDJSON: state sofort bei Änderung und alle 30 s
    (Heartbeat + Uhrzeit, Dots, Session-Zeile), list bei Änderung. Nach dem Verbinden bzw. hello alles einmal.
  - Übersteht Ab- und Anstecken; schreibt ein knappes Log nach collector.log
    (nie Session-Titel, nie Token).
#>

$ErrorActionPreference = 'Stop'

$DataDir = Join-Path $env:USERPROFILE '.usage-display'
$LatestFile = Join-Path $DataDir 'latest.json'
$LogFile = Join-Path $DataDir 'collector.log'
$ConfigFile = Join-Path $DataDir 'config.json'
$PollSeconds = 120
$HeartbeatSeconds = 30
$LocalSeconds = 2      # CLI-Registry und Bildschirmsperre
$DesktopSeconds = 10   # Session-Dateien der Desktop-App
$RemoteSeconds = 30    # Remote-Sessions über die API
$RemoteUrl = 'https://api.anthropic.com/v1/code/sessions?limit=100'
$MaxItems = 7          # Zeilen pro Listenseite
$MaxLine = 1023        # Zeilenpuffer des Boards
$UsbIds = @('VID_1A86&PID_7523', 'VID_1A86&PID_7522', 'VID_1A86&PID_55D4', 'VID_10C4&PID_EA60')  # CYD: CH340, CH9102/CH343 bzw. CP2102
$VerifySeconds = 6     # so lange darf das Board nach dem Öffnen für ack/hello brauchen
$BadPortMinutes = 10   # Port ohne Antwort so lange überspringen (nicht bei festem Port)
$MaxLogBytes = 1MB
# Eigenes Konfigurationsverzeichnis der CLI (CLAUDE_CONFIG_DIR) berücksichtigen.
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }

function Write-Log([string]$Message) {
  try {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $MaxLogBytes) {
      Move-Item $LogFile "$LogFile.1" -Force
    }
    Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) -Encoding utf8
  } catch { }
}

. (Join-Path $PSScriptRoot 'claude-cli.ps1')  # Find-ClaudeExe

# Fehlertexte landen auf dem Display: nur ASCII, max. 44 Zeichen.
function Format-DisplayError([string]$Text) {
  $ascii = -join ($Text.ToCharArray() | ForEach-Object { if ([int]$_ -ge 32 -and [int]$_ -lt 127) { $_ } else { '?' } })
  if ($ascii.Length -gt 44) { $ascii = $ascii.Substring(0, 44) }
  return $ascii
}

# Titel fürs Display: ASCII, Umlaute umschreiben (ä -> ae ...), sonstiges Nicht-ASCII
# weglassen (Akzente fallen dabei ab: é -> e), max. 40 Zeichen.
function ConvertTo-DisplayTitle([string]$Text) {
  # Surrogates und U+FFFE/FFFF vorab entfernen (fielen ohnehin weg): Normalize() wirft sonst.
  $t = ($Text -replace '[\uD800-\uDFFF\uFFFE\uFFFF]', '').Normalize([Text.NormalizationForm]::FormC)
  foreach ($p in @(@(0xE4, 'ae'), @(0xF6, 'oe'), @(0xFC, 'ue'), @(0xC4, 'Ae'), @(0xD6, 'Oe'), @(0xDC, 'Ue'), @(0xDF, 'ss'))) {
    $t = $t.Replace([string][char]$p[0], $p[1])
  }
  $t = ($t.Normalize([Text.NormalizationForm]::FormD) -replace '\s', ' ' -replace '[^\x20-\x7E]', '' -replace ' {2,}', ' ').Trim()
  if ($t.Length -gt 40) { $t = $t.Substring(0, 40).TrimEnd() }
  return $t
}

function ConvertTo-Window($w) {
  if ($null -eq $w -or $null -eq $w.utilization) { return $null }
  $reset = 0
  if ($w.resets_at -is [string]) {
    $reset = [DateTimeOffset]::Parse($w.resets_at, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds()
  } elseif ($null -ne $w.resets_at) {
    $reset = [int64]$w.resets_at
  }
  return [ordered]@{ p = [Math]::Round([double]$w.utilization, 1); r = $reset }
}

# Liefert @{ Session; Week } (je @{ p; r } oder $null) oder wirft eine kurze Fehlermeldung.
function Get-Usage {
  $exe = Find-ClaudeExe
  if (-not $exe) { throw 'Claude-CLI nicht gefunden' }

  $psi = [Diagnostics.ProcessStartInfo]::new($exe)
  foreach ($a in @('--print', '--verbose', '--input-format', 'stream-json', '--output-format', 'stream-json',
      '--no-session-persistence', '--strict-mcp-config', '--setting-sources', '')) {
    $psi.ArgumentList.Add($a)
  }
  $psi.WorkingDirectory = [IO.Path]::GetTempPath()
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  foreach ($k in @($psi.Environment.Keys)) {
    if ($k -match '^(CLAUDE|ANTHROPIC)' -and $k -ne 'CLAUDE_CONFIG_DIR') { [void]$psi.Environment.Remove($k) }
  }

  $p = [Diagnostics.Process]::Start($psi)
  try {
    $errTask = $p.StandardError.ReadToEndAsync()  # leer lesen, damit die CLI nie blockiert
    $p.StandardInput.WriteLine('{"type":"control_request","request_id":"init","request":{"subtype":"initialize"}}')
    $p.StandardInput.WriteLine('{"type":"control_request","request_id":"usage","request":{"subtype":"get_usage","skip_behaviors":true}}')
    $p.StandardInput.Flush()

    $resp = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(60)  # direkt nach einem Login braucht die CLI deutlich länger
    while (-not $resp) {
      $task = $p.StandardOutput.ReadLineAsync()
      # In Scheiben warten: Wird der Task gestoppt, gibt der Collector den Port sofort frei.
      while (-not $task.Wait(500)) {
        if ($parent -and $parent.HasExited) { throw 'Task gestoppt' }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Zeitueberschreitung beim Abruf' }
      }
      $line = $task.Result
      if ($null -eq $line) {
        $why = if ($errTask.Wait(2000)) { $errTask.Result -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1 }
        throw "Claude-CLI beendet: $why"
      }
      if (-not $line.StartsWith('{')) { continue }
      try { $msg = $line | ConvertFrom-Json -DateKind String } catch { continue }
      if ($msg.type -eq 'control_response' -and $msg.response.request_id -eq 'usage') { $resp = $msg.response }
    }
  } finally {
    try { $p.StandardInput.Close() } catch { }
    if (-not $p.WaitForExit(5000)) { try { $p.Kill($true) } catch { } }
    $p.Dispose()
  }

  if ($resp.subtype -ne 'success') { throw "CLI-Fehler: $($resp.error)" }
  $u = $resp.response
  if (-not $u.rate_limits_available) { throw 'Nicht angemeldet: claude auth login' }
  if ($null -eq $u.rate_limits) { throw 'Usage gerade nicht abrufbar' }
  return [ordered]@{
    Session = ConvertTo-Window $u.rate_limits.five_hour
    Week    = ConvertTo-Window $u.rate_limits.seven_day
  }
}

function Save-Latest($Usage, [int64]$FetchedAt) {
  $obj = [ordered]@{
    fetched_at = [DateTimeOffset]::FromUnixTimeSeconds($FetchedAt).ToLocalTime().ToString('o')
    five_hour  = $Usage.Session
    seven_day  = $Usage.Week
  }
  $tmp = "$LatestFile.tmp"
  $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $tmp -Encoding utf8
  [IO.File]::Move($tmp, $LatestFile, $true)
}

# --- Prognose ---------------------------------------------------------------

function Get-TzMinutes { return [int][TimeZoneInfo]::Local.GetUtcOffset([DateTimeOffset]::UtcNow).TotalMinutes }

# Prognose: @{ f; e } oder $null (Fenster läuft noch zu kurz). f = Zeitpunkt, an dem beim
# Durchschnittstempo seit Fensterbeginn 100 % erreicht sind, 0 = nicht vor dem Reset; dann
# e = hochgerechneter Stand beim Reset in Prozent. Das Fenster beginnt Reset minus 5 h bzw.
# 7 Tage bei 0 %; in den ersten 30 min bzw. 12 h wäre die Hochrechnung zu sprunghaft.
function Get-Forecast([string]$Key, $Window, [int64]$Now) {
  if (-not $Window) { return $null }
  $p = [double]$Window.p
  if ($p -ge 100) { return [ordered]@{ f = $Now } }
  if ($Window.r -le 0) { return $null }
  $len, $minElapsed = if ($Key -eq 's') { 18000, 1800 } else { 604800, 43200 }
  $elapsed = $Now - ($Window.r - $len)
  if ($elapsed -lt $minElapsed -or $elapsed -gt $len) { return $null }
  $rate = $p / $elapsed  # Prozent pro Sekunde
  $atReset = $p + $rate * [Math]::Max(0.0, $Window.r - $Now)
  if ($atReset -ge 100) { return [ordered]@{ f = [int64]($Now + (100 - $p) / $rate) } }
  return [ordered]@{ f = 0; e = [int][Math]::Round($atReset) }
}

# --- Sessions ----------------------------------------------------------------

# Liest JSON-Dateien über einen Cache (Pfad -> mtime/Größe): nur geänderte Dateien werden
# neu gelesen; eine gerade halb geschriebene Datei liefert den letzten guten Stand.
# $Convert macht aus dem JSON das, was gecacht und zurückgegeben wird.
function Read-JsonFiles([hashtable]$Cache, $Files, [scriptblock]$Convert) {
  $seen = @{}
  foreach ($f in $Files) {
    if (-not $f.Name.EndsWith('.json')) { continue }
    $stamp = '{0}/{1}' -f $f.LastWriteTimeUtc.Ticks, $f.Length
    $c = $Cache[$f.FullName]
    if (-not $c -or $c.Stamp -ne $stamp) {
      try {
        $o = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json -DateKind String
        if ($null -ne $o) { $c = @{ Stamp = $stamp; Data = & $Convert $o } }  # leer = wird gerade geschrieben
      } catch { }
    }
    if ($c) { $seen[$f.FullName] = $c; $c.Data }
  }
  $Cache.Clear()
  foreach ($k in $seen.Keys) { $Cache[$k] = $seen[$k] }
}

# CLI-Sessions dieses Rechners (Desktop-App und Terminal) aus $ClaudeDir\sessions\*.json;
# die *.key-Dateien dort nie lesen. Valid: Prozess lebt und hat noch dieselbe Startzeit
# (sonst ist die Datei verwaist oder die PID neu vergeben).
function Get-LocalSessions([hashtable]$Cache) {
  $files = Get-ChildItem (Join-Path $ClaudeDir 'sessions') -Filter '*.json' -File -ErrorAction SilentlyContinue
  $list = @(foreach ($j in (Read-JsonFiles $Cache $files { param($j) $j })) {
      if ($j.kind -ne 'interactive') { continue }
      $valid = $false
      try { $valid = [string](Get-Process -Id ([int]$j.pid) -ErrorAction Stop).StartTime.ToFileTimeUtc() -eq [string]$j.procStart } catch { }
      $st = switch ($j.status) { 'busy' { 'w' } 'waiting' { 'a' } default { 'i' } }  # idle, shell
      $act = if ($j.statusUpdatedAt) { $j.statusUpdatedAt } else { $j.updatedAt }
      [pscustomobject]@{
        Valid    = $valid
        Started  = [int64]$j.startedAt
        Status   = $st
        Desktop  = $j.entrypoint -eq 'claude-desktop'
        Name     = [string]$j.name
        HostId   = [string]$j.hostSessionId
        Bridge   = [string]$j.bridgeSessionId
        Activity = [int64][Math]::Floor([double]$act / 1000)
      }
    })
  return @($list | Sort-Object Started)
}

# Sessions der Desktop-App (Code-Tab). Die App ist ein MSIX-Paket: Für Prozesse außerhalb
# (Taskplaner) liegen ihre Daten unter Packages\Claude_*\LocalCache\Roaming. Beide Orte
# prüfen, doppelte per sessionId zusammenführen (neuere gewinnt).
function Get-DesktopSessions([hashtable]$Cache) {
  $dirs = @(Join-Path $env:APPDATA 'Claude\claude-code-sessions')
  $dirs += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude-code-sessions' })
  $files = foreach ($d in $dirs) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    foreach ($a in ([IO.DirectoryInfo]$d).EnumerateDirectories()) {
      foreach ($b in $a.EnumerateDirectories()) { $b.EnumerateFiles('local_*.json') }
    }
  }
  $byId = @{}
  foreach ($s in (Read-JsonFiles $Cache $files {
        param($j)
        [pscustomobject]@{
          Id       = [string]$j.sessionId
          Title    = [string]$j.title
          Activity = [int64][Math]::Floor([double]$j.lastActivityAt / 1000)
          Archived = [bool]$j.isArchived
          Bridges  = @($j.bridgeSessionIds | Where-Object { $_ -is [string] })
        }
      })) {
    if (-not $s.Id) { continue }
    $old = $byId[$s.Id]
    if (-not $old -or $s.Activity -gt $old.Activity) { $byId[$s.Id] = $s }
  }
  return @($byId.Values)
}

# Liste Seite 1 (lokal): Desktop-Sessions und laufende Terminal-Sessions. Status aus der laufenden
# Registry-Session (hostSessionId == sessionId), sonst offline.
function Get-LocalItems($Desktop, $Local) {
  $running = @{}
  foreach ($l in $Local) { if ($l.Valid -and $l.HostId) { $running[$l.HostId] = $l } }
  $items = @(foreach ($d in $Desktop) {
      if ($d.Archived) { continue }
      $l = $running[$d.Id]
      [pscustomobject]@{
        n = $d.Title
        s = if ($l) { $l.Status } else { 'o' }
        a = if ($l -and $l.Activity -gt $d.Activity) { $l.Activity } else { $d.Activity }
      }
    })
  foreach ($l in $Local) {
    if ($l.Valid -and -not $l.Desktop) {
      $items += [pscustomobject]@{ n = if ($l.Name) { $l.Name } else { 'Terminal' }; s = $l.Status; a = $l.Activity }
    }
  }
  return $items
}

# IDs der lokal gestarteten Remote-Control-Sitzungen, ohne Präfix session_/cse_.
function Get-LocalBridgeIds($Desktop, $Local) {
  $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($d in $Desktop) { foreach ($b in $d.Bridges) { [void]$ids.Add(($b -replace '^(session|cse)_', '')) } }
  foreach ($l in $Local) { if ($l.Bridge) { [void]$ids.Add(($l.Bridge -replace '^(session|cse)_', '')) } }
  return , $ids
}

# Startet den Abruf der Remote-Sessions asynchron (blockiert die Hauptschleife nicht).
# Den Token der CLI jedes Mal frisch lesen; nie loggen, nie selbst erneuern (das macht
# die CLI bei get_usage). Liefert @{ Task } oder @{ Err; Detail }.
function Start-RemoteFetch($Http) {
  try {
    $file = Join-Path $ClaudeDir '.credentials.json'
    $token = if (Test-Path -LiteralPath $file) { (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).claudeAiOauth.accessToken }
  } catch {
    return @{ Err = 'Liste nicht abrufbar'; Detail = 'Anmeldedaten nicht lesbar' }
  }
  if (-not $token) { return @{ Err = 'Kein CLI-Login'; Detail = 'kein Token der CLI' } }
  $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $RemoteUrl)
  $req.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
  $req.Headers.Add('anthropic-version', '2023-06-01')
  return @{ Task = $Http.SendAsync($req) }
}

# Ergebnis des Abrufs: @{ Items } oder @{ Err (Display); Detail (Log) }.
function Receive-RemoteFetch($Task, $LocalIds) {
  if (-not $Task.IsCompletedSuccessfully) {
    $m = if ($Task.Exception) { $Task.Exception.GetBaseException().Message } else { 'Zeitueberschreitung' }
    return @{ Err = 'Liste nicht abrufbar'; Detail = $m }
  }
  $resp = $Task.Result
  try {
    $code = [int]$resp.StatusCode
    if ($code -eq 401 -or $code -eq 403) { return @{ Err = 'Liste: Login abgelaufen'; Detail = "HTTP $code" } }
    if (-not $resp.IsSuccessStatusCode) { return @{ Err = 'Liste nicht abrufbar'; Detail = "HTTP $code" } }
    try { return @{ Items = @(ConvertFrom-RemoteSessions $resp.Content.ReadAsStringAsync().Result $LocalIds) } }
    catch { return @{ Err = 'Liste nicht abrufbar'; Detail = 'Antwort nicht lesbar' } }  # Text kann Titel enthalten
  } finally {
    $resp.Dispose()
  }
}

# Remote-Sessions aus GET /v1/code/sessions (interne, undokumentierte Schnittstelle, daher
# defensiv). Archivierte und lokal gestartete (Bridge-IDs) weglassen; Rest = andere Rechner.
function ConvertFrom-RemoteSessions([string]$Json, $LocalIds) {
  $o = $Json | ConvertFrom-Json -DateKind String -NoEnumerate
  $rows = if ($o -is [array]) { $o } elseif ($o.data -is [array]) { $o.data } else { throw 'Antwort ohne data' }
  foreach ($r in $rows) {
    if ($r.id -isnot [string] -or $r.status -eq 'archived') { continue }
    if ($LocalIds.Contains(($r.id -replace '^(cse|session)_', ''))) { continue }
    $a = [int64]0
    try { $a = [DateTimeOffset]::Parse($r.last_event_at, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds() } catch { }
    $s = switch ($r.worker_status) { 'running' { 'w' } 'requires_action' { 'a' } default { 'i' } }
    if ($r.connection_status -eq 'disconnected') { $s = 'o' }
    [pscustomobject]@{ n = [string]$r.title; s = $s; a = $a; Id = $r.id; Connected = $r.connection_status -eq 'connected' }
  }
}

# Dots-Leiste: laufende lokale Sessions (nach Startzeit), '|', verbundene Remote-Sessions
# (nach ID, damit die Reihenfolge stabil bleibt). Max. 24 Session-Zeichen.
function Get-Dots($Local, $Remote) {
  $l = -join @($Local | Where-Object Valid | ForEach-Object Status)
  $r = -join @($Remote | Where-Object Connected | Sort-Object Id | ForEach-Object s)
  if ($l.Length -gt 24) { $l = $l.Substring(0, 24) }
  if ($r.Length -gt 24 - $l.Length) { $r = $r.Substring(0, 24 - $l.Length) }
  if ($l -and $r) { return "$l|$r" }
  return "$l$r"
}

# Session-Zeile (Seite 0): eine wartende Session hat Vorrang vor einer arbeitenden, jeweils
# die zuletzt aktive; m = weitere aktive Sessions. Laufen nur idle Sessions: s = i. Sonst $null.
function Get-SessionLine($LocalItems, $Remote) {
  $live = @(@($LocalItems) + @($Remote) | Where-Object { $_ -and $_.s -ne 'o' })
  $active = @($live | Where-Object { $_.s -eq 'a' -or $_.s -eq 'w' } |
      Sort-Object @{ e = { $_.s -eq 'a' }; Descending = $true }, @{ e = 'a'; Descending = $true })
  if ($active.Count -eq 0) { if ($live.Count) { return [ordered]@{ s = 'i' } } else { return $null } }
  $n = ConvertTo-DisplayTitle $active[0].n
  return [ordered]@{ s = $active[0].s; n = $(if ($n) { $n } else { '(ohne Titel)' }); m = $active.Count - 1 }
}

# Gesperrt = der Sperrbildschirm (LogonUI.exe) läuft.
function Test-ScreenLocked { return [bool](Get-Process LogonUI -ErrorAction SilentlyContinue) }

# --- Display -----------------------------------------------------------------

# Kandidaten fürs Display in der Reihenfolge von $UsbIds: COM-Namen aus der Registry (ohne
# Admin lesbar), nur wenn der Port gerade existiert ($Present) und nicht in $Bad (Port -> bis
# wann "kein Display") gesperrt ist. Billig genug für einen Aufruf alle 3 s, anders als eine
# WMI-Abfrage. Mit festem Port ($FixedPort) nur dieser, ohne Sperrfrist.
function Find-DisplayPort([string[]]$Present, [hashtable]$Bad) {
  if ($FixedPort) {
    if ($Present -contains $FixedPort) { $FixedPort }
    return
  }
  foreach ($id in $UsbIds) {
    foreach ($key in Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\USB\$id" -ErrorAction SilentlyContinue) {
      $name = (Get-ItemProperty (Join-Path $key.PSPath 'Device Parameters') -ErrorAction SilentlyContinue).PortName
      if ($name -and $Present -contains $name -and -not ($Bad[$name] -gt [DateTime]::UtcNow)) { $name }
    }
  }
}

function Open-DisplayPort([string]$Name) {
  $sp = [IO.Ports.SerialPort]::new($Name, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
  # DTR/RTS aus, bevor der Port aufgeht: Die Leitungen hängen an EN/GPIO0 des ESP32.
  $sp.DtrEnable = $false
  $sp.RtsEnable = $false
  $sp.Encoding = [Text.Encoding]::UTF8
  $sp.WriteTimeout = 2000
  $sp.Open()
  return $sp
}

# Meldungen zu einem Port nur bei Änderung loggen (gescannt wird alle 3 s); vergessen,
# sobald der Port verbunden ist oder verschwindet.
function Write-PortLog([string]$Name, [string]$Message) {
  if ($portLog[$Name] -cne $Message) { Write-Log $Message; $portLog[$Name] = $Message }
}

# Das Board verwirft Zeilen über 1023 Byte; Listen kürzt Get-ListLine vorher selbst.
function Send-Line($Port, [string]$Line) {
  if ([Text.Encoding]::UTF8.GetByteCount($Line) -gt $MaxLine) { Write-Log "Zeile zu lang ($($Line.Length) Byte), verworfen"; return }
  $Port.Write($Line + "`n")
}

function Get-StateLine($Usage, [int64]$FetchedAt, [string]$ErrorText, $Forecast, [bool]$Locked, [string]$Dots, $Sess) {
  $state = [ordered]@{
    t   = 'state'
    now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    tz  = Get-TzMinutes
  }
  if ($Usage) {
    foreach ($k in 's', 'w') {
      $win = if ($k -eq 's') { $Usage.Session } else { $Usage.Week }
      if (-not $win) { continue }
      $o = [ordered]@{ p = $win.p; r = $win.r }
      $fc = if ($Forecast) { $Forecast[$k] }
      if ($fc) {
        $o.f = $fc.f
        if ($null -ne $fc.e) { $o.e = $fc.e }
      }
      $state[$k] = $o
    }
    $state.at = $FetchedAt
  }
  if ($ErrorText) { $state.err = $ErrorText }
  $state.lock = [int]$Locked
  $state.d = $Dots
  if ($Sess) { $state.x = $Sess }
  return ($state | ConvertTo-Json -Compress -Depth 4)
}

# list-Zeile für Seite 1/2: neueste 7, Titel als ASCII; passt die Zeile nicht in 1023 Byte,
# fallen die ältesten weg. at auf die Minute abgerundet (angezeigt wird nur "Stand HH:MM"):
# Ohne inhaltliche Änderung geht eine Liste so höchstens einmal pro Minute neu raus.
function Get-ListLine([int]$Page, $Items, [int64]$At, [string]$ErrorText) {
  $msg = [ordered]@{ t = 'list'; p = $Page }
  if ($Labels[$Page]) { $msg.l = $Labels[$Page] }
  if ($At -gt 0) { $msg.at = $At - $At % 60 }
  if ($ErrorText) { $msg.err = $ErrorText }
  $list = @($Items | Where-Object { $_ } | Sort-Object -Property a -Descending -Stable | Select-Object -First $MaxItems | ForEach-Object {
      $n = ConvertTo-DisplayTitle $_.n
      [ordered]@{ n = if ($n) { $n } else { '(ohne Titel)' }; s = $_.s; a = [int64]$_.a }
    })
  while ($true) {
    $msg.i = $list
    $line = $msg | ConvertTo-Json -Compress -Depth 4
    if ($list.Count -eq 0 -or [Text.Encoding]::UTF8.GetByteCount($line) -le $MaxLine) { return $line }
    $list = @($list | Select-Object -First ($list.Count - 1))
  }
}

# list-Zeilen merken; geänderte zum Senden vormerken (Schlüssel l1, l2).
function Update-Line([string]$Key, [string]$Line) {
  if ($lines[$Key] -ceq $Line) { return }
  $lines[$Key] = $Line
  if (-not $pending.Contains($Key)) { $pending.Add($Key) }
}

# Nach Verbindungsaufbau bzw. hello alle vorhandenen list-Zeilen erneut senden.
function Reset-Pending {
  $pending.Clear()
  foreach ($k in 'l1', 'l2') { if ($lines[$k]) { $pending.Add($k) } }
}

# --- Hauptschleife -----------------------------------------------------------

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

$mutex = [Threading.Mutex]::new($false, 'Local\ClaudeUsageDisplayCollector')
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { Write-Log 'Collector laeuft bereits, beende diese Instanz.'; exit 0 }

Write-Log "Collector gestartet (PID $PID, CLI: $(Find-ClaudeExe))"

# Unter dem Taskplaner ist "conhost --headless" der Elternprozess. Stoppt man den Task,
# endet nur conhost; dann beendet sich auch der Collector und gibt den Port frei.
$parentId = (Get-CimInstance Win32_Process -Filter "ProcessId = $PID").ParentProcessId
$parent = Get-Process -Id $parentId -ErrorAction SilentlyContinue
if ($parent -and $parent.ProcessName -ne 'conhost') { $parent = $null }

$http = [Net.Http.HttpClient]::new()
$http.Timeout = [TimeSpan]::FromSeconds(8)

$port = $null
$rx = ''
$usage = $null
$fetchedAt = [int64]0
$err = ''
$forecast = [ordered]@{ s = $null; w = $null }
$verified = $false      # Board hat auf dem offenen Port geantwortet (ack/hello)
$openedAt = [DateTime]::MinValue
$badPorts = @{}         # Port -> bis wann überspringen (keine Antwort)
$portLog = @{}          # Port -> zuletzt geloggte Meldung
$lastScanError = ''
$nextPoll = [DateTime]::MinValue
$nextScan = [DateTime]::MinValue
$nextSend = [DateTime]::MaxValue
$nextPresence = [DateTime]::MinValue
$nextLocal = [DateTime]::MinValue
$nextDesktop = [DateTime]::MinValue
$nextRemote = [DateTime]::MinValue
$locked = $false
$dots = ''
$sessLine = $null      # Session-Zeile (Feld x im state)
$localItems = @()
$localSessions = @()    # Registry-Einträge (auch verwaiste, für die Bridge-IDs)
$desktopSessions = @()
$regCache = @{}
$deskCache = @{}
# Optionale eigene Seitentitel (install.ps1 -RemoteLabel/-LocalLabel), max. 14 Zeichen,
# und fester Port (install.ps1 -Port, z. B. COM7).
$Labels = @{ 1 = ''; 2 = '' }
$FixedPort = ''
try {
  $cfg = [IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json
  foreach ($p in @{ 1 = 'localLabel'; 2 = 'remoteLabel' }.GetEnumerator()) {
    $v = ConvertTo-DisplayTitle ([string]$cfg.($p.Value))
    if ($v) { $Labels[$p.Key] = $v.Substring(0, [Math]::Min(14, $v.Length)) }
  }
  $FixedPort = ([string]$cfg.port).Trim().ToUpperInvariant()
} catch { }  # keine oder ungültige config.json: Standardtitel, Port automatisch
if ($FixedPort) { Write-Log "Fester Port: $FixedPort" }

$remote = @()           # letzte gute Remote-Liste (andere Rechner)
$remoteAt = [int64]0
$remoteErr = ''
$remoteTask = $null
$lines = @{}            # zuletzt gebaute list-Zeilen
$pending = [Collections.Generic.List[string]]::new()  # davon noch zu senden
$stateSent = $false
$backlight = -1

try {
  while ($true) {
    $now = [DateTime]::UtcNow
    if ($parent -and $parent.HasExited) { Write-Log 'Task gestoppt'; break }

    if ($now -ge $nextPoll) {
      $nextPoll = $now.AddSeconds($PollSeconds)
      # Der Abruf blockiert bis zu 60 s; vorher einen Heartbeat senden, damit das
      # Display währenddessen nicht in den Offline-Screen (90 s) fällt.
      if ($port) {
        try {
          Send-Line $port (Get-StateLine $usage $fetchedAt $err $forecast $locked $dots $sessLine)
          $nextSend = [DateTime]::UtcNow.AddSeconds($HeartbeatSeconds)
        } catch { }  # Schreibfehler behandelt der Port-Block unten
      }
      try {
        $u = Get-Usage
        $changed = ($u | ConvertTo-Json -Compress -Depth 4) -ne ($usage | ConvertTo-Json -Compress -Depth 4)
        $usage = $u
        $fetchedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Save-Latest $usage $fetchedAt

        $fc = [ordered]@{
          s = Get-Forecast 's' $usage.Session $fetchedAt
          w = Get-Forecast 'w' $usage.Week $fetchedAt
        }
        if (($fc | ConvertTo-Json -Compress) -ne ($forecast | ConvertTo-Json -Compress)) { $nextSend = [DateTime]::UtcNow }
        $forecast = $fc
        if ($err) { Write-Log 'Abruf wieder erfolgreich'; $err = ''; $changed = $true }
        if ($changed) {
          $s = if ($usage.Session) { $usage.Session.p } else { '?' }
          $w = if ($usage.Week) { $usage.Week.p } else { '?' }
          $f = if ($forecast.s -and $forecast.s.f -gt 0) {
            ', Limit ca. {0:HH:mm}' -f [DateTimeOffset]::FromUnixTimeSeconds($forecast.s.f).ToLocalTime()
          } elseif ($forecast.s -and $null -ne $forecast.s.e) { ", ca. $($forecast.s.e) % bis Reset" }
          Write-Log "Usage: Session $s %, Woche $w %$f"
          $nextSend = [DateTime]::UtcNow
        }
      } catch {
        if ($parent -and $parent.HasExited) { Write-Log 'Task gestoppt'; break }
        $m = $_.Exception.GetBaseException().Message
        $e = Format-DisplayError $m
        if ($e -ne $err) { Write-Log "Abruf fehlgeschlagen: $m"; $err = $e; $nextSend = [DateTime]::UtcNow }
      }
    }

    # Sessions und Sperre. Fehler hier dürfen die Schleife nicht beenden.
    try {
      $localDirty = $false
      $remoteDirty = $false
      if ($now -ge $nextLocal) {
        $nextLocal = $now.AddSeconds($LocalSeconds)
        $l = Test-ScreenLocked
        if ($l -ne $locked) {
          $locked = $l
          Write-Log $(if ($locked) { 'Bildschirm gesperrt' } else { 'Bildschirm entsperrt' })
          $nextSend = [DateTime]::UtcNow
        }
        $localSessions = @(Get-LocalSessions $regCache)
        $localDirty = $true
      }
      if ($now -ge $nextDesktop) {
        $nextDesktop = $now.AddSeconds($DesktopSeconds)
        $desktopSessions = @(Get-DesktopSessions $deskCache)
        $localDirty = $true
      }

      $res = $null
      if (-not $remoteTask -and $now -ge $nextRemote) {
        $nextRemote = $now.AddSeconds($RemoteSeconds)
        $r = Start-RemoteFetch $http
        if ($r.Task) { $remoteTask = $r.Task } else { $res = $r }
      }
      if ($remoteTask -and $remoteTask.IsCompleted) {
        $t = $remoteTask
        $remoteTask = $null
        $res = Receive-RemoteFetch $t (Get-LocalBridgeIds $desktopSessions $localSessions)
      }
      if ($res) {
        if ($res.ContainsKey('Items')) { $remote = $res.Items; $remoteAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
        $e = [string]$res.Err
        if ($e -ne $remoteErr) {
          Write-Log $(if ($e) { "Remote-Sessions nicht abrufbar: $($res.Detail)" } else { 'Remote-Sessions wieder abrufbar' })
          $remoteErr = $e
        }
        $remoteDirty = $true
      }

      if ($localDirty) {
        $localItems = @(Get-LocalItems $desktopSessions $localSessions)
        Update-Line 'l1' (Get-ListLine 1 $localItems ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) '')
      }
      if ($remoteDirty) { Update-Line 'l2' (Get-ListLine 2 $remote $remoteAt $remoteErr) }
      if ($localDirty -or $remoteDirty) {
        $d = Get-Dots $localSessions $remote
        $x = Get-SessionLine $localItems $remote
        if ($d -ne $dots -or ($x | ConvertTo-Json -Compress) -ne ($sessLine | ConvertTo-Json -Compress)) {
          $dots = $d
          $sessLine = $x
          $nextSend = [DateTime]::UtcNow
        }
      }
    } catch {
      $m = "Sessions: $($_.Exception.Message)"
      if ($m -ne $lastScanError) { Write-Log $m; $lastScanError = $m }
    }

    if (-not $port) {
      if ($now -ge $nextScan) {
        $nextScan = $now.AddSeconds(3)
        $present = [IO.Ports.SerialPort]::GetPortNames()
        # Abgesteckte Ports vergessen: Nach dem Wiederanstecken gleich wieder prüfen.
        foreach ($k in @($badPorts.Keys) + @($portLog.Keys)) {
          if ($present -notcontains $k) { $badPorts.Remove($k); $portLog.Remove($k) }
        }
        # Erster Kandidat, der sich öffnen lässt; als Display gilt er erst nach ack/hello.
        foreach ($name in @(Find-DisplayPort $present $badPorts)) {
          try {
            $port = Open-DisplayPort $name
            $openedAt = [DateTime]::UtcNow
            $verified = $false
            $rx = ''
            $nextSend = [DateTime]::UtcNow.AddMilliseconds(1500)  # falls das Board beim Öffnen neu startet
            $stateSent = $false
            $backlight = -1
            Reset-Pending
            break
          } catch {
            Write-PortLog $name "Port $name nicht verfuegbar: $($_.Exception.Message)"
          }
        }
      }
    } else {
      try {
        if ($now -ge $nextPresence) {
          $nextPresence = $now.AddSeconds(2)
          if (-not $port.IsOpen -or [IO.Ports.SerialPort]::GetPortNames() -notcontains $port.PortName) {
            throw 'Port nicht mehr vorhanden'
          }
        }
        $rx += $port.ReadExisting()
        while (($i = $rx.IndexOf("`n")) -ge 0) {
          $line = $rx.Substring(0, $i).Trim()
          $rx = $rx.Substring($i + 1)
          if (-not $line.StartsWith('{')) { continue }  # z. B. Boot-Meldungen des ESP32
          try { $msg = $line | ConvertFrom-Json } catch { continue }
          if (-not $verified -and $msg.t -in 'ack', 'hello') {
            $verified = $true
            Write-Log "Display verbunden ($($port.PortName))"
            $badPorts.Remove($port.PortName)
            $portLog.Remove($port.PortName)
          }
          if ($msg.t -eq 'hello') {
            Write-Log "Display gestartet (Firmware $($msg.fw))"
            $nextSend = [DateTime]::UtcNow
            $backlight = -1
            Reset-Pending
          } elseif ($msg.t -eq 'ack' -and $msg.b -is [long]) {
            if ($backlight -ge 0 -and [int]$msg.b -ne $backlight) { Write-Log "Display-Helligkeit $backlight -> $($msg.b) (LDR $($msg.l))" }
            $backlight = [int]$msg.b
          }
        }
        if ($rx.Length -gt 4096) { $rx = '' }
        if (-not $verified -and [DateTime]::UtcNow -ge $openedAt.AddSeconds($VerifySeconds)) {
          # Keine Antwort auf state: kein Display (anderes Gerät oder andere Firmware).
          $name = $port.PortName
          try { $port.Dispose() } catch { }
          $port = $null
          $badPorts[$name] = [DateTime]::UtcNow.AddMinutes($BadPortMinutes)
          Write-PortLog $name "Kein Display an $name (keine Antwort)"
          $nextScan = [DateTime]::UtcNow.AddSeconds(3)
        } elseif ([DateTime]::UtcNow -ge $nextSend) {
          Send-Line $port (Get-StateLine $usage $fetchedAt $err $forecast $locked $dots $sessLine)
          $nextSend = [DateTime]::UtcNow.AddSeconds($HeartbeatSeconds)
          $stateSent = $true
        } elseif ($verified -and $stateSent -and $pending.Count) {
          # list einzeln pro Durchlauf (250 ms), damit der Empfangspuffer des Boards
          # (2 KB) auch während eines Redraws nicht überläuft.
          $k = $pending[0]
          $pending.RemoveAt(0)
          Send-Line $port $lines[$k]
        }
      } catch {
        $m = $_.Exception.Message
        if ($verified) { Write-Log "Display getrennt ($($port.PortName)): $m" }
        else { Write-PortLog $port.PortName "Port $($port.PortName) nicht verfuegbar: $m" }
        try { $port.Dispose() } catch { }
        $port = $null
        $nextScan = [DateTime]::UtcNow.AddSeconds(1)
      }
    }

    Start-Sleep -Milliseconds 250
  }
} finally {
  if ($port) { try { $port.Dispose() } catch { } }
  $mutex.ReleaseMutex()
  Write-Log 'Collector beendet'
}
