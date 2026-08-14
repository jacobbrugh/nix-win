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

  # ── Adapter-group batching ──────────────────────────────────────────
  # Every generated module emits its resources one-per-adapter-group (see
  # ./generated/psdsc_script.nix and siblings). DSC v3 invokes an adapter
  # once per *top-level* resource, and each invocation cold-starts Windows
  # PowerShell 5.1, re-imports PSDesiredStateConfiguration 1.1, re-parses
  # the ~680 KB Get-DscResource cache and stats every tracked module file
  # — measured at ~0.8s of fixed overhead before any real work. A host
  # with 34 adapted resources pays that 34 times per operation.
  #
  # `properties.resources` is a list, so the adapter happily processes N
  # inner resources in one process. We therefore coalesce the groups,
  # partitioning them into dependency "waves" so ordering is preserved:
  # wave 0 is everything with no edge to another adapted resource, wave
  # n+1 depends on wave n's group. Members of a wave are independent by
  # construction, so their order within the group is irrelevant.
  #
  # This is safe against over-applying because the adapter's `set` in its
  # manifest carries `preTest: true` — it tests each inner resource itself
  # and only Sets the ones out of desired state.
  adapterType = "Microsoft.Windows/WindowsPowerShell";

  isAdapted = r: (r.type or null) == adapterType;
  adapted = builtins.filter isAdapted allResources;
  native = builtins.filter (r: !(isAdapted r)) allResources;
  adaptedNames = map (r: r.name) adapted;

  # "[resourceId('Some.Type/Name', 'the resource')]" -> "the resource".
  # Returns null for anything that doesn't parse as a resourceId lookup.
  depName =
    dep:
    let
      m = builtins.match ".*resourceId\\('[^']*', *'([^']*)'\\).*" dep;
    in
    if m == null then null else builtins.head m;

  dependsOnOf = r: r.dependsOn or [ ];
  adaptedDeps = r: builtins.filter (n: n != null && builtins.elem n adaptedNames) (map depName (dependsOnOf r));

  # name -> wave index, by fixpoint. Depth is bounded by the number of
  # adapted resources, so that many iterations always converges; one extra
  # step that still moves means the dependsOn graph has a cycle.
  waveStep =
    acc:
    builtins.listToAttrs (
      map (r: {
        inherit (r) name;
        value = lib.foldl' lib.max 0 (map (n: acc.${n} + 1) (adaptedDeps r));
      }) adapted
    );

  waveOf =
    let
      init = builtins.listToAttrs (map (r: { inherit (r) name; value = 0; }) adapted);
      settled = lib.foldl' (acc: _: waveStep acc) init (lib.range 1 (builtins.length adapted));
    in
    if waveStep settled != settled then
      throw "nix-win: cycle in dsc dependsOn between Microsoft.Windows/WindowsPowerShell resources"
    else
      settled;

  maxWave = lib.foldl' lib.max 0 (lib.attrValues waveOf);
  groupName = w: "nix-win adapted resources (wave ${toString w})";
  waveMembers = w: builtins.filter (r: waveOf.${r.name} == w) adapted;

  # A wave group inherits the previous wave's group plus every member edge
  # that points at something *outside* the adapted set (native resources).
  waveDeps =
    w:
    lib.optional (w > 0) "[resourceId('${adapterType}', '${groupName (w - 1)}')]"
    ++ lib.unique (
      lib.concatMap (
        r: builtins.filter (d: let n = depName d; in n == null || !(builtins.elem n adaptedNames)) (dependsOnOf r)
      ) (waveMembers w)
    );

  waveGroup =
    w:
    {
      name = groupName w;
      type = adapterType;
      properties.resources = lib.concatMap (r: r.properties.resources) (waveMembers w);
    }
    // lib.optionalAttrs (waveDeps w != [ ]) { dependsOn = waveDeps w; };

  # Native resources that named an adapted resource must now name the wave
  # group that swallowed it.
  retargetDep =
    d:
    let
      n = depName d;
    in
    if n != null && builtins.elem n adaptedNames then
      "[resourceId('${adapterType}', '${groupName (waveOf.${n})}')]"
    else
      d;

  retargetNative =
    r: if dependsOnOf r == [ ] then r else r // { dependsOn = lib.unique (map retargetDep r.dependsOn); };

  # Adapter groups stay ahead of the native resources, matching the
  # unbatched document order (sshResources and the adapted half of
  # nativeResourcesList already precede the native Registry entries).
  batchedResources =
    lib.optionals (adapted != [ ]) (map waveGroup (lib.range 0 maxWave)) ++ map retargetNative native;

  # Generate DSC v3 YAML document
  dscDocument = {
    "$schema" = "https://aka.ms/dsc/schemas/v3/bundled/config/document.vscode.json";
    resources = if cfg.batchAdapterResources then batchedResources else allResources;
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

    batchAdapterResources = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Coalesce the per-resource `Microsoft.Windows/WindowsPowerShell`
        adapter groups into one group per `dependsOn` wave, so DSC spawns
        Windows PowerShell 5.1 a handful of times per operation instead of
        once per resource.

        Set to `false` to emit one group per resource. That is markedly
        slower, but a failing resource is then reported by DSC under its
        own name rather than under a wave group, which is easier to read
        when debugging which resource broke.
      '';
    };

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
