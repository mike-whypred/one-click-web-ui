# Build Spec: One-Click Open WebUI Installer for Windows (Native, No Docker)

## Context for you, Claude Code

You are building a production-quality, double-click installer that gets a **non-technical Windows user** from zero to a working local AI chat app (Open WebUI + Ollama) with no terminal, no Docker, and no manual config.

A working prototype exists (`install.ps1` + `Install-OpenWebUI.bat`, included in this folder). Treat it as a reference for intent and happy-path logic, NOT as the target quality bar. It has known weaknesses (listed below). Your job is to harden it into something a real non-technical user can run reliably.

Do not blindly transcribe the prototype. Reimplement it properly, keep what works, fix what's listed under "Known issues to fix."

## Hard requirements (non-negotiable)

1. **Target:** 64-bit Windows 10 and Windows 11 only.
2. **No Docker.** Native install only.
3. **No system Python dependency.** Bundle a Python runtime under the install dir. Must not touch or require any Python the user already has, and must not modify system/user PATH for Python.
4. **One action for the user:** double-click one file. Everything else automatic.
5. **Idempotent / re-runnable.** Running the installer twice must not break anything or duplicate downloads. Detect existing state and skip.
6. **Offline after install.** Internet is needed only for first install. Once installed it must run with no network.
7. **Final state:** a desktop shortcut "Open WebUI" that, when double-clicked, starts Ollama (if not running), starts Open WebUI (if not running), waits for the server, and opens the browser to the local UI.

## Behavioral requirements

### Ollama
- Detect if Ollama is already installed (check `Get-Command ollama` AND the default install path `%LOCALAPPDATA%\Programs\Ollama`). If present, do not reinstall.
- If absent, download the official Windows installer from `https://ollama.com/download/OllamaSetup.exe` and run it silently (`/VERYSILENT /NORESTART`).
- **Version check:** the default model is `gemma4:e4b`, which needs a recent Ollama. If Ollama is already installed but older than the minimum required version for Gemma 4, auto-update it (re-run the silent installer). Determine the minimum version at build time by checking Ollama release notes; make the minimum a named constant at the top of the script.
- Ensure `ollama serve` is running before any `pull`. Start it hidden if not. Poll the Ollama API (`http://localhost:11434`) until it responds, with a timeout, rather than a fixed `Start-Sleep`.

### Model
- Default model: `gemma4:e4b` (~7.5 GB, laptop-friendly). Make this a named constant.
- **Detect existing models** via `ollama list`. If the user already has ANY model, skip the download entirely and inform them. Only pull the default if they have none.
- The model dropdown in Open WebUI must surface all locally installed models automatically (this is default Open WebUI behavior, just confirm it works).

### Python runtime
- Bundle Python under `%LOCALAPPDATA%\OpenWebUI\python`.
- The prototype uses the **embeddable** Python zip and patches the `._pth` file to enable site-packages. This is fragile (Open WebUI has native deps and a heavy dependency tree; embeddable Python often breaks on packages needing proper site config or compiled wheels). **Evaluate a more robust approach** and pick the most reliable:
  - Option A: full official Python installer run silently with a per-user, dirscoped install (not added to PATH).
  - Option B: `python-build-standalone` (astral/indygreg) portable CPython, which is purpose-built for embedding and far more robust than the embeddable zip.
  - Option C: keep embeddable zip only if you verify the full Open WebUI install succeeds on it.
  - **Recommended: Option B (python-build-standalone) or a uv-managed venv.** Justify your choice in a comment.
