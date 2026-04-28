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
          dependsOn = lib.mkOption {
            type = (lib.types.listOf lib.types.str);
            default = [ ];
            description = "Defines a list of DSC resource instances that DSC must successfully process before processing this instance. Each value for this property must be the `resourceID()` lookup for another instance in the configuration. Multiple instances can depend on the same instance, but every dependency for an instance must be unique in that instance's `dependsOn` property.";
          };
        };
      }
    );
    default = { };
    description = "";
  };

  config.win.dsc.nativeResourcesList = lib.mkIf cfg.enable (
    lib.mapAttrsToList (
      rname: props:
      {
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
      }
      // (lib.optionalAttrs (props.dependsOn != [ ]) { inherit (props) dependsOn; })
    ) cfg.psdsc.environment
  );
}
