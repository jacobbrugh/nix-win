# User identity for the Windows system, mirroring the nixos/nix-darwin
# shapes: `users.users.<name>` records per-user data and
# `system.primaryUser` (nix-darwin convention) names the user that
# single-user options and the home-manager integration default to.
{ config, lib, ... }:
{
  options = {
    system.primaryUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alice";
      description = ''
        The Windows user owning the single-user parts of this
        configuration. An entry in `users.users` is created
        automatically for this user.
      '';
    };

    users.users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              name = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "The Windows account name.";
              };

              home = lib.mkOption {
                type = lib.types.str;
                default = "C:/Users/${name}";
                defaultText = lib.literalExpression ''"C:/Users/''${name}"'';
                description = ''
                  Absolute Windows path to the user's home directory.
                  Forward slashes are the canonical form — every consumer
                  that interpolates this into a config file needs a path
                  that survives POSIX-style shells, and Windows APIs accept
                  forward slashes natively.
                '';
              };
            };
          }
        )
      );
      default = { };
      description = "Windows user accounts known to this configuration.";
    };
  };

  config.users.users = lib.mkIf (config.system.primaryUser != null) {
    ${config.system.primaryUser} = { };
  };
}
