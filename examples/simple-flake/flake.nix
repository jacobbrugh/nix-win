# Minimal nix-win consumer flake.
#
# Evaluate:
#   nix eval .#winConfigurations.example.config.system.primaryUser
#
# Apply (from PowerShell on Windows, inside a checkout that contains this flake):
#   ./pkgs/nix-win/nix-win.ps1 switch -FlakeUri path:<wsl-path-to-this-flake>
#   ./pkgs/nix-win/nix-win.ps1 switch -Home   # per-user scope, no admin
{
  description = "Minimal nix-win example configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-win.url = "github:jacobbrugh/nix-win";
    nix-win.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, nix-win }:
    let
      # A per-user (winHome) module written in home-manager idiom — the same
      # shapes evaluate under home-manager on other platforms.
      homeModule =
        { config, ... }:
        {
          home.stateVersion = "0.2";

          home.file.".gitmessage".text = "";
          programs.git = {
            enable = true;
            settings.user.name = "Alice Example";
          };
          home.sessionPath = [ "%USERPROFILE%\\.local\\bin" ];
        };
    in
    {
      winConfigurations.example = nix-win.lib.winSystem {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;

        modules = [
          (
            { ... }:
            {
              system.primaryUser = "alice";

              scoop.enable = true;
              scoop.buckets = {
                main = "https://github.com/ScoopInstaller/Main";
              };
              scoop.packages = {
                git = { bucket = "main"; };
                ripgrep = { bucket = "main"; };
                fzf = { bucket = "main"; };
              };

              # Embed the per-user scope home-manager-style; applied by an
              # elevated `nix-win switch` after the system phases.
              home-manager.users.alice = homeModule;
            }
          )
        ];
      };

      # The same per-user config as a standalone output, applied WITHOUT
      # admin via `nix-win switch -Home`.
      winHomeConfigurations."alice@example" = nix-win.lib.winHomeConfiguration {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        modules = [
          homeModule
          { home.username = "alice"; }
        ];
      };
    };
}
