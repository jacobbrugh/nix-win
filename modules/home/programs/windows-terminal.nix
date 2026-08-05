# programs.windowsTerminal (winHome class) — settings.json placement.
{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.windowsTerminal;
in
{
  options.programs.windowsTerminal = {
    enable = lib.mkEnableOption "Windows Terminal configuration";

    settings = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to the Windows Terminal settings.json file.";
    };

    settingsText = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Inline settings.json content.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file."AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json" =
      lib.mkMerge [
        (lib.mkIf (cfg.settings != null) { source = cfg.settings; })
        (lib.mkIf (cfg.settingsText != null) { text = cfg.settingsText; })
        { lineEnding = "crlf"; }
      ];
  };
}
