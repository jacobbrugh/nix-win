# Standalone winHome evaluation — the per-user analog of eval-config.nix,
# mirroring home-manager's homeManagerConfiguration mechanics: the caller's
# lib (nixpkgs.lib or an extended derivative) is hm-extended and evalModules
# runs ON that lib, so every module's `lib` argument carries `lib.hm.*`
# alongside whatever the caller layered on. `specialArgs` must never carry
# `lib` — it would clobber the hm extension.
{
  lib,
  legacyPackages ? null,
}:
{
  modules ? [ ],
  specialArgs ? { },
  pkgs ? null,
}:
let
  extendedLib = import ./lib/hm/stdlib-extended.nix lib;

  defaultPkgs = if pkgs != null then pkgs else legacyPackages.x86_64-linux;

  pkgsModule = {
    _module.args.pkgs = defaultPkgs;
  };

  baseModules = import ./modules/home/module-list.nix;
in
assert lib.assertMsg (!(specialArgs ? lib))
  "nix-win: do not pass `lib` via specialArgs to a winHome eval — it would clobber the hm-extended lib. Pass it as the `lib` argument instead.";
extendedLib.evalModules {
  class = "winHome";
  modules = [ pkgsModule ] ++ baseModules ++ modules;
  specialArgs = {
    modulesPath = toString ./modules/home;
  }
  // specialArgs;
}
