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

          # The scheduledTasks.<name>.hideConsole launcher, for
          # tests/run-hidden-live.ps1 on a Windows host.
          run-hidden = pkgs.callPackage ./pkgs/run-hidden/package.nix { };
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

          # Real Python packages for home.stagedUvTools: a library, an app
          # that imports it through a console script, and an app whose
          # closure carries a native extension (markupsafe's _speedups).
          py = pkgs.python312Packages;
          fixtureSrc =
            name: files:
            pkgs.runCommand "${name}-src" { } (
              ''
                mkdir -p $out
              ''
              + lib.concatStrings (
                lib.mapAttrsToList (path: text: ''
                  mkdir -p "$out/$(dirname ${path})"
                  cp ${pkgs.writeText (baseNameOf path) text} "$out/${path}"
                '') files
              )
            );
          fixturePyproject = name: scripts: ''
            [project]
            name = "${name}"
            version = "0.1.0"
            ${scripts}
            [build-system]
            requires = ["setuptools"]
            build-backend = "setuptools.build_meta"
          '';
          checkLib = py.buildPythonPackage {
            pname = "check-lib";
            version = "0.1.0";
            pyproject = true;
            build-system = [ py.setuptools ];
            src = fixtureSrc "check-lib" {
              "pyproject.toml" = fixturePyproject "check-lib" "";
              "check_lib/__init__.py" = "def greet() -> str:\n    return 'staged-ok'\n";
            };
          };
          mkCheckApp =
            pname: deps:
            py.buildPythonApplication {
              inherit pname;
              version = "0.1.0";
              pyproject = true;
              build-system = [ py.setuptools ];
              dependencies = deps;
              src = fixtureSrc pname {
                "pyproject.toml" = fixturePyproject pname ''
                  [project.scripts]
                  ${pname} = "check_tool.cli:main"
                '';
                "check_tool/__init__.py" = "";
                "check_tool/cli.py" =
                  "import check_lib\n\ndef main() -> int:\n    print(check_lib.greet())\n    return 0\n";
              };
              meta.mainProgram = pname;
            };
          checkTool = mkCheckApp "check-tool" [ checkLib ];
          nativeTool = mkCheckApp "native-tool" [
            checkLib
            py.markupsafe
          ];

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

                home.file.".config/check/check-hook.py" = {
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

          # home.stagedUvTools: the package's closure staged from its Nix
          # build, the generated launcher, launchers, PATH entry, warm-up
          # wiring and verdict, and the published read-only shimPath.
          stagedUv = self.lib.winHomeConfiguration {
            inherit pkgs;
            modules = [
              {
                home.username = "alice";
                home.stateVersion = "0.2";
                home.stagedUvTools.check-tool = {
                  package = checkTool;
                  launchers = [
                    "ps1"
                    "bash"
                  ];
                };
                home.stagedUvTools.quiet-tool = {
                  package = checkTool;
                  warmup = false;
                };
              }
            ];
          };

          # A closure carrying a native extension cannot be staged.
          stagedUvNative = self.lib.winHomeConfiguration {
            inherit pkgs;
            modules = [
              {
                home.username = "alice";
                home.stateVersion = "0.2";
                home.stagedUvTools.native-tool.package = nativeTool;
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

          # A system that declares one of everything the removal machinery
          # tracks, so the checks can assert what each generation records
          # about itself for the NEXT activation to diff against.
          removalFixture = self.lib.winSystem {
            inherit pkgs;
            modules = [
              {
                system.primaryUser = "alice";
                scheduledTasks."Check Task" = {
                  command = "powershell.exe";
                  runAtLogon = true;
                };
                scheduledTasks."Hidden Task" = {
                  command = "powershell.exe";
                  arguments = "-NoProfile -File C:\\check.ps1";
                  hideConsole = true;
                  runAtLogon = true;
                  restartTriggers = [ "check-payload" ];
                };
                # Every schedule trigger kind but the daily one, together.
                scheduledTasks."Watchdog Task" = {
                  command = "powershell.exe";
                  hideConsole = true;
                  runAtLogon = true;
                  startInterval = 60;
                  runAtUnlock = true;
                  multipleInstances = "IgnoreNew";
                };
                scoop.enable = true;
                scoop.buckets.main = "https://example.com/main";
                scoop.packages.check-app = {
                  bucket = "main";
                  version = "1.0.0";
                  beforeInstall = "Write-Host before-install-marker";
                };
                scoop.packages.plain-app.bucket = "main";
                networking.firewall.allowedTCPPorts = [ 22 ];
                networking.hosts."192.0.2.1" = [ "check.example" ];
                system.convergeScripts."Check Converge" = {
                  testScript = "return $true";
                  setScript = "Write-Host set";
                  unsetScript = "Write-Host 'unset-marker'";
                };
                system.convergeScripts."Disabled Converge" = {
                  enable = false;
                  testScript = "return $true";
                  setScript = "Write-Host set";
                };
                dsc.enable = true;
                dsc.resource."Microsoft.Windows/Registry" = {
                  "Set A Value" = {
                    keyPath = "HKLM\\SOFTWARE\\Check";
                    valueName = "Enabled";
                    valueData.DWord = 1;
                  };
                  "Delete A Value" = {
                    keyPath = "HKCU\\Software\\Check";
                    valueName = "Gone";
                    _exist = false;
                  };
                  "Delete A Key" = {
                    keyPath = "HKLM\\SOFTWARE\\CheckGone";
                    _exist = false;
                  };
                };
                dsc.registryOriginals = [
                  {
                    keyPath = "HKLM\\SOFTWARE\\Check";
                    valueName = "Enabled";
                    valueData.DWord = 0;
                  }
                  {
                    keyPath = "HKLM\\SOFTWARE\\Check";
                    valueName = "WasAbsent";
                  }
                ];
              }
            ];
          };

          # A per-user configuration that declares no session PATH entries or
          # variables: the steps that take previously-managed entries back
          # out must still be emitted.
          homeBare = self.lib.winHomeConfiguration {
            inherit pkgs;
            modules = [
              {
                home.username = "alice";
                home.stateVersion = "0.2";
              }
            ];
          };

          # programs.komorebi with and without a relaunch task.
          homeKomorebi =
            relaunchTask:
            self.lib.winHomeConfiguration {
              inherit pkgs;
              modules = [
                {
                  home.username = "alice";
                  home.stateVersion = "0.2";
                  programs.komorebi = {
                    enable = true;
                    configText = "{}";
                    inherit relaunchTask;
                  };
                }
              ];
            };

          # Run a PowerShell test script inside the build sandbox.
          pwshCheck =
            name: script: args:
            pkgs.runCommand name { nativeBuildInputs = [ pkgs.powershell ]; } ''
              export HOME=$TMPDIR
              export POWERSHELL_TELEMETRY_OPTOUT=1
              export DOTNET_CLI_TELEMETRY_OPTOUT=1
              pwsh -NoProfile -NonInteractive -File ${script} ${lib.escapeShellArgs args}
              touch $out
            '';

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

          # Removal works by diffing the previous generation's artifacts
          # against the new ones, so every generation has to carry them and
          # every removal step has to be emitted — INCLUDING for a
          # configuration that declares none of the things involved. Gating
          # either on "non-empty" is the bug where removing the last task
          # (rule, host, script, registry value) never cleans it up.
          eval-removal =
            pkgs.runCommand "nix-win-eval-removal"
              {
                nativeBuildInputs = [ pkgs.jq ];
                bare = minimal.config.system.build.toplevel;
                full = removalFixture.config.system.build.toplevel;
                homeBare = homeBare.activationPackage;
              }
              ''
                set -eu

                # A configuration that declares nothing still records "nothing".
                [ "$(cat "$bare/scheduled-tasks/tasks.json")" = "[]" ]
                [ "$(cat "$bare/firewall/rules.json")" = "[]" ]
                [ "$(cat "$bare/networking/hosts.json")" = "[]" ]
                [ "$(cat "$bare/converge-scripts/scripts.json")" = "[]" ]
                grep -q '"values":\[\]' "$bare/dsc/registry-values.json"

                # ...and still runs every removal step.
                grep -Fq "Get-NixWinRemoved -RelPath 'scheduled-tasks', 'tasks.json'" "$bare/activate.ps1"
                grep -Fq "Get-NixWinRemoved -RelPath 'firewall', 'rules.json'" "$bare/activate.ps1"
                grep -Fq "Get-NixWinRemoved -RelPath 'networking', 'hosts.json'" "$bare/activate.ps1"
                grep -Fq "Get-NixWinRemoved -RelPath 'converge-scripts', 'scripts.json'" "$bare/activate.ps1"
                grep -q 'Invoke-NixWinRegistryBaseline -Spec' "$bare/activate.ps1"
                grep -q '^function Get-NixWinRegistryPlan' "$bare/activate.ps1"
                grep -q 'Write-NixWinRemovalWarnings$' "$bare/activate.ps1"

                # The registry baseline has to run before the dsc phase
                # overwrites the values it records.
                rb=$(grep -n '^# ── registryBaseline ' "$bare/activate.ps1" | cut -d: -f1)
                dsc=$(grep -n '^# ── dsc ' "$bare/activate.ps1" | cut -d: -f1)
                [ "$rb" -lt "$dsc" ]

                # What a generation records about what it declared.
                grep -q '"name":"Check Task"' "$full/scheduled-tasks/tasks.json"
                # hideConsole: the launcher is recorded beside the declared
                # command (which stays as declared), and it is staged.
                grep -q '"hideConsoleLauncher":"nix-win/Programs/run-hidden/bin/run-hidden.exe"' "$full/scheduled-tasks/tasks.json"
                grep -q '"hideConsoleLauncher":null' "$full/scheduled-tasks/tasks.json"
                grep -q '"command":"powershell.exe"' "$full/scheduled-tasks/tasks.json"
                [ -s "$full/programdata/nix-win/Programs/run-hidden/bin/run-hidden.exe" ]
                # ...and only when a task asks for it.
                if [ -e "$bare/programdata/nix-win/Programs/run-hidden" ]; then
                  echo "launcher staged with no hideConsole task" >&2; exit 1
                fi
                grep -q 'function Get-NixWinTaskAction' "$full/activate.ps1"
                # Schedule triggers combine.
                jq -e '.[] | select(.name == "Watchdog Task")
                  | .runAtLogon == true and .startInterval == 60 and .runAtUnlock == true' \
                  "$full/scheduled-tasks/tasks.json" > /dev/null
                # A restarted task is held, disabled, until the CLI has applied
                # the home scope; a disabled task is not converged; a
                # hideConsole instance is stopped through its launcher.
                grep -Fq 'NIX_WIN_DEFERRED_TASK_STARTS' "$full/activate.ps1"
                grep -Fq 'Disable-ScheduledTask' "$full/activate.ps1"
                grep -Fq 'Settings.Enabled -ne $true' "$full/activate.ps1"
                grep -Fq -e "-ieq 'run-hidden.exe'" "$full/activate.ps1"
                # scoop beforeInstall is recorded only where set, and run.
                jq -e '.apps[] | select(.Name == "check-app")
                  | .BeforeInstall == "Write-Host before-install-marker"' \
                  "$full/scoop/scoopfile.json" > /dev/null
                jq -e '.apps[] | select(.Name == "plain-app") | has("BeforeInstall") | not' \
                  "$full/scoop/scoopfile.json" > /dev/null
                grep -Fq "beforeInstall" "$full/activate.ps1"
                grep -q '"name":"nix-win-allow-tcp-22"' "$full/firewall/rules.json"
                grep -q '"name":"check.example"' "$full/networking/hosts.json"
                grep -q '"name":"Check Converge"' "$full/converge-scripts/scripts.json"
                grep -q "unset-marker" "$full/converge-scripts/scripts.json"
                # A disabled entry is not in the generation: disabling it is
                # removing it.
                if grep -q 'Disabled Converge' "$full/converge-scripts/scripts.json"; then
                  echo "disabled converge script recorded as declared" >&2; exit 1
                fi

                rv="$full/dsc/registry-values.json"
                grep -q '"data":1,"keyPath":"HKLM\\\\SOFTWARE\\\\Check","kind":"DWord","valueName":"Enabled"' "$rv"
                grep -q '"absent":true,"keyPath":"HKCU\\\\Software\\\\Check","valueName":"Gone"' "$rv"
                grep -q '"keyDeletes":\["HKLM\\\\SOFTWARE\\\\CheckGone"\]' "$rv"
                grep -q '"data":0,"keyPath":"HKLM\\\\SOFTWARE\\\\Check","kind":"DWord","valueName":"Enabled"' "$rv"
                grep -q '"absent":true,"keyPath":"HKLM\\\\SOFTWARE\\\\Check","valueName":"WasAbsent"' "$rv"

                # The per-user session steps, with nothing declared.
                [ "$(cat "$homeBare/environment/user-path.json")" = "[]" ]
                [ "$(cat "$homeBare/environment/session-variables.json")" = "{}" ]
                grep -q 'environment\\user-path.json' "$homeBare/activate.ps1"
                grep -q 'environment\\session-variables.json' "$homeBare/activate.ps1"

                touch $out
              '';

          # PowerShell's own parser over the generated activation scripts
          # (system, with every removal step populated; home) and over the
          # sources that ship as-is.
          parse-powershell = pwshCheck "nix-win-parse-powershell" ./tests/parse.ps1 [
            "${removalFixture.config.system.build.toplevel}/activate.ps1"
            "${minimal.config.system.build.toplevel}/activate.ps1"
            "${homeMinimal.activationPackage}/activate.ps1"
            "${homeBare.activationPackage}/activate.ps1"
            "${stagedUv.activationPackage}/activate.ps1"
            "${(homeKomorebi null).activationPackage}/activate.ps1"
            "${(homeKomorebi "Check Launcher").activationPackage}/activate.ps1"
            "${./pkgs/nix-win/nix-win.ps1}"
            "${./lib/removal-prelude.ps1}"
            "${./lib/registry-baseline.ps1}"
          ];

          # The removal helpers against fixture generations: empty array,
          # single element, missing artifact, case difference, failures.
          removal-logic = pwshCheck "nix-win-removal-logic" ./tests/removal-logic.ps1 [
            "-Prelude"
            "${./lib/removal-prelude.ps1}"
          ];

          # The registry baseline's decision function, one case per row of
          # its capture and release tables.
          registry-plan = pwshCheck "nix-win-registry-plan" ./tests/registry-plan.ps1 [
            "-Prelude"
            "${./lib/registry-baseline.ps1}"
          ];

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

          # komorebi reloads its own config, so without a relaunch task
          # activation runs no komorebic command; with one, it relaunches.
          eval-komorebi =
            pkgs.runCommand "nix-win-eval-komorebi"
              {
                plain = (homeKomorebi null).activationPackage;
                relaunch = (homeKomorebi "Check Launcher").activationPackage;
              }
              ''
                set -eu
                if grep -q 'komorebic' "$plain/activate.ps1"; then
                  echo "komorebic run without a relaunch task" >&2; exit 1
                fi
                grep -Fq 'komorebic stop --bar' "$relaunch/activate.ps1"
                grep -Fq 'Start-ScheduledTask -TaskName "Check Launcher"' "$relaunch/activate.ps1"
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
                [ -x "$ap/home/.config/check/check-hook.py" ]

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
                [ "$shimPath" = "C:/Users/alice/.local/share/check-tool/launch.py" ]
                [ "$command" = "uv run -q --script $shimPath" ]

                # The app and its dependency, from their Nix builds, beside
                # the generated launcher; uv resolves nothing.
                tree="$ap/home/.local/share/check-tool"
                [ -f "$tree/check_tool/cli.py" ]
                [ -f "$tree/check_lib/__init__.py" ]
                grep -q '# dependencies = \[\]' "$tree/launch.py"
                grep -q "import_module('check_tool.cli')" "$tree/launch.py"
                [ "$(${pkgs.python312}/bin/python3 -I "$tree/launch.py")" = "staged-ok" ]

                # Launchers: .ps1 is CRLF and targets the shim; the bash
                # launcher is LF with the shebang in the first bytes
                ps1="$ap/home/.local/bin/check-tool.ps1"
                grep -q "uv run -q --script \"$shimPath\"" "$ps1"
                grep -q $'\r' "$ps1"
                # Pipeline input must reach the child: a .ps1 receives it as
                # $input and PowerShell does not wire that to child stdin.
                grep -q 'MyInvocation.ExpectingInput' "$ps1"
                grep -q '$input | &' "$ps1"
                sh="$ap/home/.local/bin/check-tool"
                head -c 2 "$sh" | grep -q '#!'
                if grep -q $'\r' "$sh"; then echo "bash launcher has CRLF" >&2; exit 1; fi

                # PATH entry emitted once for the launcher dir
                grep -Fq '%USERPROFILE%' "$ap/environment/user-path.json"

                # Warm-up present for check-tool, absent for quiet-tool, and
                # a failed warm-up fails the activation.
                grep -q 'check-tool: warming uv script environment' "$ap/activate.ps1"
                if grep -q 'quiet-tool: warming' "$ap/activate.ps1"; then
                  echo "quiet-tool warmup should be disabled" >&2; exit 1
                fi
                grep -q 'throw "staged uv tool warm-up failed' "$ap/activate.ps1"

                touch $out
              '';

          staged-uv-native-fails =
            let
              failed = pkgs.testers.testBuildFailure stagedUvNative.config.home.stagedUvTools.native-tool.tree;
            in
            pkgs.runCommand "nix-win-staged-uv-native-fails" { } ''
              grep -q 'native extensions cannot run on Windows CPython' ${failed}/testBuildFailure.log
              grep -q 'markupsafe/_speedups' ${failed}/testBuildFailure.log
              touch $out
            '';

          staged-uv-tree = pkgs.callPackage ./pkgs/staged-uv-tree/package.nix { };
        }
      );
    };
}
