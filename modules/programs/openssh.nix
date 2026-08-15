# programs.openssh — sshd_config and administrators_authorized_keys.
#
# These are two plain file placements under %ProgramData%\ssh, so they are now
# environment.files entries. They used to be PSDesiredStateConfiguration/File
# resources behind the Windows PowerShell adapter, which cost a full 5.1
# process spawn each (1.25 s apiece, exactly the adapter's floor — the File
# resource is a compiled WMI provider that does essentially nothing, so the
# entire cost was the spawn).
#
# The option lives under programs.* rather than services.* because nix-win's
# `services` option is an attrsOf submodule describing Service Control Manager
# state; `services.openssh.authorizedKeys` would be parsed as a Windows
# service literally named "openssh". Asserting that the sshd SERVICE runs is a
# separate `services.sshd` declaration.
{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.openssh;
in
{
  options.programs.openssh = {
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Public keys written to
        %ProgramData%\ssh\administrators_authorized_keys, which is the
        authorized-keys file Windows uses for every member of the
        administrators group.
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Contents of %ProgramData%\\ssh\\sshd_config.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.authorizedKeys != [ ]) {
      environment.files."ssh/administrators_authorized_keys" = {
        text = lib.concatStringsSep "\n" cfg.authorizedKeys;
        # sshd on Windows reads this file happily with either ending; CRLF
        # matches what every other tool on the platform writes.
        lineEnding = "crlf";
      };
    })
    (lib.mkIf (cfg.extraConfig != null) {
      environment.files."ssh/sshd_config" = {
        text = cfg.extraConfig;
        lineEnding = "crlf";
      };
    })
  ];
}
