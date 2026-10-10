@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Setup.ps1"
if errorlevel 1 (
  echo.
  echo Setup did not complete. Please keep the message above for troubleshooting.
  pause
  exit /b 1
)
echo.
pause
