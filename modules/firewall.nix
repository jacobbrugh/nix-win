# networking.firewall — Windows Defender Firewall rules, converged natively.
#
# Replaces NetworkingDsc/Firewall, which was the most expensive adapted
# resource on this fleet (2.29 s per rule). Most of that is not the adapter
# spawn: NetworkingDsc's Get-FirewallRuleProperty reaches each filter through
# `-AssociatedNetFirewallRule`, which in NetSecurity's CDXML compiles to a WMI
# `ASSOCIATORS OF` query — eight association queries per rule instance, with
# no batching. Fetching every rule and every filter type once and correlating
# in memory is flat in rule count instead (0.42 s for all 562 rules and all
# 562 of each filter type on this host).
#
# `allowedTCPPorts` / `allowedUDPPorts` are the NixOS option names and mean
# the same thing. Anything that needs more than a port — the program-scoped,
# address-scoped rule this fleet needs for the wezterm mux — has no honest
# NixOS or nix-darwin counterpart (nix-darwin's networking.applicationFirewall
# is five enable/block toggles with no port concept at all), so it gets an
# explicitly Windows-shaped `rules` submodule rather than a borrowed name that
# would not mean the same thing.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.networking.firewall;

  portRules =
    proto: ports:
    lib.listToAttrs (
      map (p: {
        name = "nix-win-allow-${lib.toLower proto}-${toString p}";
        value = {
          displayName = "Allow ${proto} ${toString p} (nix-win)";
          direction = "Inbound";
          protocol = proto;
          localPort = [ (toString p) ];
          action = "Allow";
          enable = true;
          program = null;
          remoteAddress = [ ];
        };
      }) ports
    );

  allRules =
    (portRules "TCP" cfg.allowedTCPPorts) // (portRules "UDP" cfg.allowedUDPPorts) // cfg.rules;

  enabled = lib.filterAttrs (_: r: r.enable) allRules;

  specJson = pkgs.writeText "firewall-rules.json" (
    builtins.toJSON (
      lib.mapAttrsToList (name: r: {
        inherit name;
        inherit (r)
          displayName
          direction
          protocol
          localPort
          program
          remoteAddress
          action
          ;
      }) enabled
    )
  );
