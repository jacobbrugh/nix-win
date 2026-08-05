# networking.hosts — the NixOS option shape (IP address → list of
# hostnames), compiled to the NetworkingDsc HostsFile resource (which is
# keyed the opposite way, by hostname).
{ config, lib, ... }:
{
  options.networking.hosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.str);
    default = { };
    example = lib.literalExpression ''
      { "192.168.0.2" = [ "fileserver.local" "nameserver.local" ]; }
    '';
    description = ''
      Locally defined maps of hostnames to IP addresses (same shape as
      the NixOS option). Entries are compiled to `dsc.hostsFile`
      resources.
    '';
  };

  config.dsc.hostsFile = lib.mkMerge (
    lib.mapAttrsToList (
      ip: names:
      lib.listToAttrs (
        map (
          name:
          lib.nameValuePair name {
            IPAddress = ip;
            Ensure = "Present";
          }
        ) names
      )
    ) config.networking.hosts
  );
}
