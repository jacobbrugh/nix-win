# Generated DSC resource modules — produced by pkgs/generators/dsc2nix.py.
# Regenerate after upstream schema changes:
#   nix build .#packages.x86_64-linux.generate-dsc-modules
#   cp -r result/ modules/dsc/generated/
{
  imports = [
    # Native DSC v3 resources (Microsoft.Windows/*)
    ./registry.nix

    # NetworkingDsc
    ./networking_firewall.nix

    # ComputerManagementDsc
    ./scheduled_task.nix

    # WindowsDefender
    ./xmppreference.nix

    # PSDesiredStateConfiguration built-in (legacy)
    ./psdsc_file.nix

    # PSDscResources (win.dsc.psdsc.*)
    ./psdsc_archive.nix
    ./psdsc_environment.nix
    ./psdsc_group.nix
    ./psdsc_msipackage.nix
    ./psdsc_registry.nix
    ./psdsc_script.nix
    ./psdsc_service.nix
    ./psdsc_user.nix
    ./psdsc_windowsfeature.nix
    ./psdsc_windowsoptionalfeature.nix
    ./psdsc_windowspackagecab.nix
    ./psdsc_windowsprocess.nix
  ];
}
