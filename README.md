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
  `preActivation → files → scoop → winget → psmodules → registryBaseline → dsc → serviceReloads → postActivation`.
  Home activation is a `lib.hm.dag`-ordered script whose `writeBoundary`
  node is trivially satisfied (the CLI deploys files before it runs).
- Generations are a Nix profile inside the distro
  (`~/.local/state/nix/profiles/nix-win-{system,home}`), so each one is a GC
  root and `rollback` has something to roll back to. What is deployed right
  now is tracked per scope at
  `%LOCALAPPDATA%\nix-win\{state.system.json, state.home.json}`
- Removing a declaration removes the thing — see
  [Removal and rollback](#removal-and-rollback)

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
| `scheduledTasks` | Task Scheduler entries, converged natively; `executionTimeLimit` (`"PT0S"` for a long-running task), `runAtUnlock`, systemd-style `restartTriggers` that kill the running tree and restart the task when they change, and `hideConsole`, which runs a console command through a launcher with no window, inside a job that a task stop kills whole, passing the command's exit code through |
| `system.convergeScripts.<name>` | Ordered test/set convergence steps (`{ priority; testScript; setScript; }`) |
| `services.<name>` | Assertions on the state/startupType of *existing* SCM services (free-form entries; other modules may declare their own options under `services`) |
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
| `rollback` | Re-point the profile at the previous generation and activate it. Nothing is rebuilt. |
| `switch-generation -Generation N` | The same, for a specific generation |
| `list-generations` | List the profile's generations; `(current)` is where the profile points, `(active)` is what the machine runs |
| `gc -Keep N` | Delete all but the newest N generations (default 5) |

`-Home` selects the per-user scope on every verb. The home attribute is
resolved home-manager-style: `winHomeConfigurations."<user>@<host>"`, then
`winHomeConfigurations."<user>"`. Pass `-FlakeUri` to point the CLI at a
flake other than the current directory, and `-WslDistro` / `-WslUser` to
target a different WSL distro or user. Run
`Get-Help ./pkgs/nix-win/nix-win.ps1 -Full` for the full parameter list.

A home scope embedded in the system configuration (`home-manager.users.<name>`)
has no generations of its own: it is applied, and rolled back, with the system
generation. `rollback -Home` is for standalone `winHomeConfigurations`.

## Removal and rollback

nix-win follows nix-darwin and home-manager: it removes what it *created by
name*, puts back what it *replaced*, and leaves alone settings it merely
asserted on things it does not own. `rollback` is the same machinery run
towards an older generation.

How it knows what to remove: every generation records what it declared, and
the next activation diffs the generation being replaced against itself.

| Declared through | When the declaration goes away |
|---|---|
| `environment.files`, `environment.systemPackages`, `home.file`, `home.packages`, `xdg.*File` | the deployed file is deleted, and directories that leaves empty are pruned. A file modified since nix-win deployed it is left in place with a warning. |
| `mkOutOfStoreSymlink` links | the junction/symlink is removed (never its target) |
| `scheduledTasks` | stopped and unregistered |
| `networking.firewall` | the rule is removed |
| `networking.hosts` | the name is taken out of the hosts file |
| `home.sessionPath`, `home.sessionVariables` | the PATH entry / variable is removed |
| `dsc.resource."Microsoft.Windows/Registry"` | the value goes back to what it was before nix-win managed it — see below |
| `system.convergeScripts` | the entry's `unsetScript` runs, if it has one |

A removal that fails is reported in a block at the end of the switch and does
not fail it: the recipe comes from the previous generation, which no
configuration change can fix.

### Registry values

The first time nix-win writes a registry value it records what was there —
the data and its kind, or that the value did not exist — in
`%LOCALAPPDATA%\nix-win\registry-baseline.json`. When the value's declaration
leaves the configuration, or a rollback lands on a generation without it,
that original is written back (or the value is deleted, along with any keys
nix-win had to create for it).

- If something else rewrites a managed value between switches, nix-win
  re-asserts the declared data and adopts the foreign value as the new
  original: it is what the machine would hold without nix-win.
- If the value no longer holds what nix-win wrote when its declaration is
  removed, something else owns it now and it is left as found.
- A value that already equals what you declare when nix-win first sees it
  cannot be captured. Its original is "absent" under the Windows policy keys
  (`Software\Policies`, `…\CurrentVersion\Policies`); anywhere else, say what
  it was with `dsc.registryOriginals`, or it is left in place on removal:

  ```nix
  dsc.registryOriginals = [
    { keyPath = "HKLM\\SOFTWARE\\OpenSSH"; valueName = "DefaultShell"; }   # was absent
    {
      keyPath = "HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem";
      valueName = "LongPathsEnabled";
      valueData.DWord = 0;
    }
  ];
  ```
- `HKCU` is pinned to the SID of the account that ran the switch, so a
  restore never lands in another profile.
- Deleting a whole key (`_exist = false` with no `valueName`) is not recorded
  and cannot be restored. Registry values written by `dsc.extraResources` or
  by scripts are not tracked.

### Converge scripts

`system.convergeScripts.<name>.unsetScript` is PowerShell that puts back what
`setScript` changed:

```nix
system.convergeScripts."Reserve TCP 9182" = {
  testScript = ''return [bool](netsh int ipv4 show excludedportrange protocol=tcp | Select-String '^\s*9182\s+9182')'';
  setScript = "netsh int ipv4 add excludedportrange protocol=tcp startport=9182 numberofports=1";
  unsetScript = "netsh int ipv4 delete excludedportrange protocol=tcp startport=9182 numberofports=1";
};
```

It runs once, on the switch after the entry is deleted or disabled, from the
copy recorded in the last generation that declared it — so it has to be in
place for one switch before the entry is removed. An entry without one is
reported as removed and its changes stay.

### Left in place

| | |
|---|---|
| `services.<name>` | the state and start type of a service nix-win does not install; there is no prior value on record |
| WinGet packages, PowerShell modules, Scoop buckets | as Homebrew under nix-darwin with `cleanup = "none"`. Scoop packages follow `scoop.cleanup`. |
| `system.activationScripts`, `home.activation`, DSC resources other than Registry | imperative; nothing to invert |
| Files nix-win backed up before first overwriting them | they stay under `generation-data\<scope>\<n>\backups` |
| What a generation created before its activation failed part-way | the next diff is against the last generation that activated fully (files are the exception — they are tracked as they are copied) |

### Migration notes (v2)

- Activation phase names: `files` and `userEnvironment` still exist in the
  system chain, but per-user file deployment and HKCU PATH management moved
  to the winHome class (`home.file`, `home.sessionPath`). A
  `system.activationScripts` dep naming a phase that no longer exists is an
  eval error (deliberately — silent dep-drops reordered scripts invisibly).
- State migrates automatically: `state.json` → `state.system.json`,
  `generations/<n>` → `generations/system/<n>` on first run.

### Migration notes (profiles)

- Generations moved from text records under
  `%LOCALAPPDATA%\nix-win\generations\` (store paths that nothing rooted, so
  a Nix garbage collection deleted them) to a Nix profile in the distro. The
  old directory is no longer read or written and can be deleted. Generation
  numbers restart from the profile's.
- If the CLI is itself deployed by your configuration, the first switch onto
  this version still runs the previous CLI. Removal by generation diff is
  live from the second switch; the registry baseline is recorded on the
  first.
- Registry values an earlier version already wrote have no recorded original.
  Declare them in `dsc.registryOriginals` before removing their declarations.

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
