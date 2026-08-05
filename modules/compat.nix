# Transitional aliases for the flat `win.*` namespace → the
# nixos/nix-darwin-mirrored namespaces. Scheduled for removal once the
# consumer repo has migrated; new configs should use the new names only.
{ lib, ... }:
let
  rename = lib.mkRenamedOptionModule;
in
{
  imports = [
    # User identity
    (rename [ "win" "user" "name" ] [ "system" "primaryUser" ])
    (lib.mkRemovedOptionModule [ "win" "user" "homeDirectory" ]
      "Set users.users.<name>.home instead (forward-slash form, default C:/Users/<name>)."
    )

    # Activation DAG
    (rename [ "win" "activationScripts" ] [ "system" "activationScripts" ])

    # Package managers (top-level, mirroring nix-darwin's homebrew)
    (rename [ "win" "scoop" "enable" ] [ "scoop" "enable" ])
    (rename [ "win" "scoop" "buckets" ] [ "scoop" "buckets" ])
    (rename [ "win" "scoop" "packages" ] [ "scoop" "packages" ])
    (rename [ "win" "scoop" "cleanup" ] [ "scoop" "cleanup" ])
    (rename [ "win" "winget" "enable" ] [ "winget" "enable" ])
    (rename [ "win" "winget" "upgrade" ] [ "winget" "upgrade" ])
    (rename [ "win" "winget" "packages" ] [ "winget" "packages" ])

    # PowerShell module installation (machine scope)
    (rename [ "win" "powershell" "modules" "pwsh7" ] [ "programs" "powershell" "modules" "pwsh7" ])
    (rename
      [ "win" "powershell" "modules" "windowsPowerShell" ]
      [ "programs" "powershell" "modules" "windowsPowerShell" ]
    )

    # DSC subtree, de-prefixed
    (rename [ "win" "dsc" "enable" ] [ "dsc" "enable" ])
    (rename [ "win" "dsc" "extraResources" ] [ "dsc" "extraResources" ])
    (rename [ "win" "dsc" "ssh" "authorizedKeys" ] [ "dsc" "ssh" "authorizedKeys" ])
    (rename [ "win" "dsc" "ssh" "sshdConfig" ] [ "dsc" "ssh" "sshdConfig" ])
    (rename
      [ "win" "dsc" "resource" "Microsoft.Windows/Registry" ]
      [ "dsc" "resource" "Microsoft.Windows/Registry" ]
    )
    (rename [ "win" "dsc" "firewall" "rules" ] [ "dsc" "firewall" "rules" ])
    (rename [ "win" "dsc" "hostsFile" ] [ "dsc" "hostsFile" ])
    (rename [ "win" "dsc" "scheduledTasks" ] [ "dsc" "scheduledTasks" ])
    (rename [ "win" "dsc" "defender" ] [ "dsc" "defender" ])
    (rename [ "win" "dsc" "psdsc" "archive" ] [ "dsc" "psdsc" "archive" ])
    (rename [ "win" "dsc" "psdsc" "environment" ] [ "dsc" "psdsc" "environment" ])
    (rename [ "win" "dsc" "psdsc" "file" ] [ "dsc" "psdsc" "file" ])
    (rename [ "win" "dsc" "psdsc" "group" ] [ "dsc" "psdsc" "group" ])
    (rename [ "win" "dsc" "psdsc" "msipackage" ] [ "dsc" "psdsc" "msipackage" ])
    (rename [ "win" "dsc" "psdsc" "registry" ] [ "dsc" "psdsc" "registry" ])
    (rename [ "win" "dsc" "psdsc" "script" ] [ "dsc" "psdsc" "script" ])
    (rename [ "win" "dsc" "psdsc" "service" ] [ "dsc" "psdsc" "service" ])
    (rename [ "win" "dsc" "psdsc" "user" ] [ "dsc" "psdsc" "user" ])
    (rename [ "win" "dsc" "psdsc" "windowsfeature" ] [ "dsc" "psdsc" "windowsfeature" ])
    (rename
      [ "win" "dsc" "psdsc" "windowsoptionalfeature" ]
      [ "dsc" "psdsc" "windowsoptionalfeature" ]
    )
    (rename [ "win" "dsc" "psdsc" "windowspackagecab" ] [ "dsc" "psdsc" "windowspackagecab" ])
    (rename [ "win" "dsc" "psdsc" "windowsprocess" ] [ "dsc" "psdsc" "windowsprocess" ])
  ];
}
