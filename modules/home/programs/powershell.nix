# programs.powershell (winHome class) — the per-user profile. Module
# installation stays a system-class concern (AllUsers scope needs admin);
# only the profile is user scope.
{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.powershell;
in
{
  options.programs.powershell = {
    profile = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Content for the PowerShell 7 profile (Microsoft.PowerShell_profile.ps1).";
    };
  };

  config = lib.mkIf (cfg.profile != null) {
    home.file."Documents/PowerShell/Microsoft.PowerShell_profile.ps1" = {
      text = cfg.profile;
      lineEnding = "crlf";
    };
  };
}
