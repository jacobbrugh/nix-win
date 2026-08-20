# home.stagedUvTools — run a Nix-built Python tool natively on Windows.
#
# A buildPythonApplication is a Linux derivation in the WSL store; Windows
# processes (pwsh, cmd.exe, Git Bash, Task Scheduler actions) cannot exec a
# /nix/store path. The portable shape is to stage the package's *source*
# tree under the profile and drive its uv_entry.py shim through
# `uv run --script`: uv provisions CPython and the shim's PEP 723
# dependencies itself, so no Windows Python install is needed.
#
# One tool =
#   * one or more package source trees staged as SIBLINGS under
#     `stagingDir` (a shim that sys.path-inserts its parent directory can
#     import a sibling package, e.g. an app plus its shared library);
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
#   * a warm-up activation step so uv's first cold run (CPython download +
#     wheel resolution) happens at switch time, not inside a live
#     invocation's timeout. Doubles as a deploy-time smoke test.
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

  # Apply a tool package's include/exclude filter, if any. `include` is an
  # allow-list of paths relative to the source root (files or directories);
  # `exclude` is a list of relative paths to drop. Filtering happens in a
  # tiny staging derivation so the staged home.file directory source is
  # exactly the filtered tree.
  filteredSource =
    pkgName: p:
    if p.include == null && p.exclude == [ ] then
      p.source
    else if p.include != null then
      pkgs.runCommand "staged-uv-${pkgName}-src" { } ''
        mkdir -p $out
        cd ${lib.escapeShellArg "${p.source}"}
        cp -rL --no-preserve=mode --parents -t $out ${lib.escapeShellArgs p.include}
      ''
    else
      pkgs.runCommand "staged-uv-${pkgName}-src" { } ''
        cp -rL --no-preserve=mode ${lib.escapeShellArg "${p.source}"} $out
        chmod -R u+w $out
        rm -rf ${lib.concatMapStringsSep " " (e: "$out/${lib.escapeShellArg e}") p.exclude}
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

        stagingDir = lib.mkOption {
          type = lib.types.str;
          default = ".local/share/${name}";
          description = ''
            Home-relative directory the package source trees are staged
            under (one subdirectory per `packages` entry).
          '';
        };

        packages = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                source = lib.mkOption {
                  type = lib.types.path;
                  description = ''
                    Source tree of the Python package (the directory that
                    contains the modules, e.g. "''${pkg.src}/src/<package>"),
                    staged to `<stagingDir>/<attr name>/`.
                  '';
                };
                include = lib.mkOption {
                  type = lib.types.nullOr (lib.types.listOf lib.types.str);
                  default = null;
                  description = ''
                    Allow-list of source-relative paths to stage; everything
                    else is dropped. Mutually exclusive with `exclude`.
                  '';
                };
                exclude = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Source-relative paths to drop from the staging.";
                };
              };
            }
          );
          description = "Package source trees staged as siblings under `stagingDir`.";
        };

        entryPackage = lib.mkOption {
          type = lib.types.str;
          default =
            let
              names = lib.attrNames config.packages;
            in
            if lib.length names == 1 then lib.head names else name;
          defaultText = lib.literalExpression "the sole packages entry, else the tool name";
          description = "The `packages` entry whose uv_entry.py is the tool's shim.";
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
            Warm uv's script environment during home activation (first cold
            run downloads CPython and the shim's wheels) and smoke-test the
            staged tool.
          '';
        };

        warmupArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "--help" ];
          description = "Arguments the warm-up invocation passes to the shim.";
        };

        shimPath = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          description = "Absolute forward-slash path of the staged uv_entry.py shim.";
        };

        command = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          description = ''
            The full `uv run` invocation string for the staged shim (`-q` so
            uv's progress chatter cannot pollute a consumer's stderr).
          '';
        };
      };

      config = {
        shimPath = "${homeDirectory}/${config.stagingDir}/${config.entryPackage}/uv_entry.py";
        command = "uv run -q --script ${config.shimPath}";
      };
    };

  homeDirectory = config.home.homeDirectory;

  stagedFiles = lib.concatMapAttrs (
    _: t:
    lib.mapAttrs' (
      pkgName: p: lib.nameValuePair "${t.stagingDir}/${pkgName}" { source = filteredSource pkgName p; }
    ) t.packages
  ) enabled;

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

    home.activation = lib.mapAttrs' (
      name: t:
      lib.nameValuePair "stagedUvTools-${name}-warmup" (
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          Write-Host "${name}: warming uv script environment..." -ForegroundColor Cyan
          $stagedUvWarmup = & uv run -q --script "${t.shimPath}" ${lib.concatStringsSep " " t.warmupArgs} 2>&1
          if ($LASTEXITCODE -ne 0) {
            Write-Warning "${name}: uv warm-up exited $LASTEXITCODE : $stagedUvWarmup"
          }
        ''
      )
    ) warmupTools;
  };
}
