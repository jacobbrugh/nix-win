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

  # The extraConfig* attrsets, keyed by file name, land in the same directory
  # under the same CRLF rule as the fixed config options above.
  mkExtraFiles =
    attr: attrs:
    lib.mapAttrs' (
      name: value:
      lib.nameValuePair "${cfg.configHome}/${name}" {
        ${attr} = value;
        lineEnding = "crlf";
      }
    ) attrs;
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

    extraConfigFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = lib.literalExpression ''{ "komorebi.bar.secondary.json" = ./komorebi.bar.secondary.json; }'';
      description = ''
        Additional config files to deploy into `configHome`, keyed by file
        name. Needed by komorebi features that reference sibling files by
        path — notably komorebi.json's `bar_configurations`, which drives one
        komorebi-bar instance per listed file.
      '';
    };

    extraConfigText = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      description = ''
        Additional config files to deploy into `configHome`, keyed by file
        name, as inline text. Kept separate from `extraConfigFiles` rather
        than merged into one `either path lines` option because `types.path`
        accepts strings that look like absolute paths, so `either` would
        silently classify inline text starting with `/` as a source path.
      '';
    };

    relaunchTask = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Start Komorebi";
      description = ''
        Name of a scheduled task that launches komorebi. When set, activation
        performs a full `komorebic stop --bar` plus Start-ScheduledTask
        instead of `komorebic reload-configuration`.

        Required for any change to `display_index_preferences`,
        `monitor_index_preferences`, `monitors` or `bar_configurations`:
        reload-configuration re-reads komorebi.json but does not re-enumerate
        monitors, rebuild the workspace topology, or relaunch komorebi-bar,
        so those keys silently take no effect until the daemon restarts.

        Start-ScheduledTask rather than Start-Process so a switch run from a
        non-interactive context (SSH, session 0) cannot strand the
        replacement in a session that never owns a desktop — komorebi needs
        an interactive desktop to set its DPI awareness context.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkConfigFile "komorebi.json" cfg.config cfg.configText)
      (mkConfigFile "applications.json" cfg.applications cfg.applicationsText)
      (mkConfigFile "komorebi.bar.json" cfg.barConfig cfg.barConfigText)

      {
        home.file = mkExtraFiles "source" cfg.extraConfigFiles // mkExtraFiles "text" cfg.extraConfigText;
      }

      {
        home.sessionVariables.KOMOREBI_CONFIG_HOME = lib.replaceStrings [ "/" ] [ "\\" ] (
          "${config.home.homeDirectory}/${cfg.configHome}"
        );

        # The daemon re-reads komorebi.json from its resolved config path;
        # komorebi-bar hot-watches komorebi.bar.json on its own. A daemon
        # started before KOMOREBI_CONFIG_HOME existed keeps resolving the
        # old fallback path until it is relaunched (e.g. via its AtLogon
        # task); reload alone cannot repoint it. The same is true of
        # monitor/workspace/bar topology — hence relaunchTask.
        home.activation.reloadKomorebi = lib.hm.dag.entryAfter [ "writeBoundary" ] (
          if cfg.relaunchTask != null then
            ''
              Write-Host "nix-win: restarting Komorebi..." -ForegroundColor Cyan
              if (Get-Command komorebic -ErrorAction SilentlyContinue) {
                  komorebic stop --bar 2>$null
                  Start-Sleep -Seconds 2
                  Start-ScheduledTask -TaskName "${cfg.relaunchTask}" -ErrorAction Stop
              }
            ''
          else
            ''
              Write-Host "nix-win: reloading Komorebi..." -ForegroundColor Cyan
              if (Get-Command komorebic -ErrorAction SilentlyContinue) {
                  komorebic reload-configuration 2>$null
              }
            ''
        );
      }
    ]
  );
}
