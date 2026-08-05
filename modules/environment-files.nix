# environment.files — machine-scope file management (the environment.etc
# analog; Windows has no /etc, %ProgramData% is the honest machine-config
# root). Files are built in the Nix store with correct line endings and
# assembled into the toplevel's programdata/ tree; the CLI copies them
# during an elevated system switch. The per-user analog is `home.file` in
# the winHome class.
{
  config,
  lib,
  pkgs,
  ...
}:
let
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
      inherit (entry) executable;
    };

  enabledFiles = lib.filterAttrs (_: e: e.enable) config.environment.files;

  builtFiles = lib.mapAttrs buildFile enabledFiles;

  # Assemble all files into the programdata/ tree
  filesDerivation = pkgs.runCommand "win-files" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: built:
        let
          targetDir = "$out/programdata/${builtins.dirOf name}";
          targetFile = "$out/programdata/${name}";
        in
        ''
          mkdir -p "${targetDir}"
          cp "${built.source}" "${targetFile}"
          ${lib.optionalString built.executable "chmod +x \"${targetFile}\""}
        ''
      ) builtFiles
    )
  );

  # Generate manifest.json entries for state tracking
  manifestEntries = lib.mapAttrsToList (name: entry: {
    path = name;
    targetRoot = "programdata";
    lineEnding = entry.lineEnding;
    executable = entry.executable;
  }) enabledFiles;
in
{
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
