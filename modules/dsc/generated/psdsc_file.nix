# Generated from DSC resource schema — do not edit manually.
# Source: 611nhm79hryz5wg21qwiir5px7r8wgbw-dscschema.mof
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
  options.win.dsc.psdsc.file = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          DestinationPath = lib.mkOption {
            type = lib.types.str;
            description = "File name and path on target node to copy or create.";
          };
          Ensure = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "File"
                  "Directory"
                  "Absent"
                ]
              )
            );
            default = null;
            description = "Defines how to evaluate the existents of the destination file.";
          };
          SourcePath = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "File name and path of file to copy from.";
          };
          Contents = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Contains the contents as string for the file. To create empty file contents must contain empty string. Contents written and compared using UTF-8 character encoding.";
          };
          Checksum = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "SHA-1"
                  "SHA-256"
                  "SHA-512"
                  "CreatedDate"
                  "ModifiedDate"
                ]
              )
            );
            default = null;
            description = "The checksum type to use when determining whether two files are the same.";
          };
          SecurityDescriptor = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "ACLs - Security descriptor for file / directory. Format as SDDL string.";
          };
          Recurs = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Recurse all child directories";
          };
          Purge = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Whether unmanaged files should be purged from target.";
          };
          credential = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Credential to access remote resources.";
          };
          Attributes = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.listOf (
                  lib.types.enum [
                    "ReadOnly"
                    "Hidden"
                    "System"
                    "Archive"
                  ]
                )
              )
            );
            default = null;
            description = "Attributes for file / directory";
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
            type = "PSDesiredStateConfiguration/File";
            properties = lib.filterAttrs (_: v: v != null) {
              inherit (props)
                DestinationPath
                Ensure
                SourcePath
                Contents
                Checksum
                SecurityDescriptor
                Recurs
                Purge
                credential
                Attributes
                ;
            };
          }
        ];
      }
      // (lib.optionalAttrs (props.dependsOn != [ ]) { inherit (props) dependsOn; })
    ) cfg.psdsc.file
  );
}
