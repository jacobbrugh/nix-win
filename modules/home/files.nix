# home.file — the home-manager-compatible per-user file option. Regular
# entries are staged into the home/ tree (copied to Windows by the CLI);
# entries whose source is a config.lib.file.mkOutOfStoreSymlink value become
# link-manifest entries the CLI materializes as junctions/symlinks.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  winLib = import ../../lib { inherit lib pkgs; };

  fileType = import ../shared/file-type.nix { inherit lib; } {
    includeTargetRoot = false;
    hmCompat = true;
    inherit pkgs;
  };

  enabled = lib.filterAttrs (_: f: f.enable) config.home.file;

  isOutOfStore = f: builtins.isAttrs f.source && (f.source._type or "") == "winOutOfStoreSymlink";

  linkFiles = lib.filterAttrs (_: f: isOutOfStore f) enabled;
  regularFiles = lib.filterAttrs (_: f: !isOutOfStore f) enabled;

  effectiveLineEnding =
    f: if f.lineEnding == "auto" then winLib.autoLineEnding f.target else f.lineEnding;

  # Stage one entry into $out/home/<target>. Directory sources are copied
  # whole (dereferencing store symlinks); file sources get their line
  # endings converted at stage time.
  stageEntry = f: ''
    src=${lib.escapeShellArg "${f.source}"}
    dst="$out/home/"${lib.escapeShellArg f.target}
    mkdir -p "$(dirname "$dst")"
    if [ -d "$src" ]; then
      cp -rL --no-preserve=mode "$src" "$dst"
      chmod -R u+w "$dst"
    else
      ${
        if effectiveLineEnding f == "crlf" then
          ''sed 's/$/\r/' < "$src" > "$dst"''
        else
          ''cp -L "$src" "$dst" && chmod u+w "$dst"''
      }
      ${lib.optionalString (f.executable == true) ''chmod +x "$dst"''}
      ${lib.optionalString (f.executable == false) ''chmod -x "$dst"''}
    fi
  '';

  filesDerivation = pkgs.runCommand "win-home-files" { } (
    ''
      mkdir -p $out/home
    ''
    + lib.concatStringsSep "\n" (lib.mapAttrsToList (_: f: stageEntry f) regularFiles)
  );

  fileManifest = lib.mapAttrsToList (_: f: {
    path = f.target;
    lineEnding = effectiveLineEnding f;
    executable = f.executable == true;
  }) regularFiles;

  linkManifest = lib.mapAttrsToList (_: f: {
    path = f.target;
    source = f.source.target;
    linkType = if f.linkType != null then f.linkType else "auto";
    inherit (f) force;
  }) linkFiles;

  onChangeEntries = lib.filterAttrs (_: f: f.onChange != "") regularFiles;
in
{
  options.home.file = lib.mkOption {
    type = fileType;
    default = { };
    description = "Files to place in the user's home directory.";
  };

  config = {
    home.build.files = filesDerivation;
    home.build.fileManifest = fileManifest;
    home.build.linkManifest = linkManifest;

    home.activation.onChange = lib.mkIf (onChangeEntries != { }) (
      lib.hm.dag.entryAfter [ "writeBoundary" ] (
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: f: ''
            # onChange: ${f.target}
            ${f.onChange}
          '') onChangeEntries
        )
      )
    );
  };
}
