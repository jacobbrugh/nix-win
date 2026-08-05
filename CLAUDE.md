# nix-win

Declarative Windows system configuration via Nix, evaluated inside WSL.

## Project Overview

nix-win is a nix-darwin-style system manager for Windows plus a
home-manager-compatible per-user layer. Two module classes:

- **`win`** (system, admin scope): `lib.evalModules` class `"win"` via
  `eval-config.nix`. Machine state — ProgramData files, HKLM registry,
  services, scheduled tasks, firewall, scoop/winget, DSC.
- **`winHome`** (per-user, no-admin scope): `eval-home.nix`, class
  `"winHome"`, on a lib extended with the vendored `lib.hm.*`
  (`lib/hm/stdlib-extended.nix`, mirroring home-manager). Implements
  home-manager's option shapes exactly (see the HM-compat contract below).

## Architecture

```
User flake → eval-config.nix (class "win") → system.build.toplevel
  → activate.ps1 + files/ + scoop/ + dsc/ + manifest.json (v2)
  → users/<name>/ (each home-manager.users.<name>'s activationPackage)
User flake → eval-home.nix (class "winHome") → home.activationPackage
  → activate.ps1 + manifest.json + home/ + environment/*.json
  → nix-win.ps1 CLI copies to Windows and runs activation, per scope
```

- **Nix evaluation** runs inside WSL (no native Windows Nix)
- **File placement** uses copy (not symlinks) from `\\wsl$\NixOS\nix\store\...`
  to Windows paths; out-of-store sources (`config.lib.file.mkOutOfStoreSymlink`)
  become NTFS junctions/symlinks via the link manifest
- **System activation** is DAG-ordered PowerShell:
  `preActivation → files → scoop → winget → psmodules → dsc → serviceReloads → postActivation`.
  A dep naming a non-existent entry is an eval ERROR (never silently dropped).
- **Home activation** is a `lib.hm.dag` (home-manager's shape, vendored
  verbatim); `writeBoundary` is a trivially-satisfied marker — the CLI deploys
  files before the script runs. Text is PowerShell.
- **State tracking** per scope at `%LOCALAPPDATA%\nix-win\`:
  `state.{system,home}.json`, `generations/{system,home}/<n>` (v1 state
  auto-migrates into the system scope)

## The HM-compat contract

A module that sticks to home-manager's option subset — `home.file`
(enable/target/source/text/executable/recursive/force/onChange),
`home.packages`, `home.sessionVariables`, `home.sessionPath`,
`home.activation` + `lib.hm.dag.*`, `xdg.configFile`, `programs.git`
(settings/ignores/attributes), `config.lib.file.mkOutOfStoreSymlink`,
`${config.home.homeDirectory}` interpolation, `assertions`/`warnings` —
evaluates unchanged under both home-manager and winHome. The
`checks.eval-hm-compat` flake check enforces this permanently; extend it when
widening the surface. Deliberate deviations (documented, do not "fix"):

- `home.homeDirectory` is a forward-slash-normalized `str`, not `types.path`
  (a Windows path can't satisfy path). Forward slashes are load-bearing:
  interpolated values pass through POSIX-style shells that eat backslashes.
- `home.activation` text is PowerShell (activation bodies are per-OS).
- `onChange` runs on every activation (no per-file change detection yet) —
  keep snippets idempotent.
- Unsupported HM surfaces (`systemd.user.*`, shell programs) fail loudly by
  option absence. Never stub-accept them — a silently-dropped service is the
  worst failure mode.

## Common Commands

```bash
nix flake check          # real checks: eval-minimal, eval-home-minimal,
                         # eval-hm-compat, eval-integrated, eval-dep-throw
nix build .#checks.x86_64-linux.eval-hm-compat
```

## Directory Structure

```
eval-config.nix              # System (class "win") evaluation entry point
eval-home.nix                # Per-user (class "winHome") evaluation entry point
flake.nix                    # lib.winSystem, lib.winHomeConfiguration, checks
lib/
  default.nix                # Path helpers, CRLF conversion, mkWinFile
  activation.nix             # DAG topological sort (system scope; missing deps throw)
  hm/                        # VENDORED from home-manager (MIT) — keep byte-equal
    dag.nix, types-dag.nix   #   upstream sources; strings.nix trimmed to
    default.nix              #   storeFileName; stdlib-extended.nix mirrors
    stdlib-extended.nix      #   home-manager's lib.extend wiring
