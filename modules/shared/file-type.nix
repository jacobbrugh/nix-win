# Shared file-entry submodule used by every file-placing option in nix-win
# (the system-scope file tree and, later, the per-user home tree). Keeping the
# submodule in one place guarantees the attrset shape users write cannot drift
# between scopes.
{ lib }:
{
  # Whether entries may choose a deployment root. The system scope exposes the
  # full root enum; scopes with a fixed root (e.g. a per-user home tree) hide
  # the option entirely.
  includeTargetRoot ? true,
}:
lib.types.attrsOf (
  lib.types.submodule (
    { name, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to install this file.";
        };

        source = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Path to the source file.";
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

        executable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether the file should be executable.";
        };
      }
      // lib.optionalAttrs includeTargetRoot {
        targetRoot = lib.mkOption {
          type = lib.types.enum [
            "home"
            "appdata-local"
            "appdata-roaming"
            "programdata"
          ];
          default = "home";
          description = "Base directory on Windows where this file is placed.";
        };
      };
    }
  )
)
