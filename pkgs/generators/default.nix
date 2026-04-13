# DSC resource manifest/schema → Nix module generator for nix-win.
# All schemas are fetched from pinned upstream sources at build time — no
# hand-authored schema files are checked into this repo.
#
# Upstream sources and pins:
#   PowerShell/DSC 5ef68a58 (main)              — windows_service, windows_firewall manifests
#   MicrosoftDocs/PowerShell-Docs-DSC 1c661f42b — registry (Microsoft.Windows/Registry) JSON schema
#   dsccommunity/ComputerManagementDsc v10.0.0   — ScheduledTask MOF
#   PSGallery WindowsDefender 1.0.0.4 nupkg      — WindowsDefender MOF
#   microsoft/omi 9c950a8d                        — PSDesiredStateConfiguration/File MOF
#   PowerShell/PSDscResources 7064eda5            — all 12 PSDscResources MOFs
#
# Usage (in flake.nix):
#   generators = forAllSystems (system:
#     import ./pkgs/generators { pkgs = nixpkgs.legacyPackages.${system}; inherit lib; }
#   );
#
# To regenerate all checked-in modules:
#   nix build .#packages.x86_64-linux.generate-dsc-modules
#   cp -r result/ modules/dsc/generated/
{ pkgs, lib }:
let
  dsc2nix = ./dsc2nix.py;
  extractSchemaMd = ./extract_schema_from_md.py;

  # ---------------------------------------------------------------------------
  # Pinned upstream sources
  # ---------------------------------------------------------------------------

  # PowerShell/DSC commit 5ef68a58 — windows_service and windows_firewall
  # manifests with embedded JSON schemas (added after v3.1.3, on main).
  windowsServiceManifest = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/PowerShell/DSC/5ef68a58589099da03315a8e6340e3ba0800b164/resources/windows_service/windows_service.dsc.resource.json";
    hash = "sha256-0FkIV6fcWceKdY+32sYwG9tFEZvfWP2ZHpIHpdU8aos=";
  };

  windowsFirewallManifest = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/PowerShell/DSC/5ef68a58589099da03315a8e6340e3ba0800b164/resources/windows_firewall/windows_firewall.dsc.resource.json";
    hash = "sha256-6saKFrdxVpRJYDz1uhh54jPNuiCc8SXvhnQN6V92fS4=";
  };

  # dsccommunity/NetworkingDsc v9.0.0 — DSC_Firewall.schema.mof
  networkingDscSrc = pkgs.fetchFromGitHub {
    owner = "dsccommunity";
    repo = "NetworkingDsc";
    rev = "v9.0.0";
    hash = "sha256-43gDcmgA2f8o77BcDgny6sx0ggwfaAo5OsS1usEo3j0=";
  };

  # dsccommunity/ComputerManagementDsc v10.0.0 — DSC_ScheduledTask.schema.mof
  computerManagementDscSrc = pkgs.fetchFromGitHub {
    owner = "dsccommunity";
    repo = "ComputerManagementDsc";
    rev = "v10.0.0";
    hash = "sha256-vmatk6DT8S0G/nDWw0O6gBn6sCASrZfqySbhCC88D4U=";
  };

  # PSGallery WindowsDefender 1.0.0.4 nupkg — MSFT_WindowsDefender.schema.mof
  windowsDefenderNupkg = pkgs.fetchurl {
    url = "https://www.powershellgallery.com/api/v2/package/WindowsDefender/1.0.0.4";
    hash = "sha256-+memVRQW3JY3MWD0AsnSX6Lsd5TKDQvgZkZ6QwFaZzk=";
  };

  # MicrosoftDocs/PowerShell-Docs-DSC 1c661f42b — Registry resource docs with
  # "Instance validating schema" JSON block for Microsoft.Windows/Registry.
  registryDocsMd = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/MicrosoftDocs/PowerShell-Docs-DSC/1c661f42b30a288a5d8f28692bcc9b85fa41e465/dsc/docs-conceptual/dsc-3.0/reference/resources/Microsoft/Windows/Registry/index.md";
    hash = "sha256-Dxgatfs3ke2J33S8GoogXOEBOJ4FRQe7CCqt9+hpQ8w=";
  };

  # microsoft/omi 9c950a8d — MSFT_FileDirectoryConfiguration (PSDesiredStateConfiguration/File).
  # Canonical schema is a Windows OS component; OMI test fixture is the closest source.
  omiDscSchemaMof = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/microsoft/omi/9c950a8d5915dda1128bb0a3eccc41617329a4c9/Unix/tests/codec/mof/blue/mofs/dscschema.mof";
    hash = "sha256-+O89gn1ao+K5SEasyd1dER9p64V31q5f5p18vGalcbc=";
  };

  # PowerShell/PSDscResources 7064eda5 — all 12 PSDscResources MOF schemas
  psdscResourcesSrc = pkgs.fetchFromGitHub {
    owner = "PowerShell";
    repo = "PSDscResources";
    rev = "7064eda52d939a4a3ce40e1f38756cfe6a09acfd";
    hash = "sha256-2ZqdpGEPZEVEmOgwAnLLdstwx+9Ufn3RCdE7D5jI7Uo=";
  };

  # ---------------------------------------------------------------------------
  # Intermediate schema derivations
  # ---------------------------------------------------------------------------

  registrySchema = pkgs.runCommand "registry-schema.json"
    { nativeBuildInputs = [ pkgs.python3 ]; }
    ''
      python3 ${extractSchemaMd} ${registryDocsMd} > $out
    '';

  windowsDefenderMof = pkgs.runCommand "MSFT_WindowsDefender.schema.mof"
    { nativeBuildInputs = [ pkgs.python3 ]; }
    ''
      python3 -c "
