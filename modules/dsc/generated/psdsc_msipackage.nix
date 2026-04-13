# Generated from DSC resource schema — do not edit manually.
# Source: MSFT_MsiPackage.schema.mof
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
  options.win.dsc.psdsc.msipackage = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          Path = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The path to the MSI file that should be installed or uninstalled.";
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
            description = "Specifies whether or not the MSI file should be installed or uninstalled.";
          };
          Arguments = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The arguments to be passed to the MSI package during installation or uninstallation.";
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
            description = "The credential of a user account to be used to mount a UNC path if needed.";
          };
          LogPath = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The path to the log file to log the output from the MSI execution.";
          };
          FileHash = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The expected hash value of the MSI file at the given path.";
          };
          HashAlgorithm = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "SHA1"
                  "SHA256"
                  "SHA384"
                  "SHA512"
                  "MD5"
                  "RIPEMD160"
                ]
              )
            );
            default = null;
            description = "The algorithm used to generate the given hash value.";
          };
          SignerSubject = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The subject that should match the signer certificate of the digital signature of the MSI file.";
          };
          SignerThumbprint = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "The certificate thumbprint that should match the signer certificate of the digital signature of the MSI file.";
          };
          ServerCertificateValidationCallback = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "PowerShell code that should be used to validate SSL certificates for paths using HTTPS.";
          };
          RunAsCredential = lib.mkOption {
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
            description = "The credential of a user account under which to run the installation or uninstallation of the MSI package.";
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
          type = "PSDesiredStateConfiguration/MsiPackage";
          properties = lib.filterAttrs (_: v: v != null) {
            ProductId = rname;
            inherit (props)
              Path
              Ensure
              Arguments
              LogPath
              FileHash
              HashAlgorithm
              SignerSubject
              SignerThumbprint
              ServerCertificateValidationCallback
              ;
            Credential =
              if props.Credential != null then lib.filterAttrs (_: v: v != null) props.Credential else null;
            RunAsCredential =
              if props.RunAsCredential != null then
                lib.filterAttrs (_: v: v != null) props.RunAsCredential
              else
                null;
          };
        }
      ];
    }) cfg.psdsc.msipackage
  );
}
