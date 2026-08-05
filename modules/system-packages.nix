# environment.systemPackages — machine-scope Nix-built packages (the
# nixos/nix-darwin option shape: a plain list of packages), staged under
# %ProgramData%\nix-win\Programs\<name> (passthru.nixWin.relativePath
# overrides the subpath). Deploy-only: machine PATH (HKLM) management is
# deliberately out of scope. Per-user packages belong in the winHome
# class's home.packages.
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
      relativePath = m.relativePath or "nix-win/Programs/${lib.getName p}";
    };

  stageOne = p: ''
    dst="$out/programdata/"${lib.escapeShellArg (meta p).relativePath}
    mkdir -p "$(dirname "$dst")"
    cp -rL --no-preserve=mode "${p}" "$dst"
    chmod -R u+w "$dst"
  '';

  packagesTree = pkgs.runCommand "win-packages" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStringsSep "\n" (map stageOne config.environment.systemPackages)
  );
in
{
  options.environment.systemPackages = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [ ];
    description = ''
      Machine-scope packages staged under %ProgramData%\nix-win\Programs.
      Deploy-only (no machine PATH management). Per-user packages belong
      in the winHome class's home.packages.
    '';
  };

  config.system.build.packages = lib.mkIf (config.environment.systemPackages != [ ]) packagesTree;
}
