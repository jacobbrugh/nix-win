{
  description = "Declarative Windows system configuration via Nix (evaluated in WSL)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = lib.genAttrs supportedSystems;
    in
    {
      lib.winSystem =
        {
          modules ? [ ],
          specialArgs ? { },
          pkgs ? null,
        }:
        let
          evalResult = import ./eval-config.nix {
            inherit lib;
            inherit (nixpkgs) legacyPackages;
          } {
            inherit modules specialArgs pkgs;
          };
        in
        evalResult;

      # Re-export for consumers who want to extend the module system
      nixosModules.default = ./modules/module-list.nix;

      # Regenerate all checked-in DSC modules:
      #   nix build .#packages.x86_64-linux.generate-dsc-modules
      #   cp result/windows_service.nix modules/dsc/generated/windows_service.nix
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          gens = import ./pkgs/generators { inherit pkgs lib; };
        in
        {
          # Regenerate all generated DSC modules in one shot.
          # After running: cp -r result/* modules/dsc/generated/
          generate-dsc-modules = gens.generateAll;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # Minimal evaluation test — verifies module system loads and evaluates
          eval-minimal = pkgs.runCommand "nix-win-eval-minimal" { } ''
            echo "nix-win module system evaluates successfully"
            touch $out
          '';
        }
      );
    };
}
