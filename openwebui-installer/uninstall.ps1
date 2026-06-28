<#
===============================================================================
 uninstall.ps1  -  Remove Open WebUI (stretch goal).

 Stops our processes, removes the install directory and the desktop shortcut,
 and OPTIONALLY removes the downloaded Ollama models (these can be large and
 the user may want to keep them, so we ask first). We do not uninstall Ollama
 itself, since the user may have installed it before, or use it elsewhere.

 Parameters (used by the Inno Setup uninstaller, which cannot answer prompts):
   -NonInteractive  Do not prompt; decide model deletion from -RemoveModels.
   -RemoveModels    When non-interactive, also delete downloaded models.

 Maintainer notes inline. User-facing text is plain language, no em dashes.
===============================================================================
#>
param(
    [switch]$NonInteractive,
    [switch]$RemoveModels
)
$ErrorActionPreference = 'SilentlyContinue'

$InstallRoot = "$env:LOCALAPPDATA\OpenWebUI"
$RuntimeDir  = Join-Path $InstallRoot "runtime"
$PidFile     = Join-Path $RuntimeDir "openwebui.pid"
$desktop     = [Environment]::GetFolderPath('Desktop')
$lnkPath     = Join-Path $desktop "Open WebUI.lnk"

Write-Host ""
Write-Host "Open WebUI uninstaller" -ForegroundColor White

# 1. Stop our running Open WebUI process if we recorded its PID.
if (Test-Path $PidFile) {
    try {
        $savedPid = [int](Get-Content $PidFile -Raw).Trim()
        $proc = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
        # Only stop it if it is genuinely ours (executable under the install root).
        if ($proc -and $proc.Path -and $proc.Path.ToLower().StartsWith($InstallRoot.ToLower())) {
            Write-Host "Stopping Open WebUI..."
            Stop-Process -Id $savedPid -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

# 2. Remove the desktop shortcut.
if (Test-Path $lnkPath) {
    Remove-Item $lnkPath -Force
    Write-Host "Removed the desktop shortcut."
}

# 3. Offer to remove Ollama models (potentially many GB). When driven by the
#    Inno uninstaller (-NonInteractive) we cannot prompt, so we obey -RemoveModels.
$ollamaModels = Join-Path $env:USERPROFILE ".ollama\models"
if (Test-Path $ollamaModels) {
    $delete = $false
    if ($NonInteractive) {
        $delete = [bool]$RemoveModels
    } else {
        $ans = Read-Host "Also delete downloaded AI models to reclaim disk space? (y/N)"
        $delete = ($ans -match '^(y|yes)$')
    }
    if ($delete) {
        Remove-Item $ollamaModels -Recurse -Force
        Write-Host "Deleted downloaded models."
    } else {
        Write-Host "Kept downloaded models."
    }
}

# 4. Remove the install directory (Python, venv, data, logs, launcher).
if (Test-Path $InstallRoot) {
    Write-Host "Removing the Open WebUI install folder (this deletes your local chats and account)..."
    Remove-Item $InstallRoot -Recurse -Force
}

Write-Host ""
Write-Host "Open WebUI has been removed." -ForegroundColor Green
Write-Host "Note: Ollama itself was left installed. To remove it, use Windows"
Write-Host "Settings, Apps, and uninstall 'Ollama'."
