# Core of the winHome class: user identity, the internal build slots the
# sibling modules fill in, and the assembly of home.activationPackage — the
# per-user analog of system.build.toplevel. Everything in this class is
# deployable WITHOUT elevation: home files, junctions, HKCU environment,
# user activation snippets.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.home;

  manifest = {
    version = 2;
    scope = "home";
    username = cfg.username;
    stateVersion = cfg.stateVersion;
    files = config.home.build.fileManifest;
    links = config.home.build.linkManifest;
  };

  manifestJson = pkgs.writeText "manifest.json" (builtins.toJSON manifest);

  failedAssertions = map (x: x.message) (lib.filter (x: !x.assertion) config.assertions);

  guard =
    drv:
    if failedAssertions != [ ] then
      throw "\nFailed assertions:\n${lib.concatStringsSep "\n" (map (x: "- ${x}") failedAssertions)}"
    else
      lib.showWarnings config.warnings drv;
in
{
  options.home = {
    username = lib.mkOption {
      type = lib.types.str;
      example = "alice";
      description = "The Windows account name.";
    };

    homeDirectory = lib.mkOption {
      type = lib.types.str;
      apply = p: builtins.replaceStrings [ "\\" ] [ "/" ] p;
      defaultText = lib.literalExpression ''"C:/Users/''${config.home.username}"'';
      description = ''
        Absolute Windows path to the home directory, normalized to
        forward slashes (a deliberate deviation from home-manager's
        `types.path`, which cannot hold a Windows path). Forward slashes
        are load-bearing: values interpolated into configs frequently
        pass through POSIX-style shells that eat backslashes, and
        Windows APIs accept forward slashes natively.

        Deployment never consumes this value — files are keyed by
        home-relative targets and the CLI resolves the root from
        `$env:USERPROFILE`. It exists for interpolation.
      '';
    };

    stateVersion = lib.mkOption {
      type = lib.types.str;
      example = "0.2";
      description = "winHome state version, for future migration logic.";
    };

    activationPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = ''
        The per-user toplevel: activation script, manifest, staged home
        file tree, and environment artifacts. Applied by
        `nix-win switch -Home` (standalone) or embedded under
        `users/<name>/` in the system toplevel (integrated).
      '';
    };

    build = {
      activationScript = lib.mkOption {
        type = lib.types.package;
        internal = true;
        description = "The assembled per-user PowerShell activation script.";
      };

      files = lib.mkOption {
        type = lib.types.package;
        internal = true;
        description = "Staged home file tree (under home/).";
      };

      fileManifest = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        internal = true;
        default = [ ];
      };

      linkManifest = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        internal = true;
        default = [ ];
      };

      packagesTree = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        internal = true;
        default = null;
        description = "Staged home.packages tree (under home/), merged over the files tree.";
      };

      environmentConfigs = lib.mkOption {
        type = lib.types.attrsOf lib.types.package;
        internal = true;
        default = { };
        description = "name → JSON artifact, copied to environment/<name>.json.";
      };
    };
  };

  config = {
    home.homeDirectory = lib.mkDefault "C:/Users/${cfg.username}";

    home.activationPackage = guard (
      pkgs.runCommand "win-home" { } ''
        mkdir -p $out

        cp ${cfg.build.activationScript} $out/activate.ps1
        cp ${manifestJson} $out/manifest.json

        if [ -d "${cfg.build.files}" ] && [ "$(ls -A ${cfg.build.files})" ]; then
          cp -r ${cfg.build.files}/* $out/ 2>/dev/null || true
        fi

        ${lib.optionalString (cfg.build.packagesTree != null) ''
          if [ -d "${cfg.build.packagesTree}" ] && [ "$(ls -A ${cfg.build.packagesTree})" ]; then
            cp -r ${cfg.build.packagesTree}/* $out/ 2>/dev/null || true
          fi
        ''}

        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: drv: ''
            mkdir -p $out/environment
            cp ${drv} $out/environment/${name}.json
          '') cfg.build.environmentConfigs
        )}
      ''
    );
  };
}
