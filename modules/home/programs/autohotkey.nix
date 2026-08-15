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

    relaunchTask = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Start Autohotkey";
      description = ''
        Name of a scheduled task that launches AutoHotkey. When set, the
        reload activation relaunches via Start-ScheduledTask, which always
        places the new instance in the user's interactive desktop session.
        Without this, a switch run from a non-interactive context (SSH,
        session 0) Start-Processes the replacement into its own session,
        where it can never receive keyboard input — hotkeys silently die
        until the next reboot.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.file.${cfg.configPath} = lib.mkMerge [
      (lib.mkIf (cfg.config != null) { source = cfg.config; })
      (lib.mkIf (cfg.configText != null) { text = cfg.configText; })
      { lineEnding = "lf"; }
    ];

    home.activation.reloadAutohotkey = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # Reload only when the deployed script actually changed, or when nothing
      # is running. This used to fire unconditionally, so every switch killed
      # AutoHotkey, slept a second and relaunched it — dropping every hotkey
      # mid-switch in order to reload a byte-identical file.
      #
      # Note this is an `if`, not an early `return`: activation entries are
      # concatenated into one script, so a top-level `return` would abandon
      # every entry that follows, not just this one.
      $ahkPath = Join-Path $env:USERPROFILE "${lib.replaceStrings [ "/" ] [ "\\" ] cfg.configPath}"
      $ahkProc = Get-Process -Name "AutoHotkey*" -ErrorAction SilentlyContinue
      if ($ahkProc -and -not (Test-NixWinFileChanged -Path $ahkPath)) {
          Write-Host "nix-win: AutoHotkey config unchanged, left running." -ForegroundColor DarkGray
      } else {
          Write-Host "nix-win: reloading AutoHotkey..." -ForegroundColor Cyan
          if ($ahkProc) {
              $ahkProc | Stop-Process -Force -ErrorAction SilentlyContinue
              Start-Sleep -Seconds 1
          }
          ${
            if cfg.relaunchTask != null then
              ''
                Start-ScheduledTask -TaskName "${cfg.relaunchTask}" -ErrorAction Stop
              ''
            else
              ''
                $ahkExe = Get-Command autohotkey -ErrorAction SilentlyContinue
                if ($ahkExe -and (Test-Path $ahkPath)) {
                    Start-Process -FilePath $ahkExe.Source -ArgumentList $ahkPath -WindowStyle Hidden
                }
              ''
          }
      }
    '';
  };
}
