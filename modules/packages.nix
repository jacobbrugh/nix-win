# Package management module for nix-win.
#
# Declares Nix-built Windows packages to be shipped to the Windows
# filesystem. Typical source: cross-compiled Rust/C/C++ derivations
# produced by `lib.buildWindowsRustPackage` (or any other derivation
# whose output is a tree of PE32+ binaries + runtime files).
#
# Each package is deployed to `<targetRoot>/<name>/` (default:
# `%LOCALAPPDATA%\Programs\<name>`). By default `<packageDir>/bin` is
# added to the user PATH so the binaries are callable as plain
# command-line tools.
#
# This module synthesises a single `system.build.packages` derivation
# whose tree layout matches the rest of the nix-win toplevel
# (`home/...`, `appdata-local/...`, etc.). `modules/system.nix` folds
# that tree into `system.build.toplevel`, so package files ride the
# same copy-from-WSL-store pipeline that `win.files` already uses.
# No new activation phase is required; deployment happens during the
# existing `files` phase.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.win.packages;
  winLib = import ../lib { inherit lib pkgs; };

  enabled = lib.filterAttrs (_: p: p.enable) cfg;

  # Map targetRoot → environment-variable-shaped fragment used to
  # compose PATH entries. We can't use `winLib.targetRoots` directly
  # (those are `%VAR%` CMD forms); PowerShell reads
  # `[Environment]::GetEnvironmentVariable('Path', 'User')` and we
  # prefer `%VAR%` placeholders because the user PATH is stored with
  # REG_EXPAND_SZ semantics — Windows expands them at use time.
  pathRoot = {
    home = "%USERPROFILE%";
    appdata-local = "%LOCALAPPDATA%";
    appdata-roaming = "%APPDATA%";
    programdata = "%ProgramData%";
  };

  # Build one subtree per package: $out/<targetRoot>/<name>/... mirrors
  # the contents of the derivation's $out. Using `cp -rL` so symlinks
  # into the Nix store get dereferenced (the Windows side has no store).
  packagesTree = pkgs.runCommand "win-packages" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: entry: ''
        mkdir -p "$out/${entry.targetRoot}"
        cp -rL --no-preserve=mode "${entry.package}" "$out/${entry.targetRoot}/${name}"
        chmod -R u+w "$out/${entry.targetRoot}/${name}"
      '') enabled
    )
  );

  # PATH entries contributed by every enabled package that opts in.
  # Consumed by modules/environment.nix via win.environment.userPath.
  packagePathEntries = lib.mapAttrsToList (
    name: entry:
    "${pathRoot.${entry.targetRoot}}\\${name}${
      lib.optionalString (entry.pathSubdir != null && entry.pathSubdir != "") "\\${entry.pathSubdir}"
    }"
  ) (lib.filterAttrs (_: e: e.addToPath) enabled);

  # environment.systemPackages — the nixos/nix-darwin option shape (a plain
  # list of packages), staged machine-wide under
  # %ProgramData%\nix-win\Programs\<name> (passthru.nixWin.relativePath
  # overrides the subpath). Deploy-only: machine PATH (HKLM) management is
  # deliberately out of scope for now. Per-user packages belong in the
  # winHome class's home.packages.
  sysPkgMeta =
    p:
    let
      m = p.passthru.nixWin or { };
    in
    {
      relativePath = m.relativePath or "nix-win/Programs/${lib.getName p}";
    };

  sysPackagesSnippets = map (
    p:
    let
      meta = sysPkgMeta p;
    in
    ''
      dst="$out/programdata/"${lib.escapeShellArg meta.relativePath}
      mkdir -p "$(dirname "$dst")"
      cp -rL --no-preserve=mode "${p}" "$dst"
      chmod -R u+w "$dst"
    ''
  ) config.environment.systemPackages;

  combinedTree = pkgs.runCommand "win-packages" { } (
    ''
      mkdir -p $out
      if [ -d "${packagesTree}" ] && [ "$(ls -A ${packagesTree})" ]; then
        cp -r ${packagesTree}/* $out/
        chmod -R u+w $out
      fi
    ''
    + lib.concatStringsSep "\n" sysPackagesSnippets
  );
in
{
  options.win.packages = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to install this package.";
            };

            package = lib.mkOption {
              type = lib.types.package;
              description = ''
                Derivation whose output tree is copied to
                `<targetRoot>/<name>/`. The typical producer is
                `lib.buildWindowsRustPackage`, but any derivation that
                puts PE32+ binaries under `$out/bin/` (and supporting
                files elsewhere under `$out/`) works.
              '';
            };

            targetRoot = lib.mkOption {
              type = lib.types.enum [
                "home"
                "appdata-local"
                "appdata-roaming"
                "programdata"
              ];
              default = "appdata-local";
              description = ''
                Windows root the package is deployed under.
                Default `appdata-local` maps to
                `%LOCALAPPDATA%\<name>` — equivalent to the idiomatic
                `%LOCALAPPDATA%\Programs\<name>` path many Windows
                installers use. Pick `programdata` only if you need
                machine-wide placement (requires admin).
              '';
            };

            addToPath = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Prepend `<targetRoot>/<name>/<pathSubdir>` to the
                user PATH (HKCU\Environment\Path). Entries added by
                nix-win are tracked in a state file so they can be
                removed cleanly when the package is no longer
                declared — see `win.environment.userPath`.
              '';
            };

            pathSubdir = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = "bin";
              description = ''
                Subdirectory of the package output to add to PATH.
                Set to `null` or `""` to add the package root itself.
              '';
            };
          };
        }
      )
    );
    default = { };
    description = ''
      Windows packages to install from Nix-built derivations. Each
      entry's output tree is copied to
      `<targetRoot>/<name>/` on the Windows host during the `files`
      activation phase.
    '';
  };

  options.environment.systemPackages = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [ ];
    description = ''
      Machine-scope packages staged under %ProgramData%\nix-win\Programs.
      Deploy-only (no machine PATH management). Per-user packages belong
      in the winHome class's home.packages.
    '';
  };

  config = {
    system.build.packages =
      if config.environment.systemPackages == [ ] then packagesTree else combinedTree;

    # Contribute PATH entries to the shared user-path helper.
    win.environment.userPath = packagePathEntries;
  };
}
