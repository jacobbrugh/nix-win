# Generated from DSC resource schema — do not edit manually.
# Source: DSC_HostsFile.schema.mof
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
  options.win.dsc.hostsFile = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          IPAddress = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the IP Address that should be mapped to the host name.";
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
            description = "Specifies if the hosts file entry should be created or deleted.";
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
            type = "NetworkingDsc/HostsFile";
            properties = lib.filterAttrs (_: v: v != null) {
              HostName = rname;
              inherit (props)
                IPAddress
                Ensure
                ;
            };
          }
        ];
      }
      // (lib.optionalAttrs (props.dependsOn != [ ]) { inherit (props) dependsOn; })
    ) cfg.hostsFile
  );
}
