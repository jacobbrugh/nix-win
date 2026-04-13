# WSL configuration module for nix-win.
# Generates .wslconfig from typed options.
{
  config,
  lib,
  ...
}:
let
  cfg = config.win.wsl;

  # Generate .wslconfig INI-style content
  wslconfigText =
    let
      mkSection =
        name: attrs:
        let
          entries = lib.mapAttrsToList (k: v: "${k}=${toString v}") (
            lib.filterAttrs (_: v: v != null) attrs
          );
        in
        lib.optionalString (entries != [ ]) ''
          [${name}]
          ${lib.concatStringsSep "\n" entries}
        '';
    in
    lib.concatStringsSep "\n" (
      lib.filter (s: s != "") [
        (mkSection "wsl2" cfg.wsl2)
        (mkSection "experimental" cfg.experimental)
      ]
    );
in
{
  options.win.wsl = {
    enable = lib.mkEnableOption "WSL configuration (.wslconfig)";

    distroName = lib.mkOption {
      type = lib.types.str;
      default = "NixOS";
      description = "Default WSL distribution name for nix-win CLI.";
    };

    wsl2 = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr (
        lib.types.oneOf [
          lib.types.str
          lib.types.int
          lib.types.bool
        ]
      ));
      default = { };
      description = "Settings for the [wsl2] section of .wslconfig.";
      example = lib.literalExpression ''
        {
          networkingMode = "nat";
          memory = "160GB";
          swap = 0;
          nestedVirtualization = true;
        }
      '';
    };

    experimental = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr (
        lib.types.oneOf [
          lib.types.str
          lib.types.int
          lib.types.bool
        ]
      ));
      default = { };
      description = "Settings for the [experimental] section of .wslconfig.";
    };
  };

  config = lib.mkIf cfg.enable {
    win.files.".wslconfig" = {
      text = wslconfigText;
      lineEnding = "crlf";
    };
  };
}