- Pin the Python version to one Open WebUI officially supports. Verify the current supported range at build time (do not assume 3.11; check Open WebUI's `pyproject.toml`/docs).
- Install Open WebUI into an isolated venv inside the install dir, not into the bundled interpreter's global site-packages.

### Open WebUI
- Install via `pip install open-webui` into the isolated environment.
- First launch on `http://localhost:8080`. Confirm port; make it a constant and handle the port already being in use (pick next free port and use it consistently in the launcher + browser open).
- Data (accounts, chats) is local only. Note the data dir location in the README.

### Launcher + shortcut
- Generate a `launch.ps1` in the install dir that: ensures Ollama running, ensures Open WebUI running, polls the HTTP endpoint until ready (timeout + friendly failure message), then opens the default browser.
- Create a desktop shortcut "Open WebUI" pointing at the launcher, running hidden (no console window flash for the user). Consider a `.vbs` or shortcut `windowStyle` trick to avoid the PowerShell window appearing.
- Detect "already running" correctly. The prototype matches processes by path substring `*OpenWebUI\python*`; make process detection robust (don't kill or duplicate an existing instance).

## Known issues to fix (from the prototype)

1. **Embeddable Python fragility** (see Python section). Highest priority.
2. **No Ollama version check** before pulling `gemma4:e4b`. An old pre-installed Ollama will fail the pull. Add the auto-update logic.
3. **Fixed `Start-Sleep` waits** instead of polling. Replace with readiness polling (Ollama API and Open WebUI HTTP) with timeouts.
4. **PATH for `ollama`** is appended only to the current session via string concatenation; fragile. Resolve the ollama exe by full path after install instead of relying on PATH.
5. **Process-window flash:** launching PowerShell from the shortcut can flash a console window. Make the launch fully hidden.
6. **No elevation handling:** the Ollama silent installer may need admin. The prototype doesn't request elevation. Decide and handle: either self-elevate the relevant step via UAC, or document that the user must approve the UAC prompt. Prefer a single UAC prompt up front if elevation is genuinely needed; avoid it if the installs are per-user.
7. **Error surfacing:** on failure the user should get a plain-language message AND the log path, not a stack trace. Wrap steps and translate common failures (no internet, disk full, port in use, antivirus block).
8. **SmartScreen:** unsigned `.bat`/`.ps1` triggers "Windows protected your PC." Document the "More info > Run anyway" step clearly, and structure the project so it can later be wrapped in a signed installer (see Stretch goals).

## Deliverables

```
/openwebui-installer
  Install-OpenWebUI.bat      # double-click entry point; bypasses execution policy, calls install.ps1
  install.ps1                # main installer, hardened per this spec
  launch.ps1.template        # (or generated at install time) the runtime launcher
  README.md                  # plain-language, for the non-technical end user
  CHANGELOG.md               # what you changed vs the prototype, and why
```

- All scripts heavily commented for a maintainer (not the end user).
- `README.md` written for a non-technical user: how to install, the SmartScreen step, where the desktop shortcut is, how to add more models **via the Open WebUI GUI** (Settings > Admin Settings > Models > pull a model), and how to uninstall.
- `CHANGELOG.md`: enumerate every deviation from the prototype with a one-line rationale, especially the Python runtime decision.

## Acceptance criteria (test these)

1. **Clean machine:** fresh Win11, no Ollama, no Python. Double-click installs everything, ends with a working chat in the browser using `gemma4:e4b`. No terminal interaction beyond approving UAC/SmartScreen.
2. **Ollama already present, current version, with models:** installer skips Ollama install AND skips model download; existing models appear in the dropdown.
3. **Ollama already present but old version:** installer auto-updates Ollama, then proceeds.
4. **System Python present:** installer ignores it entirely; no conflict; bundled runtime used.
5. **Re-run:** running the installer a second time is fast, downloads nothing already present, and doesn't duplicate the shortcut or break the install.
6. **Reboot then shortcut:** after a reboot, double-clicking the desktop shortcut brings the app up and opens the browser with no console window visible.
7. **Offline:** after install, disconnect network; the app still launches and chats (model is local).
8. **Port in use:** if 8080 is taken, installer/launcher picks a free port and the browser opens to the correct one.
9. **Failure path:** simulate no internet during first install; user sees a plain-language error and the log path, not a raw exception.

## Constants to expose at top of install.ps1

- `$ModelName = "gemma4:e4b"`
- `$OpenWebUIPort = 8080` (with free-port fallback)
- `$MinOllamaVersion = "<determine at build>"`
- `$PythonVersion = "<Open WebUI supported version>"`
- `$InstallRoot = "$env:LOCALAPPDATA\OpenWebUI"`

## Style / constraints

- PowerShell 5.1 compatible (ships with Windows; do not require PowerShell 7).
- No external PowerShell modules that need installing from the gallery.
- Allowed network egress during build/test is limited; rely only on: ollama.com, python.org / python-build-standalone GitHub releases, pypi.org. Note any other domain you need.
- Do not use em dashes in any user-facing text or comments. Use commas, parentheses, or separate sentences.

## Stretch goals (only after acceptance criteria pass)

1. **Inno Setup wrapper** (`setup.iss`) that compiles the whole thing into a single `setup.exe` with a progress bar and proper Add/Remove Programs entry. This is the path to a code-signable artifact that avoids most SmartScreen friction.
2. **Uninstaller** that stops processes, removes the install dir, the shortcut, and optionally the Ollama models, with a confirmation.
3. **GPU note / detection:** detect NVIDIA GPU and inform the user responses will be faster; no action needed (Ollama auto-uses it), purely informational.
4. **Model size guard:** before pulling the default, check free disk space and warn if under ~15 GB free.

## Reference files

The prototype `install.ps1`, `Install-OpenWebUI.bat`, and `README.md` are in this folder. Read them first, then build to this spec.