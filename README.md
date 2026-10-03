# Claude-Usage-Display

Zeigt den Claude-Verbrauch (5-Stunden-Session und 7-Tage-Woche) und den Status der
laufenden Claude-Code-Sessions auf einem ESP32-2432S028 "Cheap Yellow Display" (CYD) an.
Verbindung nur über USB-Serial, kein WLAN, kein Token auf dem Gerät.

```
Claude-CLI (get_usage)  ─┐
~\.claude\sessions       ├─► collector.ps1 ──► USB-Serial, NDJSON ──► CYD-Firmware
Desktop-Session-Dateien  │   (Taskplaner,         115200 Baud          3 Seiten, Touch
Remote-Control-Liste    ─┘    PowerShell 7)
```

- **Host:** `host/collector.ps1` fragt alle 2 Minuten den Verbrauch ab, liest alle 2 s den
  Status der lokalen Sessions und alle 30 s die Remote-Control-Sessions anderer Rechner.
  Er führt einen Verlauf für Kurve und Prognose und schickt alles ans Display.
- **Display:** drei Seiten, Tippen schaltet weiter (Home → Remote → Lokal), nach 60 s
  ohne Tippen zurück auf Home. Helligkeit automatisch über den Lichtsensor, Backlight
  aus, solange Windows gesperrt ist.

## Voraussetzungen

- **Board:** ESP32-2432S028 ("Cheap Yellow Display", 320×240, Touch). Getestet mit der
  Dual-USB-Revision (Micro-USB + USB-C, ST7789-Panel); für die ursprüngliche Revision mit
  ILI9341-Panel gibt es ein eigenes Build-Env. USB-Seriell-Chip CH340 oder CP2102.
