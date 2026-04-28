# Generated from DSC resource schema — do not edit manually.
# Source: MSFT_RegistryResource.schema.mof
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
  options.win.dsc.psdsc.registry = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          Key = lib.mkOption {
            type = lib.types.str;
            description = "The path of the registry key to add, modify, or remove. This path must include the registry hive/drive.";
          };
          ValueName = lib.mkOption {
            type = lib.types.str;
            description = "The name of the registry value. To add or remove a registry key, specify this property as an empty string without specifying ValueType or ValueData. To modify or remove the default value of a registry key, specify this property as an empty string while also specifying ValueType or ValueData.";
          };
          ValueData = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "The data the specified registry key value should have as a string or an array of strings (MultiString only).";
          };
          ValueType = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "String"
                  "Binary"
                  "DWord"
                  "QWord"
                  "MultiString"
                  "ExpandString"
                ]
              )
            );
            default = null;
            description = "The type the specified registry key value should have.";
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
            description = "Specifies whether or not the registry key or value should exist. To add or modify a registry key or value, set this property to Present. To remove a registry key or value, set the property to Absent.";
          };
          Hex = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Specifies whether or not the specified DWord or QWord registry key data is provided in a hexadecimal format. Not valid for types other than DWord and QWord. The default value is $false.";
          };
          Force = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Specifies whether or not to overwrite the specified registry key value if it already has a value or whether or not to delete a registry key that has subkeys. The default value is $false.";
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
            type = "PSDesiredStateConfiguration/Registry";
            properties = lib.filterAttrs (_: v: v != null) {
              inherit (props)
                Key
                ValueName
                ValueData
                ValueType
                Ensure
                Hex
                Force
                ;
            };
          }
        ];
      }
      // (lib.optionalAttrs (props.dependsOn != [ ]) { inherit (props) dependsOn; })
    ) cfg.psdsc.registry
  );
}
