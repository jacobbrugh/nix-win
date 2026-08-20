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

        # Standalone per-user configuration — the home-manager
        # `homeManagerConfiguration` analog. `lib` accepts the consumer's
        # (possibly extended) nixpkgs lib; it is hm-extended internally.
        winHomeConfiguration =
          {
            pkgs,
            modules ? [ ],
            extraSpecialArgs ? { },
            lib ? pkgs.lib,
          }:
          let
            evalResult = import ./eval-home.nix { inherit lib; } {
              inherit modules pkgs;
              specialArgs = extraSpecialArgs;
            };
          in
          {
            inherit (evalResult) config options;
            activationPackage = evalResult.config.home.activationPackage;
          };
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
          #   home.file.".local/bin/nix-win.ps1".source =
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

          # A trivial "installed program" payload. Exercises the packages
          # staging path — which MUST be combined with files entries in the
          # same eval: the packages tree merges over the files tree at
          # toplevel assembly, and a broken merge once silently dropped
          # every package payload while the build stayed green.
          checkPkg = pkgs.runCommand "check-pkg" { } ''
            mkdir -p $out/bin
            echo packaged > $out/bin/check-tool.txt
          '';

          # A directory payload for the directory-source branches of
          # environment.files / home.file.
          checkDir = pkgs.runCommand "check-dir" { } ''
            mkdir -p $out
            echo in-dir > $out/inner.txt
          '';

          # A fake staged-uv package source: an entry shim plus modules the
          # include/exclude filters select between.
          uvToolSrc = pkgs.runCommand "uv-tool-src" { } ''
            mkdir -p $out/eval
            printf '# uv shim\n' > $out/uv_entry.py
            echo core > $out/core.py
            echo extra > $out/extra.py
            echo secret > $out/eval/secret.py
          '';

          # A representative minimal system: exercises the module list, the
          # file tree builder, the packages merge, the activation DAG, and
          # the toplevel assembly.
          minimal = self.lib.winSystem {
            inherit pkgs;
            modules = [
              {
                system.primaryUser = "alice";
                environment.files."nix-win/eval-check.txt".text = "nix-win eval check";
                environment.files."nix-win/check.ps1".text = "Write-Host 'crlf check'";
                environment.files."nix-win/tree".source = checkDir;
                environment.systemPackages = [ checkPkg ];
              }
            ];
          };

          # Minimal per-user configuration: exercises home.file (text +
          # source + executable), home.packages (merged over the files
          # tree), xdg.configFile, sessionPath/-Variables, the activation
          # DAG, and activationPackage assembly.
          homeMinimal = self.lib.winHomeConfiguration {
            inherit pkgs;
            modules = [
              {
                home.username = "alice";
                home.stateVersion = "0.2";
                home.file.".config/nix-win/home-check.txt".text = "winHome eval check";
                home.file."bin/tool.py" = {
                  text = "print('x')";
                  executable = true;
                };
                home.packages = [ checkPkg ];
                xdg.configFile."app/settings.json".text = ''{ "a": 1 }'';
                home.sessionPath = [ "%USERPROFILE%\\.local\\bin" ];
                home.sessionVariables.NIX_WIN_CHECK = "1";
              }
            ];
          };

          # THE home-manager compatibility contract test: a module written
          # in home-manager idiom — custom options, home.file with
          # source/executable, programs.git settings/ignores/attributes,
          # ${config.home.homeDirectory} interpolation, out-of-store links,
          # lib.hm.dag.entryAfter — must evaluate unchanged under winHome,
          # and the rendered artifacts must match expectations.
          hmCompatModule =
            { config, lib, ... }:
            {
              options.programs.check.marker = lib.mkOption {
                type = lib.types.str;
                default = "unset";
              };

              config = {
                programs.check.marker = "set-by-module";

                home.file.".claude/hooks/check-hook.py" = {
                  text = "#!/usr/bin/env python3\nprint('hook')\n";
                  executable = true;
                };

                home.file."AppData/Local/check-link".source =
                  config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.config/check-src";

                programs.git = {
                  enable = true;
                  settings = {
                    user.name = "Alice Example";
                    alias.st = "status";
                  };
                  ignores = [ "*.tmp" ];
                  attributes = [ "* merge=mergiraf" ];
                };

                home.activation.checkEntry = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
                  Write-Host "check: ${config.programs.check.marker} at ${config.home.homeDirectory}"
                '';

                warnings = [ "hm-compat check warning (expected)" ];
                assertions = [
                  {
                    assertion = true;
                    message = "never shown";
                  }
                ];
              };
            };

          # home.stagedUvTools: staging (with both filter modes), launcher
          # emission, PATH entry, warm-up wiring, and the published
          # read-only shimPath.
          stagedUv = self.lib.winHomeConfiguration {
            inherit pkgs;
            modules = [
              {
                home.username = "alice";
                home.stateVersion = "0.2";
                home.stagedUvTools.check-tool = {
                  packages.check_tool = {
                    source = uvToolSrc;
                    exclude = [ "eval" ];
                  };
                  launchers = [
                    "ps1"
                    "bash"
                  ];
                };
                home.stagedUvTools.pick-tool = {
                  packages.pick_tool = {
                    source = uvToolSrc;
                    include = [
                      "uv_entry.py"
                      "core.py"
                    ];
                  };
                  warmup = false;
                };
              }
            ];
          };

          hmCompat = self.lib.winHomeConfiguration {
            inherit pkgs;
            modules = [
              {
                home.username = "alice";
                home.stateVersion = "0.2";
              }
              hmCompatModule
            ];
          };
          # winSystem with an embedded per-user config: the integration
          # module must fold the user's activationPackage into the system
          # toplevel and expose osConfig + the hm-extended lib inside the
          # sub-eval.
          integrated = self.lib.winSystem {
            inherit pkgs;
            modules = [
              {
                system.primaryUser = "alice";
                home-manager.users.alice =
                  {
                    lib,
                    osConfig,
                    ...
                  }:
                  {
                    home.stateVersion = "0.2";
                    home.file.".config/nix-win/integrated-check.txt".text =
                      "primary user is ${toString osConfig.system.primaryUser}";
                    home.packages = [ checkPkg ];
                    home.activation.integratedCheck = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
                      Write-Host "integrated check"
                    '';
                  };
              }
            ];
          };

          # Negative test: a dep naming a non-existent activation entry must
          # fail evaluation with the migration message (not silently reorder).
          depThrowMsg =
            let
              broken = self.lib.winSystem {
                inherit pkgs;
                modules = [
                  {
                    system.primaryUser = "alice";
                    system.activationScripts.custom = {
                      text = "Write-Host x";
                      deps = [ "does-not-exist" ];
                    };
                  }
                ];
              };
              attempt = builtins.tryEval (builtins.seq broken.config.system.build.activationScript.drvPath true);
            in
            attempt;
        in
        {
          # Real evaluation check — building the toplevel forces the whole
          # module system, and the assertions prove the assembled tree
          # actually carries both the files AND the packages payloads (a
          # bare build once passed while the packages merge silently
          # dropped everything).
          eval-minimal =
            pkgs.runCommand "nix-win-eval-minimal"
              {
                top = minimal.config.system.build.toplevel;
              }
              ''
                set -eu
                grep -q 'nix-win eval check' "$top/programdata/nix-win/eval-check.txt"
                grep -q 'packaged' "$top/programdata/nix-win/Programs/check-pkg/bin/check-tool.txt"
                # Directory sources stage whole (the file branch would fail on one)
                grep -q 'in-dir' "$top/programdata/nix-win/tree/inner.txt"
                touch $out
              '';

          eval-home-minimal =
            pkgs.runCommand "nix-win-eval-home-minimal"
              {
                ap = homeMinimal.activationPackage;
              }
              ''
                set -eu
                grep -q 'winHome eval check' "$ap/home/.config/nix-win/home-check.txt"
                [ -x "$ap/home/bin/tool.py" ]
                grep -q 'packaged' "$ap/home/AppData/Local/Programs/check-pkg/bin/check-tool.txt"
                touch $out
              '';

          eval-integrated =
            pkgs.runCommand "nix-win-eval-integrated"
              {
                top = integrated.config.system.build.toplevel;
              }
              ''
                set -eu
                [ -f "$top/users/alice/activate.ps1" ]
                [ -f "$top/users/alice/manifest.json" ]
                grep -q 'primary user is alice' "$top/users/alice/home/.config/nix-win/integrated-check.txt"
                grep -q 'packaged' "$top/users/alice/home/AppData/Local/Programs/check-pkg/bin/check-tool.txt"
                grep -q '"users":\["alice"\]' "$top/manifest.json"
                grep -q '"version":2' "$top/manifest.json"
                grep -q 'integrated check' "$top/users/alice/activate.ps1"
                touch $out
              '';

          eval-dep-throw =
            assert !depThrowMsg.success;
            pkgs.runCommand "nix-win-eval-dep-throw" { } ''
              echo "missing activation dep correctly failed evaluation"
              touch $out
            '';

          eval-hm-compat =
            pkgs.runCommand "nix-win-eval-hm-compat"
              {
                ap = hmCompat.activationPackage;
                homeDir = hmCompat.config.home.homeDirectory;
              }
              ''
                set -eu
                # homeDirectory is forward-slash normalized
                [ "$homeDir" = "C:/Users/alice" ]

                # Staged hook file exists and is executable
                [ -x "$ap/home/.claude/hooks/check-hook.py" ]

                # git config rendered with toGitINI semantics
                grep -q 'name = "Alice Example"' "$ap/home/.config/git/config"
                grep -q 'st = "status"' "$ap/home/.config/git/config"
                grep -qx '\*.tmp' "$ap/home/.config/git/ignore"
                grep -qx '\* merge=mergiraf' "$ap/home/.config/git/attributes"

                # Out-of-store source became a link-manifest entry, not a file
                grep -q '"path":"AppData/Local/check-link"' "$ap/manifest.json"
                grep -q '"source":"C:/Users/alice/.config/check-src"' "$ap/manifest.json"
                [ ! -e "$ap/home/AppData/Local/check-link" ]

                # Activation entry interpolated config values and sorted
                # after writeBoundary
                grep -q 'check: set-by-module at C:/Users/alice' "$ap/activate.ps1"
                wb=$(grep -n 'writeBoundary' "$ap/activate.ps1" | head -1 | cut -d: -f1)
                ce=$(grep -n 'check: set-by-module' "$ap/activate.ps1" | head -1 | cut -d: -f1)
                [ "$wb" -lt "$ce" ]

                touch $out
              '';

          eval-staged-uv =
            pkgs.runCommand "nix-win-eval-staged-uv"
              {
                ap = stagedUv.activationPackage;
                shimPath = stagedUv.config.home.stagedUvTools.check-tool.shimPath;
                command = stagedUv.config.home.stagedUvTools.check-tool.command;
              }
              ''
                set -eu
                # Published read-only values
                [ "$shimPath" = "C:/Users/alice/.local/share/check-tool/check_tool/uv_entry.py" ]
                [ "$command" = "uv run -q --script $shimPath" ]

                # exclude filter: eval/ dropped, everything else staged
                [ -f "$ap/home/.local/share/check-tool/check_tool/uv_entry.py" ]
                [ -f "$ap/home/.local/share/check-tool/check_tool/core.py" ]
                [ -f "$ap/home/.local/share/check-tool/check_tool/extra.py" ]
                [ ! -e "$ap/home/.local/share/check-tool/check_tool/eval" ]

                # include filter: only the allow-list staged
                [ -f "$ap/home/.local/share/pick-tool/pick_tool/uv_entry.py" ]
                [ -f "$ap/home/.local/share/pick-tool/pick_tool/core.py" ]
                [ ! -e "$ap/home/.local/share/pick-tool/pick_tool/extra.py" ]
                [ ! -e "$ap/home/.local/share/pick-tool/pick_tool/eval" ]

                # Launchers: .ps1 is CRLF and targets the shim; the bash
                # launcher is LF with the shebang in the first bytes
                ps1="$ap/home/.local/bin/check-tool.ps1"
                grep -q "uv run -q --script \"$shimPath\"" "$ps1"
                grep -q $'\r' "$ps1"
                sh="$ap/home/.local/bin/check-tool"
                head -c 2 "$sh" | grep -q '#!'
                if grep -q $'\r' "$sh"; then echo "bash launcher has CRLF" >&2; exit 1; fi

                # PATH entry emitted once for the launcher dir
                grep -Fq '%USERPROFILE%' "$ap/environment/user-path.json"

                # Warm-up present for check-tool, absent for pick-tool
                grep -q 'check-tool: warming uv script environment' "$ap/activate.ps1"
                if grep -q 'pick-tool: warming' "$ap/activate.ps1"; then
                  echo "pick-tool warmup should be disabled" >&2; exit 1
                fi

                touch $out
              '';
        }
      );
    };
}
