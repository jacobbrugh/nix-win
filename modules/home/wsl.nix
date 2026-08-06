# wsl.* (winHome class) — .wslconfig generation. Lives in the per-user
# class because its only output is a file in the user's home directory.
{
  config,
  lib,
  ...
}:
let
  cfg = config.wsl;

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

  settingsType = lib.types.attrsOf (
    lib.types.nullOr (
      lib.types.oneOf [
        lib.types.str
        lib.types.int
        lib.types.bool
      ]
    )
  );
in
{
  options.wsl = {
    enable = lib.mkEnableOption "WSL configuration (.wslconfig)";

    wsl2 = lib.mkOption {
      type = settingsType;
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
      type = settingsType;
      default = { };
      description = "Settings for the [experimental] section of .wslconfig.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file.".wslconfig" = {
      text = wslconfigText;
      lineEnding = "crlf";
    };
  };
}
