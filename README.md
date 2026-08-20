# nix-win

> Declarative Windows system configuration via Nix, evaluated inside WSL.

**Status:** Experimental. Usable, but the API may change.

## What is this?

nix-win is a [nix-darwin](https://github.com/LnL7/nix-darwin)-style system
manager for Windows **plus** a
[home-manager](https://github.com/nix-community/home-manager)-compatible
per-user layer. You write your Windows configuration as NixOS-style modules —
packages, files, registry keys, services, scheduled tasks, firewall rules on
the system side; dotfiles, per-user programs, HKCU environment on the home
side — evaluate it inside WSL, and apply it to the Windows host.

Think `nix-darwin` + `home-manager`, but the target is Windows.

## The two module classes

| Class | Analog | Scope | Applied by |
|---|---|---|---|
| `win` | nix-darwin | machine (ProgramData, HKLM, services, scheduled tasks, DSC) — needs admin | `nix-win switch` (elevated) |
| `winHome` | home-manager | per-user (home files, junctions, HKCU environment, user activation) — **no admin** | `nix-win switch -Home`, or embedded in a system switch |

The winHome class implements home-manager's option shapes **exactly** —
`home.file`, `home.packages`, `home.sessionVariables`, `home.sessionPath`,
`home.activation` (with `lib.hm.dag`, vendored verbatim from home-manager),
`xdg.configFile`, `programs.git`, `config.lib.file.mkOutOfStoreSymlink` — so a
module written for home-manager that sticks to that subset evaluates unchanged
under winHome. The compatibility contract is enforced by the
`eval-hm-compat` flake check. Deliberate deviations: `home.homeDirectory` is a
forward-slash `str` (a Windows path can't be a Nix `path`), and
`home.activation` text is PowerShell.

## How it works

```
┌────────────────────┐    ┌──────────────────────────────┐    ┌────────────────┐
│ your flake.nix     │───▶│ eval in WSL                  │───▶│ Windows host   │
│ scoop = { … }      │    │ class "win" + class "winHome"│    │ activate.ps1,  │
│ dsc   = { … }      │    │ → toplevel + users/<name>/   │    │ scoop, winget, │
│ home-manager.users │    │                              │    │ DSC v3, files  │
└────────────────────┘    └──────────────────────────────┘    └────────────────┘
```

- Nix evaluation runs **inside WSL** (there is no native Windows Nix)
- Files are **copied**, not symlinked — Windows symlinks to `\\wsl$\…` UNC
  paths are unreliable. Out-of-store links (`mkOutOfStoreSymlink`) become
  NTFS junctions/symlinks to real Windows paths.
- System activation is a DAG-ordered PowerShell script:
  `preActivation → files → scoop → winget → psmodules → dsc → serviceReloads → postActivation`.
  Home activation is a `lib.hm.dag`-ordered script whose `writeBoundary`
  node is trivially satisfied (the CLI deploys files before it runs).
- Generations and state are tracked per scope at
  `%LOCALAPPDATA%\nix-win\{state.system.json, state.home.json, generations/{system,home}/}`
  with rollback support

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

    # Optional: a standalone per-user configuration, applied without admin
    # via `nix-win switch -Home`.
    winHomeConfigurations."alice@my-pc" = nix-win.lib.winHomeConfiguration {
      pkgs    = nixpkgs.legacyPackages.x86_64-linux;
      modules = [ ./home.nix ];
    };
  };
}
```

Write your Windows modules:

```nix
# windows.nix (class "win" — machine scope)
{ ... }: {
  system.primaryUser = "alice";

  scoop.enable  = true;
  scoop.buckets = {
    main   = "https://github.com/ScoopInstaller/Main";
    extras = "https://github.com/ScoopInstaller/Extras";
  };
  scoop.packages = {
    git     = { bucket = "main"; };
    ripgrep = { bucket = "main"; };
    fzf     = { bucket = "main"; };
  };

  # Embed the per-user scope, home-manager style:
  home-manager.users.alice = import ./home.nix;
}
```

```nix
# home.nix (class "winHome" — per-user scope, home-manager shapes)
{ config, lib, ... }: {
  home.stateVersion = "0.2";

  home.file.".gitmessage".text = "…";
  programs.git = {
    enable = true;
    settings.user.name = "Alice Example";
  };
  home.sessionPath = [ "%USERPROFILE%\\.local\\bin" ];
  home.file."AppData/Local/nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/nvim";
}
```

Then from PowerShell on Windows (run from the repo containing this flake):

```powershell
./pkgs/nix-win/nix-win.ps1 switch          # system + embedded home (elevated)
./pkgs/nix-win/nix-win.ps1 switch -Home    # per-user only (no admin)
```

A complete minimal example lives at
[`examples/simple-flake/flake.nix`](./examples/simple-flake/flake.nix).

## Modules

### Class `win` (system)

| Namespace | Purpose |
|---|---|
| `system.primaryUser`, `users.users.<name>` | User identity (nix-darwin / NixOS shapes) |
| `system.activationScripts` | Activation DAG (NixOS shape: string or `{ text; deps; }`) |
| `environment.files` | Machine-scope files under `%ProgramData%` (the `environment.etc` analog) |
| `environment.systemPackages` | Machine-scope Nix-built packages (deploy-only) |
| `scoop`, `winget` | Package managers (top-level, mirroring nix-darwin's `homebrew`) |
| `programs.powershell.modules` | PowerShell module installation (AllUsers ⇒ admin) |
| `programs.openssh` | OpenSSH server configuration |
| `networking.hosts` | Hosts-file entries (NixOS shape: IP → hostnames), converged natively |
| `networking.firewall.{allowedTCPPorts, allowedUDPPorts, rules}` | Native firewall rule convergence |
| `scheduledTasks` | Task Scheduler entries, converged natively |
| `system.convergeScripts.<name>` | Ordered test/set convergence steps (`{ priority; testScript; setScript; }`) |
| `services.<name>` | Assertions on the state/startupType of *existing* SCM services |
| `dsc.*` | PowerShell DSC v3 — see below |
| `home-manager.{users, sharedModules, extraSpecialArgs}` | Per-user winHome sub-evals |
| `assertions`, `warnings` | Standard module-system diagnostics |

### Class `winHome` (per-user)

| Namespace | Purpose |
|---|---|
| `home.{username, homeDirectory, stateVersion}` | Identity (homeDirectory is forward-slash) |
| `home.file`, `xdg.{configFile, dataFile}` | Dotfiles (home-manager shapes + `lineEnding` extra) |
| `home.packages` | Per-user Nix-built packages (`passthru.nixWin` for placement) |
| `home.sessionVariables`, `home.sessionPath` | HKCU environment (state-tracked) |
| `home.stagedUvTools` | Nix-built Python tools staged under the profile and run natively via uv |
| `home.activation` | `lib.hm.dag` of PowerShell snippets |
| `config.lib.file.mkOutOfStoreSymlink` | NTFS junction/symlink to a real Windows path |
| `programs.git` | `settings`/`ignores`/`attributes` → `~/.config/git/*` |
| `programs.{powershell.profile, autohotkey, komorebi, windowsTerminal}`, `wsl.*` | Per-user program configs |
| `assertions`, `warnings` | Standard module-system diagnostics |

### DSC resources

DSC modules are auto-generated from upstream MOF / JSON schemas by
[`pkgs/generators/dsc2nix.py`](./pkgs/generators/dsc2nix.py) and live under
[`modules/dsc/generated/`](./modules/dsc/generated). Each generated module
exposes a typed Nix option tree that mirrors the upstream schema verbatim —
option names match the upstream field names so the [Microsoft DSC
reference](https://learn.microsoft.com/powershell/dsc/reference/resources/)
is directly usable.

| Option path | Upstream resource |
|---|---|
| `dsc.resource."Microsoft.Windows/Registry"` | Native DSC v3 Registry |
| `dsc.firewall.rules` | `NetworkingDsc/Firewall` |
| `dsc.hostsFile` | `NetworkingDsc/HostsFile` |
| `dsc.scheduledTasks` | `ComputerManagementDsc/ScheduledTask` |
| `dsc.defender` | `WindowsDefender/xMpPreference` |
| `dsc.psdsc.service` | `PSDscResources/Service` |
| `dsc.psdsc.file` | `PSDesiredStateConfiguration/File` |
| `dsc.psdsc.{archive, environment, group, …}` | other `PSDscResources/*` |
| `dsc.extraResources` | Raw DSC resource escape hatch |

The grouped `dsc.{firewall, hostsFile, scheduledTasks, psdsc.service, psdsc.file}`
options predate the native `networking.firewall` / `networking.hosts` /
`scheduledTasks` / `services` / `environment.files` modules above; prefer the
native spellings for anything they cover.

Set `dsc.enable = true;` to activate the DSC phase on switch.

## CLI

[`pkgs/nix-win/nix-win.ps1`](./pkgs/nix-win/nix-win.ps1) (PowerShell 7+):

| Command | What it does |
|---|---|
| `build` | Evaluate and build only |
| `switch` | Build, deploy, activate the system scope + the current user's embedded home scope. **Requires an elevated shell.** |
| `switch -Home` | Build and apply the per-user scope only. **No admin** (warns if elevated). |
| `rollback` | Roll back the selected scope to its previous generation |
| `list-generations` | List stored generations for the selected scope |
| `gc` | Remove old generations (keeps the 5 most recent by default) |

`-Home` selects the per-user scope on every verb. The home attribute is
resolved home-manager-style: `winHomeConfigurations."<user>@<host>"`, then
`winHomeConfigurations."<user>"`. Pass `-FlakeUri` to point the CLI at a
flake other than the current directory, and `-WslDistro` / `-WslUser` to
target a different WSL distro or user. Run
`Get-Help ./pkgs/nix-win/nix-win.ps1 -Full` for the full parameter list.

### Migration notes (v2)

- Activation phase names: `files` and `userEnvironment` still exist in the
  system chain, but per-user file deployment and HKCU PATH management moved
  to the winHome class (`home.file`, `home.sessionPath`). A
  `system.activationScripts` dep naming a phase that no longer exists is an
  eval error (deliberately — silent dep-drops reordered scripts invisibly).
- State migrates automatically: `state.json` → `state.system.json`,
  `generations/<n>` → `generations/system/<n>` on first run.

## Architecture

For the module system internals, activation DAG, adding a new module, and the
DSC generator pipeline, see [`CLAUDE.md`](./CLAUDE.md).

## Inspiration and prior art

- [nix-darwin](https://github.com/LnL7/nix-darwin) — the direct inspiration
  for the system class; `eval-config.nix` and the Scoop module mirror it
- [home-manager](https://github.com/nix-community/home-manager) — the winHome
  class implements its option shapes; `lib/hm/` vendors its dag library
  verbatim and `eval-home.nix` mirrors `homeManagerConfiguration`
- [NixOS](https://nixos.org) — the module system itself
- [NixOS-WSL](https://github.com/nix-community/NixOS-WSL) — what makes running
  Nix on Windows practical in the first place

## License

[Apache License 2.0](./LICENSE).
