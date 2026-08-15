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

  # Assemble all files into one tree per target root. The CLI copies each
  # <root>/ subtree to the directory Resolve-TargetRoot returns for it.
  filesDerivation = pkgs.runCommand "win-files" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: built:
        let
          root = enabledFiles.${name}.targetRoot;
          targetDir = "$out/${root}/${builtins.dirOf name}";
          targetFile = "$out/${root}/${name}";
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
    inherit (entry) targetRoot lineEnding executable;
  }) enabledFiles;

  # Roots actually used, so the CLI knows which subtrees to walk.
  usedRoots = lib.unique (lib.mapAttrsToList (_: e: e.targetRoot) enabledFiles);
in
{
  options.environment.files = lib.mkOption {
    type = (import ./shared/file-type.nix { inherit lib; }) {
      includeTargetRoot = true;
      # Machine scope, so %ProgramData% rather than the per-user home the
      # shared submodule otherwise defaults to.
      defaultTargetRoot = "programdata";
    };
    default = { };
    description = ''
      Machine-scope files. `targetRoot` defaults to `programdata`, the honest
      machine-config root on Windows; `system-drive` covers the places that
      conventionally sit outside it. The per-user analog is `home.file` in the
      winHome class.
    '';
  };

  config = {
    system.build.files = filesDerivation;
    system.build.fileManifest = manifestEntries;
    system.build.fileRoots = usedRoots;

    # Register file copy activation script
    system.activationScripts.files.text = ''
      Write-Host "nix-win: placing managed files..." -ForegroundColor Cyan
      # File copy is handled by the nix-win CLI based on manifest.json
    '';
  };
}
