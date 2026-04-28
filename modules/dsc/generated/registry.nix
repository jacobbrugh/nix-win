# Generated from DSC resource schema — do not edit manually.
# Source: zbcgj2xnsy4h03dlnv7s3hp4avc3i9mx-registry-schema.json
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
  options.win.dsc.resource."Microsoft.Windows/Registry" = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          _exist = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "";
          };
          keyPath = lib.mkOption {
            type = lib.types.str;
            description = "";
          };
          valueData = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    String = lib.mkOption {
                      type = (lib.types.nullOr lib.types.str);
                      default = null;
                      description = "";
                    };
                    ExpandString = lib.mkOption {
                      type = (lib.types.nullOr lib.types.str);
                      default = null;
                      description = "";
                    };
                    MultiString = lib.mkOption {
                      type = (lib.types.nullOr (lib.types.listOf lib.types.str));
                      default = null;
                      description = "";
                    };
                    Binary = lib.mkOption {
                      type = (lib.types.nullOr (lib.types.listOf lib.types.int));
                      default = null;
                      description = "";
                    };
                    DWord = lib.mkOption {
                      type = (lib.types.nullOr lib.types.int);
                      default = null;
                      description = "";
                    };
                    QWord = lib.mkOption {
                      type = (lib.types.nullOr lib.types.int);
                      default = null;
                      description = "";
                    };
                  };
                }
              )
            );
            default = null;
            description = "";
          };
          valueName = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "";
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
        type = "Microsoft.Windows/Registry";
        properties = lib.filterAttrs (_: v: v != null) {
          inherit (props)
            _exist
            keyPath
            valueName
            ;
          valueData =
            if props.valueData != null then lib.filterAttrs (_: v: v != null) props.valueData else null;
        };
      }
      // (lib.optionalAttrs (props.dependsOn != [ ]) { inherit (props) dependsOn; })
    ) cfg.resource."Microsoft.Windows/Registry"
  );
}
