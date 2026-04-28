# Generated from DSC resource schema — do not edit manually.
# Source: MSFT_WindowsFeature.schema.mof
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
  options.win.dsc.psdsc.windowsfeature = lib.mkOption {
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
            description = "Specifies whether the role or feature should be installed or uninstalled. To install the feature, set this property to Present. To uninstall the feature, set the property to Absent.";
          };
          IncludeAllSubFeature = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Specifies whether the subfeatures of the main feature should also be installed.";
          };
          LogPath = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The path to the log file to log this operation.";
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
            description = "A credential, if needed, to install or uninstall the role or feature.";
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
            type = "PSDesiredStateConfiguration/WindowsFeature";
            properties = lib.filterAttrs (_: v: v != null) {
              Name = rname;
              inherit (props)
                Ensure
                IncludeAllSubFeature
                LogPath
                ;
              Credential =
                if props.Credential != null then lib.filterAttrs (_: v: v != null) props.Credential else null;
            };
          }
        ];
      }
      // (lib.optionalAttrs (props.dependsOn != [ ]) { inherit (props) dependsOn; })
    ) cfg.psdsc.windowsfeature
  );
}
