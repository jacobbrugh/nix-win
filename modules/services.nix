# services.<name> — assert the state and start type of existing Windows
# services, converged natively.
#
# Replaces PSDesiredStateConfiguration/Service, which cost a full Windows
# PowerShell 5.1 adapter spawn per service (1.60 s measured, 4.8 s for three)
# to read two properties and maybe call Set-Service.
#
# Note this is NOT the systemd/launchd analogue: NixOS's systemd.services and
# nix-darwin's launchd.daemons DEFINE a unit, whereas these services already
# exist (sshd, Tailscale, …) and we only assert how they are configured to
# run. Borrowing those option names would imply nix-win can define a Windows
# service, which it cannot. The fields are named for what the Service Control
# Manager calls them.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services;

  enabled = lib.filterAttrs (_: s: s.enable) cfg;

  specJson = pkgs.writeText "services.json" (
    builtins.toJSON (
      lib.mapAttrsToList (name: s: {
        inherit name;
        inherit (s) state startupType;
      }) enabled
    )
  );
in
{
  options.services = lib.mkOption {
    default = { };
    description = ''
      Existing Windows services whose run state should be asserted, keyed by
      service name.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to manage this service.";
          };

          state = lib.mkOption {
            type = lib.types.enum [
              "Running"
              "Stopped"
            ];
            default = "Running";
            description = "Desired run state.";
          };

          startupType = lib.mkOption {
            type = lib.types.enum [
              "Automatic"
              "Manual"
              "Disabled"
            ];
            default = "Automatic";
            description = "Desired Service Control Manager start type.";
          };
        };
      }
    );
  };

  config = lib.mkIf (enabled != { }) {
    system.build.services = specJson;

    system.activationScripts.services = {
      deps = [ "files" ];
      text = ''
        Write-Host "nix-win: converging services..." -ForegroundColor Cyan
        $svcSpec = Join-Path $env:NIX_WIN_STORE_PATH "services\services.json"
        $svcDeclared = @(Get-Content -LiteralPath $svcSpec -Raw | ConvertFrom-Json)

        # One bulk Get-Service, filtered in memory — same reasoning as the
        # scheduled-task and firewall steps. A per-service lookup is another
        # round trip each and buys nothing.
        $svcAll = @{}
        foreach ($s in (Get-Service)) { $svcAll[$s.Name] = $s }

        foreach ($d in $svcDeclared) {
            # $svcName, NOT $name: these scriptblocks are invoked from inside
            # Invoke-NixWinItem, whose own [string]$Name parameter would
            # otherwise shadow it (PowerShell variable names are
            # case-insensitive), so `$name` would resolve to the display label
            # rather than the service.
            $svcName = $d.name
            Invoke-NixWinItem -Name "service $svcName" -Test {
                if (-not $svcAll.ContainsKey($svcName)) {
                    # A service we do not install must exist already; saying so
                    # is far more useful than silently trying to start it.
                    throw "service '$svcName' is not installed"
                }
                $live = $svcAll[$svcName]
                if ("$($live.StartType)" -ne "$($d.startupType)") { return $false }
                if ("$($live.Status)" -ne "$($d.state)") { return $false }
                return $true
            } -Set {
                $live = $svcAll[$svcName]
                if ("$($live.StartType)" -ne "$($d.startupType)") {
                    Set-Service -Name $svcName -StartupType $d.startupType
                }
                if ("$($live.Status)" -ne "$($d.state)") {
                    if ($d.state -eq 'Running') {
                        Start-Service -Name $svcName
                    } else {
                        Stop-Service -Name $svcName -Force
                    }
                }
            }
        }
      '';
    };
  };
}
