# DSC (Desired State Configuration) module for nix-win.
# Collects resources from all sub-modules and generates a single DSC v3 configuration YAML.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dsc;

  # Collect all resources from sub-modules.
  # ssh.nix uses its own sshResources option; all generated modules write to
  # nativeResourcesList.
  allResources =
    cfg.sshResources
    ++ cfg.nativeResourcesList
    ++ cfg.extraResources;

  # Generate DSC v3 YAML document
  dscDocument = {
    "$schema" = "https://aka.ms/dsc/schemas/v3/bundled/config/document.vscode.json";
    resources = allResources;
  };

  # Use Nix's toJSON then convert to YAML via yq
  dscJson = pkgs.writeText "dsc-config.json" (builtins.toJSON dscDocument);

  dscYaml = pkgs.runCommand "dsc-config.yaml" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
    yq -P < ${dscJson} > $out
  '';
in
{
  imports = [
    # Hand-written modules (business logic not derivable from schemas)
    ./ssh.nix
    # Generated modules (from DSC schemas via pkgs/generators/dsc2nix.py)
    ./generated
  ];

  options.dsc = {
    enable = lib.mkEnableOption "DSC v3 configuration management";

    extraResources = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Additional raw DSC resources to include in the configuration.";
    };

    # Internal options for hand-written modules
    sshResources = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      internal = true;
    };

    # Populated by all generated modules in ./generated.
    nativeResourcesList = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      internal = true;
    };
  };

  config = lib.mkIf cfg.enable {
    system.build.dscConfig = dscYaml;

    system.activationScripts.dsc.text = ''
        Write-Host "nix-win: applying DSC configuration..." -ForegroundColor Cyan
        $dscConfig = Join-Path $env:NIX_WIN_STORE_PATH "dsc\config.yaml"
        if (Get-Command dsc -ErrorAction SilentlyContinue) {
            # Strip PowerToys DSCModules from PATH during DSC run — DSC v3 can't
            # resolve the relative PowerToys.DSC.exe path in their manifests, causing
            # ~125 spurious warnings. We don't use any PowerToys DSC resources.
            $prevPath = $env:PATH
            $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -notlike '*PowerToys*DSCModules*' }) -join ';'
            # Pipe an empty string so dsc (and the psDscAdapter it spawns, which
            # inherits dsc's stdin) gets an immediate EOF instead of blocking on
            # an inherited open-pipe console stdin. Without this, launching the
            # switch with a never-closing stdin (e.g. `ssh host 'cmd'` forwarding
            # an open terminal, or a tool that pipes stdin) wedges the adapter
            # here forever at 0% CPU. Config comes from --file, so dsc needs no
            # real stdin; stdout/stderr stay on the console and still stream.
            "" | dsc config set --file $dscConfig
            $env:PATH = $prevPath
        } else {
            Write-Warning "DSC v3 is not installed. Install via: winget install Microsoft.DSC"
        }
      '';
  };
}
