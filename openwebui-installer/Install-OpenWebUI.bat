@echo off
REM ===========================================================================
REM  Install-OpenWebUI.bat
REM  Double-click entry point for the Open WebUI + Ollama native installer.
REM
REM  This file exists for one reason: a non-technical user can double-click a
REM  .bat, but cannot be expected to open PowerShell and relax its execution
REM  policy. We launch install.ps1 with an execution-policy bypass that is
REM  scoped to THIS process only (it does not change any machine or user
REM  policy), with -NoProfile so a user's broken PowerShell profile cannot
REM  derail the install.
REM
REM  We deliberately do NOT request administrator rights here. Every component
REM  (Ollama, the bundled Python, the venv, the desktop shortcut) installs
REM  per-user under %LOCALAPPDATA%, so no UAC elevation is needed. See the
REM  "Elevation" note in CHANGELOG.md.
REM ===========================================================================

setlocal
set "SCRIPT_DIR=%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install.ps1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo Installation did not finish. Read the message above; it includes the
    echo location of a log file you can send for help.
) else (
    echo All done. Look for the "Open WebUI" shortcut on your desktop.
)
echo.
echo Press any key to close this window.
pause >nul
endlocal
exit /b %RC%
