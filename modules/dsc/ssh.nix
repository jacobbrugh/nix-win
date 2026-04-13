# SSH configuration for DSC.
# Manages sshd_config and administrators_authorized_keys via DSC file resources.
{
  config,
  lib,
  ...
}:
let
  cfg = config.win.dsc;
  sshCfg = config.win.dsc.ssh;

  authorizedKeysResource = lib.optional (sshCfg.authorizedKeys != [ ]) {
    name = "Admin SSH Authorized Keys";
    type = "Microsoft.Windows/WindowsPowerShell";
    properties.resources = [
      {
        name = "Admin SSH Authorized Keys Inner";
        type = "PSDesiredStateConfiguration/File";
        properties = {
          DestinationPath = "C:\\ProgramData\\ssh\\administrators_authorized_keys";
          Contents = lib.concatStringsSep "\n" sshCfg.authorizedKeys;
        };
      }
    ];
  };

  sshdConfigResource = lib.optional (sshCfg.sshdConfig != null) {
    name = "SSHD Config";
    type = "Microsoft.Windows/WindowsPowerShell";
    properties.resources = [
      {
        name = "SSHD Config Inner";
        type = "PSDesiredStateConfiguration/File";
        properties = {
          DestinationPath = "C:\\ProgramData\\ssh\\sshd_config";
          Contents = sshCfg.sshdConfig;
        };
      }
    ];
  };
in
{
  options.win.dsc.ssh = {
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys for administrators_authorized_keys.";
    };

    sshdConfig = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Contents of sshd_config.";
    };
  };

  config.win.dsc.sshResources = lib.mkIf cfg.enable (
    authorizedKeysResource ++ sshdConfigResource
  );
}
