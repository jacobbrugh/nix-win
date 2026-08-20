# Utility library for nix-win.
# Provides helpers for path translation, line ending conversion, PowerShell script generation.
{ lib, pkgs }:
let
  # File extensions that default to CRLF line endings on Windows
  crlfExtensions = [
    ".ps1"
    ".psm1"
    ".psd1"
    ".cmd"
    ".bat"
    ".reg"
    ".ini"
    ".cfg"
    ".json"
    ".yaml"
    ".yml"
    ".toml"
    ".xml"
    ".csv"
  ];

  # Determine line ending for a file based on extension
  autoLineEnding =
    path:
    let
      matchResult = builtins.match ".*(\\..[^.]*)" path;
      extStr = if matchResult != null then lib.toLower (builtins.head matchResult) else "";
    in
    if builtins.elem extStr crlfExtensions then "crlf" else "lf";

  # Convert LF to CRLF in a derivation
  toCrlf =
    name: src:
    pkgs.runCommand "${name}-crlf" { nativeBuildInputs = [ pkgs.coreutils ]; } ''
      sed 's/$/\r/' < ${src} > $out
    '';

  # Build a file with the correct line ending
  mkWinFile =
    {
      name,
      source ? null,
      text ? null,
      lineEnding ? "auto",
    }:
    let
      rawSource =
        if source != null then
          source
        else if text != null then
          pkgs.writeText name text
        else
          throw "nix-win: file '${name}' must have either 'source' or 'text'";

      effectiveLineEnding = if lineEnding == "auto" then autoLineEnding name else lineEnding;
    in
    if effectiveLineEnding == "crlf" then toCrlf name rawSource else rawSource;

  # Quote a string as a PowerShell single-quoted literal — the pwsh analog
  # of lib.escapeShellArg, whose POSIX '\'' escape is garbage to the
  # PowerShell parser. Inside single quotes pwsh interprets nothing except
  # '' (a literal quote), so doubling embedded quotes is the complete
  # escape. Caveat: strings containing double quotes that cross a
  # native-argument boundary additionally rely on PS 7.3+ Standard
  # argument passing to survive intact.
  escapePwsh = s: "'" + lib.replaceStrings [ "'" ] [ "''" ] s + "'";

  # Windows path roots mapping
  targetRoots = {
    home = "%USERPROFILE%";
    appdata-local = "%LOCALAPPDATA%";
    appdata-roaming = "%APPDATA%";
    programdata = "%ProgramData%";
  };

  # Rust cross-compile builders — see lib/build-rust-package.nix for details.
  # Exposes both buildWindowsRustPackage (buildRustPackage-style) and
  # buildWindowsCranePackage (crane-style).
  windowsRust = import ./build-rust-package.nix { inherit pkgs; };

in
{
  inherit
    autoLineEnding
    toCrlf
    mkWinFile
    escapePwsh
    targetRoots
    ;
  inherit (windowsRust) buildWindowsRustPackage buildWindowsCraneDepsOnly buildWindowsCranePackage;
}
