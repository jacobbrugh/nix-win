# Entry point for nix-win module evaluation.
# Mirrors nix-darwin's eval-config.nix — calls lib.evalModules with class "win".
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
  baseModules = import ./modules/module-list.nix;

  # If no pkgs provided, construct from legacyPackages for x86_64-linux (WSL default)
  defaultPkgs =
    if pkgs != null then
      pkgs
    else if legacyPackages != null then
      legacyPackages.x86_64-linux
    else
      throw "nix-win: either pkgs or legacyPackages must be provided";

  pkgsModule = {
    _module.args.pkgs = defaultPkgs;
  };

  eval = lib.evalModules {
    class = "win";
    modules = [ pkgsModule ] ++ baseModules ++ modules;
    specialArgs = {
      modulesPath = builtins.toString ./modules;
    } // specialArgs;
  };
in
{
  inherit (eval) config options;
  inherit eval;
}
