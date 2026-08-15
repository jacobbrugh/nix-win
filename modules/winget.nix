# WinGet package manager module for nix-win.
# Declares GUI applications to install via winget.
# Standalone from DSC for simplicity and transparency.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.winget;

  # Emit the declaration as data and do the convergence in activation, the
  # same shape the scoop module uses. The previous generator emitted one
  # `winget install` line per package and ran them unconditionally: five
  # no-op installs costing ~2.8 s on a converged switch, with a fat tail
  # (~13.6 s) whenever a `winget install` decided to refresh the source
  # index. Querying installed state once and installing nothing when
  # converged removes both.
  packagesJson = pkgs.writeText "winget-packages.json" (
    builtins.toJSON (
      lib.mapAttrsToList (id: pkg: {
        Id = id;
        Source = pkg.source;
        Version = pkg.version;
      }) cfg.packages
    )
  );
in
{
  options.winget = {
    enable = lib.mkEnableOption "WinGet package management";

    upgrade = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to act on a package whose installed version differs from
        its declared `version`.

        When false (the default), an already-installed package is left
        alone whatever version it is at, matching the `--no-upgrade`
        behaviour this module has always had. A version mismatch is
        reported rather than applied, so drift is visible without a switch
        silently upgrading — or downgrading — an application.

        When true, a mismatch is applied by installing the declared
        version.
      '';
    };

    packages = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.source = lib.mkOption {
            type = lib.types.str;
            default = "winget";
            description = "WinGet source name.";
          };
          options.version = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Pin to a specific package version, passed as `--version` to
              `winget install`. Only applied when the package is missing,
              or when `winget.upgrade` is true — see that option.
            '';
          };
        }
      );
      default = { };
      description = "WinGet packages to install, keyed by package ID.";
      example = lib.literalExpression ''
        {
          "Microsoft.PowerShell" = { version = "7.4.6.0"; };
          "AgileBits.1Password" = {};
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    system.build.wingetPackages = packagesJson;

    system.activationScripts.winget.text = ''
        Write-Host "nix-win: converging WinGet packages..." -ForegroundColor Cyan
        $wingetSpec = Join-Path $env:NIX_WIN_STORE_PATH "winget\packages.json"
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-Warning "WinGet is not available, skipping."
        } else {
            $declared = @(Get-Content -LiteralPath $wingetSpec -Raw | ConvertFrom-Json)
            $wingetFailures = @()
            # Must be $true/$false, not a bare true/false: PowerShell resolves a
            # bareword in a condition as a COMMAND, and Git for Windows puts
            # true.exe and false.exe on PATH. Both produce no output, so both
            # spellings evaluate falsy and `upgrade = true` silently did nothing.
            $wingetUpgrade = ${if cfg.upgrade then "$true" else "$false"}

            # One query for every installed package. Microsoft.WinGet.Client
            # ships with App Installer and loads in PowerShell 7 even though it
            # lives under the Windows PowerShell module root; import + query is
            # ~0.85 s and returns typed objects. Per-package
            # `winget list --id X --exact` was measured at 12.11 s for five
            # packages, so it is only the fallback.
            $installed = $null
            try {
                Import-Module Microsoft.WinGet.Client -ErrorAction Stop
                $installed = @{}
                foreach ($p in Get-WinGetPackage) {
                    # InstalledVersion can carry a literal "> " prefix, which
                    # is winget marking the install as newer than the source
                    # knows about (seen here on AgileBits.1Password).
                    $v = "$($p.InstalledVersion)".Trim().TrimStart('>').Trim()
                    $installed[$p.Id.ToLowerInvariant()] = $v
                }
            } catch {
                Write-Host "  (Microsoft.WinGet.Client unavailable, falling back to per-package queries)" -ForegroundColor DarkYellow
                $installed = $null
            }

            foreach ($d in $declared) {
                $id = $d.Id
                $want = $null
                if ($d.PSObject.Properties.Name -contains 'Version') { $want = $d.Version }

                # WinGet IDs are case-insensitive, and declarations drift from
                # the canonical casing (e.g. "Microsoft.Powertoys" against an
                # installed "Microsoft.PowerToys"). Compare folded, so a
                # cosmetic mismatch is not read as "not installed" and does not
                # trigger a reinstall on every switch.
                $have = $null
                $isInstalled = $false
                if ($null -ne $installed) {
                    $key = $id.ToLowerInvariant()
                    if ($installed.ContainsKey($key)) {
                        $isInstalled = $true
                        $have = $installed[$key]
                    }
                } else {
                    # Keep the output rather than discarding it, so a probe
                    # that fails for some reason other than "absent" can say so.
                    $probe = (winget list --id $id --exact --disable-interactivity `
                        --accept-source-agreements 2>&1 | Out-String)
                    $isInstalled = ($LASTEXITCODE -eq 0)
                    if (-not $isInstalled -and $probe -notmatch 'No installed package') {
                        Write-Host "  $id probe: $($probe.Trim())" -ForegroundColor DarkYellow
                    }
                }

                $reason = $null
                if (-not $isInstalled) {
                    $reason = 'not installed'
                } elseif ($null -ne $want -and $null -ne $have -and $have -ne $want) {
                    if ($wingetUpgrade) {
                        $reason = "pinned $want, found $have"
                    } else {
                        # Report, do not act: this is the long-standing
                        # --no-upgrade behaviour. Acting here would upgrade or
                        # downgrade a GUI application behind the user's back.
                        Write-Host "  $id ok ($have; declared $want, not applied - winget.upgrade is false)" -ForegroundColor DarkYellow
                        continue
                    }
                } else {
                    $shown = if ($null -ne $have) { $have } else { 'present' }
                    Write-Host "  $id ok ($shown)" -ForegroundColor DarkGray
                    continue
                }

                try {
                    Write-Host "  $id installing ($reason)" -ForegroundColor Yellow
                    $wingetArgs = @(
                        'install', '--id', $id, '--source', $d.Source,
                        '--accept-source-agreements', '--accept-package-agreements',
                        '--disable-interactivity', '--silent'
                    )
                    if ($null -ne $want) { $wingetArgs += @('--version', $want) }
                    # stderr is deliberately NOT discarded. It used to go to
                    # $null, which hid every failed install behind a phase that
                    # still reported success.
                    winget @wingetArgs
                    if ($LASTEXITCODE -ne 0) { throw "winget install exited $LASTEXITCODE" }
                    Write-Host "  $id changed" -ForegroundColor Green
                } catch {
                    $wingetFailures += "$id`: $($_.Exception.Message)"
                    Write-Host "  $id FAILED: $($_.Exception.Message)" -ForegroundColor Red
                }
            }

            # Fail once, after every package has had its turn.
            if ($wingetFailures.Count -gt 0) {
                throw "winget: $($wingetFailures.Count) package(s) failed:`n  " + ($wingetFailures -join "`n  ")
            }
        }
      '';
  };
}
