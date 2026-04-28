# Generated from DSC resource schema — do not edit manually.
# Source: MSFT_WindowsProcess.schema.mof
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
  options.win.dsc.psdsc.windowsprocess = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          Path = lib.mkOption {
            type = lib.types.str;
            description = "The full path or file name to the process executable to start or stop.";
          };
          Arguments = lib.mkOption {
            type = lib.types.str;
            description = "A string of arguments to pass to the process executable. Pass in an empty string if no arguments are needed.";
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
            description = "The credential to run the process under.";
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
            description = "Indicates whether the process is present (running) or absent (not running).";
          };
          StandardOutputPath = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The path to write the standard output stream to.";
          };
          StandardErrorPath = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The path to write the standard error stream to.";
          };
          StandardInputPath = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The path to receive standard input from.";
          };
          WorkingDirectory = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The directory to run the processes under.";
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
            type = "PSDesiredStateConfiguration/WindowsProcess";
            properties = lib.filterAttrs (_: v: v != null) {
              inherit (props)
                Path
                Arguments
                Ensure
                StandardOutputPath
                StandardErrorPath
                StandardInputPath
                WorkingDirectory
                ;
              Credential =
                if props.Credential != null then lib.filterAttrs (_: v: v != null) props.Credential else null;
            };
          }
        ];
      }
      // (lib.optionalAttrs (props.dependsOn != [ ]) { inherit (props) dependsOn; })
    ) cfg.psdsc.windowsprocess
  );
}
