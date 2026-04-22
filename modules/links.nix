# Directory junction / symbolic link management for nix-win.
# Mirrors the home-manager `xdg.configFile.<name>.source = mkOutOfStoreSymlink`
# pattern: declare a target path that points at a location outside the Nix
# store (typically a dotfiles-repo directory), activation creates the link
# idempotently, and removing the entry from config triggers cleanup on the
# next switch via the state manifest.
#
# DSC's PSDesiredStateConfiguration/File resource cannot create junctions or
# symbolic links (Type is constrained to File|Directory), so this module is
# applied by the nix-win CLI via the link manifest it emits — not via DSC.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.win.links;

  enabledLinks = lib.filterAttrs (_: e: e.enable) cfg;

  # Manifest consumed by the nix-win CLI's Deploy-Links phase. Keys are
  # strings so Windows backslashes and $env:* references round-trip through
  # JSON without any Nix-side interpretation.
  manifestEntries = lib.mapAttrsToList (
    name: entry: {
      path = name;
      source = entry.source;
      targetRoot = entry.targetRoot;
      linkType = entry.linkType;
      force = entry.force;
    }
  ) enabledLinks;
in
{
  options.win.links = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether this link should be created.";
            };

            source = lib.mkOption {
              type = lib.types.str;
              description = ''
                Absolute Windows path that the link points at. May contain
                PowerShell environment variable references (e.g.
                `$env:USERPROFILE`, `$env:LOCALAPPDATA`) which the CLI
                expands at activation time.
              '';
              example = lib.literalExpression ''
                "$env:USERPROFILE\\.local\\share\\chezmoi\\nix\\home\\editor\\nvim"
              '';
            };

            targetRoot = lib.mkOption {
              type = lib.types.enum [
                "home"
                "appdata-local"
                "appdata-roaming"
                "programdata"
              ];
              default = "home";
              description = ''
                Base directory on Windows where the link's path is placed.
                Same roots as `win.files` for consistency.
              '';
            };

            linkType = lib.mkOption {
              type = lib.types.enum [
                "junction"
                "symlink"
              ];
              default = "junction";
              description = ''
                "junction": NTFS directory junction. Local-only (no network
                  shares, no files), no special privilege required, honored
                  transparently by almost every Windows app.
                "symlink": Symbolic link. Works for files and directories,
                  can traverse network shares, but requires Developer Mode
                  (or elevated admin) to create without a UAC prompt.
              '';
            };

            force = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                When true, replace an existing regular file or directory at
                the target path with the link. When false (default), an
                existing non-link target is left alone and a warning is
                printed — this preserves any user data that may be at the
                path from before the link was declared.
              '';
            };
          };
        }
      )
    );
    default = { };
    description = ''
      Directory junctions and symbolic links to create on activation.

      Links declared here are tracked in nix-win's state manifest so that
      removing an entry from the configuration causes the link to be
      deleted on the next switch (mirroring home-manager behavior).

      Non-link targets are preserved unless `force = true` is set on the
      entry.
    '';
    example = lib.literalExpression ''
      {
        ".config/nvim" = {
          source = "$env:USERPROFILE\\.local\\share\\chezmoi\\nix\\home\\editor\\nvim";
          targetRoot = "appdata-local";
          linkType = "junction";
        };
      }
    '';
  };

  config = {
    system.build.linkManifest = manifestEntries;
  };
}
