# PowerShell module management for nix-win.
# Declares PowerShell modules to install with specific versions.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.win.powershell;

  modulesManifest = {
    pwsh7 = cfg.modules.pwsh7;
    windowsPowerShell = cfg.modules.windowsPowerShell;
  };

  manifestFile = pkgs.writeText "psmodules.json" (builtins.toJSON modulesManifest);
in
{
  options.win.powershell = {
    modules = {
      pwsh7 = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "PowerShell 7 modules to install as name → version.";
        example = lib.literalExpression ''
          { "Microsoft.WinGet.Dsc" = "1.8.0"; }
        '';
      };

      windowsPowerShell = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Windows PowerShell 5.1 modules to install as name → version.";
        example = lib.literalExpression ''
          { "ComputerManagementDsc" = "10.0.0"; "NetworkingDsc" = "9.0.0"; }
        '';
      };
    };

    profile = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Content for the PowerShell 7 profile (Microsoft.PowerShell_profile.ps1).";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.modules.pwsh7 != { } || cfg.modules.windowsPowerShell != { }) {
      system.build.psmodulesManifest = manifestFile;

      win.activationScripts.psmodules.text = ''
          Write-Host "nix-win: installing PowerShell modules..." -ForegroundColor Cyan
          $manifest = Get-Content (Join-Path $env:NIX_WIN_STORE_PATH "powershell\psmodules.json") | ConvertFrom-Json

          # Install pwsh7 modules
          foreach ($prop in $manifest.pwsh7.PSObject.Properties) {
              $name = $prop.Name
              $version = $prop.Value
              Write-Host "  pwsh7: $name@$version" -ForegroundColor Gray
              if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
                  Install-PSResource -Name $name -Version $version -Scope AllUsers -TrustRepository -ErrorAction SilentlyContinue
              } else {
                  Install-Module -Name $name -RequiredVersion $version -Scope AllUsers -Force -AllowClobber -ErrorAction SilentlyContinue
              }
          }

          # Install Windows PowerShell 5.1 modules and remove stale versions
          foreach ($prop in $manifest.windowsPowerShell.PSObject.Properties) {
              $name = $prop.Name
              $version = $prop.Value
              Write-Host "  winps: $name@$version" -ForegroundColor Gray
              powershell.exe -NoProfile -Command "Install-Module -Name '$name' -RequiredVersion '$version' -Scope AllUsers -Force -AllowClobber -ErrorAction SilentlyContinue"
              # Remove other versions to avoid DSC resource resolution conflicts
              powershell.exe -NoProfile -Command "Get-Module -ListAvailable '$name' | Where-Object { `$_.Version -ne '$version' } | ForEach-Object { Uninstall-Module -Name '$name' -RequiredVersion `$_.Version -Force -ErrorAction SilentlyContinue }"
          }
        '';
    })

    (lib.mkIf (cfg.profile != null) {
      win.files."Documents/PowerShell/Microsoft.PowerShell_profile.ps1" = {
        text = cfg.profile;
        lineEnding = "crlf";
      };
    })
  ];
}
