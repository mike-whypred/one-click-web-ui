<#
===============================================================================
 install.ps1  -  One-click native installer for Open WebUI + Ollama on Windows

 Audience for THIS file: a maintainer. It is heavily commented on purpose.
 Audience for the messages it prints: a non-technical end user.

 Goal: take a 64-bit Windows 10/11 machine from nothing to a working local AI
 chat app, with no Docker, no terminal use beyond a double-click, no system
 Python dependency, and no PATH changes. Re-runnable (idempotent) and offline
 after the first install.

 High-level flow:
   1.  Preflight (OS, architecture, disk space).
   2.  Ollama: install or update to a version new enough for the default model.
   3.  Start the Ollama server and wait until its API answers.
   4.  Model: pull the default ONLY if the user has no models at all.
   5.  Python: bundle a private CPython via uv, scoped under the install dir.
   6.  Open WebUI: install into an isolated venv (never global site-packages).
   7.  Generate the runtime launcher and a hidden-launch wrapper.
   8.  Create the "Open WebUI" desktop shortcut.

 Design decisions worth knowing before you edit:
   * Python runtime = uv-managed standalone CPython + venv (spec Option B /
     "uv-managed venv"). uv is a single self-contained .exe with a STABLE
     "latest/download" URL, it downloads the same python-build-standalone
     CPython the spec recommends, it handles compiled wheels correctly, and it
     keeps the interpreter, cache and venv entirely under the install dir. This
     avoids the embeddable-zip fragility AND the dated-asset-URL rot you hit if
     you fetch python-build-standalone tarballs directly. See CHANGELOG.md.
   * No elevation. All installs are per-user under %LOCALAPPDATA%.
   * Full executable paths are resolved and used directly; we never rely on
     PATH for ollama or python.
   * Readiness is confirmed by POLLING HTTP endpoints with timeouts, never by
     a fixed Start-Sleep.

 PowerShell 5.1 compatible. No PowerShell Gallery modules.
 No em dashes in any user-facing text or comment (commas / parentheses only).
===============================================================================
#>

[CmdletBinding()]
param()

# Stop on any uncaught error so our trap can turn it into a friendly message.
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# CONSTANTS  (exposed at the top of the file, as required by the spec)
# ---------------------------------------------------------------------------

# Default chat model. Laptop-friendly. Surfaced automatically in the Open WebUI
# model dropdown once pulled. Kept as a single named constant so it is trivial
# to change. Note: confirm the tag exists with "ollama list" / the Ollama
# library if you bump this.
$ModelName = "gemma4:e4b"

# Preferred HTTP port for Open WebUI. If taken, we transparently pick the next
# free port and use it consistently in the launcher and when opening the browser.
$OpenWebUIPort = 8080

# Minimum Ollama version required by the default model. gemma4:e4b needs a
# recent Ollama; support for the Gemma 4 family landed in the 0.20.x line and
# was stable by 0.22. We require 0.22.0 as a safe floor. If you change
# $ModelName, re-check this against Ollama's release notes.
$MinOllamaVersion = "0.22.0"

# Python version to provision. Open WebUI's pyproject pins ">= 3.11, < 3.13",
# so 3.12 is the newest supported line and has the best Windows wheel coverage.
$PythonVersion = "3.12"

# Everything we own lives here. Per-user, no admin needed.
$InstallRoot = "$env:LOCALAPPDATA\OpenWebUI"

# ---------------------------------------------------------------------------
# DERIVED PATHS AND URLS
# ---------------------------------------------------------------------------

$LogDir      = Join-Path $InstallRoot "logs"
$RuntimeDir  = Join-Path $InstallRoot "runtime"   # pid/port state for the launcher
$DataDir     = Join-Path $InstallRoot "data"      # Open WebUI accounts and chats
$UvDir       = Join-Path $InstallRoot "uv"        # uv.exe lives here
$UvExe       = Join-Path $UvDir "uv.exe"
$PythonDir   = Join-Path $InstallRoot "python"    # uv-managed CPython installs
$UvCacheDir  = Join-Path $InstallRoot "uv-cache"
$VenvDir     = Join-Path $InstallRoot "venv"      # isolated Open WebUI environment
$OpenWebUIExe = Join-Path $VenvDir "Scripts\open-webui.exe"

