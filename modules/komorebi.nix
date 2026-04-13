# Komorebi window manager configuration module for nix-win.
{
  config,
  lib,
  ...
}:
let
  cfg = config.win.komorebi;
in
{
  options.win.komorebi = {
    enable = lib.mkEnableOption "Komorebi window manager configuration";

    config = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to komorebi.json config file.";
    };

    configText = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Inline komorebi.json content.";
    };

    applications = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to applications.json config file.";
    };

    applicationsText = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Inline applications.json content.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf (cfg.config != null || cfg.configText != null) {
        win.files.".config/komorebi/komorebi.json" = {
          source = cfg.config;
          text = cfg.configText;
          lineEnding = "crlf";
        };
      })

      (lib.mkIf (cfg.applications != null || cfg.applicationsText != null) {
        win.files.".config/komorebi/applications.json" = {
          source = cfg.applications;
          text = cfg.applicationsText;
          lineEnding = "crlf";
        };
      })

      {
        win.activationScripts.serviceReloads.text = lib.mkAfter ''
            Write-Host "nix-win: reloading Komorebi..." -ForegroundColor Cyan
            if (Get-Command komorebic -ErrorAction SilentlyContinue) {
                komorebic reload-configuration 2>$null
            }
          '';
      }
    ]
  );
}
