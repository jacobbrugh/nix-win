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

  # Collect all resources from sub-modules. Generated modules write to
  # nativeResourcesList.
  allResources = cfg.nativeResourcesList ++ cfg.extraResources;

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

  # Which manifests this configuration actually needs. Everything else in the
  # dsc install directory is discovery cost we pay for nothing.
  resourceTypes = lib.unique (map (r: r.type or "") allResources);
  needsRegistry = lib.elem "Microsoft.Windows/Registry" resourceTypes;
  needsAdapter = lib.elem "Microsoft.Windows/WindowsPowerShell" resourceTypes;

  # Only curate when every declared type is one we know how to stage.
  # DSC_RESOURCE_PATH REPLACES the search path rather than adding to it, so a
  # type we did not anticipate (an extraResources entry naming some other
  # resource) would simply stop being discoverable. Falling back to default
  # discovery is slower but always correct, which is the right trade for a
  # tool that applies system configuration.
  stageableTypes = [
    "Microsoft.Windows/Registry"
    "Microsoft.Windows/WindowsPowerShell"
  ];
  unstageable = lib.subtractLists stageableTypes resourceTypes;
  curateDiscovery = allResources != [ ] && unstageable == [ ];

  curationBlock = lib.optionalString curateDiscovery ''
    # ── Curated resource discovery ────────────────────────────────────
    # dsc re-runs discovery on every invocation, scanning its whole install
    # directory plus every directory on PATH. Almost all of that is for
    # resources this configuration never uses: an appx discovery extension
    # that shells out to Get-AppxPackage (~1.2 s), the WMI adapter
    # enumerating 918 read-only resources (~0.69 s), and the pwsh-7
    # adapter's own List (~0.49 s). Measured on this host at 1.77-1.85 s
    # per invocation, entirely wasted.
    #
    # DSC_RESOURCE_PATH replaces that search path, so staging just the
    # manifests we use cuts discovery to 0.16-0.23 s.
    #
    # CAREFUL: it replaces the EXECUTABLE lookup path too, not only the
    # manifest search path. Staging the adapter manifest without a
    # directory containing powershell.exe produces
    #     WARN Executable 'powershell' not found for operation 'get' ...
    # and every adapted resource then fails. `dsc resource list` does NOT
    # reveal this — listing only reads manifests and never resolves their
    # executables, so it looks perfectly healthy. It takes an actual
    # adapted-resource invocation to surface it. Hence the explicit
    # WindowsPowerShell\v1.0 entry below.
    $prevResourcePath = $env:DSC_RESOURCE_PATH
    $dscStaged = $true
    # .Source is empty when dsc resolves to something that is not a file on
    # disk (a function or alias). Curation needs the install directory, so
    # fall back to default discovery rather than failing the switch.
    $dscReal = (Get-Command dsc).Source
    if ([string]::IsNullOrEmpty($dscReal)) {
        Write-Warning "nix-win: cannot locate the dsc executable on disk; falling back to default discovery."
        $dscStaged = $false
    }
    $dscPkg = $null
    $dscStage = Join-Path $env:LOCALAPPDATA "nix-win\dsc-resources"
    if ($dscStaged) {
        # WinGet installs dsc.exe as a shim symlink under ...\WinGet\Links;
        # the manifests live beside the real binary, not beside the shim.
        try {
            $dscLink = (Get-Item -LiteralPath $dscReal).LinkTarget
            if ($dscLink) { $dscReal = $dscLink }
        } catch { }
        $dscPkg = Split-Path -Parent $dscReal
    }

    $dscWanted = @(${
      lib.concatStringsSep ", " (
        (lib.optionals needsRegistry [
          "'registry.dsc.resource.json'"
          "'registry.exe'"
        ])
        ++ (lib.optionals needsAdapter [ "'windowspowershell.dsc.resource.json'" ])
      )
    })
    if ($dscStaged -and -not (Test-Path -LiteralPath $dscStage)) {
        New-Item -ItemType Directory -Path $dscStage -Force | Out-Null
    }

    # PRUNE anything we no longer want. The stage persists across switches, and
    # DSC_RESOURCE_PATH discovers whatever is in it — so a manifest staged by an
    # older generation keeps being found long after the config stopped using it.
    # Concretely: once the last adapted resource was migrated away, a leftover
    # windowspowershell.dsc.resource.json + psDscAdapter/ made every switch emit
    #   WARN Executable 'powershell' not found for operation 'get' ...
    # four times, because the adapter was still discovered while the PowerShell
    # directory it needs was (correctly) no longer on the path. Staging that only
    # ever adds is not idempotent; it accumulates.
    if ($dscStaged -and (Test-Path -LiteralPath $dscStage)) {
        $dscKeep = @($dscWanted)
        ${lib.optionalString needsAdapter ''$dscKeep += 'psDscAdapter' ''}
        foreach ($existing in (Get-ChildItem -LiteralPath $dscStage -Force)) {
            if ($dscKeep -notcontains $existing.Name) {
                Write-Host "  pruning stale staged resource: $($existing.Name)" -ForegroundColor DarkGray
                Remove-Item -LiteralPath $existing.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    foreach ($f in $(if ($dscStaged) { $dscWanted } else { @() })) {
        $src = Join-Path $dscPkg $f
        $dst = Join-Path $dscStage $f
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Warning "nix-win: $f is missing from the dsc install at $dscPkg; falling back to default discovery."
            $dscStaged = $false
            break
        }
        # Copy only when it differs, so a repeat switch does no IO.
        if (-not (Test-Path -LiteralPath $dst) -or
            (Get-Item -LiteralPath $dst).Length -ne (Get-Item -LiteralPath $src).Length) {
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }
    ${lib.optionalString needsAdapter ''
      # The adapter manifest invokes ./psDscAdapter/powershell.resource.ps1
      # relative to its own directory, so that directory has to come along.
      if ($dscStaged) {
          $adapterSrc = Join-Path $dscPkg "psDscAdapter"
          $adapterDst = Join-Path $dscStage "psDscAdapter"
          if (-not (Test-Path -LiteralPath $adapterSrc)) {
              Write-Warning "nix-win: psDscAdapter is missing from the dsc install; falling back to default discovery."
              $dscStaged = $false
          } elseif (-not (Test-Path -LiteralPath $adapterDst)) {
              Copy-Item -LiteralPath $adapterSrc -Destination $adapterDst -Recurse -Force
          }
      }
    ''}

    if ($dscStaged) {
        $dscPathEntries = @($dscStage)
        ${lib.optionalString needsAdapter ''
          # Where powershell.exe lives — the adapter's declared executable.
          $ps51 = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0"
          if (Test-Path -LiteralPath $ps51) { $dscPathEntries += $ps51 }
        ''}
        $env:DSC_RESOURCE_PATH = $dscPathEntries -join ';'
    }
  '';

  restoreBlock = lib.optionalString curateDiscovery ''
    if ($null -eq $prevResourcePath) {
        Remove-Item Env:DSC_RESOURCE_PATH -ErrorAction SilentlyContinue
    } else {
        $env:DSC_RESOURCE_PATH = $prevResourcePath
    }
  '';
in
{
  imports = [
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
${curationBlock}
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
${restoreBlock}

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
