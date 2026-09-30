@echo off
rem Runs the client app on a phone plugged in by USB, on any network.
rem Double-click it, or run it from any terminal. See tool\run_on_phone.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\run_on_phone.ps1" %*
if errorlevel 1 pause
