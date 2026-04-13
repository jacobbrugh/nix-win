# Windows Terminal configuration module for nix-win.
# Manages settings.json for Windows Terminal.
{
  config,
  lib,
  ...
}:
let
  cfg = config.win.windowsTerminal;
in
{
  options.win.windowsTerminal = {
    enable = lib.mkEnableOption "Windows Terminal configuration";

    settings = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to Windows Terminal settings.json file.";
    };

    settingsText = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Inline Windows Terminal settings.json content.";
    };
  };

  config = lib.mkIf cfg.enable {
    win.files."AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json" =
      {
        source = cfg.settings;
        text = cfg.settingsText;
        targetRoot = "home";
        lineEnding = "crlf";
      };
  };
}