in
{
  options.networking.firewall = {
    allowedTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      example = [ 22 ];
      description = "Inbound TCP ports to allow. Same meaning as the NixOS option.";
    };

    allowedUDPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "Inbound UDP ports to allow. Same meaning as the NixOS option.";
    };

    rules = lib.mkOption {
      default = { };
      description = ''
        Firewall rules that need more than a port — a program scope, a remote
        address scope — keyed by rule name.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether this rule should be present and enabled.";
            };
            displayName = lib.mkOption {
              type = lib.types.str;
              description = "Human-readable name shown in the firewall UI.";
            };
            direction = lib.mkOption {
              type = lib.types.enum [
                "Inbound"
                "Outbound"
              ];
              default = "Inbound";
              description = "Traffic direction the rule matches.";
            };
            protocol = lib.mkOption {
              type = lib.types.str;
              default = "Any";
              example = "TCP";
              description = "Protocol (TCP, UDP, ICMPv4, Any, …).";
            };
            localPort = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Local ports the rule matches. Empty means any.";
            };
            program = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Absolute path of the program the rule is scoped to.";
            };
            remoteAddress = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "100.64.0.0/10" ];
              description = "Remote addresses or CIDRs the rule is scoped to. Empty means any.";
            };
            action = lib.mkOption {
              type = lib.types.enum [
                "Allow"
                "Block"
              ];
              default = "Allow";
              description = "What to do with matching traffic.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf (enabled != { }) {
    system.build.firewallRules = specJson;

    system.activationScripts.firewall = {
      deps = [ "files" ];
      text = ''
        Write-Host "nix-win: converging firewall rules..." -ForegroundColor Cyan
        $fwSpec = Join-Path $env:NIX_WIN_STORE_PATH "firewall\rules.json"
        $fwDeclared = @(Get-Content -LiteralPath $fwSpec -Raw | ConvertFrom-Json)

        # Fetch every rule and every filter type ONCE and correlate by
        # InstanceID. This is the whole point of replacing NetworkingDsc:
        # asking for one rule's filters via -AssociatedNetFirewallRule is a
        # WMI ASSOCIATORS OF query per filter per rule (eight per rule), while
        # the unfiltered enumerations are one round trip each regardless of
        # how many rules exist.
        # Errors here are NOT swallowed. Get-NetFirewallPortFilter and
        # Get-NetFirewallAddressFilter require elevation and fail with "Access
        # is denied" without it (Get-NetFirewallRule and
        # Get-NetFirewallApplicationFilter do not). With -ErrorAction
        # SilentlyContinue the map is simply left empty, and every
        # `if ($fwPort.ContainsKey(...))` guard then skips its comparison — so
        # a rule whose port is wrong reports `ok` because nothing looked. That
        # silent under-checking is worse than the DSC resource this replaces.
        # Record what could not be read and fail the affected items loudly.
        $fwLoadErrors = @{}
        function Get-NixWinFilterMap {
            param([Parameter(Mandatory)][string]$Cmd, [Parameter(Mandatory)][string]$Kind)
            $map = @{}
            try {
                foreach ($f in (& $Cmd -ErrorAction Stop)) { $map[$f.InstanceID] = $f }
            } catch {
                $fwLoadErrors[$Kind] = $_.Exception.Message.Trim()
            }
            return $map
        }

        $fwRules = @{}
        try {
            foreach ($r in (Get-NetFirewallRule -ErrorAction Stop)) { $fwRules[$r.Name] = $r }
        } catch {
            throw "cannot enumerate firewall rules: $($_.Exception.Message.Trim())"
        }
        $fwPort = Get-NixWinFilterMap -Cmd 'Get-NetFirewallPortFilter'        -Kind 'port'
        $fwAddr = Get-NixWinFilterMap -Cmd 'Get-NetFirewallAddressFilter'     -Kind 'address'
        $fwApp  = Get-NixWinFilterMap -Cmd 'Get-NetFirewallApplicationFilter' -Kind 'application'

        # Order-insensitive set comparison. Compare-Object refuses an empty
        # array for -ReferenceObject, and every list here can legitimately be
        # empty, so compare sorted joins instead.
        function Test-NixWinSetEqual {
            param([string[]]$A, [string[]]$B)
            $x = @($A | Sort-Object) -join '|'
            $y = @($B | Sort-Object) -join '|'
            return ($x -eq $y)
        }

        foreach ($d in $fwDeclared) {
            # $fwName, NOT $name: these scriptblocks run inside
            # Invoke-NixWinItem, whose own [string]$Name parameter would
            # shadow it (PowerShell variable names are case-insensitive), so
            # `$name` would resolve to the display label rather than the rule.
            $fwName = $d.name
            Invoke-NixWinItem -Name "firewall $fwName" -Test {
                if (-not $fwRules.ContainsKey($fwName)) { return $false }
                $live = $fwRules[$fwName]
                if ("$($live.DisplayName)" -ne "$($d.displayName)") { return $false }
                if ("$($live.Direction)" -ne "$($d.direction)") { return $false }
                if ("$($live.Action)" -ne "$($d.action)") { return $false }
                # Enabled is an enum whose string form is True/False.
                if ("$($live.Enabled)" -ne 'True') { return $false }

                # Protocol/port live on the port filter. If that enumeration
                # failed, say so rather than reporting converged on a property
                # nothing examined.
                if ($fwLoadErrors.ContainsKey('port')) {
                    throw "cannot read port filters ($($fwLoadErrors['port'])); refusing to report this rule converged"
                }
                if ($fwPort.ContainsKey($fwName)) {
                    $pf = $fwPort[$fwName]
                    if ("$($pf.Protocol)" -ne "$($d.protocol)") { return $false }
                    $wantPorts = @($d.localPort | ForEach-Object { "$_" })
                    $havePorts = @($pf.LocalPort | ForEach-Object { "$_" })
                    if ($wantPorts.Count -eq 0) {
                        # "no ports declared" means any; the filter spells that 'Any'.
                        if ($havePorts.Count -ne 0 -and $havePorts[0] -ne 'Any') { return $false }
                    } elseif (-not (Test-NixWinSetEqual -A $wantPorts -B $havePorts)) {
                        return $false
                    }
                } elseif (@($d.localPort).Count -gt 0) {
                    # Ports declared but the rule carries no port filter at all.
                    return $false
                }

                if ($null -ne $d.program) {
                    if ($fwLoadErrors.ContainsKey('application')) {
                        throw "cannot read application filters ($($fwLoadErrors['application']))"
                    }
                    if (-not $fwApp.ContainsKey($fwName)) { return $false }
                    if ("$($fwApp[$fwName].Program)" -ne "$($d.program)") { return $false }
                }

                $wantAddr = @($d.remoteAddress | ForEach-Object { "$_" })
                if ($wantAddr.Count -gt 0) {
                    if ($fwLoadErrors.ContainsKey('address')) {
                        throw "cannot read address filters ($($fwLoadErrors['address']))"
                    }
                    if (-not $fwAddr.ContainsKey($fwName)) { return $false }
                    $haveAddr = @($fwAddr[$fwName].RemoteAddress | ForEach-Object { "$_" })
                    if (-not (Test-NixWinSetEqual -A $wantAddr -B $haveAddr)) { return $false }
                }
                return $true
            } -Set {
                # Remove and recreate rather than patching. NetworkingDsc's own
                # update path is where its $ParametersList typo lives (it reads
                # an undefined variable, so the loop body never runs and every
                # unspecified property is silently dropped); recreating from the
                # full declaration cannot half-apply.
                if ($fwRules.ContainsKey($fwName)) {
                    Remove-NetFirewallRule -Name $fwName -ErrorAction SilentlyContinue
                }
                # $fwArgs, not $args: the latter is an automatic variable.
                $fwArgs = @{
                    Name        = $fwName
                    DisplayName = $d.displayName
                    Direction   = $d.direction
                    Action      = $d.action
                    Enabled     = 'True'
                }
                if ("$($d.protocol)" -ne 'Any') { $fwArgs.Protocol = $d.protocol }
                if (@($d.localPort).Count -gt 0) { $fwArgs.LocalPort = @($d.localPort) }
                if ($null -ne $d.program) { $fwArgs.Program = $d.program }
                if (@($d.remoteAddress).Count -gt 0) { $fwArgs.RemoteAddress = @($d.remoteAddress) }
                $null = New-NetFirewallRule @fwArgs
            }
        }
      '';
    };
  };
}
