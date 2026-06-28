@echo off
REM ===========================================================================
REM  Uninstall-OpenWebUI.bat
REM  Double-click to remove Open WebUI. Per-user, no admin needed.
REM ===========================================================================
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%uninstall.ps1"
echo.
echo Press any key to close this window.
pause >nul
endlocal
