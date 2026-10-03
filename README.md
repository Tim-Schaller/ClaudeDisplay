# Claude-Usage-Display

Shows your Claude usage (5-hour session and 7-day week) and the status of your running
Claude Code sessions on an ESP32-2432S028 "Cheap Yellow Display" (CYD).
USB serial only: no Wi-Fi, no token on the device.

```
Claude CLI (get_usage)  ─┐
~\.claude\sessions       ├─► collector.ps1 ──► USB serial, NDJSON ──► CYD firmware
Desktop session files    │   (Task Scheduler,     115200 baud          3 pages, touch
Remote Control list     ─┘    PowerShell 7)
```

- **Host:** `host/collector.ps1` fetches the usage every 2 minutes, reads the state of the
  local sessions every 2 s and the Remote Control sessions of other machines every 30 s.
  It computes a forecast and sends everything to the display.
- **Display:** three pages, tap to switch (Home → Local → Remote), back to Home after
  60 s without a tap. Brightness follows the light sensor; the backlight turns off while
  Windows is locked.

> **Made for the Claude Desktop app on Windows (Code tab).** This project is not meant
> for setups that only use the Claude Code CLI in a terminal; for those, Claude Code's
> built-in [status line](https://code.claude.com/docs/en/statusline) is the better fit.
> In the background the collector uses the CLI that ships with Claude Desktop; you don't
> install or use the CLI yourself.

> The texts on the display and in the log are in German. This README quotes them as they
> appear, with the English meaning next to them.

## Requirements

- **Board:** ESP32-2432S028 ("Cheap Yellow Display", 320×240, touch). Tested with the
  dual-USB revision (micro-USB + USB-C, ST7789 panel); the original revision with an
  ILI9341 panel has its own build env. USB serial chip CH340, CH9102 or CP2102.
- **PC:** Windows 10/11 with [PowerShell 7.5+](https://aka.ms/powershell). No admin rights needed.
- **Claude:** the Claude Desktop app for Windows with the Code tab, signed in with a
  claude.ai subscription (Pro, Max, Team or Enterprise). With an API key there are no
  usage limits and therefore nothing to show. Setups with only the standalone Claude Code
  CLI are not supported.
- **Only for building from source:** [PlatformIO Core](https://platformio.org/install/cli), easiest through
  the PlatformIO extension for VS Code or the official installer. Both put `pio` into
  `%USERPROFILE%\.platformio\penv\Scripts`, but **not** on the PATH. For the current
  PowerShell session this is enough:
  `$env:PATH += ";$env:USERPROFILE\.platformio\penv\Scripts"`. Alternatively with Python 3:
  `py -m pip install --user platformio`, then use `py -m platformio` instead of `pio`.

## Contents

| Path | Purpose |
|---|---|
| `firmware/` | PlatformIO project: envs `app` (ST7789) and `app-ili9341` = display, `test-st7789`/`test-ili9341` = test image |
| `host/collector.ps1` | Background process: usage, forecast, sessions, `latest.json`, serial |
| `host/claude-cli.ps1` | Finds the Claude CLI (used by `collector.ps1` and the install scripts) |
| `host/install.ps1` | Sets up autostart (Task Scheduler, no admin) and signs in the CLI |
| `host/uninstall.ps1` | Undoes everything |
| `setup/` | Setup assistant for the release ZIP (`Setup.cmd`, `Setup.ps1`, `Uninstall.cmd`, `README.txt`) |
| `tools/make-release.ps1` | Builds a release into `dist/`: all firmware images (checked for local paths) and the setup ZIP |

## Quick start (plug & play)

1. Download **`ClaudeDisplay-Setup-vX.Y.Z.zip`** from the
   [latest release](https://github.com/Tim-Schaller/ClaudeDisplay/releases/latest) and unpack it
   to a folder you keep (e.g. `Documents\ClaudeDisplay`).
2. Plug the CYD into your PC with a USB **data** cable.
3. Double-click **`Setup.cmd`** and follow the prompts (if Windows asks, choose
   "More info" → "Run anyway").

The setup assistant

- checks Claude Desktop and PowerShell 7 (and offers to install PowerShell 7 from the
  Microsoft Store, no admin rights needed),
- finds the board (CH340, CH9102 or CP2102),
- downloads Espressif's official esptool (pinned version, SHA256-checked) for the duration
  of the setup,
- optionally backs up the board's original firmware into the `backup` folder,
- flashes the display firmware and asks whether the screen looks right; if not, it
  flashes the other panel variant (ST7789 / ILI9341),
- installs the background service, including the one-time browser login to Claude.

Afterwards the display shows your usage within a few seconds. To remove the background
service later, double-click `Uninstall.cmd`.

**Without the assistant:** the release also contains the firmware images on their own.
Each contains bootloader, partition table and app and is written to address `0x0`, e.g.
with the [Espressif web flasher](https://espressif.github.io/esptool-js/) in Chrome/Edge or
with `py -m esptool --chip esp32 --port COMx --baud 460800 write_flash 0x0 <file>`:

| Image | For |
|---|---|
| `claude-display-st7789-vX.Y.Z.bin` | Dual-USB revision (ST7789 panel) |
| `claude-display-ili9341-vX.Y.Z.bin` | Original revision (ILI9341 panel) |
| `test-st7789-vX.Y.Z.bin`, `test-ili9341-vX.Y.Z.bin` | Test image to find out which panel you have (see setup step 2) |

Then install the host part as in setup step 4. If the image looks wrong (inverted colors,
swapped red/blue, rotated), build the firmware yourself with the build flags from setup
step 2.
## Setup (manual / from source)

Run all commands in PowerShell 7 from the project folder (root of this repo); `-d firmware`
tells PlatformIO where the firmware project is. If you downloaded the repo as a ZIP,
Windows marks the scripts as "from the internet"; that is why the commands use
`-ExecutionPolicy Bypass`.

### 1. Back up the original firmware (recommended)

The board ships with a demo program. If you want it back later, back up the whole flash
before flashing for the first time (4 MB, about 2 minutes; `COMx` = the board's port in
Device Manager). The first build downloads the tools (esptool):

```powershell
pio run -d firmware -e app; New-Item -ItemType Directory -Force firmware\backup | Out-Null
```
```powershell
pio pkg exec -p tool-esptoolpy -- esptool.py --chip esp32 --port COMx --baud 460800 read_flash 0 ALL firmware\backup\original-firmware.bin
```

`firmware/backup/` is listed in `.gitignore` and never ends up in the repo.

### 2. Determine the panel type

The CYD revisions use different display controllers. The test image shows labelled color
bars; the right variant has a black background, matching colors and readable text
("<- oben links" = "top left" is in the top-left corner):

```powershell
pio run -d firmware -e test-st7789 -t upload
```

If it looks wrong, try `test-ili9341`. If something is still off, build flags help; they
apply to the app in the same way (set them before building and keep them for the app):

| Problem | Flag |
|---|---|
| White background, negative colors | `$env:PLATFORMIO_BUILD_FLAGS = "-DPANEL_INVERT=1"` |
| Red and blue swapped | `$env:PLATFORMIO_BUILD_FLAGS = "-DPANEL_SWAP_RB=1"` |
| Image rotated or mirrored | `$env:PLATFORMIO_BUILD_FLAGS = "-DROTATION=3"` (0–3 rotated, 4–7 mirrored; default 1) |

Combine several flags with spaces, e.g. `"-DPANEL_INVERT=1 -DROTATION=3"`.

### 3. Flash the firmware

```powershell
pio run -d firmware -e app -t upload
```

For ILI9341 boards use `-e app-ili9341`. PlatformIO finds the port by itself; with several
serial devices attached add `--upload-port COMx`. If the collector is already running it
holds the port: run `Stop-ScheduledTask 'Claude Usage Display'` first and
`Start-ScheduledTask 'Claude Usage Display'` afterwards.

### 4. Install the host part (once, no admin rights)

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\host\install.ps1
```

The script

1. copies `collector.ps1` and `claude-cli.ps1` to `%USERPROFILE%\.usage-display\`,
2. creates the task **"Claude Usage Display"**. It starts at logon via
   `conhost --headless`, so without a visible window,
3. signs in the Claude Code CLI bundled with Claude Desktop if it is not signed in yet
   (`claude auth login`, a one-time browser login with your Claude account). The collector
   uses this CLI in the background; its login is separate from the desktop app's own login,
4. starts the collector.

Optional parameters, e.g. your own page titles (max. 14 characters) such as the name of the
server the remote sessions run on:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\host\install.ps1 -LocalLabel "Laptop" -RemoteLabel "my-server"
```

| Parameter | Effect |
|---|---|
| `-LocalLabel`, `-RemoteLabel` | Title of page 1 and 2 (default "Lokal" / "Remote"); `""` restores the default |
| `-Port COMx` | Use a fixed COM port instead of searching; `""` switches back to automatic |
| `-NoLogin` | Do not start the CLI login |

The values are stored in `%USERPROFILE%\.usage-display\config.json` and survive later
installs. Running the script again is harmless; it is also how you apply a changed
`collector.ps1`. The collector searches the display port automatically (CH340, CH9102,
CP2102) and only uses a port on which the board answers. Other USB serial devices are
skipped for 10 minutes after 6 s without an answer.

### 5. Check

- After about 5–10 s the display shows values, with "Stand HH:MM" (= "as of HH:MM") at
  the bottom.
- Log: `%USERPROFILE%\.usage-display\collector.log`
- Latest values: `%USERPROFILE%\.usage-display\latest.json`

## Where do the numbers come from?

The desktop app does **not** run Claude Code's status line; that only runs in the
terminal REPL. The collector therefore takes the same route the desktop app uses
internally. It briefly starts the Claude CLI in headless mode
(`--print --input-format stream-json --output-format stream-json`), sends the
`get_usage` control request and reads `rate_limits.five_hour` / `seven_day`
(`utilization` 0–100 %, `resets_at`).

- This uses **no** quota, because no request goes to the model.
- The CLI handles sign-in and token refresh itself (`~\.claude\.credentials.json`).
- A token from `claude setup-token` is **not** enough: it only has the `user:inference`
  scope, and fetching usage needs `user:profile`.
- The collector uses the newest CLI version bundled with Claude Desktop
  (`%APPDATA%\Claude\claude-code\<version>\…\claude.exe`; for the MSIX version of the app,
  outside the app at `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude\claude-code\…`).
  If a standalone CLI happens to be installed at `%USERPROFILE%\.local\bin\claude.exe`,
  that one is preferred. Without a bundled CLI the collector would also try WinGet and
  the PATH, but that is a fallback, not a supported setup.
  A `CLAUDE_CONFIG_DIR` setting is respected.
- `get_usage` is an internal interface marked as experimental. If Anthropic changes it,
  the display shows the collector's error message in the footer.

**Session status:**
- **Local (page 1):** every running Claude Code session of the desktop app (and any CLI session in a terminal, if you also use one) keeps
  `~\.claude\sessions\<pid>.json` up to date with `busy` / `waiting` / `idle`. The
  collector only reads these `.json` files (never the `.key` files) and checks PID and
  start time. Title and last activity of desktop sessions come from their session files
  (`…\Claude\claude-code-sessions`). Regular chats from the Chat tab cannot be read
  locally and are not shown.
- **Remote (page 2):** sessions on other machines (e.g. a server running Claude Code in a
  terminal) appear when **Remote Control** is enabled there (`/config` → "Enable Remote
  Control for all sessions", or `claude --remote-control`). Each session then registers
  with Anthropic, and the collector fetches the list from
  `GET https://api.anthropic.com/v1/code/sessions`, without any network connection to the
  other machine. To do so it **reads** the CLI's access token from `.credentials.json`:
  read-only, never logged, never refreshed (the CLI does that during the `get_usage` runs)
  and never sent to the display. Strictly speaking, page 2 shows all non-archived sessions
  from that list that cannot be matched to a session on this machine, including ended
  ones (hollow ring). If you don't use Remote Control anywhere, you will mostly see older
  sessions of your own there. The interface is internal and undocumented; if it breaks,
  page 2 shows an error and everything else keeps working.
- Only titles, status and times are shown, never chat content.

## Display

**Page 0: Home**

```
┌────────────────────────────────────────┐
│ Claude Usage      ● ○ ○       ● 11:36  │  page dots, green ● = data is current
│   ╭──────╮            ╭──────╮         │
│  │  17 %  │          │  24 %  │        │  ring: green up to 50 %,
│  │Session │          │ Woche  │        │  yellow around 80 %, red from 95 %
│ Reset 3 h 14 min      Reset 3 T 2 h    │
│ Limit ca. 13:40     ca. 38 % bis Reset │  forecast
│ ● wartet: API client refactoring    +1 │  session line
│ ● ● | ● ● ●                Stand 11:35 │  dots: one per running session
└────────────────────────────────────────┘
```

"Woche" = week, "T" = days ("Tage").

- **Forecast:** "Limit ca. HH:MM" (= limit reached around HH:MM, orange) if, at the average
  pace since the window started (reset minus 5 h or 7 days, starting at 0 %), the limit
  is reached before the reset; otherwise "ca. XX % bis Reset" (= about XX % at reset: the
  projected value at reset, colored like the gauges). Example: 20 % after 2.6 h →
  7.7 %/h → about 38 % at reset. It only appears 30 min (session) or 12 h (week) after
  the window started; before that it would be too jumpy.
- **Session line:** the session that is waiting for you (orange, "wartet: …" = waiting),
  otherwise the one that is working (green, "arbeitet: …" = working), with its title;
  "+1" etc. counts further active sessions. Local and remote sessions both count. If all
  running sessions are idle it says "alle Sessions idle"; without running sessions it is empty.
- **Dots:** local sessions on the left, connected remote sessions after the separator.
  Pulsing green = working, fast-blinking orange = waiting for you (permission or
  question; for remote sessions also a finished turn that claude.ai files under "needs
  input"), gray = idle.

**Pages 1 (Local, "Lokal") and 2 (Remote):** the last 7 sessions with a status dot (colors
as above, hollow ring = offline/ended), title and age of the last activity ("5 min",
"3 h", "2 T" = 2 days; for waiting sessions "wartet" = waiting). At the bottom a summary,
e.g. "1 arbeitet, 4 idle" (1 working, 4 idle).

- **"Warte auf Daten"** (waiting for data): the display has not received anything from
  the host since it started.
- **"Offline":** no message from the host for 90 s. The last known values are shown at
  the bottom.
- **`--`:** value unknown, e.g. before the first successful fetch.
- **Brightness:** the light sensor only distinguishes bright from dark (it saturates in
  daylight). After 10 s of darkness the display dims to about 10 %; after 10 s of light
  it returns to 100 %. While Windows is locked the backlight is off.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Footer "Nicht angemeldet: claude auth login" (not signed in) | Run `install.ps1` again; it starts the login |
| Footer "Claude-CLI nicht gefunden" (CLI not found) | Is Claude Desktop installed and has its Code tab been opened at least once? The desktop app downloads its bundled CLI there |
| "Warte auf Daten" stays on screen | Is the task running? `Get-ScheduledTask 'Claude Usage Display'`; also check `collector.log` |
| Log: "Port COMx nicht verfuegbar: Access … denied" (port not available) | Another program holds the port (serial monitor, PlatformIO upload, a second collector). The collector retries every 3 s |
| Display is not found | Device Manager: does "USB-SERIAL CH340 (COMx)" or "CP210x (COMx)" show up? If not, install the chip's driver (WCH CH341SER or Silicon Labs CP210x). Charge-only cable? |
| Board restarts when the port is opened | Happens occasionally (DTR/RTS auto-reset circuit). Harmless: the board sends `hello` and the collector immediately sends the current state |
| Wrong colors or mirrored image | Check panel type and build flags (`PANEL_INVERT`, `PANEL_SWAP_RB`, `ROTATION`), see setup step 2 |
| Log: "Kein Display an COMx (keine Antwort)" (no display, no answer) | Another USB serial device is on that port, or the board does not run this firmware yet. Flash the firmware or set `install.ps1 -Port COMx` |
| White screen | SPI clock too high. It is set to 27 MHz in `lgfx_cyd.h`; above about 32 MHz the panel initialisation fails on some boards |
| PlatformIO install fails with `CERTIFICATE_VERIFY_FAILED` | A proxy with TLS inspection (common in corporate networks) intercepts the connection. Install outside that network or point `REQUESTS_CA_BUNDLE` to the corporate certificate |
| Numbers differ briefly from claude.ai | The fetch runs every 2 minutes; "Stand HH:MM" tells you how current they are |
| Remote page: "Kein CLI-Login" / "Liste: Login abgelaufen" (no CLI login / login expired) | The CLI login is missing or expired: run `install.ps1` again |
| Remote page: "Liste nicht abrufbar" (list not available) | No network, or the internal interface has changed. The last list stays on screen |
| Remote page stays empty | Remote Control is not enabled on the other machine, or it uses a different Claude account |
| Display stays dark although unlocked | "Locked" means `LogonUI.exe` is running. After unlocking, the next update arrives within 2 s |
| Display does not dim / dims in daylight | The thresholds are in `firmware/src/app/main.cpp` (`LDR_DARK`, `LDR_BRIGHT`). Changes appear in the log as "Display-Helligkeit … (LDR …)". A case must not cover the sensor |

The log is kept short: start, connect, disconnect, changed values, errors. Repeated
identical errors are logged only once. At 1 MB it is rotated to `collector.log.1`.

## Protocol

One JSON message per line (UTF-8, `\n`), 115200 baud, 8N1. Both sides ignore lines that
do not start with `{` (e.g. ESP32 boot messages). The board drops lines longer than
1023 bytes entirely. Texts are ASCII (umlauts transliterated), because the fonts know
nothing else.

**Host → display**

`state`: on every change, after `hello`, and every 30 s.

```json
{"t":"state","now":1790975844,"tz":120,
 "s":{"p":17.0,"r":1791031800,"f":1790990400},"w":{"p":24.0,"r":1791284400,"f":0,"e":44},
 "at":1790975800,"lock":0,"d":"w|aiii","x":{"s":"a","n":"API client refactoring","m":1}}
```

| Field | Meaning |
|---|---|
| `now` | Current time, Unix seconds (UTC). The board keeps its clock with it |
| `tz` | Local UTC offset in minutes, including daylight saving time |
| `s`, `w` | Session (5 h) and week (7 d): `p` = used in %, `r` = reset (Unix s), `f` = forecast: time at which 100 % is reached, `0` = not before the reset (then `e` = projected value at reset in %), missing = no forecast yet. If the object is missing, the value is unknown |
| `at` | Time of the last successful fetch (missing until there is one) |
| `err` | Short error text for the footer (ASCII, max. 44 characters). Missing when all is well |
| `lock` | `1` = Windows locked → backlight off (also stays in effect while offline) |
| `d` | Dots: one character per running session, `w` working, `a` waiting, `i` idle; local first, then `\|`, then remote (max. 24) |
| `x` | Session line: `s` = `a` waiting / `w` working / `i` all idle, `n` = title (ASCII, max. 40), `m` = number of further active sessions. Missing = no running sessions |

`list`: session list for page `p` (1 = local, 2 = remote), on change and after `hello`.

```json
{"t":"list","p":2,"at":1790975800,"l":"my-server","i":[{"n":"Refactoring API client","s":"i","a":1790890000}]}
```

Max. 7 entries, newest first. `n` = title (max. 40 characters), `s` = `w` working,
`a` waiting, `i` idle, `o` offline/ended, `a` = last activity (Unix s). Optional `err`
(error while fetching) and `l` (custom page title, max. 14 characters).

**Display → host**

| Message | When |
|---|---|
| `{"t":"hello","fw":"2.4.0"}` | After start-up. The host immediately sends `state` and both `list` |
| `{"t":"ack","s":17.0,"w":24.0,"b":255,"l":0}` | After every `state`: the accepted values, target brightness `b` (0–255), raw light sensor value `l` |

**Timing:** usage every 120 s, local sessions every 2 s, remote list every 30 s, lock
state every 2 s, heartbeat every 30 s, offline screen after 90 s without `state`.
The board computes the countdowns itself from `r` and the clock set by the host.

## Uninstall

Mind the order: restoring the original firmware needs PlatformIO (esptool).

**1. Optional: restore the original firmware** (the file backed up in setup step 1).
Stop the collector first (`Stop-ScheduledTask 'Claude Usage Display'`).

```powershell
pio pkg exec -p tool-esptoolpy -- esptool.py --chip esp32 --port COMx --baud 460800 write_flash 0 firmware\backup\original-firmware.bin
```

**2. Remove the host part:**

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\host\uninstall.ps1
```

Removes the task, stops the collector and deletes `%USERPROFILE%\.usage-display`.
Optional switches:

- `-Logout` also signs out the Claude CLI.
- `-RemovePlatformIO` also deletes `%USERPROFILE%\.platformio`. Only use it after step 1,
  and only if you installed PlatformIO just for this project: the folder also holds the
  tools of other PlatformIO projects and of the VS Code extension.

This project does not modify `~\.claude\settings.json`.

## Hardware notes

- Tested with ESP32-D0WD-V3, 4 MB flash, CH340 (VID 1A86, PID 7523).
- Panel of the dual-USB revision: ST7789 family (controller ID `81 81 B3`, read back via
  SPI), no inversion, BGR, rotation 1 = landscape 320×240.
- SPI: SCLK 14, MOSI 13, MISO 12, CS 15, DC 2, no reset pin. Backlight GPIO 21 (PWM).
  Touch (XPT2046): CLK 25, MOSI 32, MISO 39, CS 33, IRQ 36. Light sensor GPIO 34.
- Without a reset pin the panel keeps its registers until power is removed. The firmware
  therefore resets it by software at start-up and then writes `B6h` (gate scan
  direction). This way the image is the same after every restart, whatever firmware ran
  before.
- Auto-reset circuit: RTS → EN, DTR → GPIO0. That is why the collector opens the port
  with `DtrEnable = RtsEnable = false`.

Some of the pin and clock findings were inspired by the
[Blink](https://github.com/KfirLevy258/Blink) project. No code was taken from it.

## License

MIT with the "Commons Clause": you may use, modify and share it freely, but selling it or
offering paid products or services whose value derives substantially from this software
is not allowed. See [LICENSE](LICENSE) for details.
