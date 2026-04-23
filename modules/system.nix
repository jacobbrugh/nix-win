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
    version = 1;
    stateVersion = cfg.stateVersion;
    files = config.system.build.fileManifest;
    links = config.system.build.linkManifest;
    scoop = {
      enable = config.win.scoop.enable;
    };
    winget = {
      enable = config.win.winget.enable;
    };
    dsc = {
      enable = config.win.dsc.enable;
    };
  };

  manifestJson = pkgs.writeText "manifest.json" (builtins.toJSON manifest);
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
          declared via `win.packages`, laid out under the same
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
    };
  };

  config.system.build.toplevel = pkgs.runCommand "win-system" { } ''
    mkdir -p $out

    # Activation script
    cp ${cfg.build.activationScript} $out/activate.ps1

    # Manifest
    cp ${manifestJson} $out/manifest.json

    # Files tree
    if [ -d "${cfg.build.files}" ] && [ "$(ls -A ${cfg.build.files})" ]; then
      cp -r ${cfg.build.files}/* $out/ 2>/dev/null || true
    fi

    # Packages tree — merges alongside the files tree under the same
    # home/, appdata-local/, etc. roots so Deploy-Files in the CLI
    # picks everything up with a single pass.
    ${lib.optionalString (cfg.build.packages != null) ''
      if [ -d "${cfg.build.packages}" ] && [ "$(ls -A ${cfg.build.packages})" ]; then
        cp -r ${cfg.build.packages}/* $out/ 2>/dev/null || true
      fi
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
  '';
}
