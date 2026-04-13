# AutoHotkey configuration module for nix-win.
# Manages the AHK config file and registers a reload activation script.
{
  config,
  lib,
  ...
}:
let
  cfg = config.win.autohotkey;
in
{
  options.win.autohotkey = {
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
    win.files.${cfg.configPath} = {
      source = cfg.config;
      text = cfg.configText;
      lineEnding = "lf";
    };

    win.activationScripts.serviceReloads.text = lib.mkBefore ''
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
