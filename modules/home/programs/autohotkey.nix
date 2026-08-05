# programs.autohotkey (winHome class) — AHK config file + reload-on-activation.
{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.autohotkey;
in
{
  options.programs.autohotkey = {
    enable = lib.mkEnableOption "AutoHotkey configuration management";

    config = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to the AutoHotkey v2 script file.";
    };

    configText = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Inline AutoHotkey v2 script content.";
    };

    configPath = lib.mkOption {
      type = lib.types.str;
      default = ".config/ahk/main.ahk";
      description = "Target path relative to home directory.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file.${cfg.configPath} = lib.mkMerge [
      (lib.mkIf (cfg.config != null) { source = cfg.config; })
      (lib.mkIf (cfg.configText != null) { text = cfg.configText; })
      { lineEnding = "lf"; }
    ];

    home.activation.reloadAutohotkey = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      Write-Host "nix-win: reloading AutoHotkey..." -ForegroundColor Cyan
      $ahkProc = Get-Process -Name "AutoHotkey*" -ErrorAction SilentlyContinue
      if ($ahkProc) {
          $ahkProc | Stop-Process -Force
          Start-Sleep -Seconds 1
      }
      $ahkPath = Join-Path $env:USERPROFILE "${lib.replaceStrings [ "/" ] [ "\\" ] cfg.configPath}"
      $ahkExe = Get-Command autohotkey -ErrorAction SilentlyContinue
      if ($ahkExe -and (Test-Path $ahkPath)) {
          Start-Process -FilePath $ahkExe.Source -ArgumentList $ahkPath -WindowStyle Hidden
      }
    '';
  };
}
