# xdg.configFile / xdg.dataFile / xdg.cacheHome — home-manager's xdg module
# surface, mapped onto home-relative paths. Many cross-platform tools read
# ~/.config on Windows too, so this raises verbatim module reuse.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.xdg;

  fileType = import ../shared/file-type.nix { inherit lib; } {
    includeTargetRoot = false;
    hmCompat = true;
    inherit pkgs;
  };

  # Home-relative form of an xdg base dir ("C:/Users/x/.config" → ".config").
  rel = base: lib.removePrefix (config.home.homeDirectory + "/") base;

  forward =
    base: files:
    lib.mapAttrs' (
      _: file:
      lib.nameValuePair "${rel base}/${file.target}" {
        inherit (file)
          enable
          source
          executable
          recursive
          force
          onChange
          lineEnding
          linkType
          ;
        target = "${rel base}/${file.target}";
      }
    ) files;
in
{
  options.xdg = {
    configHome = lib.mkOption {
      type = lib.types.str;
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/.config"'';
      description = "Absolute path to the XDG config home.";
    };

    dataHome = lib.mkOption {
      type = lib.types.str;
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/.local/share"'';
      description = "Absolute path to the XDG data home.";
    };

    cacheHome = lib.mkOption {
      type = lib.types.str;
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/.cache"'';
      description = "Absolute path to the XDG cache home.";
    };

    configFile = lib.mkOption {
      type = fileType;
      default = { };
      description = "Files to place under the XDG config home.";
    };

    dataFile = lib.mkOption {
      type = fileType;
      default = { };
      description = "Files to place under the XDG data home.";
    };
  };

  config = {
    xdg.configHome = lib.mkDefault "${config.home.homeDirectory}/.config";
    xdg.dataHome = lib.mkDefault "${config.home.homeDirectory}/.local/share";
    xdg.cacheHome = lib.mkDefault "${config.home.homeDirectory}/.cache";

    home.file = lib.mkMerge [
      (forward cfg.configHome cfg.configFile)
      (forward cfg.dataHome cfg.dataFile)
    ];
  };
}
