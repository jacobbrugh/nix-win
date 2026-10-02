# ── Removal of what the previous generation declared ──────────────────
# Inlined into the system activate.ps1 (lib/activation.nix reads this file).
#
# Each module writes a JSON artifact into its generation. During activation
# the generation being replaced is still reachable at
# $env:NIX_WIN_OLD_STORE_PATH -- nix-darwin's /run/current-system,
# home-manager's $oldGenPath -- so a step can diff the old artifact against
# its own and remove what disappeared from the configuration.
#
# The variable is unset on a first activation, when the old store path has
# been garbage-collected, and under a CLI that predates it. Every helper here
# treats that as "the old state is unknown" and removes nothing.

$script:NixWinRemovalWarnings = [System.Collections.Generic.List[string]]::new()

# Emit the entries of a JSON array artifact, one per pipeline object.
# Callers ALWAYS wrap the call in @(): an empty array, a single element and
# a missing file all have to come out as an array.
function Get-NixWinArtifact {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Root,
        # Path segments, not a joined string, so the same call works on any
        # platform's separator (the logic is unit-tested under Linux pwsh).
        [Parameter(Mandatory)][string[]]$RelPath
    )
    if ([string]::IsNullOrEmpty($Root)) { return }
    $nwFile = $Root
    foreach ($nwSeg in $RelPath) { $nwFile = Join-Path $nwFile $nwSeg }
    if (-not (Test-Path -LiteralPath $nwFile -PathType Leaf)) { return }
    $nwRaw = Get-Content -LiteralPath $nwFile -Raw
    if ([string]::IsNullOrWhiteSpace($nwRaw)) { return }
    # `'null' | ConvertFrom-Json` yields one $null object; drop it.
    foreach ($nwItem in @($nwRaw | ConvertFrom-Json)) {
        if ($null -ne $nwItem) { $nwItem }
    }
}

# The old generation's entries whose key is absent from the declared set.
# A read failure degrades to "nothing to remove", loudly.
function Get-NixWinRemoved {
    param(
        [Parameter(Mandatory)][string[]]$RelPath,
        [object[]]$Declared = @(),
        [string]$Key = 'name'
    )
    $nwOldRoot = $env:NIX_WIN_OLD_STORE_PATH
    if ([string]::IsNullOrEmpty($nwOldRoot)) { return }

    $nwCi = [System.StringComparer]::OrdinalIgnoreCase
    $nwHave = [System.Collections.Generic.HashSet[string]]::new($nwCi)
    $nwSeen = [System.Collections.Generic.HashSet[string]]::new($nwCi)
    foreach ($nwD in @($Declared)) {
        if ($null -eq $nwD) { continue }
        $nwDProp = $nwD.PSObject.Properties[$Key]
        if ($null -ne $nwDProp) { [void]$nwHave.Add([string]$nwDProp.Value) }
    }

    $nwOld = @()
    try {
        $nwOld = @(Get-NixWinArtifact -Root $nwOldRoot -RelPath $RelPath)
    } catch {
        Write-Warning "nix-win: cannot read $($RelPath -join '/') from the previous generation ($($_.Exception.Message)); nothing is removed for it this switch."
        return
    }
    foreach ($nwO in $nwOld) {
        # Older generations may lack a field newer code keys on.
        $nwOProp = $nwO.PSObject.Properties[$Key]
        if ($null -eq $nwOProp) { continue }
        $nwK = [string]$nwOProp.Value
        if (-not $nwHave.Contains($nwK) -and $nwSeen.Add($nwK)) { $nwO }
    }
}

# Remove one item that left the configuration.
#
# A failure here is a warning, never a failed switch. The recipe comes from
# the immutable previous generation: if it failed the switch, state would not
# be saved, the next switch would diff against the same generation and fail
# the same way, and no configuration edit could ever get past it. (nix-darwin's
# launchd unload and reverse-patch are both `|| true` for the same reason.)
function Invoke-NixWinRemoval {
    param(
        [Parameter(Mandatory)][string]$Label,
        # Returns $true while the item still exists.
        [Parameter(Mandatory)][scriptblock]$Present,
        [Parameter(Mandatory)][scriptblock]$Remove
    )
    try {
        $nwThere = @(& $Present)
        if ($nwThere.Count -eq 0 -or -not $nwThere[-1]) {
            Write-Host "  $Label already absent" -ForegroundColor DarkGray
            return
        }
        & $Remove | Out-Null
        Write-Host "  $Label removed" -ForegroundColor Yellow
    } catch {
        $script:NixWinRemovalWarnings.Add("$Label`: $($_.Exception.Message)")
        Write-Host "  $Label REMOVAL FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Printed once, at the end of activation.
function Write-NixWinRemovalWarnings {
    if ($script:NixWinRemovalWarnings.Count -eq 0) { return }
    Write-Host ""
    Write-Host "nix-win: $($script:NixWinRemovalWarnings.Count) removal(s) did not complete and are NOT retried:" -ForegroundColor Yellow
    foreach ($nwW in $script:NixWinRemovalWarnings) {
        Write-Host "  $nwW" -ForegroundColor Yellow
    }
}
