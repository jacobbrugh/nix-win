# networking.hosts — the NixOS option shape (IP address → list of hostnames),
# converged natively against %SystemRoot%\System32\drivers\etc\hosts.
#
# This used to compile to the NetworkingDsc HostsFile resource, which cost a
# full Windows PowerShell 5.1 adapter spawn (1.31 s measured) to add one line
# to a text file. It is now a convergence check like any other: one read of
# the file to test, a rewrite only when an entry is missing or points
# somewhere else.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.networking.hosts;

  # Flatten to (hostname, ip) pairs, the direction the file is written in.
  entries = lib.flatten (
    lib.mapAttrsToList (ip: names: map (name: { inherit ip name; }) names) cfg
  );

  psStr = s: "'" + (lib.replaceStrings [ "'" ] [ "''" ] s) + "'";

  psPairs = lib.concatMapStringsSep "\n            " (
    e: "@{ Name = ${psStr e.name}; Ip = ${psStr e.ip} }"
  ) entries;

  # The names this generation manages, for the next generation to diff
  # against: a name it no longer declares is taken back out of the hosts file.
  hostsJson = pkgs.writeText "hosts.json" (builtins.toJSON entries);
in
{
  options.networking.hosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.str);
    default = { };
    example = lib.literalExpression ''
      { "192.168.0.2" = [ "fileserver.local" "nameserver.local" ]; }
    '';
    description = ''
      Locally defined maps of hostnames to IP addresses (same shape as the
      NixOS option). Managed entries are added to the Windows hosts file;
      lines nix-win does not manage are left untouched.
    '';
  };

  config = lib.mkMerge [
    {
      system.build.networkingHosts = hostsJson;

      # Unconditional, so that removing the last entry still cleans up.
      system.activationScripts.networkingHostsRemoval = {
        deps = [ "files" ];
        text = ''
          $nhDeclared = @(Get-NixWinArtifact -Root $env:NIX_WIN_STORE_PATH -RelPath 'networking', 'hosts.json')
          $nhGone = @(Get-NixWinRemoved -RelPath 'networking', 'hosts.json' -Declared $nhDeclared)
          if ($nhGone.Count -gt 0) {
              Write-Host "nix-win: removing hosts entries that left the configuration..." -ForegroundColor Cyan
              $nhPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
              $nhGoneNames = @(foreach ($nhOld in $nhGone) { [string]$nhOld.name })

              # Split a hosts line into address, names and trailing comment.
              # Returns $null for blank and comment-only lines.
              function Split-NixWinHostsLine {
                  param([string]$Line)
                  $nhBody = $Line
                  $nhComment = '''
                  $nhHash = $Line.IndexOf('#')
                  if ($nhHash -ge 0) { $nhBody = $Line.Substring(0, $nhHash); $nhComment = $Line.Substring($nhHash) }
                  $nhParts = @($nhBody.Trim() -split '\s+' | ForEach-Object { if ($_) { $_ } })
                  if ($nhParts.Count -lt 2) { return $null }
                  return @{ Ip = $nhParts[0]; Names = @($nhParts[1..($nhParts.Count - 1)]); Comment = $nhComment }
              }

              Invoke-NixWinRemoval -Label "hosts $($nhGoneNames -join ', ')" -Present {
                  if (-not (Test-Path -LiteralPath $nhPath)) { return $false }
                  foreach ($nhLine in @(Get-Content -LiteralPath $nhPath)) {
                      $nhSplit = Split-NixWinHostsLine "$nhLine"
                      if ($null -eq $nhSplit) { continue }
                      foreach ($nhN in $nhSplit.Names) { if ($nhGoneNames -contains $nhN) { return $true } }
                  }
                  return $false
              } -Remove {
                  # Drop only the names that left the configuration: a line
                  # that also carries other names keeps them.
                  $nhNew = foreach ($nhLine in @(Get-Content -LiteralPath $nhPath)) {
                      $nhSplit = Split-NixWinHostsLine "$nhLine"
                      if ($null -eq $nhSplit) { $nhLine; continue }
                      $nhKeep = @(foreach ($nhN in $nhSplit.Names) { if ($nhGoneNames -notcontains $nhN) { $nhN } })
                      if ($nhKeep.Count -eq $nhSplit.Names.Count) { $nhLine; continue }
                      if ($nhKeep.Count -eq 0) { continue }
                      ("$($nhSplit.Ip)`t$($nhKeep -join ' ') $($nhSplit.Comment)").TrimEnd()
                  }
                  Set-Content -LiteralPath $nhPath -Value @($nhNew) -Encoding ascii
              }
          }
        '';
      };
    }

    (lib.mkIf (entries != [ ]) {
    system.convergeScripts."networking.hosts" = {
      # Ahead of the default so anything later in the phase that resolves a
      # name gets the managed entries first.
      priority = 500;

      # When the last entry is removed this converge script leaves the
      # configuration too. The names are taken out of the hosts file by the
      # networkingHostsRemoval step, which diffs name by name; this only keeps
      # the removal report from claiming the entry's changes stay.
      unsetScript = ''
        Write-Host "    (hosts names are removed by the networkingHostsRemoval step)" -ForegroundColor DarkGray
      '';

      testScript = ''
        $wanted = @(
            ${psPairs}
        )
        $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        if (-not (Test-Path -LiteralPath $hostsPath)) { return $false }
        $lines = @(Get-Content -LiteralPath $hostsPath)

        foreach ($w in $wanted) {
            $found = $false
            foreach ($line in $lines) {
                # Skip comments and blanks. A hosts line is
                # "<ip><whitespace><name> [name...]"; a name may legitimately
                # appear on a line with several aliases.
                $t = "$line".Trim()
                if ($t.Length -eq 0 -or $t.StartsWith('#')) { continue }
                $parts = @($t -split '\s+' | Where-Object { $_ })
                if ($parts.Count -lt 2) { continue }
                $names = $parts[1..($parts.Count - 1)]
                if ($names -contains $w.Name) {
                    # Present. It only counts as converged if it points at the
                    # address we declared — otherwise a stale entry would be
                    # reported in-desired-state forever.
                    if ($parts[0] -ne $w.Ip) { return $false }
                    $found = $true
                    break
                }
            }
            if (-not $found) { return $false }
        }
        return $true
      '';

      setScript = ''
        $wanted = @(
            ${psPairs}
        )
        $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        $lines = @()
        if (Test-Path -LiteralPath $hostsPath) { $lines = @(Get-Content -LiteralPath $hostsPath) }

        $managed = @($wanted | ForEach-Object { $_.Name })
        # Drop any existing line that mentions a managed name, then re-add.
        # Rewriting rather than editing in place keeps this idempotent whether
        # the previous entry was missing, stale, or duplicated.
        $kept = foreach ($line in $lines) {
            $t = "$line".Trim()
            if ($t.Length -eq 0 -or $t.StartsWith('#')) { $line; continue }
            $parts = @($t -split '\s+' | Where-Object { $_ })
            if ($parts.Count -lt 2) { $line; continue }
            $names = $parts[1..($parts.Count - 1)]
            $overlap = @($names | Where-Object { $managed -contains $_ })
            if ($overlap.Count -eq 0) { $line }
        }

        $new = @($kept)
        foreach ($w in $wanted) { $new += "$($w.Ip)`t$($w.Name)" }

        # The hosts file is ASCII and CRLF by convention; Set-Content's default
        # encoding on PowerShell 7 is UTF-8 without BOM, which is compatible.
        Set-Content -LiteralPath $hostsPath -Value $new -Encoding ascii
      '';
    };
    })
  ];
}
