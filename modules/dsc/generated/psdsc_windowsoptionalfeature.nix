# Generated from DSC resource schema — do not edit manually.
# Source: MSFT_WindowsOptionalFeature.schema.mof
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
  options.win.dsc.psdsc.windowsoptionalfeature = lib.mkOption {
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
            description = "Specifies whether the feature should be enabled or disabled. To enable the feature, set this property to Present. To disable the feature, set the property to Absent.";
          };
          RemoveFilesOnDisable = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Specifies that all files associated with the feature should be removed if the feature is being disabled.";
          };
          NoWindowsUpdateCheck = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Specifies whether or not DISM contacts Windows Update (WU) when searching for the source files to enable the feature. If $true, DISM will not contact WU.";
          };
          LogLevel = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "ErrorsOnly"
                  "ErrorsAndWarning"
                  "ErrorsAndWarningAndInformation"
                ]
              )
            );
            default = null;
            description = "The maximum output level to show in the log. Accepted values are: ErrorsOnly (only errors are logged), ErrorsAndWarning (errors and warnings are logged), and ErrorsAndWarningAndInformation (errors, warnings, and debug information are logged).";
          };
          LogPath = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The path to the log file to log this operation.";
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
            type = "PSDesiredStateConfiguration/WindowsOptionalFeature";
            properties = lib.filterAttrs (_: v: v != null) {
              Name = rname;
              inherit (props)
                Ensure
                RemoveFilesOnDisable
                NoWindowsUpdateCheck
                LogLevel
                LogPath
                ;
            };
          }
        ];
      }
      // (lib.optionalAttrs (props.dependsOn != [ ]) { inherit (props) dependsOn; })
    ) cfg.psdsc.windowsoptionalfeature
  );
}
