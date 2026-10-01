@echo off
rem Puts this PC's server online for testing, free, at your fixed ngrok address.
rem Double-click it; close the window to go offline. See docs\FREE-HOSTING.md.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backend\scripts\start_online.ps1" %*
if errorlevel 1 pause
