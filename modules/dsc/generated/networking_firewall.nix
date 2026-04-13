# Generated from DSC resource schema — do not edit manually.
# Source: DSC_Firewall.schema.mof
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
  options.win.dsc.firewall.rules = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          DisplayName = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Localized, user-facing name of the Firewall Rule being created.";
          };
          Group = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Name of the Firewall Group where we want to put the Firewall Rule.";
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
            description = "Ensure the presence/absence of the resource.";
          };
          Enabled = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "True"
                  "False"
                ]
              )
            );
            default = null;
            description = "Enable or disable the supplied configuration.";
          };
          Action = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "NotConfigured"
                  "Allow"
                  "Block"
                ]
              )
            );
            default = null;
            description = "Allow or Block the supplied configuration.";
          };
          Profile = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies one or more profiles to which the rule is assigned.";
          };
          Direction = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Inbound"
                  "Outbound"
                ]
              )
            );
            default = null;
            description = "Direction of the connection.";
          };
          RemotePort = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specific Port used for filter. Specified by port number, range, or keyword";
          };
          LocalPort = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Local Port used for the filter.";
          };
          Protocol = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specific Protocol for filter. Specified by name, number, or range.";
          };
          Description = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Documentation for the Rule.";
          };
          Program = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Path and file name of the program for which the rule is applied.";
          };
          Service = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the short name of a Windows service to which the firewall rule applies.";
          };
          Authentication = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "NotRequired"
                  "Required"
                  "NoEncap"
                ]
              )
            );
            default = null;
            description = "Specifies that authentication is required on firewall rules.";
          };
          Encryption = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "NotRequired"
                  "Required"
                  "Dynamic"
                ]
              )
            );
            default = null;
            description = "Specifies that encryption in authentication is required on firewall rules.";
          };
          InterfaceAlias = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies the alias of the interface that applies to the traffic.";
          };
          InterfaceType = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Any"
                  "Wired"
                  "Wireless"
                  "RemoteAccess"
                ]
              )
            );
            default = null;
            description = "Specifies that only network connections made through the indicated interface types are subject to the requirements of this rule.";
          };
          LocalAddress = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies that network packets with matching IP addresses match this rule.";
          };
          LocalUser = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the principals to which network traffic this firewall rule applies.";
          };
          Package = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies the Windows Store application to which the firewall rule applies.";
          };
          Platform = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies which version of Windows the associated rule applies.";
          };
          RemoteAddress = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies that network packets with matching IP addresses match this rule.";
          };
          RemoteMachine = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies that matching IPsec rules of the indicated computer accounts are created.";
          };
          RemoteUser = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies that matching IPsec rules of the indicated user accounts are created.";
          };
          DynamicTransport = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Any"
                  "ProximityApps"
                  "ProximitySharing"
                  "WifiDirectPrinting"
                  "WifiDirectDisplay"
                  "WifiDirectDevices"
                ]
              )
            );
            default = null;
            description = "Specifies a dynamic transport.";
          };
          EdgeTraversalPolicy = lib.mkOption {
            type = (
              lib.types.nullOr (
                lib.types.enum [
                  "Block"
                  "Allow"
                  "DeferToUser"
                  "DeferToApp"
                ]
              )
            );
            default = null;
            description = "Specifies that matching firewall rules of the indicated edge traversal policy are created.";
          };
          IcmpType = lib.mkOption {
            type = (lib.types.nullOr (lib.types.listOf lib.types.str));
            default = null;
            description = "Specifies the ICMP type codes.";
          };
          LocalOnlyMapping = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates that matching firewall rules of the indicated value are created.";
          };
          LooseSourceMapping = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates that matching firewall rules of the indicated value are created.";
          };
          OverrideBlockRules = lib.mkOption {
            type = (lib.types.nullOr lib.types.bool);
            default = null;
            description = "Indicates that matching network traffic that would otherwise be blocked are allowed.";
          };
          Owner = lib.mkOption {
            type = (lib.types.nullOr lib.types.str);
            default = null;
            description = "Specifies that matching firewall rules of the indicated owner are created.";
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
          type = "NetworkingDsc/Firewall";
          properties = lib.filterAttrs (_: v: v != null) {
            Name = rname;
            inherit (props)
              DisplayName
              Group
              Ensure
              Enabled
              Action
              Profile
              Direction
              RemotePort
              LocalPort
              Protocol
              Description
              Program
              Service
              Authentication
              Encryption
              InterfaceAlias
              InterfaceType
              LocalAddress
              LocalUser
              Package
              Platform
              RemoteAddress
              RemoteMachine
              RemoteUser
              DynamicTransport
              EdgeTraversalPolicy
              IcmpType
              LocalOnlyMapping
              LooseSourceMapping
              OverrideBlockRules
              Owner
              ;
          };
        }
      ];
    }) cfg.firewall.rules
  );
}
