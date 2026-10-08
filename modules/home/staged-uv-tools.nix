# home.stagedUvTools — run a Nix-built Python tool natively on Windows.
#
# Windows processes (pwsh, cmd.exe, Git Bash, Task Scheduler actions) cannot
# exec a /nix/store path, but the files a Python package installs are plain
# Python. So the tool is staged from its Nix build: the `site-packages` of the
# package and of every Python module in its runtime closure
# (`requiredPythonModules` over its propagatedBuildInputs) are merged into
# `stagingDir`, beside a generated `launch.py` that calls the package's
# `meta.mainProgram` console-script entry point. What runs on Windows is
# exactly what the package's checks ran against; uv only provides the
# CPython, and no dependency list exists to keep in sync with the package.
# The build fails on a native extension, which Windows CPython cannot load.
#
# One tool =
#   * the staged tree + launch.py under `stagingDir`;
#   * optional launchers in ~/.local/bin — a `.ps1` for PowerShell and an
#     extensionless bash-shebang file for Git Bash/MSYS. TWO launchers,
#     because the shells resolve a bare name by incompatible rules and no
#     single file satisfies both: PowerShell appends `.ps1` regardless of
#     PATHEXT and will not exec an extensionless file (to it that is a
#     native binary, and Windows has no kernel shebang support), while Git
#     Bash appends only `.exe`, never consults PATHEXT, and decides a file
#     is executable by reading `#!` from its first two bytes. So `.ps1` is
#     invisible to bash and the shebang file is unrunnable by pwsh;
#   * a durable HKCU PATH entry for ~/.local/bin when any launcher is
#     emitted (home.sessionPath dedupes);
#   * a warm-up activation step that runs the tool once at switch time, so
#     uv's first CPython download never lands inside a live invocation's
#     timeout. A failed warm-up fails the switch.
#
# Forward slashes in the shim path deliberately: they survive POSIX-style
# shell escaping (backslashes are eaten), and pwsh, uv and Python accept
# them natively on Windows.
#
# The computed `shimPath` / `command` values are read-only sub-options so
# other scopes can reference them instead of restating path literals — a
# win-class module reaches them via
# `config.home-manager.users.<name>.home.stagedUvTools.<tool>.command`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.home.stagedUvTools;
  enabled = lib.filterAttrs (_: t: t.enable) cfg;

  stagedUvTree = pkgs.callPackage ../../pkgs/staged-uv-tree/package.nix { };

  # The Windows runtime tree for one tool, built from the package and its
  # Python closure as Nix built them.
  toolTree =
    name: t:
    let
      python = t.python;
      closure = lib.filter (d: d ? pythonModule) (
        python.pkgs.requiredPythonModules (t.package.propagatedBuildInputs or [ ])
      );
      sources = map (d: "${d}/${python.sitePackages}") ([ t.package ] ++ closure);
      mainProgram =
        t.package.meta.mainProgram
          or (throw "home.stagedUvTools.${name}: package ${t.package.name} sets no meta.mainProgram");
      requiresPython = ">=${python.pythonVersion},<${lib.versions.major python.version}.${
        toString (lib.toInt (lib.versions.minor python.version) + 1)
      }";
    in
    pkgs.runCommand "staged-uv-${name}" { nativeBuildInputs = [ stagedUvTree ]; } ''
      staged-uv-tree --out $out \
        --main-program ${lib.escapeShellArg mainProgram} \
        --requires-python ${lib.escapeShellArg requiresPython} \
        ${lib.escapeShellArgs sources}
    '';

  toolModule =
    { name, config, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to stage and wire this tool.";
        };

        package = lib.mkOption {
          type = lib.types.package;
          description = ''
            The Nix-built Python application to stage. Its `site-packages`,
            plus that of every Python module in its runtime closure, is
            staged; `meta.mainProgram` names the console script the
            launcher runs.
          '';
        };

        python = lib.mkOption {
          type = lib.types.package;
          default = pkgs.python312;
          defaultText = lib.literalExpression "pkgs.python312";
          description = ''
            The interpreter the package was built against. Selects the
            `site-packages` layout and the CPython version uv provides.
          '';
        };

        stagingDir = lib.mkOption {
          type = lib.types.str;
          default = ".local/share/${name}";
          description = "Home-relative directory the tree and launch.py are staged under.";
        };

        launchers = lib.mkOption {
          type = lib.types.listOf (
            lib.types.enum [
              "ps1"
              "bash"
            ]
          );
          default = [ ];
          description = ''
            Launchers to emit in ~/.local/bin as `<binName>.ps1` (PowerShell)
            and/or `<binName>` (Git Bash shebang file).

            Emit a launcher only for a shell that invokes the tool by BARE
            NAME. A tool started by absolute path, or spawned by another
            process, needs neither: those callers read `command` / `shimPath`
            instead. Adding a launcher nothing resolves by name costs a file
            on PATH and an entry in every PATH scan for no behaviour.
          '';
        };

        binName = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Basename of the emitted launcher(s).";
        };

        warmup = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Run the staged tool once during home activation (the first cold
            run downloads CPython). A failure fails the switch.
          '';
        };

        warmupArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "--help" ];
          description = "Arguments the warm-up invocation passes to the tool.";
        };

        tree = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          description = "The built runtime tree staged at `stagingDir`.";
        };

        shimPath = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          description = "Absolute forward-slash path of the generated launch.py.";
        };

        command = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          description = ''
            The full `uv run` invocation string for the staged tool (`-q` so
            uv's progress chatter cannot pollute a consumer's stderr).
          '';
        };
      };

      config = {
        tree = toolTree name config;
        shimPath = "${homeDirectory}/${config.stagingDir}/launch.py";
        command = "uv run -q --script ${config.shimPath}";
      };
    };

  homeDirectory = config.home.homeDirectory;

  stagedFiles = lib.mapAttrs' (_: t: lib.nameValuePair t.stagingDir { source = t.tree; }) enabled;

  launcherFiles = lib.concatMapAttrs (
    _: t:
    lib.optionalAttrs (lib.elem "ps1" t.launchers) {
      ".local/bin/${t.binName}.ps1" = {
        text = ''
          # PowerShell hands a script its pipeline input as $input and does
          # NOT connect that to a child process's stdin, so `x | tool` leaves
          # a stdin-reading tool seeing EOF and silently processing nothing.
          # Forward it explicitly. $OutputEncoding governs the bytes handed to
          # the child and is UTF-8 by default in PowerShell 6+; the console's
          # own encoding is not involved on this path.
          if ($MyInvocation.ExpectingInput) {
            $input | & uv run -q --script "${t.shimPath}" @args
          } else {
            & uv run -q --script "${t.shimPath}" @args
          }
          exit $LASTEXITCODE
        '';
        lineEnding = "crlf";
      };
    }
    # `lineEnding = "lf"` is load-bearing: with CRLF the interpreter reads
    # as `/usr/bin/env bash\r` and the exec fails. No `executable = true` —
    # the chmod would run in the Linux-side staging derivation and NTFS has
    # no permission bit for it to survive into; MSYS infers the exec bit
    # from the `#!` magic bytes, which is what actually carries this.
    // lib.optionalAttrs (lib.elem "bash" t.launchers) {
      ".local/bin/${t.binName}" = {
        text = ''
          #!/usr/bin/env bash
          exec uv run -q --script "${t.shimPath}" "$@"
        '';
        lineEnding = "lf";
      };
    }
  ) enabled;

  warmupTools = lib.filterAttrs (_: t: t.warmup) enabled;
  warmupEntry = name: "stagedUvTools-${name}-warmup";
