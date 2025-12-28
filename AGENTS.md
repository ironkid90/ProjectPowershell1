# AGENTS.md - ProjectPowershell1

## Overview
PowerShell profile configuration project with Clojure starter code (Calva/REPL).

## Commands
- **Test PS profile syntax**: `pwsh -NoProfile -Command "& { . .\Profile.v1.0-improved.ps1 }"`
- **Clojure REPL**: Use Calva in VS Code (`Ctrl+Shift+P` → "Calva: Start a Project REPL")
- **Run Clojure**: `clj -M -m <namespace>` (requires deps.edn)

## Architecture
- `Profile.v1.0-improved.ps1` — Main PowerShell profile (context detection, PSReadLine, deferred loading)
- `Microsoft.PowerShell_profile.ps1` — Loader stub for PS 5.1 compatibility
- `profile.d/` — Modular profile scripts (10-git, 20-aliases, 30-completions)
- `src/get_started/` — Clojure learning files (Calva tutorials)
- `deps.edn` — Clojure 1.12.1 dependencies

## Code Style
- **PowerShell**: PascalCase for functions (`Test-IsAdmin`), `$global:` prefix for globals
- **Error handling**: Use try/catch with `-ErrorAction SilentlyContinue` for optional commands
- **Clojure**: snake_case filenames, standard Clojure conventions
- **Comments**: Inline `#` for sections, avoid excessive comments
- Use `Test-CommandExists` before invoking optional tools (gsudo, oh-my-posh, zoxide)
