# nix-win

Declarative Windows system configuration via Nix, evaluated inside WSL.

## Project Overview

nix-win is a nix-darwin-style system manager for Windows. It uses the NixOS module system (`lib.evalModules` with class `"win"`) to evaluate configuration inside WSL, build output artifacts (config files, scoopfile.json, DSC YAML, activation scripts), and apply them to the Windows host.

## Architecture

```
User flake → eval-config.nix (lib.evalModules, class "win") → system.build.toplevel
  → activate.ps1 + files/ + scoop/ + dsc/ + manifest.json
  → nix-win.ps1 CLI copies to Windows and runs activation
```

- **Nix evaluation** runs inside WSL (no native Windows Nix)
- **File placement** uses copy (not symlinks) from `\\wsl$\NixOS\nix\store\...` to Windows paths
- **Activation** is DAG-ordered PowerShell: `preActivation → files → scoop → winget → psmodules → dsc → serviceReloads → postActivation`
- **State tracking** at `%LOCALAPPDATA%\nix-win\` with generation management

## Common Commands

```bash
# Evaluate the module system (quick syntax check)
nix eval --impure --expr '(import ./eval-config.nix { inherit (builtins.getFlake "nixpkgs") lib; } { pkgs = ...; modules = [...]; }).config.win'

# Build a test configuration
nix build --impure --expr '...' -o /tmp/nix-win-test

# Inspect build output
find /tmp/nix-win-test/ -type f | sort
cat /tmp/nix-win-test/activate.ps1
cat /tmp/nix-win-test/dsc/config.yaml
```

## Directory Structure

```
eval-config.nix              # Module evaluation entry point
flake.nix                    # Flake exposing lib.winSystem
modules/
  module-list.nix            # All base module imports
  system.nix                 # system.build.toplevel derivation
  user.nix                   # win.user.{name,homeDirectory}
  files.nix                  # win.files.<path> = { source|text; lineEnding; targetRoot; }
  activation.nix             # win.activationScripts DAG framework
  scoop.nix                  # win.scoop.{buckets,packages,cleanup}
  winget.nix                 # win.winget.packages
  powershell.nix             # win.powershell.{modules,profile}
  dsc/
    default.nix              # DSC top-level (collects resources → DSC v3 YAML)
    ssh.nix                  # win.dsc.ssh.{authorizedKeys, sshdConfig}  (hand-written)
    generated/               # Auto-generated from upstream DSC schemas — do not edit
      default.nix            # imports every generated module
      registry.nix           # win.dsc.resource."Microsoft.Windows/Registry"
      networking_firewall.nix# win.dsc.firewall.rules (NetworkingDsc)
      scheduled_task.nix     # win.dsc.scheduledTasks (ComputerManagementDsc)
      xmppreference.nix      # win.dsc.defender (WindowsDefender/xMpPreference)
      psdsc_*.nix            # win.dsc.psdsc.<resource> (PSDscResources)
  autohotkey.nix             # win.autohotkey.{enable,config}
  komorebi.nix               # win.komorebi.{enable,config,applications}
  wslconfig.nix              # win.wsl.{wsl2,experimental}
  windows-terminal.nix       # win.windowsTerminal.settings
lib/
  default.nix                # Path helpers, CRLF conversion, mkWinFile
  activation.nix             # DAG topological sort for activation scripts
pkgs/
  nix-win/nix-win.ps1        # PowerShell CLI (build/switch/diff/rollback)
```

## Public API

```nix
# In consumer's flake.nix:
inputs.nix-win.url = "github:jacobbrugh/nix-win";

winConfigurations.pc1 = nix-win.lib.winSystem {
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  modules = [ ./nix/system/windows.nix ];
  specialArgs = { inherit self czData czUtil; };
};
```

## Adding a New Module

1. Create `modules/<name>.nix` following the standard NixOS module pattern
2. Add it to `modules/module-list.nix`
3. Define options under `win.<namespace>`
4. In `config`, set `win.activationScripts.<phase>.text` to add activation logic
5. Optionally contribute to `system.build.*` for generated artifacts

## Key Design Decisions

- **Copy-based, not symlinks**: Windows symlinks to WSL UNC paths are unreliable
- **Line endings at build time**: `lineEnding = "auto"` infers CRLF for .ps1/.json/.yaml, LF for rest
- **DSC typed modules**: Auto-generated Nix option types mirror upstream MOF/JSON schemas via `pkgs/generators/dsc2nix.py` (hand-written wrapper only for `win.dsc.ssh`)
- **Scoop mirrors Homebrew**: Generates scoopfile.json, runs `scoop import` on activation
- **WinGet standalone**: Not wrapped in DSC for simplicity
- **DAG activation**: Topologically sorted by deps, missing deps are silently skipped
