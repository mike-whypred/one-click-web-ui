# One-Click Open WebUI Installer for Windows (native, no Docker)

A double-click installer that takes a non-technical Windows user from zero to a
working local AI chat app (**Open WebUI + Ollama**) with no terminal, no Docker,
no manual config, and no system Python dependency. After the first install it
runs fully offline on the user's own PC.

> **Just want to install it?** Download `setup.exe` from the
> [Releases page](https://github.com/mike-whypred/one-click-web-ui/releases/latest)
> and double-click it. Full end-user instructions are in
> [`openwebui-installer/README.md`](openwebui-installer/README.md).
> (`setup.exe` is built automatically on a Windows runner whenever a `v*` tag is
> pushed; see `.github/workflows/build-installer.yml`.)

## What this repo contains

```
spec                       # the build specification (source of truth)
CLAUDE.md                  # orientation for AI coding assistants
openwebui-installer/       # the installer itself
  Install-OpenWebUI.bat    # double-click entry point
  install.ps1              # main installer (Ollama, bundled Python, model, launcher, shortcut)
  launch.ps1.template      # runtime launcher (install.ps1 fills it in and writes launch.ps1)
  Uninstall-OpenWebUI.bat  # uninstaller entry point
  uninstall.ps1            # removes the install, optionally the models
  setup.iss               # Inno Setup wrapper -> a single signable setup.exe
  README.md               # plain-language guide for the end user
  CHANGELOG.md            # design decisions and rationale
```

The repo is tiny (tens of KB of scripts). Nothing large is committed: Ollama,
the bundled Python runtime, and the AI model (about 9.6 GB) are all downloaded
at install time on the target machine, not stored here.

## How it works (high level)

1. **Ollama** (the model engine) is installed or updated to a version new enough
   for the default model, then started and polled until its API responds.
2. The default model is pulled **only if the user has no models at all**.
3. A **private Python** is provisioned with `uv` (a self-contained tool) and an
   isolated virtual environment is created under `%LOCALAPPDATA%\OpenWebUI`,
   never touching any system Python or PATH.
4. **Open WebUI** is installed into that environment.
5. A **runtime launcher** and a **desktop shortcut** ("Open WebUI") are created.
   The shortcut starts everything (hidden, no console flash), waits for the
   server, and opens the browser.

Full rationale for every decision is in
[`openwebui-installer/CHANGELOG.md`](openwebui-installer/CHANGELOG.md).

## Requirements

- 64-bit Windows 10 or Windows 11
- About 15 GB free disk space (the model is large)
- Internet for the first install only

No administrator rights are needed; everything installs per-user.

## Testing on a Windows machine

There are two ways to run it. Use option 1 to iterate; option 2 is the polished
artifact.

### 1. Run the scripts directly (no build step)

1. Download or clone this repo onto the Windows machine.
2. Double-click `openwebui-installer\Install-OpenWebUI.bat`.
3. At the blue SmartScreen prompt, click **More info**, then **Run anyway**
   (the scripts are unsigned).

### 2. Build and run setup.exe

`setup.iss` is the source for an installer executable; it must be compiled.

1. Install [Inno Setup 6](https://jrsoftware.org/isdl.php) (free, Windows only;
   6.3 or newer is recommended).
2. Open `openwebui-installer\setup.iss` in the Inno Setup Compiler and click
   **Compile**. The output is `openwebui-installer\dist\setup.exe`.
3. Run `setup.exe`. It installs per-user (no UAC), shows a progress bar, runs the
   setup, and registers an Add/Remove Programs entry.

> `dist/` and `*.exe` are gitignored. To share the built installer, attach
> `setup.exe` to a GitHub Release rather than committing it.

## Status

The scripts target Windows PowerShell 5.1 and were written and reviewed on
macOS, where PowerShell is unavailable, so they are **not yet tested on real
hardware**. The first run on a Windows 10/11 machine is the real test; expect to
iterate. The acceptance scenarios to verify are listed in [`spec`](spec).

To code-sign the artifact (and avoid most SmartScreen friction), see the signing
notes at the bottom of `setup.iss`.
