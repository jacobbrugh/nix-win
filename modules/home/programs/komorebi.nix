# programs.komorebi (winHome class) — window manager config + reload.
#
# All config files deploy into `configHome`, and KOMOREBI_CONFIG_HOME is
# exported (HKCU\Environment) pointing at that directory so komorebi,
# komorebic and komorebi-bar resolve the managed files instead of their
# fallback (loose files in the profile root). Without the env var, stale
# unmanaged copies in %USERPROFILE% silently win.
{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.komorebi;

  mkConfigFile =
    name: source: text:
    lib.mkIf (source != null || text != null) {
      home.file."${cfg.configHome}/${name}" = lib.mkMerge [
        (lib.mkIf (source != null) { inherit source; })
        (lib.mkIf (text != null) { inherit text; })
        { lineEnding = "crlf"; }
      ];
    };
in
{
  options.programs.komorebi = {
    enable = lib.mkEnableOption "Komorebi window manager configuration";

    configHome = lib.mkOption {
      type = lib.types.str;
      default = ".config/komorebi";
      description = ''
        Home-relative directory holding every komorebi config file.
        Exported as KOMOREBI_CONFIG_HOME in the user environment.
      '';
    };

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

    barConfig = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to komorebi.bar.json config file.";
    };

    barConfigText = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Inline komorebi.bar.json content.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkConfigFile "komorebi.json" cfg.config cfg.configText)
      (mkConfigFile "applications.json" cfg.applications cfg.applicationsText)
      (mkConfigFile "komorebi.bar.json" cfg.barConfig cfg.barConfigText)

      {
        home.sessionVariables.KOMOREBI_CONFIG_HOME = lib.replaceStrings [ "/" ] [ "\\" ] (
          "${config.home.homeDirectory}/${cfg.configHome}"
        );

        # The daemon re-reads komorebi.json from its resolved config path;
        # komorebi-bar hot-watches komorebi.bar.json on its own. A daemon
        # started before KOMOREBI_CONFIG_HOME existed keeps resolving the
        # old fallback path until it is relaunched (e.g. via its AtLogon
        # task); reload alone cannot repoint it.
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
