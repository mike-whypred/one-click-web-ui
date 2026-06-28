# CHANGELOG: what changed vs the prototype, and why

This rebuild follows the build spec rather than transcribing the prototype.
Each deviation below has a one-line rationale. The most important decision (the
Python runtime) is first.

## Python runtime: embeddable zip  ->  python-build-standalone (self-extracted) + venv

- **Changed:** Dropped the embeddable Python zip and its `._pth` patching. We
  download a pinned **python-build-standalone** CPython 3.12 (`install_only`
  build, spec Option B), extract it ourselves with the built-in `tar.exe` under
  `%LOCALAPPDATA%\OpenWebUI`, then create an isolated venv with CPython's own
  `python -m venv`. `uv` is still bundled, but only as the fast package installer
  (`uv pip install`) into that venv.
- **Why python-build-standalone, extracted by us:** it is purpose-built for
  embedding, ships the latest patch release, handles compiled wheels, and extracts
  to plain real folders. That last point matters: see the os-error-448 fix below.
- **Why not uv-managed Python (the earlier approach):** uv lays its managed
  interpreters out behind a directory junction (the "minor version link"). On a
  real Windows 11 test machine, traversing that junction failed with "untrusted
  mount point" (os error 448) because the OS enforces redirection trust on
  junctions created by a normal-user process. Self-extracting a tarball avoids
  junctions entirely.
- **Why not the python.org installer (spec Option A):** Python 3.12 is in its
  security-only phase and ships source only (no Windows `.exe` installer for
  current patches), and Open WebUI requires Python `< 3.13`, so there is no
  current official installer to use.
- **URL rot:** addressed by pinning a dated `python-build-standalone` release URL
  (verified to return 200), rather than a `latest/download` URL that breaks when
  the dated asset filename changes.

## Python version: pinned to 3.12 (verified, not assumed)

- **Changed:** Pinned `$PythonVersion = "3.12"`.
- **Why:** Open WebUI's `pyproject.toml` requires `>= 3.11, < 3.13`. 3.12 is the
  newest supported line and has the broadest Windows wheel coverage. We did not
  assume 3.11.

## Ollama version check + auto-update (new)

- **Changed:** Added `$MinOllamaVersion = "0.22.0"`. If Ollama is already
  installed but older, we re-run the silent installer to update it before any
  pull.
- **Why:** The prototype pulled the default model with no version check, so an
  old pre-installed Ollama would fail. `gemma4:e4b` needs a recent Ollama
  (Gemma 4 support landed in the 0.20.x line, stable by 0.22). Re-verify this
  floor against Ollama release notes if you change `$ModelName`.

## Readiness polling instead of fixed sleeps

- **Changed:** Replaced fixed `Start-Sleep` waits with `Wait-HttpReady`, which
  polls the Ollama API (`:11434`) and the Open WebUI endpoint (`/health`) with
  timeouts, in both the installer and the launcher.
- **Why:** Fixed sleeps are either too short (flaky) or too long (slow). Polling
  is correct and faster on average.

## Ollama resolved by full path, not PATH

- **Changed:** `Resolve-OllamaExe` checks `Get-Command` AND the per-user install
  path `%LOCALAPPDATA%\Programs\Ollama\ollama.exe`, then we always call the full
  path. We never edit PATH.
- **Why:** The prototype appended to the session PATH by string concatenation,
  which is fragile and does not survive a new shell. Full-path invocation is
  deterministic.

## Model download only when the user has none

- **Changed:** We parse `ollama list` and skip the download entirely if ANY
  model is present, informing the user. Only when there are zero models do we
  pull `$ModelName`.
- **Why:** Matches the spec; avoids a needless multi-GB download and respects
  models the user already has (they still appear in the dropdown automatically).

## Hidden launch (no console flash)

- **Changed:** The desktop shortcut runs `wscript.exe launch-hidden.vbs`, which
  starts the launcher with `-WindowStyle Hidden`. The shortcut does not point at
  PowerShell directly.
- **Why:** Launching PowerShell from a shortcut flashes a console window. Going
  through a `.vbs` run by `wscript` shows no window at all, which is the reliable
  approach on PowerShell 5.1.

## Robust "already running" detection (no path-substring matching)

- **Changed:** When the launcher starts Open WebUI it records the PID and port
  in `runtime\openwebui.pid` / `openwebui.port`. On the next launch it reuses
  the instance only if that PID is alive, its executable lives under the install
  root, and it answers HTTP. Otherwise it starts fresh.
