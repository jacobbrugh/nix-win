# File management module for nix-win.
# Declares files to be placed on the Windows filesystem.
# Files are built in the Nix store with correct line endings and assembled into a tree.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.win.files;
  winLib = import ../lib { inherit lib pkgs; };

  # Build a single file entry into the store
  buildFile =
    name: entry:
    let
      source = winLib.mkWinFile {
        inherit name;
        inherit (entry) source text lineEnding;
      };
    in
    {
      inherit name source;
      inherit (entry) targetRoot executable;
    };

  # environment.files entries are ProgramData-rooted by definition (the
  # environment.etc analog — machine scope, needs an elevated switch).
  envFiles = lib.mapAttrs (_: e: e // { targetRoot = "programdata"; }) (
    lib.filterAttrs (_: e: e.enable) config.environment.files
  );

  # All enabled file entries
  enabledFiles = lib.filterAttrs (_: e: e.enable) cfg // envFiles;

  builtFiles = lib.mapAttrs buildFile enabledFiles;

  # Assemble all files into a directory tree matching the targetRoot layout
  filesDerivation = pkgs.runCommand "win-files" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: built:
        let
          targetDir = "$out/${built.targetRoot}/${builtins.dirOf name}";
          targetFile = "$out/${built.targetRoot}/${name}";
        in
        ''
          mkdir -p "${targetDir}"
          cp "${built.source}" "${targetFile}"
          ${lib.optionalString built.executable "chmod +x \"${targetFile}\""}
        ''
      ) builtFiles
    )
  );

  # Generate manifest.json for state tracking
  manifestEntries = lib.mapAttrsToList (
    name: entry:
    {
      path = name;
      targetRoot = entry.targetRoot;
      lineEnding = entry.lineEnding;
      executable = entry.executable;
    }
  ) enabledFiles;
in
{
  options.win.files = lib.mkOption {
    type = (import ./shared/file-type.nix { inherit lib; }) { includeTargetRoot = true; };
    default = { };
    description = "Files to place on the Windows filesystem.";
  };

  # The environment.etc analog: machine-scope files, rooted at %ProgramData%
  # (Windows has no /etc; ProgramData is the honest machine-config root).
  # Same submodule shape as win.files/home.file minus the root choice.
  options.environment.files = lib.mkOption {
    type = (import ./shared/file-type.nix { inherit lib; }) { includeTargetRoot = false; };
    default = { };
    description = ''
      Machine-scope files, placed under %ProgramData%. The per-user
      analog is `home.file` in the winHome class.
    '';
  };

  config = {
    system.build.files = filesDerivation;
    system.build.fileManifest = manifestEntries;

    # Register file copy activation script
    system.activationScripts.files.text = ''
      Write-Host "nix-win: placing managed files..." -ForegroundColor Cyan
      # File copy is handled by the nix-win CLI based on manifest.json
    '';
  };
}
