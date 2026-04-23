# User-environment module for nix-win.
#
# Manages the current user's environment variables (HKCU\Environment).
# Today only `userPath` is exposed — a list of entries to prepend to
# the user PATH. Other env vars can be bolted on the same way.
#
# We intentionally don't use DSC's
# `PSDesiredStateConfiguration/Environment` resource because it only
# supports Process/Machine targets (not User), which means machine-wide
# PATH edits requiring admin — not what most consumers want.
#
# Instead, an activation script writes directly to
# `[Environment]::SetEnvironmentVariable('Path', ..., 'User')`. To
# avoid leaking entries across generations, nix-win tracks the
# entries it previously added in `%LOCALAPPDATA%\nix-win\user-path.json`
# and strips them from the current PATH before prepending the new set.
# Anything the user (or another installer) added themselves is
# preserved.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.win.environment;

  # Dedup while preserving order — first occurrence wins.
  dedupEntries =
    xs:
    let
      step =
        acc: x:
        if builtins.elem x acc.seen then acc else {
          list = acc.list ++ [ x ];
          seen = acc.seen ++ [ x ];
        };
    in
    (builtins.foldl' step { list = [ ]; seen = [ ]; } xs).list;

  desiredPath = dedupEntries cfg.userPath;

  # Emit as a JSON file so PowerShell can ConvertFrom-Json it
  # unambiguously (avoids escaping hell in embedded heredocs). The
  # file is folded into the system toplevel at
  # `$out/environment/user-path.json`, and the activation script
  # resolves it through `$env:NIX_WIN_STORE_PATH` — the same pattern
  # scoop/winget/dsc modules use to reach their generated configs.
  desiredPathJson = pkgs.writeText "user-path.json" (builtins.toJSON desiredPath);
in
{
  options.win.environment = {
    userPath = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Entries to prepend to the user PATH
        (HKCU\Environment\Path). Typically `%LOCALAPPDATA%\Programs\<app>\bin`
        or similar — PowerShell env-var references are accepted and
        are stored unexpanded so Windows resolves them at use time
        (REG_EXPAND_SZ).

        Entries previously added by nix-win are tracked in
        `%LOCALAPPDATA%\nix-win\user-path.json` and stripped on the
        next switch, so removing a package cleanly removes its PATH
        entry. Entries added outside nix-win are left alone.

        This option is a list (not an attrset) because order matters:
        the first entry has the highest precedence.
      '';
    };
  };

  config = lib.mkIf (desiredPath != [ ]) {
    system.build.environmentConfig = desiredPathJson;

    win.activationScripts.userEnvironment = {
      deps = [ "files" ];
      text = ''
        Write-Host "nix-win: updating user environment..." -ForegroundColor Cyan

        $stateDir = Join-Path $env:LOCALAPPDATA "nix-win"
        $pathStateFile = Join-Path $stateDir "user-path.json"
        $desiredFile = Join-Path $env:NIX_WIN_STORE_PATH "environment\user-path.json"

        $desired = @(Get-Content -LiteralPath $desiredFile -Raw | ConvertFrom-Json)
        # PowerShell's ConvertFrom-Json returns a string for a
        # single-element array; coerce to array for consistent handling.
        if ($desired -isnot [array]) { $desired = @($desired) }

        $previouslyManaged = @()
        if (Test-Path -LiteralPath $pathStateFile) {
            $raw = Get-Content -LiteralPath $pathStateFile -Raw | ConvertFrom-Json
            $previouslyManaged = if ($raw -isnot [array]) { @($raw) } else { $raw }
        }

        # Read the current user PATH raw (no expansion) so we can
        # rewrite it in the same REG_EXPAND_SZ form. `[Environment]`
        # helpers expand env vars by default; go through the
        # registry to preserve `%VAR%` placeholders.
        $envKey = 'HKCU:\Environment'
        $currentRaw = (Get-ItemProperty -Path $envKey -Name Path -ErrorAction SilentlyContinue).Path
        if (-not $currentRaw) { $currentRaw = ''' }
        $currentItems = @($currentRaw -split ';' | Where-Object { $_ })

        # Strip entries nix-win added last generation; anything else
        # survives.
        $base = @($currentItems | Where-Object { $previouslyManaged -notcontains $_ })

        # Prepend newly-desired entries, dedup against the base.
        $merged = @()
        foreach ($e in $desired) { if ($merged -notcontains $e) { $merged += $e } }
        foreach ($e in $base) { if ($merged -notcontains $e) { $merged += $e } }

        $newPath = ($merged -join ';')
        if ($newPath -ne $currentRaw) {
            # REG_EXPAND_SZ keeps `%VAR%` placeholders intact so
            # Windows expands them per-process.
            $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
            try {
                $regKey.SetValue('Path', $newPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            } finally {
                $regKey.Close()
            }

            # Broadcast WM_SETTINGCHANGE so running Explorer / shell
            # sessions refresh their environment. Existing consoles
            # still need a restart, but new processes pick up the
            # change immediately.
            $sig = @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
            $type = Add-Type -MemberDefinition $sig -Name 'NixWinEnv' -Namespace 'NixWin' `
                             -PassThru -ErrorAction SilentlyContinue
            if ($type) {
                $HWND_BROADCAST = [IntPtr]0xffff
                $WM_SETTINGCHANGE = 0x001A
                $SMTO_ABORTIFHUNG = 0x0002
                [UIntPtr]$out = [UIntPtr]::Zero
                [void]$type::SendMessageTimeout(
                    $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, 'Environment',
                    $SMTO_ABORTIFHUNG, 5000, [ref]$out)
            }

            Write-Host "  user PATH updated ($($merged.Count) entries)" -ForegroundColor DarkGray
        } else {
            Write-Host "  user PATH already up to date" -ForegroundColor DarkGray
        }

        # Persist what nix-win added this generation so we can strip
        # it next time if it's been removed from the config.
        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }
        ($desired | ConvertTo-Json -Compress) | Set-Content -LiteralPath $pathStateFile -NoNewline
      '';
    };
  };
}
