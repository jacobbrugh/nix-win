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
  `preActivation → files → scoop → winget → psmodules → registryBaseline → dsc → serviceReloads → postActivation`.
  A dep naming a non-existent entry is an eval ERROR (never silently dropped).
- **Home activation** is a `lib.hm.dag` (home-manager's shape, vendored
  verbatim); `writeBoundary` is a trivially-satisfied marker — the CLI deploys
  files before the script runs. Text is PowerShell.
- **Generations** are a Nix profile in the distro
  (`~/.local/state/nix/profiles/nix-win-{system,home}`), so each is a GC
  root. `switch` = build → `nix-env --set` → activate; `rollback` /
  `switch-generation` = re-point the profile → activate. All three run the
  one `Invoke-Activate` path. An embedded home scope has no profile; it moves
  with the system generation.
- **State** per scope at `%LOCALAPPDATA%\nix-win\`: `state.{system,home}.json`
  (`storePath` = the last generation that activated fully, plus the deployed
  `files` / `links` maps), `generation-data/<scope>/<n>` (backups, dsc
  result), `registry-baseline.json`.

## Removal and rollback

Removing a declaration removes the thing; `rollback` is the same machinery
aimed at an older generation. Three mechanisms, each mirroring an upstream one:

- **Files (CLI, `Remove-StaleFiles`)**: every path in the previous state's
  `files` that the new generation does not ship is deleted *after* activation
  succeeds — if it still carries the store mtime stamp. Modified files are
  left with a warning (home-manager's "contents have diverged"); locked ones
  are carried in state as `removing` and retried.
- **Named resources (activation, `lib/removal-prelude.ps1`)**: each module
  writes a JSON artifact into its generation and diffs the OLD generation's
  copy — reachable at `$env:NIX_WIN_OLD_STORE_PATH`, nix-darwin's
  `/run/current-system` — against its own. `Get-NixWinRemoved` returns what
  disappeared; `Invoke-NixWinRemoval` removes it. Scheduled tasks, firewall
  rules, hosts names, and converge scripts (`unsetScript`, run from the old
  generation's recorded copy like nix-darwin's `system.patches`).
- **Registry values (activation, `lib/registry-baseline.ps1`)**: the original
  of every declared value is captured before the dsc phase writes it and
  restored when the declaration goes away. State lives outside the
  generations because no generation can reproduce it. `Get-NixWinRegistryPlan`
  is a pure function; the registry I/O around it is thin.

Rules that are easy to break:

- **A removal step and its artifact are unconditional.** Never wrap them in
  `mkIf (declared != { })`: the generation that removes the LAST item is
  exactly the one that needs the step. `checks.eval-removal` asserts this for
  a configuration that declares nothing.
- **A failed removal is a warning (`$script:NixWinRemovalWarnings`), never a
  failed switch.** The recipe lives in the immutable previous generation; if
  it failed the switch, state would not advance and every later switch would
  fail the same way.
- **Artifact schemas only grow.** After a rollback an OLDER generation's code
  reads a NEWER generation's artifacts; probe for fields with
  `.PSObject.Properties[...]`.
- **Old CLI, new modules — and the reverse — must both work.** The CLI is
  usually deployed by the configuration it applies, so the first switch onto
  a new nix-win runs the previous CLI. Activation must no-op its removal when
  `NIX_WIN_OLD_STORE_PATH` is unset; the CLI must read state keys with
  `Get-StateValue` / `Get-StateTable`.
- **The PowerShell preludes are real `.ps1` files** read with
  `builtins.readFile`, not Nix strings, so `checks.parse-powershell`,
  `removal-logic` and `registry-plan` run over the text that ships.
  `tests/cli-functions.ps1` and `tests/registry-live.ps1` need NTFS and a
  real registry; run them on Windows.
- **WSL command strings in the CLI are `$`-free with single-quoted absolute
  paths**: `wsl.exe -u <user> -- bash -c` passes the string through the
  login shell before bash.

Left in place by design: `services.<name>`, WinGet packages, PowerShell
modules, Scoop buckets, the effects of activation scripts, and DSC resources
other than Registry (README § Removal and rollback has the table).

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
                         # eval-hm-compat, eval-integrated, eval-dep-throw,
                         # eval-removal, parse-powershell, removal-logic,
                         # registry-plan
nix build .#checks.x86_64-linux.eval-hm-compat

# Windows-only tests (NTFS, real registry under a scratch HKCU key):
pwsh -NoProfile -File tests/cli-functions.ps1
pwsh -NoProfile -File tests/registry-live.ps1
```