$OllamaDownloadUrl = "https://ollama.com/download/OllamaSetup.exe"
$OllamaDefaultExe  = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
$OllamaApiUrl      = "http://localhost:11434"

# uv ships a stable "latest" redirect for each platform asset. This is the only
# domain we use beyond the spec's allow-list (ollama.com, python.org /
# python-build-standalone GitHub releases, pypi.org); uv itself lives in the
# astral-sh GitHub org and in turn fetches python-build-standalone (allowed)
# and packages from pypi (allowed).
$UvDownloadUrl = "https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip"

# Disk space we want free before pulling a multi-GB model (stretch goal guard).
$MinFreeGB = 15

# Timestamped log file for this run.
$LogFile = $null

# ---------------------------------------------------------------------------
# LOGGING AND ERROR SURFACING
# ---------------------------------------------------------------------------

function Initialize-Logging {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $script:LogFile = Join-Path $LogDir "install-$stamp.log"
    "=== Open WebUI install started $(Get-Date) ===" | Out-File -FilePath $script:LogFile -Encoding utf8
}

# Write-Log: one place for both the on-screen message and the log file.
# Levels: INFO (normal progress), WARN (non-fatal), STEP (section header).
function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','STEP','OK')][string]$Level = 'INFO'
    )
    $line = "[{0}] {1}" -f $Level, $Message
    if ($script:LogFile) { $line | Out-File -FilePath $script:LogFile -Append -Encoding utf8 }
    switch ($Level) {
        'STEP' { Write-Host ""; Write-Host (">> " + $Message) -ForegroundColor Cyan }
        'WARN' { Write-Host ("   " + $Message) -ForegroundColor Yellow }
        'OK'   { Write-Host ("   " + $Message) -ForegroundColor Green }
        default { Write-Host ("   " + $Message) }
    }
}

# Translate a raw error into plain language. We pattern-match common failure
# causes the spec calls out (no internet, disk full, port in use, antivirus).
function Get-FriendlyError {
    param([string]$Raw)
    $r = $Raw.ToLower()
    if ($r -match 'could not resolve|no such host|name or service|remote name|unable to connect|timed out|getresponse|connection.*refused|0x80072ee') {
        return "We could not reach the internet. Connect to a network and run the installer again. (Only the first install needs internet.)"
    }
    if ($r -match 'not enough space|disk full|enospc|0x70|space to') {
        return "Your disk is full. Free up some space (a few GB) and run the installer again."
    }
    if ($r -match 'access.*denied|unauthorized|0x5\b|permission') {
        return "Windows blocked a step, often antivirus or a permissions issue. Allow the installer in your antivirus, then run it again."
    }
    if ($r -match 'address.*in use|port') {
        return "A required network port was busy. Close other apps (or restart the PC) and run the installer again."
    }
    return $null
}

# Fail: the single exit door for fatal problems. Prints a plain-language
# message plus the log path, never a stack trace, and exits non-zero so the
# .bat can react.
function Fail {
    param([string]$Message, [string]$Raw)
    Write-Host ""
    Write-Host "Sorry, the install could not finish." -ForegroundColor Red
    Write-Host ("  Problem: " + $Message) -ForegroundColor Red
    $friendly = $null
    if ($Raw) { $friendly = Get-FriendlyError $Raw }
    if ($friendly) { Write-Host ("  Likely cause: " + $friendly) -ForegroundColor Yellow }
    if ($script:LogFile) {
        Write-Host ("  Full details are in this log file:") -ForegroundColor Red
        Write-Host ("    " + $script:LogFile) -ForegroundColor Red
        ("FATAL: " + $Message) | Out-File -FilePath $script:LogFile -Append -Encoding utf8
        if ($Raw) { ("RAW: " + $Raw) | Out-File -FilePath $script:LogFile -Append -Encoding utf8 }
    }
    exit 1
}

# ---------------------------------------------------------------------------
# SMALL HELPERS
# ---------------------------------------------------------------------------

# Enable TLS 1.2 for all web requests (older Windows 10 defaults can omit it,
# which makes downloads fail with confusing errors).
function Enable-Tls12 {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
}

