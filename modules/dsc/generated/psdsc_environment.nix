# Generated from DSC resource schema — do not edit manually.
# Source: MSFT_EnvironmentResource.schema.mof
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
  options.win.dsc.psdsc.environment = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          Value = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The desired value for the environment variable.";
          };
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
            description = "Specifies if the environment varaible should exist.";
          };
          Path = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates whether or not the environment variable is the Path variable.";
          };
          Target = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.listOf (
                  lib.types.enum [
                    "Process"
                    "Machine"
                  ]
                )
              )
            );
            default = null;
            description = "Indicates the target where the environment variable should be set.";
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
          type = "PSDesiredStateConfiguration/Environment";
          properties = lib.filterAttrs (_: v: v != null) {
            Name = rname;
            inherit (props)
              Value
              Ensure
              Path
              Target
              ;
          };
        }
      ];
    }) cfg.psdsc.environment
  );
}
