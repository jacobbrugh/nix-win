# home.sessionPath and home.sessionVariables — the user's HKCU environment.
# The PATH machinery is the relocated system-scope userPath implementation:
# entries nix-win adds are tracked in a state file and stripped on the next
# switch, so removing a declaration cleanly removes its entry. Variables get
# the same managed-set treatment.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.home;

  # Dedup while preserving order — first occurrence wins.
  dedupEntries =
    xs:
    let
      step =
        acc: x:
        if builtins.elem x acc.seen then
          acc
        else
          {
            list = acc.list ++ [ x ];
            seen = acc.seen ++ [ x ];
          };
    in
    (builtins.foldl' step {
      list = [ ];
      seen = [ ];
    } xs).list;

  desiredPath = dedupEntries cfg.sessionPath;

  desiredVars = lib.mapAttrs (_: toString) cfg.sessionVariables;
in
{
  options.home = {
    sessionPath = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Entries to prepend to the user PATH (HKCU\Environment\Path).
        `%VAR%`-style references are stored unexpanded (REG_EXPAND_SZ)
        so Windows resolves them at use time. Order matters: the first
        entry has the highest precedence. Entries previously added by
        nix-win are tracked in `%LOCALAPPDATA%\nix-win\user-path.json`
        and stripped on the next switch.
      '';
    };

    sessionVariables = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          lib.types.path
          lib.types.int
          lib.types.float
        ]
      );
      default = { };
      example = {
        EDITOR = "nvim";
      };
      description = ''
        Environment variables to set in the user scope
        (HKCU\Environment). Managed names are tracked in
        `%LOCALAPPDATA%\nix-win\session-variables.json`; a variable
        removed from this set is deleted from the registry on the next
        switch.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (desiredPath != [ ]) {
      home.build.environmentConfigs.user-path = pkgs.writeText "user-path.json" (
        builtins.toJSON desiredPath
      );

      home.activation.sessionPath = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        Write-Host "nix-win: updating user PATH..." -ForegroundColor Cyan

        $stateDir = Join-Path $env:LOCALAPPDATA "nix-win"
        $pathStateFile = Join-Path $stateDir "user-path.json"
        $desiredFile = Join-Path $env:NIX_WIN_HOME_STORE_PATH "environment\user-path.json"

        $desired = @(Get-Content -LiteralPath $desiredFile -Raw | ConvertFrom-Json)
        if ($desired -isnot [array]) { $desired = @($desired) }

        $previouslyManaged = @()
        if (Test-Path -LiteralPath $pathStateFile) {
            $raw = Get-Content -LiteralPath $pathStateFile -Raw | ConvertFrom-Json
            $previouslyManaged = if ($raw -isnot [array]) { @($raw) } else { $raw }
        }

        # Read the current user PATH raw (no expansion) so we can rewrite
        # it in the same REG_EXPAND_SZ form.
        $envKey = 'HKCU:\Environment'
        $currentRaw = (Get-ItemProperty -Path $envKey -Name Path -ErrorAction SilentlyContinue).Path
        if (-not $currentRaw) { $currentRaw = ''' }
        $currentItems = @($currentRaw -split ';' | Where-Object { $_ })

        # Strip entries nix-win added last generation; anything else survives.
        $base = @($currentItems | Where-Object { $previouslyManaged -notcontains $_ })

        $merged = @()
        foreach ($e in $desired) { if ($merged -notcontains $e) { $merged += $e } }
        foreach ($e in $base) { if ($merged -notcontains $e) { $merged += $e } }

        $newPath = ($merged -join ';')
        if ($newPath -ne $currentRaw) {
            $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
            try {
                $regKey.SetValue('Path', $newPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            } finally {
                $regKey.Close()
            }
            Invoke-NixWinSettingChange
            Write-Host "  user PATH updated ($($merged.Count) entries)" -ForegroundColor DarkGray
        } else {
            Write-Host "  user PATH already up to date" -ForegroundColor DarkGray
        }

        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }
        ($desired | ConvertTo-Json -Compress) | Set-Content -LiteralPath $pathStateFile -NoNewline
      '';
    })

    (lib.mkIf (desiredVars != { }) {
      home.build.environmentConfigs.session-variables = pkgs.writeText "session-variables.json" (
        builtins.toJSON desiredVars
      );

      home.activation.sessionVariables = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        Write-Host "nix-win: updating user environment variables..." -ForegroundColor Cyan

        $stateDir = Join-Path $env:LOCALAPPDATA "nix-win"
        $varsStateFile = Join-Path $stateDir "session-variables.json"
        $desiredFile = Join-Path $env:NIX_WIN_HOME_STORE_PATH "environment\session-variables.json"

        $desired = Get-Content -LiteralPath $desiredFile -Raw | ConvertFrom-Json -AsHashtable

        $previouslyManaged = @()
        if (Test-Path -LiteralPath $varsStateFile) {
            $raw = Get-Content -LiteralPath $varsStateFile -Raw | ConvertFrom-Json
            $previouslyManaged = if ($raw -isnot [array]) { @($raw) } else { $raw }
        }

        $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        $changed = $false
        try {
            # Remove variables nix-win managed last generation that are no
            # longer declared.
            foreach ($name in $previouslyManaged) {
                if (-not $desired.ContainsKey($name)) {
                    if ($null -ne $regKey.GetValue($name)) {
                        $regKey.DeleteValue($name, $false)
                        $changed = $true
                        Write-Host "  removed $name" -ForegroundColor DarkGray
                    }
                }
            }
            foreach ($name in $desired.Keys) {
                $value = [string]$desired[$name]
                if ([string]$regKey.GetValue($name, "", 'DoNotExpandEnvironmentNames') -cne $value) {
                    # REG_EXPAND_SZ keeps %VAR% placeholders intact.
                    $regKey.SetValue($name, $value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
                    $changed = $true
                    Write-Host "  set $name" -ForegroundColor DarkGray
                }
            }
        } finally {
            $regKey.Close()
        }
        if ($changed) { Invoke-NixWinSettingChange }

        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }
        ConvertTo-Json -Compress @($desired.Keys) | Set-Content -LiteralPath $varsStateFile -NoNewline
      '';
    })
  ];
}
