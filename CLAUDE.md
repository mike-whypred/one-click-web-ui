# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A double-click Windows installer that takes a **non-technical user** from zero to a working
local AI chat app (**Open WebUI + Ollama**), with no terminal, no Docker, and no manual config.
The full requirements live in [`spec`](./spec) — read it before doing anything. It is the
source of truth: hard requirements, behavioral requirements, known prototype issues to fix,
deliverables, and acceptance criteria.

## Current state

The deliverables are built under [`openwebui-installer/`](./openwebui-installer):

```
openwebui-installer/
  Install-OpenWebUI.bat      # double-click entry point; -ExecutionPolicy Bypass -File install.ps1
  install.ps1                # main installer (8 numbered steps, see its header)
  launch.ps1.template        # runtime launcher; install.ps1 fills {{...}} and writes launch.ps1
  Uninstall-OpenWebUI.bat    # stretch: uninstaller entry point
  uninstall.ps1              # stretch: stops our process, removes install dir + shortcut
  setup.iss                  # stretch: Inno Setup wrapper -> dist\setup.exe (per-user, signable)
  README.md                  # for the non-technical end user
  CHANGELOG.md               # every deviation from the prototype + rationale
```

Key decisions made during the build (full rationale in `CHANGELOG.md`): Python runtime is a
**self-extracted python-build-standalone CPython 3.12 + `python -m venv`**, with `uv` kept only
as the fast `pip` installer (uv-managed Python was abandoned because its directory junctions hit
"untrusted mount point" / os error 448 on Windows 11; python.org has no current 3.12 installer);
`$MinOllamaVersion = 0.22.0`; **no UAC** (all installs are per-user); hidden launch via a generated
`.vbs` run by `wscript`; "already running" detection via PID+path+health (not path-substring). Stretch goals done: uninstaller, NVIDIA GPU note, disk-space
guard, Inno Setup `setup.iss` wrapper (per-user, builds `dist\setup.exe`, signable).

Note: the spec references a prototype (`install.ps1`, `Install-OpenWebUI.bat`, `README.md`
"in this folder"). Those prototype files were **never present** in the repo; the current scripts
were written fresh against the spec, not transcribed.

There is no build, lint, or test tooling, and no PowerShell available in this dev environment
(macOS), so the scripts are **untested on real hardware**. Acceptance is manual, against the 9
scenarios in the spec's "Acceptance criteria" section (clean machine, Ollama present/old/with-models,
system Python present, re-run, reboot, offline, port-in-use, failure path). These require a real
Windows 10/11 64-bit machine.

## Architecture (the big picture)

Three runtime components the installer must wire together:

1. **Ollama** — the model server (`http://localhost:11434`). Installed via the official silent
   Windows installer. The launcher ensures `ollama serve` is running.
2. **Bundled Python venv** — an isolated interpreter + venv under `%LOCALAPPDATA%\OpenWebUI`,
   never the user's system Python and never on PATH. Open WebUI is `pip install`ed into it.
3. **Open WebUI** — the web app (`http://localhost:8080`), launched from the venv, served in
   the browser.

Flow: `Install-OpenWebUI.bat` → `install.ps1` (one-time setup, idempotent) generates a
`launch.ps1` + desktop shortcut. The shortcut → `launch.ps1` is the everyday runtime path:
start Ollama if needed, start Open WebUI if needed, poll until ready, open the browser.

## Constraints that are easy to violate (from the spec)

- **PowerShell 5.1 compatible.** Do not use PowerShell 7 syntax or features. Ships-with-Windows only.
- **No external PowerShell Gallery modules.**
- **No em dashes** anywhere in user-facing text or comments. Use commas, parentheses, or
  separate sentences.
- **Idempotent.** Re-running must detect existing state and skip; never duplicate downloads or
  shortcuts, never kill an existing running instance.
- **No system Python, no PATH mutation** for Python. Bundle the runtime.
- **Offline after install.** Network is for first install only.
- **Readiness polling, not fixed sleeps.** Poll the Ollama API and the Open WebUI HTTP endpoint
  with timeouts.
- **Resolve `ollama` by full path** after install, not via PATH.
- **Hidden launch.** No console window flash from the shortcut.
- **Plain-language errors + log path** on failure, never a raw stack trace.
- **Network egress allowed only** to: ollama.com, python.org / python-build-standalone GitHub
  releases, pypi.org. Note any additional domain you need.

## Values to verify at build time (do not assume)

These are intentionally left as "determine at build" in the spec — check current sources before
hardcoding:

- `$MinOllamaVersion` — minimum Ollama version that supports the default model. Check Ollama
  release notes.
- `$PythonVersion` — a version Open WebUI officially supports. Check Open WebUI's `pyproject.toml`
  / docs; do not assume 3.11.
- Python runtime approach — spec recommends `python-build-standalone` or a uv-managed venv over
  the fragile embeddable zip. Justify the choice in a comment.

Stable constants: `$ModelName = "gemma4:e4b"`, `$OpenWebUIPort = 8080` (with free-port fallback),
`$InstallRoot = "$env:LOCALAPPDATA\OpenWebUI"`.

## Audience split for comments and docs

- **Scripts:** comment heavily for a *maintainer*.
- **README.md:** written for a *non-technical end user* (install steps, the SmartScreen
  "More info > Run anyway" step, where the shortcut is, adding models via the Open WebUI GUI,
  uninstall).
- **CHANGELOG.md:** enumerate every deviation from the prototype with a one-line rationale,
  especially the Python runtime decision.