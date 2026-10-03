Claude-Usage-Display - Setup
============================

Shows your Claude usage and the status of your Claude Code sessions on an
ESP32-2432S028 "Cheap Yellow Display" (CYD), connected via USB.

Requirements
- Windows 10/11
- Claude Desktop with the Code tab, signed in with a claude.ai subscription
  (Pro, Max, Team or Enterprise)
- The CYD board and a USB DATA cable (not a charge-only cable)

Install
1. Unpack this ZIP to a folder you keep (e.g. Documents\ClaudeDisplay).
2. Plug the CYD into your PC.
3. Double-click Setup.cmd and follow the prompts. If Windows asks whether to run
   it, choose "More info" -> "Run anyway".
   Setup checks Claude Desktop and PowerShell 7 (and offers to install it),
   finds the board, downloads Espressif's official esptool, optionally backs up
   the board's original firmware, flashes the display firmware and installs the
   background service (one-time browser login to Claude).

Use
- Tap a session on the display to open it on the PC; tap anywhere else to switch
  pages: Home -> Local -> Remote.
- The display texts are in German ("Warte auf Daten" = waiting for data).

Uninstall
- Double-click Uninstall.cmd. The firmware stays on the board; a backup of the
  original firmware (if you made one) is in the "backup" folder.

More: https://github.com/Tim-Schaller/ClaudeDisplay