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
            # real stdin.
            #
            # stdout is captured rather than echoed. dsc emits one JSON document
            # describing every resource, which ran to 64,716 characters here —
            # 74% of the entire switch log — and said nothing a reader could use,
            # since a converged resource reports changedProperties: null. Only
            # stderr still streams, so warnings and progress appear live.
            $dscOut = "" | dsc config set --file $dscConfig
            $dscExit = $LASTEXITCODE
            $env:PATH = $prevPath

            # Park the full document next to the generation record. It carries
            # per-resource durations, which is the only reliable way to attribute
            # time inside this phase.
            $dscJson = $null
            if ($env:NIX_WIN_GENERATION_DIR) {
                if (-not (Test-Path -LiteralPath $env:NIX_WIN_GENERATION_DIR)) {
                    New-Item -ItemType Directory -Path $env:NIX_WIN_GENERATION_DIR -Force | Out-Null
                }
                $dscJson = Join-Path $env:NIX_WIN_GENERATION_DIR "dsc-result.json"
                Set-Content -LiteralPath $dscJson -Value ($dscOut | Out-String) -NoNewline
            }

            # Summarise. Anything that changed or failed gets its own line; the
            # rest collapse into a count, with the full detail on disk.
            $doc = $null
            try { $doc = ($dscOut | Out-String) | ConvertFrom-Json } catch { $doc = $null }

            if ($null -eq $doc) {
                Write-Warning "nix-win: could not parse the dsc result document."
                if ($dscJson) { Write-Host "  raw output: $dscJson" -ForegroundColor DarkGray }
            } else {
                # A group/adapter resource nests its members under .result, so
                # flatten rather than assuming one level.
                $flat = [System.Collections.Generic.List[object]]::new()
                function Add-DscResults {
                    param($Nodes)
                    foreach ($n in $Nodes) {
                        if ($null -eq $n) { continue }
                        $names = $n.PSObject.Properties.Name
                        if ($names -contains 'result' -and $n.result -is [System.Object[]]) {
                            Add-DscResults -Nodes $n.result
                        } else {
                            $flat.Add($n)
                        }
                    }
                }
                if ($doc.PSObject.Properties.Name -contains 'results') {
                    Add-DscResults -Nodes $doc.results
                }

                $changedCount = 0
                foreach ($r in $flat) {
                    $rn = $r.PSObject.Properties.Name
                    $changed = @()
                    if ($rn -contains 'result' -and $null -ne $r.result -and
                        ($r.result.PSObject.Properties.Name -contains 'changedProperties') -and
                        $null -ne $r.result.changedProperties) {
                        $changed = @($r.result.changedProperties)
                    }
                    if ($changed.Count -gt 0) {
                        $changedCount++
                        $d = ""
                        if (($rn -contains 'metadata') -and $null -ne $r.metadata -and
                            ($r.metadata.PSObject.Properties.Name -contains 'Microsoft.DSC')) {
                            $d = " $($r.metadata.'Microsoft.DSC'.duration)"
                        }
                        Write-Host "  changed $($r.name) [$($r.type)] ($($changed -join ', '))$d" -ForegroundColor Green
                    }
                }

                foreach ($m in @($doc.messages)) {
                    if ($null -ne $m) { Write-Host "  $($m | ConvertTo-Json -Compress -Depth 4)" -ForegroundColor Yellow }
                }

                $total = ""
                if (($doc.PSObject.Properties.Name -contains 'metadata') -and
                    ($doc.metadata.PSObject.Properties.Name -contains 'Microsoft.DSC')) {
                    $total = " in $($doc.metadata.'Microsoft.DSC'.duration)"
                }
                $plural = if ($flat.Count -eq 1) { "resource" } else { "resources" }
                Write-Host "  $($flat.Count) $plural, $changedCount changed$total" -ForegroundColor DarkGray
                if ($dscJson) { Write-Host "  full result: $dscJson" -ForegroundColor DarkGray }

                if ($doc.PSObject.Properties.Name -contains 'hadErrors' -and $doc.hadErrors) {
                    throw "dsc reported errors; see $dscJson"
                }
            }

            if ($dscExit -ne 0) { throw "dsc config set exited $dscExit" }
        } else {
            Write-Warning "DSC v3 is not installed. Install via: winget install Microsoft.DSC"
        }
      '';
  };
}
