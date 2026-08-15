# Shared file-entry submodule used by every file-placing option in nix-win
# (the system-scope file tree and the per-user home tree). Keeping the
# submodule in one place guarantees the attrset shape users write cannot
# drift between scopes.
#
# Two shapes are produced:
#   - the system shape (hmCompat = false): nix-win's original fields
#     (enable/source/text/lineEnding/executable [+ targetRoot]);
#   - the home-manager-compatible shape (hmCompat = true): home-manager's
#     home.file fields (enable/target/source/text/executable/recursive/
#     force/onChange) plus the Windows extras lineEnding and linkType, with
#     `source` also accepting the tagged value produced by
#     `config.lib.file.mkOutOfStoreSymlink` (deployed as a junction or
#     symlink instead of a copied file).
{ lib }:
{
  # Whether entries may choose a deployment root. The system scope exposes the
  # full root enum; scopes with a fixed root (the per-user home tree) hide the
  # option entirely.
  includeTargetRoot ? true,
  # Which root an entry lands under when it does not say. The per-user tree
  # wants "home"; the machine-scope tree wants "programdata".
  defaultTargetRoot ? "home",
  # Emit the home-manager-compatible field set. Requires pkgs (for the
  # text → source default via writeTextFile).
  hmCompat ? false,
  pkgs ? null,
}:
let
  winOutOfStoreType = lib.mkOptionType {
    name = "winOutOfStoreSymlink";
    description = "out-of-store link target (config.lib.file.mkOutOfStoreSymlink)";
    check = v: builtins.isAttrs v && (v._type or "") == "winOutOfStoreSymlink";
    merge = lib.mergeEqualOption;
  };

  storeFileName = (import ../../lib/hm/strings.nix { inherit lib; }).storeFileName;
in
assert hmCompat -> pkgs != null;
lib.types.attrsOf (
  lib.types.submodule (
    { name, config, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to install this file.";
        };

        text = lib.mkOption {
          type = lib.types.nullOr lib.types.lines;
          default = null;
          description = "Text content of the file.";
        };

        lineEnding = lib.mkOption {
          type = lib.types.enum [
            "lf"
            "crlf"
            "auto"
          ];
          default = "auto";
          description = "Line ending style. 'auto' infers from file extension.";
        };
      }
      // (
        if hmCompat then
          {
            target = lib.mkOption {
              type = lib.types.str;
              defaultText = lib.literalExpression "name";
              description = "Path to the target file, relative to the home directory.";
            };

            source = lib.mkOption {
              type = lib.types.either lib.types.path winOutOfStoreType;
              description = ''
                Path of the source file or directory, or an out-of-store
                link target produced by
                `config.lib.file.mkOutOfStoreSymlink` (deployed as an NTFS
                junction/symlink instead of a copy). If `text` is non-null
                this option automatically points to a file containing that
                text.
              '';
            };

            executable = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = ''
                Set the execute bit on the staged file. If `null`, the mode
                of the source file is kept. A semantic no-op on NTFS —
                accepted for home-manager compatibility so shared modules
                evaluate unchanged.
              '';
            };

            recursive = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Accepted for home-manager compatibility. Directory sources
                are always deployed as full copies on Windows (there is no
                store to symlink into), so this option does not change
                behavior.
              '';
            };

            force = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Whether the target path should be unconditionally replaced,
                skipping the not-previously-managed backup warning.
              '';
            };

            onChange = lib.mkOption {
              type = lib.types.lines;
              default = "";
              description = ''
                PowerShell commands to run after files have been deployed.
                Deviation from home-manager: nix-win cannot yet detect
                per-file changes, so these run on every activation — keep
                them idempotent.
              '';
            };

            linkType = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.enum [
                  "junction"
                  "symlink"
                ]
              );
              default = null;
              description = ''
                For out-of-store sources: force a junction or a symlink.
                `null` probes the expanded source at activation — directory
                → junction (unprivileged), file → symlink (needs Developer
                Mode).
              '';
            };
          }
        else
          {
            source = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Path to the source file.";
            };

            executable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether the file should be executable.";
            };
          }
      )
      // lib.optionalAttrs includeTargetRoot {
        targetRoot = lib.mkOption {
          type = lib.types.enum [
            "home"
            "appdata-local"
            "appdata-roaming"
            "programdata"
            "system-drive"
          ];
          default = defaultTargetRoot;
          description = ''
            Base directory on Windows where this file is placed.
            `system-drive` is the root of %SystemDrive% (normally `C:\`), for
            machine-scope files that conventionally live outside
            %ProgramData%.
          '';
        };
      };

      config = lib.optionalAttrs hmCompat {
        target = lib.mkDefault name;
        source = lib.mkIf (config.text != null) (
          lib.mkDefault (
            pkgs.writeTextFile {
              inherit (config) text;
              executable = config.executable == true; # can be null
              name = storeFileName name;
            }
          )
        );
      };
    }
  )
)