- **Why:** The prototype matched processes by the path substring
  `*OpenWebUI\python*`, which is brittle and risks adopting or killing the wrong
  process. PID + path + health check is precise, and we never kill or duplicate
  an existing instance.

## Port-in-use handling, consistent across launcher and browser

- **Changed:** `$OpenWebUIPort = 8080` with a free-port fallback. The installer
  picks a free port and bakes it into the launcher as the preferred port; the
  launcher re-validates at runtime, starts Open WebUI with `--port`, and opens
  the browser to the same port.
- **Why:** 8080 is commonly taken. The chosen port must be used consistently in
  the launcher and the browser open, which the prototype did not guarantee.

## Elevation: none required (decided, not ignored)

- **Changed:** No UAC elevation anywhere. Ollama's Windows installer is a
  per-user Inno Setup package (`/VERYSILENT /NORESTART` installs to
  `%LOCALAPPDATA%` without admin); uv, the bundled Python, the venv, and the
  shortcut are all per-user.
- **Why:** The spec says to prefer no UAC when installs are genuinely per-user.
  They are, so we avoid the prompt entirely. SmartScreen is still documented in
  the README ("More info > Run anyway").

## Error surfacing: plain language + log path, never a stack trace

- **Changed:** A top-level `try/catch` routes every failure through `Fail`,
  which prints a plain-language message and the log file path. `Get-FriendlyError`
  translates common causes (no internet, disk full, port busy, antivirus block).
  The hidden launcher shows errors in a `WScript.Shell` popup (since it has no
  visible console).
- **Why:** Required by the spec; a non-technical user must never see a raw
  exception.

## Local, offline-friendly data location

- **Changed:** The launcher sets `DATA_DIR` to `%LOCALAPPDATA%\OpenWebUI\data`
  so accounts and chats persist across upgrades and are easy to find/back up.
  Documented in the README.
- **Why:** Keeps data stable and local, and survives reinstalling/upgrading the
  Open WebUI package in the venv.

## Stretch goals included

- **Uninstaller** (`Uninstall-OpenWebUI.bat` + `uninstall.ps1`): stops our
  process (only if it is genuinely ours), removes the install dir and shortcut,
  and optionally deletes downloaded models after confirmation. Leaves Ollama
  installed.
- **GPU note:** preflight detects an NVIDIA GPU and tells the user responses
  will be faster (informational only; Ollama uses it automatically).
- **Disk-space guard:** preflight warns if under ~15 GB is free before the model
  pull.
- **Inno Setup wrapper** (`setup.iss`): compiles the folder into a single
  per-user `setup.exe` with a progress bar and an Add/Remove Programs entry, runs
  `install.ps1` as a post-install step (visible console so the download shows
  progress), adds a hidden-launch Start Menu icon, and drives `uninstall.ps1`
  non-interactively on removal (with an Inno dialog for the "delete models?"
  choice). `PrivilegesRequired=lowest` keeps it UAC-free. Includes a documented
  path to code-sign the artifact via a SignTool. `uninstall.ps1` gained
  `-NonInteractive` / `-RemoveModels` switches so the Inno uninstaller can run it
  without prompts.

## Fixes after first real-hardware run (Windows 11)

- **Native stderr no longer aborts the install.** uv and pip write normal
  progress to stderr; with `$ErrorActionPreference='Stop'` plus `2>&1`, the first
  such line became a terminating `NativeCommandError` and killed the install at
  "Provisioning CPython". `Invoke-Exe` and the ollama list/pull block now relax
  the error preference for the native call and judge success by exit code only.
- **Abandoned uv-managed Python (os error 448).** First we found `uv python
  install` failed creating a global "minor version link" junction; suppressing
  that was not enough, because `uv venv` then failed merely *reading* the managed
  interpreter through the same junction ("untrusted mount point"). Root cause: the
  machine enforces redirection trust on junctions made by a normal-user process.
  Switched to self-extracted python-build-standalone (real folders, no junctions)
  plus `python -m venv`, and set `UV_LINK_MODE=copy` so `uv pip` never uses
  hardlinks/symlinks either.

## Notes / things to re-verify when maintaining

- `$ModelName = "gemma4:e4b"` is kept as a named constant per the spec. Confirm
  the exact tag exists via `ollama list` / the Ollama library if you change it;
  the library lists this build at about 9.6 GB.
- `setup.iss` needs Inno Setup 6.3+ for `x64compatible`; on older 6.x use `x64`.
  Replace the placeholder `AppId` GUID for a real release.
- Untested on real hardware in this build environment (macOS). The acceptance
  scenarios in the spec require a Windows 10/11 machine.
