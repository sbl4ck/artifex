@echo off
rem ARTIFEX setup for Windows. Double-click it, or run it from a terminal with options:
rem   setup-windows.cmd -Model qwen3:14b
rem   setup-windows.cmd -Status ^| -Stop ^| -Start ^| -Logs ^| -Uninstall
rem See setup-windows.ps1 for everything it does. A log of each run is written to
rem %LOCALAPPDATA%\ARTIFEX\setup.log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1" %*
set "rc=%ERRORLEVEL%"
rem Keep the window open on a plain run (such as a double-click) so the result can be read.
if "%~1"=="" pause
exit /b %rc%