import zipfile, sys
z = zipfile.ZipFile('${windowsDefenderNupkg}')
sys.stdout.buffer.write(z.read('DSCResources/MSFT_WindowsDefender/MSFT_WindowsDefender.schema.mof'))
" > $out
    '';

  # ---------------------------------------------------------------------------
  # Generator helpers
  # ---------------------------------------------------------------------------

  fromDscSource =
    name: src: extraArgs:
    pkgs.runCommand "${name}.nix"
      { nativeBuildInputs = [ pkgs.python3 pkgs.nixfmt-rfc-style ]; }
      ''
        python3 ${dsc2nix} ${src} ${lib.escapeShellArgs extraArgs} > ./raw.nix
        nixfmt ./raw.nix
        cp ./raw.nix $out
      '';

  fromDscManifest = name: src: fromDscSource name src [ ];

  fromMof =
    name: src: extraArgs:
    pkgs.runCommand "${name}.nix"
      { nativeBuildInputs = [ pkgs.python3 pkgs.nixfmt-rfc-style ]; }
      ''
        python3 ${dsc2nix} --mof ${src} ${lib.escapeShellArgs extraArgs} > ./raw.nix
        nixfmt ./raw.nix
        cp ./raw.nix $out
      '';

  # Helper for a PSDscResources module: all use psdsc-wrapper mode under win.dsc.psdsc.*
  psdscMof = friendlyName: mofClass: keyProps:
    fromMof "psdsc_${lib.toLower friendlyName}"
      "${psdscResourcesSrc}/DscResources/${mofClass}/${mofClass}.schema.mof"
      (
        [
          "--resource-type"
          "PSDesiredStateConfiguration/${friendlyName}"
          "--mode"
          "psdsc-wrapper"
          "--option-path"
          "win.dsc.psdsc.${lib.toLower friendlyName}"
        ]
        ++ (if lib.length keyProps == 1 then [ "--key-prop" (lib.head keyProps) ] else [ ])
      );

  # ---------------------------------------------------------------------------
  # Generate all nix-win DSC modules
  # ---------------------------------------------------------------------------
  generateAll = pkgs.linkFarm "nix-win-dsc-modules" [
    # --- NetworkingDsc ---
    {
      name = "networking_firewall.nix";
      path = fromMof "networking_firewall"
        "${networkingDscSrc}/source/DSCResources/DSC_Firewall/DSC_Firewall.schema.mof"
        [
          "--resource-type" "NetworkingDsc/Firewall"
          "--mode" "psdsc-wrapper"
          "--option-path" "win.dsc.firewall.rules"
          "--key-prop" "Name"
        ];
    }
    {
      name = "registry.nix";
      path = fromDscSource "registry" registrySchema [
        "--schema-json" "--resource-type" "Microsoft.Windows/Registry"
      ];
    }
    # --- ComputerManagementDsc ---
    {
      name = "scheduled_task.nix";
      path = fromMof "scheduled_task"
        "${computerManagementDscSrc}/source/DSCResources/DSC_ScheduledTask/DSC_ScheduledTask.schema.mof"
        [
          "--resource-type" "ComputerManagementDsc/ScheduledTask"
          "--mode" "psdsc-wrapper"
          "--option-path" "win.dsc.scheduledTasks"
          "--key-prop" "TaskName"
        ];
    }
    # --- WindowsDefender ---
    {
      name = "xmppreference.nix";
      path = fromMof "xmppreference" windowsDefenderMof [
        "--resource-type" "WindowsDefender/WindowsDefender"
        "--mode" "psdsc-wrapper"
        "--option-path" "win.dsc.defender"
        "--key-prop" "IsSingleInstance"
      ];
    }
    # --- PSDesiredStateConfiguration/File (legacy built-in) ---
    {
      name = "psdsc_file.nix";
      # Source: microsoft/omi 9c950a8d test fixture — canonical schema is a
      # Windows OS component with no standalone upstream repo.
      path = fromMof "psdsc_file" omiDscSchemaMof [
        "--resource-type" "PSDesiredStateConfiguration/File"
        "--mode" "psdsc-wrapper"
        "--option-path" "win.dsc.psdsc.file"
      ];
    }
    # --- PSDscResources (all 12) ---
    { name = "psdsc_archive.nix";               path = psdscMof "Archive"               "MSFT_Archive"               [ ]; }
    { name = "psdsc_environment.nix";           path = psdscMof "Environment"           "MSFT_EnvironmentResource"   [ "Name" ]; }
    { name = "psdsc_group.nix";                 path = psdscMof "Group"                 "MSFT_GroupResource"         [ "GroupName" ]; }
    { name = "psdsc_msipackage.nix";            path = psdscMof "MsiPackage"            "MSFT_MsiPackage"            [ "ProductId" ]; }
    { name = "psdsc_registry.nix";              path = psdscMof "Registry"              "MSFT_RegistryResource"      [ ]; }
    { name = "psdsc_script.nix";               path = psdscMof "Script"               "MSFT_ScriptResource"        [ ]; }
    { name = "psdsc_service.nix";               path = psdscMof "Service"               "MSFT_ServiceResource"       [ "Name" ]; }
    { name = "psdsc_user.nix";                  path = psdscMof "User"                  "MSFT_UserResource"          [ "UserName" ]; }
    { name = "psdsc_windowsfeature.nix";        path = psdscMof "WindowsFeature"        "MSFT_WindowsFeature"        [ "Name" ]; }
    { name = "psdsc_windowsoptionalfeature.nix"; path = psdscMof "WindowsOptionalFeature" "MSFT_WindowsOptionalFeature" [ "Name" ]; }
    { name = "psdsc_windowspackagecab.nix";     path = psdscMof "WindowsPackageCab"     "MSFT_WindowsPackageCab"     [ "Name" ]; }
    { name = "psdsc_windowsprocess.nix";        path = psdscMof "WindowsProcess"        "MSFT_WindowsProcess"        [ ]; }
  ];
in
{
  inherit fromDscManifest fromDscSource generateAll;
}
