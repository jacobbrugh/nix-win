# The home-manager-style integration module for the win system class,
# mirroring home-manager's own nixos/common.nix: per-user winHome sub-evals
# under `home-manager.users.<name>`, with the hm-extended lib injected via
# submoduleWith specialArgs, `osConfig` giving user modules read access to
# the system configuration, and each user's activationPackage folded into
# the system toplevel under users/<name>/ (applied by `nix-win switch`
# after the system phases, so scoop/winget-installed tools are on PATH for
# user activation).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.home-manager;

  extendedLib = import ../lib/hm/stdlib-extended.nix lib;

  hmModule = lib.types.submoduleWith {
    description = "nix-win home module";
    class = "winHome";
    specialArgs = {
      lib = extendedLib;
      osConfig = config;
      modulesPath = toString ./home;
    }
    // cfg.extraSpecialArgs;

    modules = [
      (
        { name, ... }:
        {
          imports = import ./home/module-list.nix ++ cfg.sharedModules;

          config = {
            _module.args.pkgs = lib.mkDefault pkgs;
            home.username = lib.mkDefault (config.users.users.${name}.name or name);
            home.homeDirectory = lib.mkDefault (config.users.users.${name}.home or "C:/Users/${name}");
          };
        }
      )
    ];
  };
in
{
  options.home-manager = {
    useGlobalPkgs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether user sub-evals use the system configuration's `pkgs`.
        Accepted for home-manager interface parity; winHome has no
        per-user nixpkgs module, so `false` is unsupported.
      '';
    };

    extraSpecialArgs = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        Extra specialArgs passed to every user's winHome eval. Must not
        contain `lib` — that would clobber the hm-extended lib.
      '';
    };

    sharedModules = lib.mkOption {
      type = with lib.types; listOf raw;
      default = [ ];
      description = "Extra modules added to all users.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf hmModule;
      default = { };
      # Prevent the entire submodule being included in the documentation.
      visible = "shallow";
      description = "Per-user winHome configuration.";
    };
  };

  config = lib.mkIf (cfg.users != { }) {
    assertions = [
      {
        assertion = cfg.useGlobalPkgs;
        message = "nix-win: home-manager.useGlobalPkgs = false is unsupported — winHome has no per-user nixpkgs module.";
      }
      {
        assertion = !(cfg.extraSpecialArgs ? lib);
        message = "nix-win: home-manager.extraSpecialArgs must not carry `lib` — it would clobber the hm-extended lib for user modules.";
      }
    ]
    ++ lib.flatten (
      lib.mapAttrsToList (
        user: userCfg:
        map (assertion: {
          inherit (assertion) assertion;
          message = "${user} profile: ${assertion.message}";
        }) userCfg.assertions
      ) cfg.users
    );

    warnings = lib.flatten (
      lib.mapAttrsToList (
        user: userCfg: map (warning: "${user} profile: ${warning}") userCfg.warnings
      ) cfg.users
    );

    system.build.userActivationPackages = lib.mapAttrs (
      _: userCfg: userCfg.home.activationPackage
    ) cfg.users;
  };
}
