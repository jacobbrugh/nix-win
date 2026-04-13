# User identity for the Windows system.
{
  config,
  lib,
  ...
}:
let
  cfg = config.win.user;
in
{
  options.win.user = {
    name = lib.mkOption {
      type = lib.types.str;
      example = lib.literalExpression ''"alice"'';
      description = "Windows username (must be set by the consumer).";
    };

    homeDirectory = lib.mkOption {
      type = lib.types.str;
      default = "C:\\Users\\${cfg.name}";
      defaultText = lib.literalExpression ''"C:\\Users\\''${cfg.name}"'';
      description = "Absolute Windows path to the user's home directory.";
    };
  };
}
