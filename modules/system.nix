# Core system module for nix-win.
# Defines system.build.toplevel — the main output derivation containing
# all managed files, generated configs, and the activation script.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.system;

  # Generate manifest.json from all module build outputs
  manifest = {
    version = 2;
    scope = "system";
    users = builtins.attrNames cfg.build.userActivationPackages;
    stateVersion = cfg.stateVersion;
    files = config.system.build.fileManifest;
    links = config.system.build.linkManifest;
    scoop = {
      enable = config.scoop.enable;
    };
    winget = {
      enable = config.winget.enable;
    };
    dsc = {
      enable = config.dsc.enable;
    };
  };

  manifestJson = pkgs.writeText "manifest.json" (builtins.toJSON manifest);

  # Standard module-system assertion/warning enforcement (same pattern as
  # NixOS/nix-darwin): failed assertions abort the toplevel eval, warnings
  # print when the toplevel is evaluated.
  failedAssertions = map (x: x.message) (lib.filter (x: !x.assertion) config.assertions);

  guard =
    drv:
    if failedAssertions != [ ] then
      throw "\nFailed assertions:\n${lib.concatStringsSep "\n" (map (x: "- ${x}") failedAssertions)}"
    else
      lib.showWarnings config.warnings drv;
in
{
  options.system = {
    stateVersion = lib.mkOption {
      type = lib.types.str;
      default = "0.1";
      description = "nix-win state version. Used for future migration logic.";
    };

    build = {
      toplevel = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        description = "The top-level derivation containing the complete Windows system configuration.";
      };

      activationScript = lib.mkOption {
        type = lib.types.package;
        description = "The assembled PowerShell activation script.";
      };

      files = lib.mkOption {
        type = lib.types.package;
        description = "Derivation containing all managed files.";
      };

      packages = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = ''
          Derivation containing all Nix-built Windows packages
          declared via `environment.systemPackages`, laid out under the same
          `home/`, `appdata-local/`, etc. roots as `system.build.files`.
        '';
      };

      fileManifest = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
        description = "List of file manifest entries for state tracking.";
      };

      linkManifest = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              path = lib.mkOption {
                type = lib.types.str;
                description = "Link path relative to its targetRoot.";
              };
              source = lib.mkOption {
                type = lib.types.str;
                description = ''
                  Absolute Windows path the link resolves to. May contain
                  PowerShell environment variable references such as
                  `$env:USERPROFILE`; the nix-win CLI expands them at
                  activation.
                '';
              };
              targetRoot = lib.mkOption {
                type = lib.types.enum [
                  "home"
                  "appdata-local"
                  "appdata-roaming"
                  "programdata"
                ];
                description = "Base directory the link's path is rooted under.";
              };
              linkType = lib.mkOption {
                type = lib.types.enum [
                  "junction"
                  "symlink"
                ];
                description = ''
                  NTFS directory junction (unprivileged, local-only, dirs
                  only) or symbolic link (files or dirs, needs Developer
                  Mode or admin).
                '';
              };
              force = lib.mkOption {
                type = lib.types.bool;
                description = ''
                  Whether to replace an existing regular file or directory
                  at the target path with the link.
                '';
              };
            };
          }
        );
        default = [ ];
        description = "List of directory-junction / symlink manifest entries for state tracking.";
      };

      scoopfile = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Generated scoopfile.json derivation.";
      };

      wingetScript = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Generated WinGet install script.";
      };

      dscConfig = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Generated DSC v3 configuration YAML.";
      };

      psmodulesManifest = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Generated PowerShell modules manifest.";
      };

      environmentConfig = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = ''
          Generated user-path.json consumed by the userEnvironment
          activation phase. Placed under
          `$out/environment/user-path.json` in the toplevel.
        '';
      };

      userActivationPackages = lib.mkOption {
        type = lib.types.attrsOf lib.types.package;
        internal = true;
        default = { };
        description = ''
          Per-user home activation packages (from the home-manager
          integration module), folded into the toplevel under
          `users/<name>/`.
        '';
      };
    };
  };

  config.system.build.toplevel = guard (pkgs.runCommand "win-system" { } ''
    mkdir -p $out

    # Activation script
    cp ${cfg.build.activationScript} $out/activate.ps1

    # Manifest
    cp ${manifestJson} $out/manifest.json

    # Files tree. cp must preserve mode; the chmod after each copy re-opens
    # the store's 0555 directories so the next tree can merge into them.
    # Nothing here may swallow stderr or mask the exit status — a copy that
    # cannot land its payload must fail the build.
    cp -rL ${cfg.build.files}/. $out/
    chmod -R u+w $out

    # Packages tree — merges alongside the files tree under the same
    # programdata/ root so Deploy-Files in the CLI picks everything up
    # with a single pass.
    ${lib.optionalString (cfg.build.packages != null) ''
      # A path staged by both environment.files and environment.systemPackages
      # would be a silent last-wins overwrite; fail the build instead.
      collisions=$(comm -12 \
        <(cd ${cfg.build.files} && find . -type f | sort) \
        <(cd ${cfg.build.packages} && find . -type f | sort))
      if [ -n "$collisions" ]; then
        echo "error: environment.files and environment.systemPackages stage the same path(s):" >&2
        echo "$collisions" >&2
        exit 1
      fi
      cp -rL ${cfg.build.packages}/. $out/
      chmod -R u+w $out
    ''}

    # Scoop
    ${lib.optionalString (cfg.build.scoopfile != null) ''
      mkdir -p $out/scoop
      cp ${cfg.build.scoopfile} $out/scoop/scoopfile.json
    ''}

    # WinGet
    ${lib.optionalString (cfg.build.wingetScript != null) ''
      mkdir -p $out/winget
      cp ${cfg.build.wingetScript} $out/winget/install.ps1
    ''}

    # DSC
    ${lib.optionalString (cfg.build.dscConfig != null) ''
      mkdir -p $out/dsc
      cp ${cfg.build.dscConfig} $out/dsc/config.yaml
    ''}

    # PowerShell modules
    ${lib.optionalString (cfg.build.psmodulesManifest != null) ''
      mkdir -p $out/powershell
      cp ${cfg.build.psmodulesManifest} $out/powershell/psmodules.json
    ''}

    # Environment (user PATH management)
    ${lib.optionalString (cfg.build.environmentConfig != null) ''
      mkdir -p $out/environment
      cp ${cfg.build.environmentConfig} $out/environment/user-path.json
    ''}

    # Per-user home activation packages (home-manager integration)
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: ap: ''
        mkdir -p $out/users
        cp -r ${ap} "$out/users/"${lib.escapeShellArg name}
      '') cfg.build.userActivationPackages
    )}
  '');
}
