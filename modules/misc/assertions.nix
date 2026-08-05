# Standard module-system assertions/warnings options, shared by both the
# system ("win") and per-user ("winHome") classes. Enforcement happens where
# each class assembles its main output derivation: modules/system.nix guards
# system.build.toplevel; the home class guards home.activationPackage.
{ lib, ... }:
{
  options = {
    assertions = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      internal = true;
      default = [ ];
      example = [
        {
          assertion = false;
          message = "you can't enable this for that reason";
        }
      ];
      description = ''
        This option allows modules to express conditions that must
        hold for the evaluation of the configuration to succeed,
        along with associated error messages for the user.
      '';
    };

    warnings = lib.mkOption {
      internal = true;
      default = [ ];
      type = lib.types.listOf lib.types.str;
      example = [ "This option is deprecated." ];
      description = ''
        This option allows modules to show warnings to users during
        the evaluation of the configuration.
      '';
    };
  };
}
