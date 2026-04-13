# Generated from DSC resource schema — do not edit manually.
# Source: MSFT_Archive.schema.mof
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
  options.win.dsc.psdsc.archive = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          Path = lib.mkOption {
            type = lib.types.str;
            description = "The path to the archive file that should be expanded to or removed from the specified destination.";
          };
          Destination = lib.mkOption {
            type = lib.types.str;
            description = "The path where the specified archive file should be expanded to or removed from.";
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
            description = "Specifies whether or not the expanded content of the archive file at the specified path should exist at the specified destination. To update the specified destination to have the expanded content of the archive file at the specified path, specify this property as Present. To remove the expanded content of the archive file at the specified path from the specified destination, specify this proper...";
          };
          Validate = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Specifies whether or not to validate that a file at the destination with the same name as a file in the archive actually matches that corresponding file in the archive by the specified checksum method. If the file does not match and Ensure is specified as Present and Force is not specified, the resource will throw an error that the file at the desintation cannot be overwritten. If the file does...";
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
            description = "The Checksum method to use to validate whether or not a file at the destination with the same name as a file in the archive actually matches that corresponding file in the archive. An invalid argument exception will be thrown if Checksum is specified while Validate is specified as false. ModifiedDate will check that the LastWriteTime property of the file at the destination matches the LastWrite...";
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
            description = "The credential of a user account with permissions to access the specified archive path and destination if needed.";
          };
          Force = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Specifies whether or not any existing files or directories at the destination with the same name as a file or directory in the archive should be overwritten to match the file or directory in the archive. When this property is false, an error will be thrown if an item at the destination needs to be overwritten. The default value is false.";
          };
        };
      }
    );
    default = { };
    description = "";
  };

  config.win.dsc.nativeResourcesList = lib.mkIf cfg.enable (
    lib.mapAttrsToList (rname: props: {
      name = rname;
      type = "Microsoft.Windows/WindowsPowerShell";
      properties.resources = [
        {
          name = "${rname} Inner";
          type = "PSDesiredStateConfiguration/Archive";
          properties = lib.filterAttrs (_: v: v != null) {
            inherit (props)
              Path
              Destination
              Ensure
              Validate
              Checksum
              Force
              ;
            Credential =
              if props.Credential != null then lib.filterAttrs (_: v: v != null) props.Credential else null;
          };
        }
      ];
    }) cfg.psdsc.archive
  );
}
