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

  # Escape a string for use in PowerShell
  escapePowershell =
    s:
    builtins.replaceStrings
      [
        "'"
        "`"
        "$"
      ]
      [
        "''"
        "``"
        "`$"
      ]
      s;

  # Windows path roots mapping
  targetRoots = {
    home = "%USERPROFILE%";
    appdata-local = "%LOCALAPPDATA%";
    appdata-roaming = "%APPDATA%";
    programdata = "%ProgramData%";
  };

  # Target roots that require admin privileges
  adminRoots = [
    "programdata"
  ];

  isAdminRoot = root: builtins.elem root adminRoots;

in
{
  inherit
    autoLineEnding
    toCrlf
    mkWinFile
    escapePowershell
    targetRoots
    adminRoots
    isAdminRoot
    ;
}