# Download a file with a couple of retries. We use Invoke-WebRequest with
# -UseBasicParsing so it works on a stock PowerShell 5.1 with no IE engine.
function Invoke-Download {
    param([string]$Url, [string]$OutFile, [int]$Retries = 3)
    Enable-Tls12
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Write-Log ("Downloading: " + $Url + " (attempt " + $i + ")")
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 0
            if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) { return }
            throw "Downloaded file was empty."
        } catch {
            Write-Log ("Download attempt " + $i + " failed: " + $_.Exception.Message) 'WARN'
            if ($i -eq $Retries) { throw }
            Start-Sleep -Seconds 3
        }
    }
}

# Is a TCP port free to bind on localhost? We try to listen on it; if the bind
# throws, something already owns the port. (Avoids the slow Test-NetConnection.)
function Test-PortFree {
    param([int]$Port)
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { $listener.Stop() }
    }
}

# First free port at or after $Start.
function Get-FreePort {
    param([int]$Start)
    for ($p = $Start; $p -lt ($Start + 50); $p++) {
        if (Test-PortFree -Port $p) { return $p }
    }
    throw "Could not find a free network port near $Start."
}

# Poll an HTTP endpoint until it answers (any HTTP response counts as "up"),
# or until the timeout. Returns $true on success. This replaces fixed sleeps.
function Wait-HttpReady {
    param([string]$Url, [int]$TimeoutSec = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 | Out-Null
            return $true
        } catch {
            # A 4xx/5xx still means "server is answering"; only connection-level
            # failures mean "not up yet". Treat a WebException with a response
            # as ready.
            if ($_.Exception.Response) { return $true }
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

# Run an external exe, log its output, and throw ONLY on a non-zero exit code.
#
# Important: tools like uv and pip write normal progress to stderr. With
# $ErrorActionPreference='Stop' in force, merging stderr via 2>&1 would turn
# each progress line into a terminating NativeCommandError and abort the
# install even on success. So we relax the preference for the duration of the
# call and judge success purely by the exit code.
function Invoke-Exe {
    param([string]$FilePath, [string[]]$Arguments, [string]$What)
    Write-Log ("Running: " + $FilePath + " " + ($Arguments -join ' '))
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            # $_ may be a string or an ErrorRecord (stderr); stringify either way.
            ("" + $_) | Out-File -FilePath $script:LogFile -Append -Encoding utf8
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($LASTEXITCODE -ne 0) {
        throw ("$What failed (exit code $LASTEXITCODE). See log for details.")
    }
}

# ---------------------------------------------------------------------------
# STEP 1: PREFLIGHT
# ---------------------------------------------------------------------------

function Invoke-Preflight {
    Write-Log "Checking your Windows version and free disk space..." 'STEP'

    if (-not [Environment]::Is64BitOperatingSystem) {
        Fail "This installer supports 64-bit Windows only."
    }

    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    # Windows 10 RTM is build 10240. Anything below that is unsupported.
    if ($build -lt 10240) {
        Fail "This installer supports Windows 10 and Windows 11 only."
    }
    Write-Log ("Windows OK: " + $os.Caption + " (build " + $build + ").") 'OK'

    # Make our directory tree.
    foreach ($d in @($InstallRoot, $RuntimeDir, $DataDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # Disk space guard (stretch goal). Check the drive that holds InstallRoot.
    $driveLetter = (Split-Path $InstallRoot -Qualifier)
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $driveLetter + "'")
        $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
        if ($freeGB -lt $MinFreeGB) {
            Write-Log ("Only " + $freeGB + " GB free on " + $driveLetter + ". The model needs about 10 GB; " + $MinFreeGB + " GB free is recommended. Continuing, but the download may fail if space runs out.") 'WARN'
        } else {
            Write-Log ("Free disk space OK: " + $freeGB + " GB on " + $driveLetter + ".") 'OK'
        }
    } catch {
        Write-Log "Could not measure free disk space; continuing." 'WARN'
    }

    # GPU note (stretch goal): purely informational.
    try {
        $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
        if ($gpu) {
            Write-Log ("NVIDIA GPU detected (" + $gpu.Name + "). Ollama will use it automatically and answers will be faster. No action needed.") 'OK'
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# STEP 2: OLLAMA INSTALL / UPDATE
# ---------------------------------------------------------------------------

# Resolve a usable ollama.exe full path, or $null. We check PATH (Get-Command)
# AND the known per-user install location, then always work via the full path.
function Resolve-OllamaExe {
    $cmd = Get-Command ollama -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) { return $cmd.Source }
    if (Test-Path $OllamaDefaultExe) { return $OllamaDefaultExe }
    return $null
}

# Parse "ollama version is 0.22.1" -> [version]0.22.1, or $null.
function Get-OllamaVersion {
    param([string]$Exe)
    try {
        $out = & $Exe --version 2>&1 | Out-String
        if ($out -match '(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    } catch { }
    return $null
}

# Download and silently (re)install Ollama. The official installer is a per-user
# Inno Setup package, so /VERYSILENT /NORESTART runs without admin and installs
# under %LOCALAPPDATA%\Programs\Ollama.
function Install-OllamaSilently {
    $tmp = Join-Path $env:TEMP "OllamaSetup.exe"
    Invoke-Download -Url $OllamaDownloadUrl -OutFile $tmp
    Write-Log "Installing Ollama silently (no window). This can take a minute..."
    $p = Start-Process -FilePath $tmp -ArgumentList "/VERYSILENT","/NORESTART" -PassThru -Wait
    if ($p.ExitCode -ne 0) {
        throw ("Ollama installer exited with code " + $p.ExitCode + ".")
    }
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

function Invoke-OllamaSetup {
    Write-Log "Setting up Ollama (the engine that runs the AI model)..." 'STEP'

    $exe = Resolve-OllamaExe
    if ($exe) {
        $ver = Get-OllamaVersion -Exe $exe
        if ($ver -and ($ver -ge [version]$MinOllamaVersion)) {
            Write-Log ("Ollama already installed (version " + $ver + "). Skipping.") 'OK'
        } else {
            $found = if ($ver) { $ver.ToString() } else { "unknown" }
            Write-Log ("Ollama is present but too old (" + $found + "; need " + $MinOllamaVersion + "+). Updating it...") 'WARN'
            Install-OllamaSilently
        }
    } else {
        Write-Log "Ollama is not installed. Downloading and installing it now..."
        Install-OllamaSilently
    }

    # Always resolve the full path again after any install/update.
    $script:OllamaExe = Resolve-OllamaExe
    if (-not $script:OllamaExe) {
        throw "Ollama was installed but its program file could not be found."
    }
    Write-Log ("Ollama ready at: " + $script:OllamaExe) 'OK'
}

# ---------------------------------------------------------------------------
# STEP 3: START OLLAMA SERVER
# ---------------------------------------------------------------------------

function Start-OllamaServer {
    Write-Log "Starting the Ollama server and waiting for it to respond..." 'STEP'

    # If it already answers, do nothing (idempotent, avoids duplicate servers).
    if (Wait-HttpReady -Url $OllamaApiUrl -TimeoutSec 3) {
        Write-Log "Ollama server already running." 'OK'
        return
    }

    # Start "ollama serve" hidden, do not wait (it stays running).
    Start-Process -FilePath $script:OllamaExe -ArgumentList "serve" -WindowStyle Hidden | Out-Null

    if (-not (Wait-HttpReady -Url $OllamaApiUrl -TimeoutSec 60)) {
        throw "The Ollama server did not start in time."
    }
    Write-Log "Ollama server is up." 'OK'
}

# ---------------------------------------------------------------------------
# STEP 4: MODEL
# ---------------------------------------------------------------------------

function Invoke-ModelSetup {
    Write-Log "Checking for an AI model..." 'STEP'

    # Native ollama calls write progress to stderr; relax the error preference
    # so a stderr line is not turned into a terminating error (see Invoke-Exe).
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # "ollama list" prints a header row plus one row per model. If the user
        # already has ANY model, we skip the download entirely (per spec).
        $list = & $script:OllamaExe list 2>&1 | Out-String
        $rows = $list -split "`n" | Where-Object { $_.Trim() -ne '' }
        $modelCount = [Math]::Max(0, $rows.Count - 1)  # minus the header line

        if ($modelCount -ge 1) {
            Write-Log ("You already have " + $modelCount + " model(s) installed. Skipping the download; they will appear in the Open WebUI dropdown.") 'OK'
            return
        }

        Write-Log ("No models found. Downloading the default model (" + $ModelName + ", about 10 GB). This is the slow part; please leave it running...")
        # ollama pull streams progress; route it through our logger.
        & $script:OllamaExe pull $ModelName 2>&1 | ForEach-Object {
            ("" + $_) | Out-File -FilePath $script:LogFile -Append -Encoding utf8
            Write-Host ("   " + $_)
        }
        if ($LASTEXITCODE -ne 0) {
            throw ("Downloading the model '" + $ModelName + "' failed.")
        }
        Write-Log ("Model " + $ModelName + " is ready.") 'OK'
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

# ---------------------------------------------------------------------------
# STEP 5: PYTHON RUNTIME (via uv)
# ---------------------------------------------------------------------------

# Point uv at our directories so the interpreter, cache and venv all live under
# the install root and nothing touches the user's machine-wide setup or PATH.
function Set-UvEnvironment {
    $env:UV_PYTHON_INSTALL_DIR = $PythonDir
    $env:UV_CACHE_DIR          = $UvCacheDir
    $env:UV_NO_MODIFY_PATH     = "1"     # belt and braces: uv must not edit PATH
    # Only ever use uv's own managed CPython, never a system Python (isolation).
    $env:UV_PYTHON_PREFERENCE  = "only-managed"
    # Do NOT create the global "minor version link" shims. On some Windows setups
    # creating that junction fails with "untrusted mount point" (os error 448),
    # and we do not need global shims because everything runs through the venv.
    $env:UV_PYTHON_INSTALL_BIN = "0"
}

function Install-Uv {
    Write-Log "Setting up a private Python (bundled, separate from any Python you may have)..." 'STEP'

    if (Test-Path $UvExe) {
        Write-Log "uv (the Python manager) already present. Skipping its download." 'OK'
        return
    }
    if (-not (Test-Path $UvDir)) { New-Item -ItemType Directory -Path $UvDir -Force | Out-Null }

    $zip = Join-Path $env:TEMP "uv-windows.zip"
    Invoke-Download -Url $UvDownloadUrl -OutFile $zip
    # Expand-Archive is built in to PowerShell 5.1.
    Expand-Archive -Path $zip -DestinationPath $UvDir -Force
    Remove-Item $zip -ErrorAction SilentlyContinue

    if (-not (Test-Path $UvExe)) {
        # Some uv archives nest the exe one level down; find and lift it.
        $found = Get-ChildItem -Path $UvDir -Filter "uv.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { Copy-Item $found.FullName $UvExe -Force }
    }
    if (-not (Test-Path $UvExe)) { throw "uv.exe was not found after extraction." }
    Write-Log "uv installed." 'OK'
}

# ---------------------------------------------------------------------------
# STEP 6: OPEN WEBUI INTO AN ISOLATED VENV
# ---------------------------------------------------------------------------

function Install-OpenWebUI {
    Write-Log "Setting up a private Python and installing Open WebUI (the chat app)..." 'STEP'
    Set-UvEnvironment

    if (Test-Path $OpenWebUIExe) {
        Write-Log "Open WebUI already installed in its private environment. Skipping." 'OK'
        return
    }

    # Create the isolated venv with the pinned Python. We deliberately do NOT run
    # "uv python install" first: that step also creates global version-link shims,
    # which can fail on Windows with "untrusted mount point" (os error 448).
    # "uv venv --python 3.12" downloads the managed interpreter on demand into our
    # scoped UV_PYTHON_INSTALL_DIR and builds the venv, without the global shims.
    # The venv is separate from the interpreter's own site-packages, per the spec.
    if (-not (Test-Path (Join-Path $VenvDir "Scripts"))) {
        Write-Log ("Provisioning CPython " + $PythonVersion + " and creating the environment (downloaded once)...")
        Invoke-Exe -FilePath $UvExe -Arguments @("venv","--python",$PythonVersion,$VenvDir) -What "Creating the Python environment"
    }

    # Install Open WebUI from PyPI into that venv. "uv pip install --python"
    # targets the venv interpreter explicitly.
    $venvPython = Join-Path $VenvDir "Scripts\python.exe"
    Invoke-Exe -FilePath $UvExe -Arguments @("pip","install","--python",$venvPython,"open-webui") -What "Installing Open WebUI"

    if (-not (Test-Path $OpenWebUIExe)) {
        throw "Open WebUI did not install correctly (its program file is missing)."
    }
    Write-Log "Open WebUI installed." 'OK'
}

# ---------------------------------------------------------------------------
# STEP 7: GENERATE THE LAUNCHER
# ---------------------------------------------------------------------------

function Write-Launcher {
    Write-Log "Creating the launcher and shortcut..." 'STEP'

    # Decide a port now so the launcher has a sensible starting point. The
    # launcher re-validates at runtime and will move on if this port is taken
    # later, but baking the preferred value keeps install and launch consistent.
    $chosenPort = Get-FreePort -Start $OpenWebUIPort
    if ($chosenPort -ne $OpenWebUIPort) {
        Write-Log ("Port " + $OpenWebUIPort + " is in use; the app will prefer port " + $chosenPort + " instead.") 'WARN'
    }

    $templatePath = Join-Path $PSScriptRoot "launch.ps1.template"
    if (-not (Test-Path $templatePath)) { throw "launch.ps1.template is missing next to install.ps1." }
    $template = Get-Content $templatePath -Raw

    # Substitute the install-time values into the template placeholders.
    $launch = $template
    $launch = $launch.Replace("{{PREFERRED_PORT}}", "$chosenPort")
    $launch = $launch.Replace("{{INSTALL_ROOT}}", $InstallRoot)
    $launch = $launch.Replace("{{VENV_DIR}}", $VenvDir)
    $launch = $launch.Replace("{{OLLAMA_EXE}}", $script:OllamaExe)

    $launchPath = Join-Path $InstallRoot "launch.ps1"
    $launch | Out-File -FilePath $launchPath -Encoding utf8 -Force

    # A tiny .vbs that runs the launcher with a hidden PowerShell window. The
    # desktop shortcut points at this (run by wscript), so the user never sees a
    # console window flash. This is the most reliable way to avoid the flash on
    # PowerShell 5.1.
    $vbsPath = Join-Path $InstallRoot "launch-hidden.vbs"
    $vbs = @"
' Auto-generated. Launches Open WebUI with no visible window.
Dim shell, cmd
Set shell = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{{LAUNCH}}"""
shell.Run cmd, 0, False
"@
    $vbs = $vbs.Replace("{{LAUNCH}}", $launchPath)
    $vbs | Out-File -FilePath $vbsPath -Encoding ascii -Force

    $script:LauncherVbs = $vbsPath
    Write-Log "Launcher created." 'OK'
}

# ---------------------------------------------------------------------------
# STEP 8: DESKTOP SHORTCUT
# ---------------------------------------------------------------------------

function New-DesktopShortcut {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop "Open WebUI.lnk"

    # Idempotent: overwrite our own shortcut rather than making duplicates.
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnkPath)
    # Point at wscript running our hidden .vbs (no console window appears).
    $sc.TargetPath = "$env:SystemRoot\System32\wscript.exe"
    $sc.Arguments = ('"' + $script:LauncherVbs + '"')
    $sc.WorkingDirectory = $InstallRoot
    $sc.IconLocation = "$env:SystemRoot\System32\SHELL32.dll,14"  # a globe icon
    $sc.Description = "Start Open WebUI (local AI chat)"
    $sc.Save()

    Write-Log ("Desktop shortcut created: " + $lnkPath) 'OK'
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

# Module-scope handles set during the run.
$script:OllamaExe   = $null
$script:LauncherVbs = $null

# Top-level guard: any thrown error becomes a friendly message + log path.
try {
    Initialize-Logging
    Write-Host ""
    Write-Host "Open WebUI installer" -ForegroundColor White
    Write-Host "This sets up a private AI chat app on your PC. It can take a while"
    Write-Host "the first time (it downloads a few large files). You can leave it running."

    Invoke-Preflight
    Invoke-OllamaSetup
    Start-OllamaServer
    Invoke-ModelSetup
    Install-Uv
    Install-OpenWebUI
    Write-Launcher
    New-DesktopShortcut

    Write-Host ""
    Write-Host "Success. Open WebUI is installed." -ForegroundColor Green
    Write-Host "Double-click the 'Open WebUI' shortcut on your desktop to start chatting."
    Write-Host ("Your chats and account are stored privately here: " + $DataDir)
    exit 0
}
catch {
    Fail -Message $_.Exception.Message -Raw ($_ | Out-String)
}
