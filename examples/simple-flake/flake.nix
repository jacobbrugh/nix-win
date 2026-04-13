# Minimal nix-win consumer flake.
#
# Evaluate:
#   nix eval .#winConfigurations.example.config.win.user.name
#
# Apply (from PowerShell on Windows, inside a checkout that contains this flake):
#   ./pkgs/nix-win/nix-win.ps1 switch -FlakeUri path:<wsl-path-to-this-flake>
{
  description = "Minimal nix-win example configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-win.url = "github:jacobbrugh/nix-win";
    nix-win.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, nix-win }:
    {
      winConfigurations.example = nix-win.lib.winSystem {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;

        modules = [
          (
            { ... }:
            {
              win.user.name = "alice";

              win.scoop.enable = true;
              win.scoop.buckets = {
                main = "https://github.com/ScoopInstaller/Main";
              };
              win.scoop.packages = {
                git = { bucket = "main"; };
                ripgrep = { bucket = "main"; };
                fzf = { bucket = "main"; };
              };
            }
          )
        ];
      };
    };
}