in
{
  options.home.stagedUvTools = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule toolModule);
    default = { };
    description = "Nix-built Python tools staged under the profile and run natively via uv.";
  };

  config = lib.mkIf (enabled != { }) {
    home.file = stagedFiles // launcherFiles;

    home.sessionPath = lib.mkIf (lib.any (t: t.launchers != [ ]) (lib.attrValues enabled)) [
      "%USERPROFILE%\\.local\\bin"
    ];

    # Each warm-up records its failure and lets the rest run, so one switch
    # reports every broken tool; the verdict then fails the activation.
    home.activation =
      lib.mapAttrs' (
        name: t:
        lib.nameValuePair (warmupEntry name) (
          lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            if (-not (Test-Path variable:script:NixWinStagedUvFailures)) {
              $script:NixWinStagedUvFailures = [System.Collections.Generic.List[string]]::new()
            }
            Write-Host "${name}: warming uv script environment..." -ForegroundColor Cyan
            $stagedUvWarmup = & uv run -q --script "${t.shimPath}" ${lib.concatStringsSep " " t.warmupArgs} 2>&1
            if ($LASTEXITCODE -ne 0) {
              $script:NixWinStagedUvFailures.Add("${name}: exited $LASTEXITCODE`n$($stagedUvWarmup | Out-String)")
            }
          ''
        )
      ) warmupTools
      // lib.optionalAttrs (warmupTools != { }) {
        stagedUvTools-verdict = lib.hm.dag.entryAfter (map warmupEntry (lib.attrNames warmupTools)) ''
          if ((Test-Path variable:script:NixWinStagedUvFailures) -and $script:NixWinStagedUvFailures.Count -gt 0) {
            throw "staged uv tool warm-up failed:`n$($script:NixWinStagedUvFailures -join "`n")"
          }
        '';
      };
  };
}
