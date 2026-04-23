{
  description = "Smoke test for nix-win's buildWindowsRustPackage helper";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-win.url = "path:../..";
    nix-win.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, nix-win }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      buildRust = nix-win.lib.${system}.buildWindowsRustPackage;
    in
    {
      packages.${system}.default = buildRust {
        pname = "rust-hello";
        version = "0.1.0";
        src = ./.;
        cargoLock.lockFile = ./Cargo.lock;
      };
    };
}
