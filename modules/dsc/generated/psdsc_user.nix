# Generated from DSC resource schema — do not edit manually.
# Source: MSFT_UserResource.schema.mof
# Regenerate: nix build .#packages.x86_64-linux.generate-dsc-modules
{
  lib,
  config,
  ...
}:
let
  cfg = config.win.dsc;
in
{
  options.win.dsc.psdsc.user = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          Ensure = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Present"
                  "Absent"
                ]
              )
            );
            default = null;
            description = "An enumerated value that describes if the user is expected to exist on the machine";
          };
          FullName = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The display name of the user";
          };
          Description = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "A description for the user";
          };
          Password = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    UserName = lib.mkOption {
                      type = (lib.types.nullOr lib.types.str);
                      default = null;
                      description = "The username to run the task as.";
                    };
                    Password = lib.mkOption {
                      type = (lib.types.nullOr lib.types.str);
                      default = null;
                      description = "The password for the user account.";
                    };
                  };
                }
              )
            );
            default = null;
            description = "The password for the user";
          };
          Disabled = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Value used to disable/enable a user account";
          };
          PasswordNeverExpires = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Value used to set whether a user's password expires or not";
          };
          PasswordChangeRequired = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Value used to require a user to change their password";
          };
          PasswordChangeNotAllowed = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Value used to set whether a user can/cannot change their password";
          };
        };
      }
    );
    default = { };
    description = "";
  };

  config.win.dsc.nativeResourcesList = lib.mkIf cfg.enable (
    lib.mapAttrsToList (rname: props: {
      name = rname;
      type = "Microsoft.Windows/WindowsPowerShell";
      properties.resources = [
        {
          name = "${rname} Inner";
          type = "PSDesiredStateConfiguration/User";
          properties = lib.filterAttrs (_: v: v != null) {
            UserName = rname;
            inherit (props)
              Ensure
              FullName
              Description
              Disabled
              PasswordNeverExpires
              PasswordChangeRequired
              PasswordChangeNotAllowed
              ;
            Password =
              if props.Password != null then lib.filterAttrs (_: v: v != null) props.Password else null;
          };
        }
      ];
    }) cfg.psdsc.user
  );
}
