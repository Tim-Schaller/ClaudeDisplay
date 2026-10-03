@echo off
rem Claude-Usage-Display: Hintergrunddienst entfernen (Firmware bleibt auf dem Display).
where pwsh >nul 2>nul || (echo PowerShell 7 not found. & pause & exit /b 1)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0host\uninstall.ps1" %*
echo.
pause
