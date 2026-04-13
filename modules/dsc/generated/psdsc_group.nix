# Generated from DSC resource schema — do not edit manually.
# Source: MSFT_GroupResource.schema.mof
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
  options.win.dsc.psdsc.group = lib.mkOption {
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
            description = "Indicates if the group should exist or not.";
          };
          Description = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The description the group should have.";
          };
          Members = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "The members the group should have.";
          };
          MembersToInclude = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "The members the group should include.";
          };
          MembersToExclude = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "The members the group should exclude.";
          };
          Credential = lib.mkOption {
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
            description = "A credential to resolve non-local group members.";
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
          type = "PSDesiredStateConfiguration/Group";
          properties = lib.filterAttrs (_: v: v != null) {
            GroupName = rname;
            inherit (props)
              Ensure
              Description
              Members
              MembersToInclude
              MembersToExclude
              ;
            Credential =
              if props.Credential != null then lib.filterAttrs (_: v: v != null) props.Credential else null;
          };
        }
      ];
    }) cfg.psdsc.group
  );
}
