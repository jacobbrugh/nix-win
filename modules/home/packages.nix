# home.packages — home-manager's option shape (a plain list of packages).
# Each package's output tree is staged under the home root (default
# AppData/Local/Programs/<name>) and its bin dir is prepended to the user
# PATH. Per-package knobs ride passthru.nixWin = { relativePath?,
# addToPath?, pathSubdir? } so the list type stays exactly home-manager's.
#
# The typical payload is a Windows cross-compiled derivation
# (lib.buildWindowsRustPackage / buildWindowsCranePackage). Listing a
# Linux ELF package deploys unrunnable binaries — the consumer owns
# keeping Linux-only packages out of the Windows module list.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  meta =
    p:
    let
      m = p.passthru.nixWin or { };
    in
    {
      relativePath = m.relativePath or "AppData/Local/Programs/${lib.getName p}";
      addToPath = m.addToPath or true;
      pathSubdir = m.pathSubdir or "bin";
    };

  staged = map (p: {
    package = p;
    inherit (meta p) relativePath addToPath pathSubdir;
  }) config.home.packages;

  stageOne = e: ''
    dst="$out/home/"${lib.escapeShellArg e.relativePath}
    mkdir -p "$(dirname "$dst")"
    cp -rL --no-preserve=mode "${e.package}" "$dst"
    chmod -R u+w "$dst"
  '';

  packagesTree = pkgs.runCommand "win-home-packages" { } (
    ''
      mkdir -p $out/home
    ''
    + lib.concatStringsSep "\n" (map stageOne staged)
  );

  pathEntries = map (
    e:
    "%USERPROFILE%\\${lib.replaceStrings [ "/" ] [ "\\" ] e.relativePath}${
      lib.optionalString (e.pathSubdir != null && e.pathSubdir != "") "\\${e.pathSubdir}"
    }"
  ) (lib.filter (e: e.addToPath) staged);
in
{
  options.home.packages = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [ ];
    description = "Packages staged into the user's home directory.";
  };

  config = lib.mkIf (config.home.packages != [ ]) {
    home.build.packagesTree = packagesTree;
    home.sessionPath = pathEntries;
  };
}
