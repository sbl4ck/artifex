@echo off
rem ARTIFEX setup for Windows. Double-click it, or run it from a terminal with options:
rem   setup-windows.cmd -Model qwen3:14b
rem   setup-windows.cmd -Status ^| -Stop ^| -Start ^| -Logs ^| -Uninstall
rem See setup-windows.ps1 for everything it does.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-windows.ps1" %*
set "rc=%ERRORLEVEL%"
rem Keep the window open after a double-click so the result can be read.
if "%~1"=="" echo %CMDCMDLINE% | findstr /i /c:" /c " >/dev/null && pause
exit /b %rc%
