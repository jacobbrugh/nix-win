# DAG-based activation script ordering for nix-win.
# Each activation entry has a name, text, and list of dependencies.
# Entries are topologically sorted and concatenated into the final activation script.
{ lib }:
let
  # Simple topological sort on activation entries
  # entries: attrset of { text: string; deps: [string]; }
  # Returns: list of { name: string; text: string; } in dependency order
  sortActivation =
    entries:
    let
      names = builtins.attrNames entries;

      # A dep naming a non-existent entry is an error, not a no-op: silently
      # dropping it reorders the script instead of failing, which is invisible
      # at eval and only shows up as wrong runtime behavior.
      effectiveDeps =
        name:
        map (
          d:
          if builtins.hasAttr d entries then
            d
          else
            throw "nix-win: activation script '${name}' depends on '${d}', which does not exist. (If this was a nix-win built-in phase, it may have moved to the winHome class; see the migration notes in the README.)"
        ) (entries.${name}.deps or [ ]);

      # Kahn's algorithm (iterative via fold)
      go =
        { sorted, remaining }:
        if remaining == [ ] then
          sorted
        else
          let
            # Find entries whose deps are all in sorted
            sortedNames = map (e: e.name) sorted;
            ready = builtins.filter (
              name: builtins.all (d: builtins.elem d sortedNames) (effectiveDeps name)
            ) remaining;
          in
          if ready == [ ] then
            throw "nix-win: circular dependency in activation scripts among: ${builtins.concatStringsSep ", " remaining}"
          else
            go {
              sorted = sorted ++ map (name: { inherit name; inherit (entries.${name}) text; }) ready;
              remaining = builtins.filter (name: !(builtins.elem name ready)) remaining;
            };
    in
    go {
      sorted = [ ];
      remaining = names;
    };

  # Concatenate sorted activation entries into a single PowerShell script.
  #
  # Each phase is bracketed with a stopwatch and emits one timing record, so
  # the switch is attributable per phase rather than being one opaque block.
  # The brackets are plain statements rather than a wrapping scriptblock:
  # phases share state with each other (the dsc phase reads variables the
  # curation block sets, entries assume `return` is not swallowed), so
  # wrapping each one in its own scope would change behaviour.
  #
  # `stage` is the argument so the emitted records slot into the same schema
  # the Unix producers use; `timingStage` lets the caller distinguish the
  # system scope from the per-user one.
  mkActivationScript =
    entries: timingStage:
    let
      sorted = sortActivation entries;
      sections = map (
        entry:
        ''
          # ── ${entry.name} ──────────────────────────────────────────────
          $__nixwin_t0 = [System.Diagnostics.Stopwatch]::StartNew()
          $__nixwin_rc = 0
          try {
          ${entry.text}
          } catch {
              $__nixwin_rc = 1
              $__nixwin_t0.Stop()
              Emit-NixWinTiming -Stage '${timingStage}' -Step '${entry.name}' `
                  -DurationMs $__nixwin_t0.Elapsed.TotalMilliseconds -ExitCode 1
              throw
          }
          $__nixwin_t0.Stop()
          Emit-NixWinTiming -Stage '${timingStage}' -Step '${entry.name}' `
              -DurationMs $__nixwin_t0.Elapsed.TotalMilliseconds -ExitCode $__nixwin_rc
        ''
      ) sorted;
    in
    builtins.concatStringsSep "\n" sections;

  # Emitter shared by both activation scopes. Appends one JSON record per
  # phase to a spool that otelcol's filelog receiver tails.
  #
  # The record carries exactly the nine keys the Unix producers emit
  # (pkgs/run-activation-steps, pkgs/activation-switch-timer), so the existing
  # Grafana dashboard shows Windows phases beside the Unix ones with no
  # dashboard change. `generation` is the store path, matching what the Unix
  # side reads from /run/current-system.
  #
  # Writing to a spool on disk, never pushing in-process: a switch must not
  # block on, or fail because of, a telemetry endpoint.
  timingPrelude = ''
    # ── Activation timing ─────────────────────────────────────────────
    $script:NixWinTimingSpool = $null
    function Emit-NixWinTiming {
        param(
            [Parameter(Mandatory)][string]$Stage,
            [Parameter(Mandatory)][string]$Step,
            [Parameter(Mandatory)][double]$DurationMs,
            [int]$ExitCode = 0
        )
        try {
            if ($null -eq $script:NixWinTimingSpool) {
                # ProgramData first: the system switch runs elevated and the
                # shipper reads as LocalSystem. `switch -Home` is deliberately
                # unelevated, so fall back to the user's own state dir, which
                # the receiver also globs.
                $candidates = @(
                    (Join-Path $env:ProgramData 'nix-win\activation-timing'),
                    (Join-Path $env:LOCALAPPDATA 'nix-win\activation-timing')
                )
                foreach ($dir in $candidates) {
                    try {
                        if (-not (Test-Path -LiteralPath $dir)) {
                            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
                        }
                        $probe = Join-Path $dir 'events.jsonl'
                        # Prove writability now rather than discovering it per record.
                        [System.IO.File]::AppendAllText($probe, "")
                        $script:NixWinTimingSpool = $probe
                        break
                    } catch { continue }
                }
                if ($null -eq $script:NixWinTimingSpool) { $script:NixWinTimingSpool = "" }
            }
            if ([string]::IsNullOrEmpty($script:NixWinTimingSpool)) { return }

            $gen = ""
            if ($env:NIX_WIN_STORE_PATH) { $gen = $env:NIX_WIN_STORE_PATH }
            elseif ($env:NIX_WIN_HOME_STORE_PATH) { $gen = $env:NIX_WIN_HOME_STORE_PATH }

            $now = [DateTimeOffset]::UtcNow
            # Unix epoch nanoseconds. DateTimeOffset only resolves to 100ns
            # ticks, so scale rather than pretending to nanosecond precision.
            $nanos = ($now.ToUnixTimeMilliseconds() * 1000000)
            $record = [ordered]@{
                ts             = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffffffK')
                time_unix_nano = $nanos
                host           = $env:COMPUTERNAME.ToLower()
                generation     = $gen
                stage          = $Stage
                step           = $Step
                duration_ms    = [Math]::Round($DurationMs, 3)
                exit_code      = $ExitCode
                source         = 'inline'
            }
            $line = ($record | ConvertTo-Json -Compress -Depth 3)
            [System.IO.File]::AppendAllText($script:NixWinTimingSpool, $line + "`n")
        } catch {
            # Telemetry must never be able to fail a switch.
            Write-Host "  (timing record dropped: $($_.Exception.Message))" -ForegroundColor DarkGray
        }
    }
  '';
in
{
  inherit sortActivation mkActivationScript timingPrelude;
}
