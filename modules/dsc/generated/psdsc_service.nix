# Generated from DSC resource schema — do not edit manually.
# Source: MSFT_ServiceResource.schema.mof
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
  options.win.dsc.psdsc.service = lib.mkOption {
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
            description = "Ensures that the service is present or absent. Defaults to Present.";
          };
          Path = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The path to the service executable file.";
          };
          StartupType = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Automatic"
                  "Manual"
                  "Disabled"
                ]
              )
            );
            default = null;
            description = "Indicates the startup type for the service.";
          };
          BuiltInAccount = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "LocalSystem"
                  "LocalService"
                  "NetworkService"
                ]
              )
            );
            default = null;
            description = "Indicates the sign-in account to use for the service.";
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
            description = "The credential to run the service under.";
          };
          DesktopInteract = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "The service can create or communicate with a window on the desktop. Must be false for services not running as LocalSystem. Defaults to False.";
          };
          State = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Running"
                  "Stopped"
                  "Ignore"
                ]
              )
            );
            default = null;
            description = "Indicates the state you want to ensure for the service. Defaults to Running.";
          };
          DisplayName = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The display name of the service.";
          };
          Description = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The description of the service.";
          };
          Dependencies = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "An array of strings indicating the names of the dependencies of the service.";
          };
          StartupTimeout = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "The time to wait for the service to start in milliseconds. Defaults to 30000.";
          };
          TerminateTimeout = lib.mkOption {
            type = (lib.types.nullOr lib.types.int);
            default = null;
            description = "The time to wait for the service to stop in milliseconds. Defaults to 30000.";
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
            type = "PSDesiredStateConfiguration/Service";
            properties = lib.filterAttrs (_: v: v != null) {
              Name = rname;
              inherit (props)
                Ensure
                Path
                StartupType
                BuiltInAccount
                DesktopInteract
                State
                DisplayName
                Description
                Dependencies
                StartupTimeout
                TerminateTimeout
                ;
              Credential =
                if props.Credential != null then lib.filterAttrs (_: v: v != null) props.Credential else null;
            };
          }
        ];
      }
      // (lib.optionalAttrs (props.dependsOn != [ ]) { inherit (props) dependsOn; })
    ) cfg.psdsc.service
  );
}
