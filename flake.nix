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
      lib = {
        winSystem =
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
      }
      # Per-system helpers. Exposes the Rust cross-compile wrapper so
      # consumer flakes can build Windows binaries from their own
      # derivations:
      #
      #   inputs.nix-win.lib.${system}.buildWindowsRustPackage {
      #     pname = "foo"; version = "0.1.0"; src = ./.;
      #     cargoHash = lib.fakeHash;
      #   };
      //
      forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          winLib = import ./lib { inherit lib pkgs; };
        in
        {
          inherit (winLib) buildWindowsRustPackage buildWindowsCraneDepsOnly buildWindowsCranePackage;
        }
      );

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
          # The nix-win CLI as a plain file derivation: the .ps1 copied
          # into the Nix store at a stable name. Dotfiles repos can pin
          # the upstream CLI instead of vendoring a copy:
          #   win.files.".local/bin/nix-win.ps1".source =
          #     "''${inputs.nix-win.packages.''${system}.nix-win}/nix-win.ps1";
          nix-win = pkgs.runCommand "nix-win-cli" { } ''
            mkdir -p $out
            cp ${./pkgs/nix-win/nix-win.ps1} $out/nix-win.ps1
          '';

          # Regenerate all generated DSC modules in one shot.
          # After running: cp -r result/* modules/dsc/generated/
          generate-dsc-modules = gens.generateAll;
        }
      );

      # `nix run github:jacobbrugh/nix-win -- <command>` shells out to
      # pwsh.exe (from WSL) or pwsh (from native) and runs the CLI. Mirrors
      # the `nix run github:LnL7/nix-darwin` entry point so nothing has to
      # be installed locally to drive nix-win.
      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          launcher = pkgs.writeShellScript "nix-win" ''
            script="${./pkgs/nix-win/nix-win.ps1}"
            if command -v pwsh.exe >/dev/null 2>&1; then
                exec pwsh.exe -File "$script" "$@"
            elif command -v pwsh >/dev/null 2>&1; then
                exec pwsh -File "$script" "$@"
            else
                echo "nix-win: no pwsh.exe or pwsh on PATH; run the script directly:" >&2
                echo "  pwsh $script <command>" >&2
                exit 127
            fi
          '';
          app = {
            type = "app";
            program = "${launcher}";
          };
        in
        {
          nix-win = app;
          default = app;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # A representative minimal system: exercises the module list, the
          # file tree builder, the activation DAG, and the toplevel assembly.
          minimal = self.lib.winSystem {
            inherit pkgs;
            modules = [
              {
                win.user.name = "alice";
                win.files.".config/nix-win/eval-check.txt".text = "nix-win eval check";
                win.files."Documents/PowerShell/check.ps1".text = "Write-Host 'crlf check'";
              }
            ];
          };
        in
        {
          # Real evaluation check — building the toplevel forces the whole
          # module system, not just an echo.
          eval-minimal = minimal.config.system.build.toplevel;
        }
      );
    };
}