## Directory Structure

```
eval-config.nix              # System (class "win") evaluation entry point
eval-home.nix                # Per-user (class "winHome") evaluation entry point
flake.nix                    # lib.winSystem, lib.winHomeConfiguration, checks
lib/
  default.nix                # Path helpers, CRLF conversion, mkWinFile, escapePwsh
  activation.nix             # DAG topological sort (system scope; missing deps throw)
  removal-prelude.ps1        # Get-NixWinRemoved / Invoke-NixWinRemoval (inlined into activate.ps1)
  registry-baseline.ps1      # registry capture/restore planner + I/O (inlined into activate.ps1)
  build-rust-package.nix     # buildWindowsRustPackage / crane cross-compile builders
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
  networking.nix             # networking.hosts (NixOS shape), converged natively
  firewall.nix               # networking.firewall.{allowedTCPPorts,allowedUDPPorts,rules}
  scheduled-tasks.nix        # top-level scheduledTasks, converged natively
  converge-scripts.nix       # system.convergeScripts.<name> {priority,testScript,setScript}
  services.nix               # services.<name> assertions on EXISTING SCM services
  misc/assertions.nix        # assertions/warnings options (both classes)
  shared/file-type.nix       # THE file submodule factory: system shape and
                             #   hmCompat (home-manager) shape from one source
  environment-files.nix      # environment.files (machine scope; environment.etc analog)
  system-packages.nix        # environment.systemPackages
  activation.nix             # system.activationScripts (NixOS shape, coercedTo str)
  scoop.nix / winget.nix     # top-level scoop.* / winget.* (homebrew analog)
  powershell.nix             # programs.powershell.modules
  programs/openssh.nix       # programs.openssh
  dsc/                       # dsc.* — default.nix + generated/ (do not edit
                             #   generated by hand; regenerate via the package below)
  home/                      # winHome class modules
    module-list.nix, home.nix, files.nix, staged-uv-tools.nix, packages.nix,
    session.nix, activation.nix, lib.nix, xdg.nix, wsl.nix,
    programs/{git,powershell,autohotkey,komorebi,windows-terminal}.nix
pkgs/
  nix-win/nix-win.ps1        # CLI: build/switch/rollback/switch-generation/
                             #   list-generations/gc, -Home for the per-user scope
tests/                       # PowerShell tests: parse.ps1, removal-logic.ps1 and
                             #   registry-plan.ps1 run in flake checks;
                             #   cli-functions.ps1 and registry-live.ps1 on Windows
  generators/                # dsc2nix.py + pinned schema sources; regenerate with
                             #   nix build .#generate-dsc-modules && cp -rL result/* modules/dsc/generated/
```

## Public API

```nix
inputs.nix-win.url = "github:jacobbrugh/nix-win";

winConfigurations.myhost = nix-win.lib.winSystem {
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  modules = [
    ./windows.nix
    { home-manager.users.alice = import ./home.nix; }
  ];
  specialArgs = { inherit self; };   # may carry lib for the SYSTEM eval
};

winHomeConfigurations."alice@myhost" = nix-win.lib.winHomeConfiguration {
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
  MOF/JSON schemas via `pkgs/generators/dsc2nix.py`; prefer the native
  converge modules (networking, firewall, scheduledTasks, services,
  environment.files) over the grouped `dsc.*` options they superseded
- **Scoop mirrors Homebrew**: generates scoopfile.json, runs `scoop import`
- **WinGet standalone**: not wrapped in DSC for simplicity
- **DAG activation**: topologically sorted by deps; a missing dep is an eval
  error, never a silent skip
- **Admin split**: the system scope asserts elevation up front; the home
  scope requires none and warns if elevated (admin-token writes leave ACLs
  the unelevated user trips over)
