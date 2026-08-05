# programs.komorebi (winHome class) — window manager config + reload.
{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.komorebi;
in
{
  options.programs.komorebi = {
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
        home.file.".config/komorebi/komorebi.json" = lib.mkMerge [
          (lib.mkIf (cfg.config != null) { source = cfg.config; })
          (lib.mkIf (cfg.configText != null) { text = cfg.configText; })
          { lineEnding = "crlf"; }
        ];
      })

      (lib.mkIf (cfg.applications != null || cfg.applicationsText != null) {
        home.file.".config/komorebi/applications.json" = lib.mkMerge [
          (lib.mkIf (cfg.applications != null) { source = cfg.applications; })
          (lib.mkIf (cfg.applicationsText != null) { text = cfg.applicationsText; })
          { lineEnding = "crlf"; }
        ];
      })

      {
        home.activation.reloadKomorebi = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          Write-Host "nix-win: reloading Komorebi..." -ForegroundColor Cyan
          if (Get-Command komorebic -ErrorAction SilentlyContinue) {
              komorebic reload-configuration 2>$null
          }
        '';
      }
    ]
  );
}
