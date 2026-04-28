# Generated from DSC resource schema — do not edit manually.
# Source: MSFT_ScriptResource.schema.mof
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
  options.win.dsc.psdsc.script = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          GetScript = lib.mkOption {
            type = lib.types.str;
            description = "A string that can be used to create a PowerShell script block that retrieves the current state of the resource.";
          };
          SetScript = lib.mkOption {
            type = lib.types.str;
            description = "A string that can be used to create a PowerShell script block that sets the resource to the desired state.";
          };
          TestScript = lib.mkOption {
            type = lib.types.str;
            description = "A string that can be used to create a PowerShell script block that validates whether or not the resource is in the desired state.";
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
            description = "The credential of the user account to run the script under if needed.";
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
            type = "PSDesiredStateConfiguration/Script";
            properties = lib.filterAttrs (_: v: v != null) {
              inherit (props)
                GetScript
                SetScript
                TestScript
                ;
              Credential =
                if props.Credential != null then lib.filterAttrs (_: v: v != null) props.Credential else null;
            };
          }
        ];
      }
      // (lib.optionalAttrs (props.dependsOn != [ ]) { inherit (props) dependsOn; })
    ) cfg.psdsc.script
  );
}
