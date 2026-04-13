# nix-win

> Declarative Windows system configuration via Nix, evaluated inside WSL.

**Status:** Experimental. Usable, but the API may change.

## What is this?

nix-win is a [nix-darwin](https://github.com/LnL7/nix-darwin)-style system
manager for Windows. You write your Windows configuration as a NixOS-style
module — users, files, scoop/winget packages, PowerShell modules, Windows
Terminal settings, DSC resources (registry keys, scheduled tasks, firewall
rules, services, …) — evaluate it inside WSL, and apply it to the Windows
host.

Think `nix-darwin`, but the target is Windows.

## How it works

```
┌────────────────────┐    ┌──────────────────────────────┐    ┌────────────────┐
│ your flake.nix     │───▶│ eval-config.nix (in WSL)     │───▶│ Windows host   │
│ win.scoop = { … }  │    │ lib.evalModules, class="win" │    │ activate.ps1,  │
│ win.dsc   = { … }  │    │ → activate.ps1 + dsc/ + …    │    │ scoop, winget, │
└────────────────────┘    └──────────────────────────────┘    │ DSC v3, files  │
                                                              └────────────────┘
```

- Nix evaluation runs **inside WSL** (there is no native Windows Nix)
- Files are **copied**, not symlinked — Windows symlinks to `\\wsl$\…` UNC paths are unreliable
- Activation is a DAG-ordered PowerShell script:
  `preActivation → files → scoop → winget → psmodules → dsc → serviceReloads → postActivation`
- Generations are tracked at `%LOCALAPPDATA%\nix-win\` with rollback support

## Requirements

- Windows 10 or 11
- [WSL2](https://learn.microsoft.com/windows/wsl/install) with a Nix-capable
  distro ([NixOS-WSL](https://github.com/nix-community/NixOS-WSL) recommended)
- PowerShell 7+
- Optional, per subsystem you use: [Scoop](https://scoop.sh),
  [WinGet](https://learn.microsoft.com/windows/package-manager/),
  [DSC v3](https://learn.microsoft.com/powershell/dsc/overview)

## Quickstart

Create a flake that depends on `nix-win`:

```nix
# flake.nix
{
  description = "My Windows system";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-win.url = "github:jacobbrugh/nix-win";
    nix-win.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nix-win }: {
    winConfigurations.my-pc = nix-win.lib.winSystem {
      pkgs    = nixpkgs.legacyPackages.x86_64-linux;
      modules = [ ./windows.nix ];
    };
  };
}
```

Write your Windows module:

```nix
# windows.nix
{ ... }: {
  win.user.name = "alice";

  win.scoop.enable  = true;
  win.scoop.buckets = {
    main   = "https://github.com/ScoopInstaller/Main";
    extras = "https://github.com/ScoopInstaller/Extras";
  };
  win.scoop.packages = {
    git     = { bucket = "main"; };
    ripgrep = { bucket = "main"; };
    fzf     = { bucket = "main"; };
  };
}
```

Then from PowerShell on Windows (run from the repo containing this flake):

```powershell
./pkgs/nix-win/nix-win.ps1 switch
```

This evaluates your flake inside WSL, copies the build output into
`%USERPROFILE%` / `%APPDATA%` / `%LOCALAPPDATA%` / `%ProgramData%`, and runs
the generated `activate.ps1`.

A complete minimal example lives at
[`examples/simple-flake/flake.nix`](./examples/simple-flake/flake.nix).

## Modules

| Namespace             | Purpose                                                           |
|-----------------------|-------------------------------------------------------------------|
| `win.user`            | Windows user identity                                             |
| `win.files`           | Declarative file placement (home / appdata / programdata)         |
| `win.scoop`           | Scoop buckets and packages (mirrors nix-darwin's Homebrew module) |
| `win.winget`          | WinGet packages                                                   |
| `win.powershell`      | PowerShell modules and `$PROFILE` content                         |
| `win.autohotkey`      | AutoHotkey config                                                 |
| `win.komorebi`        | Komorebi tiling WM config                                         |
| `win.windowsTerminal` | Windows Terminal `settings.json`                                  |
| `win.wsl`             | `.wslconfig` management                                           |
| `win.dsc.*`           | PowerShell DSC v3 — see below                                     |

### DSC resources

DSC modules are auto-generated from upstream MOF / JSON schemas by
[`pkgs/generators/dsc2nix.py`](./pkgs/generators/dsc2nix.py) and live under
[`modules/dsc/generated/`](./modules/dsc/generated). Each generated module
exposes a typed Nix option tree that mirrors the upstream schema verbatim —
option names match the upstream field names so the [Microsoft DSC
reference](https://learn.microsoft.com/powershell/dsc/reference/resources/)
is directly usable.

| Option path                                     | Upstream resource                      |
|--------------------------------------------------|----------------------------------------|
| `win.dsc.resource."Microsoft.Windows/Registry"`  | Native DSC v3 Registry                 |
| `win.dsc.firewall.rules`                         | `NetworkingDsc/Firewall`               |
| `win.dsc.scheduledTasks`                         | `ComputerManagementDsc/ScheduledTask`  |
| `win.dsc.defender`                               | `WindowsDefender/xMpPreference`        |
| `win.dsc.psdsc.service`                          | `PSDscResources/Service`               |
| `win.dsc.psdsc.file`                             | `PSDesiredStateConfiguration/File`     |
| `win.dsc.psdsc.{archive, environment, group, …}` | other `PSDscResources/*`               |
| `win.dsc.ssh.{authorizedKeys, sshdConfig}`       | Hand-written SSH config wrapper        |
| `win.dsc.extraResources`                         | Raw DSC resource escape hatch          |

Set `win.dsc.enable = true;` to activate the DSC phase on switch.

## CLI

[`pkgs/nix-win/nix-win.ps1`](./pkgs/nix-win/nix-win.ps1) (PowerShell 7+):

| Command             | What it does                                                |
|---------------------|-------------------------------------------------------------|
| `build`             | Evaluate and build only                                     |
| `switch`            | Build, deploy files, and run activation scripts             |
| `rollback`          | Roll back to the previous generation                        |
| `list-generations`  | List stored generations                                     |
| `gc`                | Remove old generations (keeps the 5 most recent by default) |

Pass `-FlakeUri` to point the CLI at a flake other than the current directory,
and `-WslDistro` / `-WslUser` to target a different WSL distro or user. Run
`Get-Help ./pkgs/nix-win/nix-win.ps1 -Full` for the full parameter list.

## Architecture

For the module system internals, activation DAG, adding a new module, and the
DSC generator pipeline, see [`CLAUDE.md`](./CLAUDE.md).

## Inspiration and prior art

- [nix-darwin](https://github.com/LnL7/nix-darwin) — the direct inspiration;
  `eval-config.nix` and the Scoop module structure mirror it
- [home-manager](https://github.com/nix-community/home-manager) — the pattern
  of declarative per-user dotfile management
- [NixOS](https://nixos.org) — the module system itself
- [NixOS-WSL](https://github.com/nix-community/NixOS-WSL) — what makes running
  Nix on Windows practical in the first place

## License

[Apache License 2.0](./LICENSE).