modules/
  module-list.nix            # System-class base modules
  system.nix                 # system.build.toplevel (manifest v2, users/ folding,
                             #   assertions/warnings enforcement)
  users.nix                  # system.primaryUser + users.users.<name>.{name,home}
  home-manager.nix           # home-manager.users.<name> integration (submoduleWith
                             #   class "winHome", specialArgs.lib = hm-extended lib,
                             #   osConfig, per-user assertion/warning forwarding)
  networking.nix             # networking.hosts (NixOS shape) → dsc.hostsFile
  compat.nix                 # win.* → new-namespace aliases (transitional)
  misc/assertions.nix        # assertions/warnings options (both classes)
  shared/file-type.nix       # THE file submodule factory: system shape and
                             #   hmCompat (home-manager) shape from one source
  files.nix                  # win.files (transitional) + environment.files
  packages.nix               # win.packages (transitional) + environment.systemPackages
  activation.nix             # system.activationScripts (NixOS shape, coercedTo str)
  scoop.nix / winget.nix     # top-level scoop.* / winget.* (homebrew analog)
  powershell.nix             # programs.powershell.modules (+ transitional profile)
  dsc/                       # dsc.* — default.nix, ssh.nix, generated/ (do not edit
                             #   generated by hand; regenerate via the package below)
  home/                      # winHome class modules
    module-list.nix, home.nix, files.nix, packages.nix, session.nix,
    activation.nix, lib.nix, xdg.nix, wsl.nix,
    programs/{git,powershell,autohotkey,komorebi,windows-terminal}.nix
pkgs/
  nix-win/nix-win.ps1        # CLI: build/switch/rollback/list-generations/gc,
                             #   -Home for the per-user scope
  generators/                # dsc2nix.py + pinned schema sources; regenerate with
                             #   nix build .#generate-dsc-modules && cp -rL result/* modules/dsc/generated/
```

## Public API

```nix
inputs.nix-win.url = "github:jacobbrugh/nix-win";

winConfigurations.pc1 = nix-win.lib.winSystem {
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  modules = [
    ./windows.nix
    { home-manager.users.alice = import ./home.nix; }
  ];
  specialArgs = { inherit self; };   # may carry lib for the SYSTEM eval
};

winHomeConfigurations."alice@pc1" = nix-win.lib.winHomeConfiguration {
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  modules = [ ./home.nix ];
  lib = myExtendedLib;               # hm-extended internally; extraSpecialArgs
  extraSpecialArgs = { … };          # must NOT carry lib (asserted)
};
```

lib threading mirrors home-manager: the caller's lib (possibly carrying its
own extensions) is run through `lib/hm/stdlib-extended.nix` and `evalModules`
runs ON that lib, so winHome modules see `lib.hm.*` plus the caller's
extensions. In the integrated path the parent win eval's lib (from
`specialArgs.lib`) is hm-extended and injected via `submoduleWith`
`specialArgs.lib`. Never pass `lib` through `extraSpecialArgs` — it would
clobber `lib.hm` (asserted in both paths).

## Adding a New Module

System class: create `modules/<name>.nix`, add to `modules/module-list.nix`,
name options for the upstream namespace they mirror (`programs.*`,
`services.*`, `environment.*`, `dsc.*` — NOT a `win.` prefix; that namespace
is transitional-alias-only). Home class: `modules/home/<name>.nix` +
`modules/home/module-list.nix`, sticking to home-manager option shapes
wherever an HM analog exists.

## Key Design Decisions

- **Copy-based, not symlinks**: Windows symlinks to WSL UNC paths are
  unreliable; out-of-store junctions/symlinks target real Windows paths only
- **Line endings at build time**: `lineEnding = "auto"` infers CRLF for
  .ps1/.json/.yaml, LF for the rest (`lib/default.nix` crlfExtensions)
- **One file submodule factory** (`modules/shared/file-type.nix`) behind
  `win.files`, `environment.files`, `home.file`, `xdg.*File` — the attrset
  shape cannot drift between scopes
- **DSC typed modules**: auto-generated Nix option types mirror upstream
  MOF/JSON schemas via `pkgs/generators/dsc2nix.py` (hand-written wrapper
  only for `dsc.ssh`)
- **Scoop mirrors Homebrew**: generates scoopfile.json, runs `scoop import`
- **WinGet standalone**: not wrapped in DSC for simplicity
- **DAG activation**: topologically sorted by deps; a missing dep is an eval
  error, never a silent skip
- **Admin split**: the system scope asserts elevation up front; the home
  scope requires none and warns if elevated (admin-token writes leave ACLs
  the unelevated user trips over)
