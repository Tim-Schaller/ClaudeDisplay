@echo off
rem Claude-Usage-Display: Setup per Doppelklick (aus dem entpackten Release-ZIP).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Setup.ps1" %*
echo.
pause
