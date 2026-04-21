# Scoop package manager module for nix-win.
# Mirrors nix-darwin's Homebrew module: declare packages → generate scoopfile.json → import on activation.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.win.scoop;

  # Generate scoopfile.json matching Scoop's import format.
  # `scoop import` honors the Version field by passing name@version to
  # `scoop install`, so pinning works through the normal import path.
  scoopfileContent = {
    buckets = lib.mapAttrsToList (name: source: {
      Name = name;
      Source = source;
    }) cfg.buckets;
    apps = lib.mapAttrsToList (
      name: pkg:
      { Name = name; Source = pkg.bucket; Info = "64bit"; }
      // lib.optionalAttrs (pkg.version != null) { Version = pkg.version; }
    ) cfg.packages;
  };

  scoopfile = pkgs.writeText "scoopfile.json" (builtins.toJSON scoopfileContent);
in
{
  options.win.scoop = {
    enable = lib.mkEnableOption "Scoop package management";

    buckets = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Scoop buckets as name → source URL.";
      example = lib.literalExpression ''
        {
          main = "https://github.com/ScoopInstaller/Main";
          extras = "https://github.com/ScoopInstaller/Extras";
        }
      '';
    };

    packages = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.bucket = lib.mkOption {
            type = lib.types.str;
            description = "Which bucket this package comes from.";
          };
          options.version = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Pin to a specific package version. When null (default),
              Scoop installs whatever the bucket currently ships.
              When set, emitted as the `Version` field in scoopfile.json
              so `scoop import` invokes `scoop install name@version`.
            '';
          };
        }
      );
      default = { };
      description = "Scoop packages to install, keyed by package name.";
      example = lib.literalExpression ''
        {
          bat = { bucket = "main"; version = "0.26.1"; };
          autohotkey = { bucket = "extras"; };
        }
      '';
    };

    cleanup = lib.mkOption {
      type = lib.types.enum [
        "none"
        "uninstall"
      ];
      default = "none";
      description = ''
        Cleanup strategy for packages not in the config.
        "none": leave extra packages alone.
        "uninstall": remove packages not declared here.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    system.build.scoopfile = scoopfile;

    win.activationScripts.scoop.text = ''
        Write-Host "nix-win: importing Scoop packages..." -ForegroundColor Cyan
        $scoopfile = Join-Path $env:NIX_WIN_STORE_PATH "scoop\scoopfile.json"
        if (Get-Command scoop -ErrorAction SilentlyContinue) {
            scoop import $scoopfile
        } else {
            Write-Warning "Scoop is not installed, skipping package import."
        }
        ${lib.optionalString (cfg.cleanup == "uninstall") ''
          # Remove packages not in the config
          $declared = @(${
            lib.concatMapStringsSep ", " (name: "'${name}'") (builtins.attrNames cfg.packages)
          })
          $installed = scoop list 2>$null | ForEach-Object { $_.Name }
          foreach ($pkg in $installed) {
              if ($pkg -notin $declared) {
                  Write-Host "  Removing undeclared package: $pkg" -ForegroundColor Yellow
                  scoop uninstall $pkg
              }
          }
        ''}
      '';
  };
}