- **PC:** Windows 10/11 mit [PowerShell 7.5+](https://aka.ms/powershell). Keine Admin-Rechte nötig.
- **Claude:** Claude Desktop (Code-Tab) oder Claude Code CLI, angemeldet mit einem
  claude.ai-Abo (Pro, Max, Team oder Enterprise). Mit API-Key gibt es keine Usage-Limits
  und damit nichts anzuzeigen.
- **Zum Flashen:** [PlatformIO Core](https://platformio.org/install/cli), am einfachsten
  über die PlatformIO-Erweiterung für VS Code oder den offiziellen Installer. Beide legen
  `pio` unter `%USERPROFILE%\.platformio\penv\Scripts` ab, aber **nicht** im PATH. Für die
  aktuelle PowerShell-Sitzung reicht:
  `$env:PATH += ";$env:USERPROFILE\.platformio\penv\Scripts"`. Alternativ mit Python 3:
  `py -m pip install --user platformio` und dann `py -m platformio` statt `pio`.
## Inhalt

| Pfad | Zweck |
|---|---|
| `firmware/` | PlatformIO-Projekt: Envs `app` (ST7789) und `app-ili9341` = Anzeige, `test-st7789`/`test-ili9341` = Testbild |
| `host/collector.ps1` | Dauerprozess: Abruf, Sessions, Verlauf (`history.json`), `latest.json`, Serial |
| `host/claude-cli.ps1` | Findet die Claude-CLI (von `collector.ps1` und den Install-Scripts genutzt) |
| `host/install.ps1` | Autostart einrichten (Taskplaner, ohne Admin) und CLI anmelden |
| `host/uninstall.ps1` | Alles rückgängig machen |

## Setup

Alle Befehle im Projektordner (Wurzel dieses Repos) in PowerShell 7 ausführen; `-d firmware`
sagt PlatformIO, wo das Firmware-Projekt liegt. Wurde das Repo als ZIP heruntergeladen,
markiert Windows die Scripte als "aus dem Internet"; deshalb `-ExecutionPolicy Bypass` beim
Aufruf.

### 1. Original-Firmware sichern (empfohlen)

Das Board kommt mit einem Demo-Programm. Wer es später zurückhaben will, sichert vor dem
ersten Flashen den kompletten Flash (4 MB, ca. 2 Minuten; `COMx` = Port des Boards im
Gerätemanager). Der erste Build lädt die Werkzeuge (esptool) herunter:

```powershell
pio run -d firmware -e app; New-Item -ItemType Directory -Force firmware\backup | Out-Null
```
```powershell
pio pkg exec -p tool-esptoolpy -- esptool.py --chip esp32 --port COMx --baud 460800 read_flash 0 ALL firmware\backup\original-firmware.bin
```

`firmware/backup/` ist in `.gitignore` eingetragen und landet nicht im Repo.

### 2. Panel-Typ bestimmen

Die CYD-Revisionen haben unterschiedliche Display-Controller. Das Testbild zeigt
beschriftete Farbbalken; richtig ist die Variante mit schwarzem Hintergrund, passenden
Farben und lesbarem Text ("<- oben links" steht oben links):

```powershell
pio run -d firmware -e test-st7789 -t upload
```

Stimmt es nicht, `test-ili9341` probieren. Passt dann immer noch etwas nicht, helfen
Build-Flags, die genauso für die App gelten (vor dem Build setzen, für die App beibehalten):

| Problem | Flag |
|---|---|
| Weißer Hintergrund, Farben negativ | `$env:PLATFORMIO_BUILD_FLAGS = "-DPANEL_INVERT=1"` |
| Rot und Blau vertauscht | `$env:PLATFORMIO_BUILD_FLAGS = "-DPANEL_SWAP_RB=1"` |
| Bild gedreht oder gespiegelt | `$env:PLATFORMIO_BUILD_FLAGS = "-DROTATION=3"` (0–3 gedreht, 4–7 gespiegelt; Standard 1) |

Mehrere Flags mit Leerzeichen kombinieren, z. B. `"-DPANEL_INVERT=1 -DROTATION=3"`.

### 3. Firmware flashen

```powershell
pio run -d firmware -e app -t upload
```

Für ILI9341-Boards `-e app-ili9341`. PlatformIO findet den Port selbst; bei mehreren
seriellen Geräten `--upload-port COMx` anhängen. Läuft der Collector schon, hält er den
Port belegt: vorher `Stop-ScheduledTask 'Claude Usage Display'`, danach
`Start-ScheduledTask 'Claude Usage Display'`.

### 4. Host installieren (einmalig, ohne Admin-Rechte)

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\host\install.ps1
```
Das Script

1. kopiert `collector.ps1` und `claude-cli.ps1` nach `%USERPROFILE%\.usage-display\`,
2. legt den Task **"Claude Usage Display"** an. Er startet bei der Anmeldung über
   `conhost --headless`, also ohne sichtbares Fenster,
3. meldet die Claude-CLI an, falls sie es noch nicht ist (`claude auth login`,
   einmaliger Browser-Login mit dem Claude-Account),
4. startet den Collector.

Optionale Parameter, z. B. eigene Seitentitel (max. 14 Zeichen) wie der Name des Servers,
auf dem die Remote-Sessions laufen:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\host\install.ps1 -RemoteLabel "mein-server" -LocalLabel "Laptop"
```

| Parameter | Wirkung |
|---|---|
| `-RemoteLabel`, `-LocalLabel` | Titel von Seite 1 bzw. 2 (Standard "Remote" / "Lokal"); `""` stellt den Standard wieder her |
| `-Port COMx` | Festen COM-Port verwenden statt automatischer Suche; `""` schaltet zurück auf automatisch |
| `-NoLogin` | Keinen CLI-Login starten |

Die Werte landen in `%USERPROFILE%\.usage-display\config.json` und bleiben bei späteren
Installationen erhalten. Mehrfaches Ausführen ist unschädlich; so übernimmt man auch eine
geänderte `collector.ps1`. Den Display-Port sucht der Collector automatisch (CH340, CH9102,
CP2102) und nimmt nur einen Port, an dem das Board antwortet. Andere USB-Seriell-Geräte
werden nach 6 s ohne Antwort für 10 Minuten übergangen.

### 5. Prüfen

- Auf dem Display stehen nach etwa 5–10 s Werte, unten "Stand HH:MM".
- Log: `%USERPROFILE%\.usage-display\collector.log`
- Letzter Stand: `%USERPROFILE%\.usage-display\latest.json`

## Woher kommen die Zahlen?

Die Desktop-App führt die Statusline von Claude Code **nicht** aus, die läuft nur
in der Terminal-REPL. Der Collector nutzt deshalb denselben Weg wie die Desktop-App
intern. Er startet die Claude-CLI kurz im Headless-Modus
(`--print --input-format stream-json --output-format stream-json`), schickt den
Control-Request `get_usage` und liest `rate_limits.five_hour` / `seven_day`
(`utilization` 0–100 %, `resets_at`).

- Das verbraucht **kein** Kontingent, weil keine Anfrage an das Modell geht.
- Anmeldung und Token-Refresh macht die CLI selbst (`~\.claude\.credentials.json`).
- Ein Token aus `claude setup-token` reicht **nicht**: Es hat nur den Scope
  `user:inference`, für den Usage-Abruf ist `user:profile` nötig.
- Gefunden wird die CLI in dieser Reihenfolge: eigenständige Installation unter
  `%USERPROFILE%\.local\bin\claude.exe`, dann die neueste von Claude Desktop mitgebrachte
  Version (`%APPDATA%\Claude\claude-code\<version>\…\claude.exe`, bei der MSIX-Variante der
  App außerhalb der App unter `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude\claude-code\…`),
  dann WinGet (`%LOCALAPPDATA%\Microsoft\WinGet\Links\claude.exe`) und zuletzt `claude.exe`
  im PATH. Ein gesetztes `CLAUDE_CONFIG_DIR` wird berücksichtigt.
- `get_usage` ist eine interne, als experimentell markierte Schnittstelle. Ändert
  Anthropic sie, zeigt das Display die Fehlermeldung des Collectors in der Fußzeile.

**Session-Status:**
- **Lokal (Seite 2):** Jede laufende Claude-Code-Session (Desktop-App und Terminal) pflegt
  `~\.claude\sessions\<pid>.json` mit `busy` / `waiting` / `idle`. Der Collector liest nur
  diese `.json`-Dateien (nie die `.key`-Dateien) und prüft PID und Startzeit. Titel und
  letzte Aktivität der Desktop-Sessions kommen aus deren Session-Dateien
  (`…\Claude\claude-code-sessions`). Normale Chats aus dem Chat-Tab sind lokal nicht
  lesbar und werden nicht angezeigt.
- **Remote (Seite 1):** Sessions auf anderen Rechnern (z. B. einem Server, auf dem Claude
  Code im Terminal läuft) erscheinen, wenn dort **Remote Control** aktiv ist
  (`/config` → "Enable Remote Control for all sessions" oder `claude --remote-control`).
  Dann meldet sich jede Session bei Anthropic an, und der Collector holt die Liste über
  `GET https://api.anthropic.com/v1/code/sessions`, ohne Netzverbindung zum anderen Rechner.
  Dafür **liest** er das Access-Token der CLI aus `.credentials.json`: nur lesend, nie
  geloggt, nie erneuert (das macht die CLI bei den `get_usage`-Läufen) und nie an das
  Display gesendet. Genau genommen zeigt Seite 1 alle nicht archivierten Sessions dieser
  Liste, die keiner Session auf diesem Rechner zugeordnet werden können, auch beendete
  (leerer Ring). Wer Remote Control nirgends nutzt, sieht dort meist nur ältere eigene
  Sessions. Die Schnittstelle ist intern und undokumentiert; fällt sie aus, zeigt Seite 1
  einen Fehler, der Rest läuft weiter.
- Angezeigt werden nur Titel, Status und Zeit, nie Chat-Inhalte.

## Anzeige

**Seite 0: Home**

```
┌────────────────────────────────────────┐
│ Claude Usage      ● ○ ○       ● 11:36  │  Seitenpunkte, ● grün = Daten aktuell
│   ╭──────╮            ╭──────╮         │
│  │  17 %  │          │  24 %  │        │  Ring: grün bis 50 %,
│  │Session │          │ Woche  │        │  gelb um 80 %, rot ab 95 %
│ Reset 3 h 14 min      Reset 3 T 2 h    │
│ Limit ca. 13:40     ca. 38 % bis Reset │  Prognose
│ ▁▂▃▅▂▁▂▃▅  |          ▁▁▂▂▃▃  |        │  Verlauf heute (0–24 Uhr), | = jetzt
│ ● ● | ● ● ●                Stand 11:35 │  Dots: eine pro laufender Session
└────────────────────────────────────────┘
```

- **Prognose:** „Limit ca. HH:MM“ (orange), wenn das Limit beim Durchschnittstempo seit
  Fensterbeginn (Reset minus 5 h bzw. 7 Tage, dort 0 %) vor dem Reset erreicht wird,
  sonst „ca. XX % bis Reset“ (hochgerechneter Stand beim Reset, eingefärbt wie die Gauges).
  Beispiel: 20 % nach 2,6 h → 7,7 %/h → beim Reset ca. 38 %. Sie erscheint erst 30 min
  (Session) bzw. 12 h (Woche) nach Fensterbeginn, vorher wäre sie zu sprunghaft.
- **Verlauf:** Tageskurve in 15-min-Schritten, gespeichert in `history.json` (8 Tage).
- **Dots:** links die lokalen Sessions, nach dem Trennstrich die verbundenen
  Remote-Sessions. Grün pulsierend = arbeitet, orange schnell blinkend = wartet auf dich
  (Freigabe oder Frage), grau = idle.

**Seiten 1 (Remote) und 2 (Lokal):** die letzten 7 Sessions mit Status-Punkt (Farben wie
oben, leerer Ring = offline/beendet), Titel und Alter der letzten Aktivität („5 min“,
„3 h“, „2 T“; bei wartenden Sessions „wartet“). Unten die Zusammenfassung, z. B.
„1 arbeitet, 4 idle“.

- **Warte auf Daten:** Das Display hat seit dem Start noch nichts vom Host bekommen.
- **Offline:** Seit 90 s keine Nachricht vom Host. Unten stehen die zuletzt bekannten Werte.
- **`--`:** Wert unbekannt, z. B. vor dem ersten erfolgreichen Abruf.
- **Helligkeit:** Der Lichtsensor unterscheidet nur hell/dunkel (bei Tageslicht ist er
  gesättigt). Ist es 10 s lang dunkel, dimmt das Display auf ca. 10 %; wird es 10 s lang
  hell, geht es auf 100 %. Solange Windows gesperrt ist, ist das Backlight aus.

## Troubleshooting

| Symptom | Ursache / Abhilfe |
|---|---|
| Fußzeile "Nicht angemeldet: claude auth login" | `install.ps1` erneut ausführen, das startet den Login |
| Fußzeile "Claude-CLI nicht gefunden" | Claude Desktop installiert? Pfad siehe oben. Alternativ die CLI eigenständig installieren |
| "Warte auf Daten" bleibt stehen | Läuft der Task? `Get-ScheduledTask 'Claude Usage Display'`, außerdem `collector.log` prüfen |
| Log: "Port COMx nicht verfuegbar: Access … denied" | Ein anderes Programm hält den Port (serieller Monitor, PlatformIO-Upload, zweiter Collector). Der Collector versucht es alle 3 s erneut |
| Display wird nicht gefunden | Gerätemanager: Erscheint "USB-SERIAL CH340 (COMx)" bzw. "CP210x (COMx)"? Sonst den Treiber des Chips installieren (WCH CH341SER bzw. Silicon Labs CP210x). Reines Ladekabel? |
| Board startet beim Öffnen des Ports neu | Kommt vereinzelt vor (DTR/RTS-Auto-Reset-Schaltung). Harmlos: Das Board meldet `hello`, der Collector schickt sofort den Stand |
| Farben falsch oder Bild gespiegelt | Panel-Typ und Build-Flags (`PANEL_INVERT`, `PANEL_SWAP_RB`, `ROTATION`) prüfen, siehe Setup Schritt 2 |
| Log: "Kein Display an COMx (keine Antwort)" | An dem Port hängt ein anderes USB-Seriell-Gerät, oder das Board läuft noch nicht mit dieser Firmware. Firmware flashen bzw. `install.ps1 -Port COMx` setzen |
| Weißer Bildschirm | SPI-Takt zu hoch. Er steht in `lgfx_cyd.h` auf 27 MHz, über ca. 32 MHz scheitert die Panel-Initialisierung bei manchen Boards |
| PlatformIO-Install scheitert mit `CERTIFICATE_VERIFY_FAILED` | Ein Proxy mit TLS-Inspection (typisch in Firmennetzen) bricht die Verbindung auf. Außerhalb installieren oder `REQUESTS_CA_BUNDLE` auf das Firmen-Zertifikat setzen |
| Zahlen weichen kurz von claude.ai ab | Der Abruf läuft alle 2 Minuten, maßgeblich ist "Stand HH:MM" |
| Seite Remote: "Kein CLI-Login" / "Liste: Login abgelaufen" | CLI-Login fehlt oder ist abgelaufen: `install.ps1` erneut ausführen |
| Seite Remote: "Liste nicht abrufbar" | Netz weg oder die interne Schnittstelle hat sich geändert. Die letzte Liste bleibt stehen |
| Seite Remote bleibt leer | Auf dem anderen Rechner ist Remote Control nicht aktiv, oder er nutzt einen anderen Claude-Account |
| Display bleibt dunkel, obwohl entsperrt | Gesperrt gilt, solange `LogonUI.exe` läuft. Nach dem Entsperren kommt der nächste Stand binnen 2 s |
| Display dimmt nicht / dimmt bei Tag | Die Schwellen stehen in `firmware/src/app/main.cpp` (`LDR_DARK`, `LDR_BRIGHT`). Wechsel stehen im Log als "Display-Helligkeit … (LDR …)". Ein Gehäuse darf den Sensor nicht abdecken |

Das Log ist knapp gehalten: Start, Verbindung, Trennung, geänderte Werte, Fehler.
Wiederholte gleiche Fehler stehen nur einmal drin. Ab 1 MB wird es nach
`collector.log.1` rotiert.

## Protokoll

Eine JSON-Nachricht pro Zeile (UTF-8, `\n`), 115200 Baud, 8N1. Zeilen, die nicht
mit `{` beginnen, ignorieren beide Seiten (z. B. Boot-Meldungen des ESP32).
Zeilen über 1023 Byte verwirft das Board komplett. Texte sind ASCII (Umlaute
transliteriert), weil die Schriften nichts anderes kennen.

**Host → Display**

`state`: bei jeder Änderung, nach `hello` und alle 30 s.

```json
{"t":"state","now":1790975844,"tz":120,
 "s":{"p":17.0,"r":1791031800,"f":1790990400},"w":{"p":24.0,"r":1791284400,"f":0,"e":44},
 "at":1790975800,"lock":0,"d":"w|iiii"}
```

| Feld | Bedeutung |
|---|---|
| `now` | Aktuelle Zeit, Unix-Sekunden (UTC). Das Board führt damit seine Uhr |
| `tz` | Lokaler UTC-Offset in Minuten inkl. Sommerzeit |
| `s`, `w` | Session (5 h) und Woche (7 d): `p` = verbraucht in %, `r` = Reset (Unix-s), `f` = Prognose: Zeitpunkt, an dem 100 % erreicht werden, `0` = nicht vor dem Reset (dann `e` = hochgerechneter Stand beim Reset in %), fehlt = noch keine Prognose. Fehlt das Objekt, ist der Wert unbekannt |
| `at` | Zeitpunkt des letzten erfolgreichen Abrufs (fehlt, solange es keinen gab) |
| `err` | Kurzer Fehlertext für die Fußzeile (ASCII, max. 44 Zeichen). Fehlt, wenn alles gut ist |
| `lock` | `1` = Windows gesperrt → Backlight aus (gilt auch im Offline-Fall weiter) |
| `d` | Dots: ein Zeichen je laufender Session, `w` arbeitet, `a` wartet, `i` idle; erst lokal, dann `\|`, dann Remote (max. 24) |

`hist`: Tagesverlauf, eine Nachricht je Fenster (`k` = `s` oder `w`), bei Änderung und nach `hello`.

```json
{"t":"hist","k":"s","day":1790892000,"v":[-1,-1,…,12,15,17,-1,…]}
```

`day` = lokaler Tagesbeginn 00:00 (Unix-s), `v` = 96 Werte à 15 min (0–100, `-1` = keine Daten).

`list`: Session-Liste für Seite `p` (1 = Remote, 2 = Lokal), bei Änderung und nach `hello`.

```json
{"t":"list","p":1,"at":1790975800,"l":"mein-server","i":[{"n":"Refactoring API-Client","s":"i","a":1790890000}]}
```

Max. 7 Einträge, neueste zuerst. `n` = Titel (max. 40 Zeichen), `s` = `w` arbeitet,
`a` wartet, `i` idle, `o` offline/beendet, `a` = letzte Aktivität (Unix-s). Optional
`err` (Fehler beim Abruf) und `l` (eigener Seitentitel, max. 14 Zeichen).

**Display → Host**

| Nachricht | Wann |
|---|---|
| `{"t":"hello","fw":"2.1.0"}` | Nach dem Start. Der Host schickt sofort `state`, beide `hist` und beide `list` |
| `{"t":"ack","s":17.0,"w":24.0,"b":255,"l":0}` | Nach jedem `state`: übernommene Werte, Ziel-Helligkeit `b` (0–255), Lichtsensor roh `l` |

**Timing:** Verbrauch alle 120 s, lokale Sessions alle 2 s, Remote-Liste alle 30 s,
Sperre alle 2 s, Heartbeat alle 30 s, Offline-Screen nach 90 s ohne `state`.
Die Countdowns rechnet das Board selbst aus `r` und seiner vom Host gestellten Uhr.

## Deinstallation

Reihenfolge beachten: Für das Wiederherstellen der Original-Firmware braucht es
PlatformIO (esptool).

**1. Optional: Original-Firmware wiederherstellen** (die in Setup-Schritt 1 gesicherte
Datei). Vorher den Collector stoppen (`Stop-ScheduledTask 'Claude Usage Display'`).

```powershell
pio pkg exec -p tool-esptoolpy -- esptool.py --chip esp32 --port COMx --baud 460800 write_flash 0 firmware\backup\original-firmware.bin
```

**2. Host-Teil entfernen:**

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\host\uninstall.ps1
```

Entfernt den Task, beendet den Collector und löscht `%USERPROFILE%\.usage-display`.
Optionale Schalter:

- `-Logout` meldet zusätzlich die Claude-CLI ab.
- `-RemovePlatformIO` löscht zusätzlich `%USERPROFILE%\.platformio`. Erst nach Schritt 1
  verwenden, und nur, wenn PlatformIO ausschließlich für dieses Projekt installiert wurde:
  Der Ordner enthält auch die Werkzeuge anderer PlatformIO-Projekte und der VS-Code-Erweiterung.

`~\.claude\settings.json` wird von diesem Projekt nicht verändert.

## Hardware-Notizen

- Getestet mit ESP32-D0WD-V3, 4 MB Flash, CH340 (VID 1A86, PID 7523).
- Panel der Dual-USB-Revision: ST7789-Familie (Controller-ID `81 81 B3`, per SPI
  ausgelesen), keine Invertierung, BGR, Rotation 1 = Querformat 320×240.
- SPI: SCLK 14, MOSI 13, MISO 12, CS 15, DC 2, kein Reset-Pin. Backlight GPIO 21 (PWM).
  Touch (XPT2046): CLK 25, MOSI 32, MISO 39, CS 33, IRQ 36. Lichtsensor GPIO 34.
- Ohne Reset-Pin behält das Panel seine Register bis zum Stromlos-Machen. Die Firmware
  setzt es deshalb beim Start per Software-Reset zurück und schreibt danach `B6h`
  (Gate-Scan-Richtung). Das Bild ist so nach jedem Neustart gleich, egal welche Firmware
  vorher lief.
- Auto-Reset-Schaltung: RTS → EN, DTR → GPIO0. Deshalb öffnet der Collector den Port
  mit `DtrEnable = RtsEnable = false`.

Pin- und Takt-Erkenntnisse sind zum Teil vom Projekt
[Blink](https://github.com/KfirLevy258/Blink) inspiriert. Code wurde von dort nicht
übernommen.

## Lizenz

MIT mit "Commons Clause": Nutzen, Ändern und Weitergeben ist frei, der Verkauf bzw.
kostenpflichtige Angebote, deren Wert im Wesentlichen aus dieser Software stammt, sind nicht
erlaubt. Details in [LICENSE](LICENSE).
