@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Uninstall.ps1"
if errorlevel 1 (
  echo Uninstall did not complete. Keep the message above for troubleshooting.
  pause
  exit /b 1
)
pause
