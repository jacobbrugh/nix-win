#Requires -Version 7.0
<#
.SYNOPSIS
    nix-win — Declarative Windows system configuration via Nix (evaluated in WSL).

.DESCRIPTION
    Builds Windows system configuration using Nix inside WSL, then applies it
    to the Windows host by copying files and running activation scripts.

.PARAMETER Command
    The command to run: build, switch, rollback, list-generations, gc

.EXAMPLE
    nix-win switch
    nix-win build
    nix-win rollback
    nix-win list-generations
    nix-win gc -Keep 5
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet("build", "switch", "rollback", "list-generations", "gc")]
    [string]$Command,

    [Parameter()]
    [string]$FlakeUri = "",

    [Parameter()]
    [string]$FlakeAttr = "",

    [Parameter()]
    [string]$WslDistro = "NixOS",

    [Parameter()]
    [string]$WslUser = $env:USERNAME,

    [Parameter()]
    [int]$Keep = 5
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Resolve FlakeUri — if not given, look for a flake.nix in the current directory
# and translate its Windows path to a WSL path via wslpath.
if (-not $FlakeUri) {
    $cwdFlake = Join-Path (Get-Location).Path "flake.nix"
    if (-not (Test-Path $cwdFlake)) {
        throw "No flake.nix found in $((Get-Location).Path). Pass -FlakeUri <path:wsl-path> or cd into a directory containing a flake.nix."
    }
    $winPath = (Get-Location).Path.Replace('\', '/')
    $wslPath = (wsl.exe -d $WslDistro -- wslpath -a $winPath 2>$null).Trim()
    $FlakeUri = "path:$wslPath"
}

$StateDir = Join-Path $env:LOCALAPPDATA "nix-win"
$StateFile = Join-Path $StateDir "state.json"
$GenerationsDir = Join-Path $StateDir "generations"

# ── Helpers ────────────────────────────────────────────────────────────────

function Invoke-Wsl {
    param([string]$Cmd)
    $result = wsl.exe -d $WslDistro -u $WslUser -- bash -c $Cmd 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $Cmd`n$result"
    }
    return $result
}

function Get-StorePath {
    $hostname = (hostname).ToLower()
    $attr = if ($FlakeAttr) { $FlakeAttr } else { "winConfigurations.$hostname" }
    $uri = "$FlakeUri#$attr.config.system.build.toplevel"

    Write-Host "nix-win: building $uri ..." -ForegroundColor Cyan
    $storePath = Invoke-Wsl "nix build '$uri' --no-link --print-out-paths --no-write-lock-file 2>/dev/null"
    $storePath = ($storePath | Select-Object -Last 1).Trim()

    if (-not $storePath -or -not $storePath.StartsWith("/nix/store/")) {
        throw "nix build returned invalid store path: $storePath"
    }

    return $storePath
}

function ConvertTo-WinPath {
    param([string]$WslPath)
    return "\\wsl$\$WslDistro$($WslPath -replace '/', '\')"
}

function Get-State {
    if (Test-Path $StateFile) {
        $raw = Get-Content $StateFile | ConvertFrom-Json -AsHashtable
        return $raw
    }
    return @{
        currentGeneration = 0
        storePath         = ""
        files             = @{}
        links             = @{}
    }
}

function Save-State {
    param($State)
    if (-not (Test-Path $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    $State | ConvertTo-Json -Depth 10 | Set-Content $StateFile
}

function Resolve-TargetRoot {
    param([string]$Root)
    switch ($Root) {
        "home" { return $env:USERPROFILE }
        "appdata-local" { return $env:LOCALAPPDATA }
        "appdata-roaming" { return $env:APPDATA }
        "programdata" { return $env:ProgramData }
        default { throw "Unknown target root: $Root" }
    }
}

# ── Link Deployment ────────────────────────────────────────────────────────
# DSC's PSDesiredStateConfiguration/File resource can't create directory
# junctions or symbolic links, so the CLI applies them directly from the
# manifest's `links` array. State tracking mirrors the file side:
# declarations removed from config are unlinked on the next switch as long
# as the on-disk target is still a reparse point (real files/dirs left
# alone for safety).

function Expand-LinkString {
    param([string]$Value)
    # Expand $env:FOO references so the manifest can declare sources in
    # user-independent form (e.g. "$env:USERPROFILE\...").
    return $ExecutionContext.InvokeCommand.ExpandString($Value)
}

function Remove-ManagedLink {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Write-Host "  unlink $Path" -ForegroundColor DarkGray
        # Remove-Item on a junction deletes the reparse point, not the
        # junction target. -Recurse:$false is belt and suspenders.
        Remove-Item -LiteralPath $Path -Force -Recurse:$false -ErrorAction SilentlyContinue
    } else {
        Write-Warning "  skip unlink: $Path is not a reparse point (real file/dir left alone)"
    }
}

function New-ManagedLink {
    param(
        [string]$TargetPath,
        [string]$Source,
        [string]$LinkType,
        [bool]$Force
    )

    # Ensure the parent directory exists before trying to create the link.
    $parent = Split-Path -Parent $TargetPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $existing = Get-Item -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            # Already a link/junction. If it already points at our source,
            # we're done; otherwise replace it.
            if ($existing.Target -and $existing.Target -eq $Source) { return }
            Remove-Item -LiteralPath $TargetPath -Force
        } elseif ($Force) {
            Remove-Item -LiteralPath $TargetPath -Force -Recurse
        } else {
            Write-Warning "  skip link: $TargetPath is a real file/dir (set force=true to replace)"
            return
        }
    }

    $nativeType = switch ($LinkType) {
        "junction" { "Junction" }
        "symlink"  { "SymbolicLink" }
        default    { throw "Unknown linkType: $LinkType" }
    }
    Write-Host "  link $TargetPath -> $Source ($LinkType)" -ForegroundColor DarkGray
    New-Item -ItemType $nativeType -Path $TargetPath -Target $Source -Force | Out-Null
}

function Deploy-Links {
    param(
        [string]$WinStorePath,
        [hashtable]$PrevLinks
    )

    $newLinks = @{}

    $manifestFile = Join-Path $WinStorePath "manifest.json"
    $declaredLinks = @()
    if (Test-Path -LiteralPath $manifestFile) {
        $m = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
        if ($m -and $m.PSObject.Properties['links'] -and $m.links) {
            $declaredLinks = @($m.links)
        }
    }

    # Index declared keys up front so the removal pass can diff against the
    # previous generation's state before we start mutating anything.
    $newKeys = @{}
    foreach ($entry in $declaredLinks) {
        $base = Resolve-TargetRoot $entry.targetRoot
        $targetPath = Join-Path $base $entry.path
        $newKeys[$targetPath.Replace('\', '/')] = $true
    }

    # Removal pass: anything that was managed last generation but isn't
    # declared now gets unlinked (only if it's still a reparse point).
    foreach ($key in @($PrevLinks.Keys)) {
        if (-not $newKeys.ContainsKey($key)) {
            $path = $key -replace '/', '\'
            Remove-ManagedLink -Path $path
        }
    }

    # Creation pass: materialize every declared link.
    foreach ($entry in $declaredLinks) {
        $base = Resolve-TargetRoot $entry.targetRoot
        $targetPath = Join-Path $base $entry.path
        $source = Expand-LinkString $entry.source
        $force = [bool]$entry.force

        New-ManagedLink `
            -TargetPath $targetPath `
            -Source $source `
            -LinkType $entry.linkType `
            -Force $force

        $newLinks[$targetPath.Replace('\', '/')] = @{
            status   = "managed"
            linkType = $entry.linkType
            source   = $source
        }
    }

    return $newLinks
}

# ── File Deployment ────────────────────────────────────────────────────────

# Copy a file to a target path, tolerating the case where the destination
# is currently held open as a mapped image by another process (DLLs loaded
# by running services, executables of live processes, etc.).
#
# The direct overwrite path (Copy-Item -Force) fails with
# ERROR_SHARING_VIOLATION in that case, because `CreateFile(GENERIC_WRITE)`
# on the destination conflicts with the loader's existing handle — which
# was opened without FILE_SHARE_WRITE. See Larry Osterman's 2004 post on
# FILE_SHARE_DELETE for the loader's actual share set:
#   https://learn.microsoft.com/en-us/archive/blogs/larryosterman/why-is-it-file_share_read-and-file_share_write-anyway
#
# But the loader does grant FILE_SHARE_DELETE, so MoveFile succeeds even
# while the file is mapped. Fall back to rename-then-copy: move the live
# file aside to a `.nix-win-stale-<ticks>` name (the existing mapping
# stays pinned to the underlying file identity, so running processes keep
# working), then copy the new bytes into the freed path. New processes
# that LoadLibrary the original path pick up the new bytes; Sweep-StaleFiles
# cleans up on a later switch once the holder exits.
#
# This mirrors the pattern every Windows auto-updater relies on (Chrome,
# VS Code, Windows Update for user-space DLLs).
function Copy-FileRobust {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    # Happy path: direct overwrite succeeds unless a live handle pins the
    # destination without FILE_SHARE_WRITE.
    try {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
        return
    } catch [System.IO.IOException] {
        # Most likely ERROR_SHARING_VIOLATION (win32 32). Fall through.
    } catch [System.UnauthorizedAccessException] {
        # Same class of failure; also handled by rename-replace.
    }

    $stale = "$Destination.nix-win-stale-$([DateTime]::UtcNow.Ticks)"
    try {
        [System.IO.File]::Move($Destination, $stale)
    } catch {
        throw "nix-win: cannot replace in-use file $Destination ($_)"
    }

    try {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
    } catch {
        # Rollback. Use Move() with overwrite so a racing writer at
        # $Destination doesn't trap the old file in .stale-* limbo.
        [System.IO.File]::Move($stale, $Destination, $true)
        throw
    }

    # Best-effort cleanup. Typically fails the first time because the
    # holder is still live; Sweep-StaleFiles on the next switch retries
    # once the holder has exited (e.g. user restarted wezterm-mux-server).
    try {
        Remove-Item -LiteralPath $stale -Force -ErrorAction Stop
    } catch {
        Write-Host "  (deferred: $stale still in use)" -ForegroundColor DarkYellow
    }
}

# Best-effort cleanup of rename-aside markers from prior switches.
# Called at the top of each root's Deploy-Files pass so orphans don't
# accumulate across generations once their holders exit.
function Sweep-StaleFiles {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return }
    Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.nix-win-stale-*' `
        -ErrorAction SilentlyContinue | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch {}
    }
}

function Deploy-Files {
    param(
        [string]$WinStorePath,
        [hashtable]$PrevFiles
    )

    $newFiles = @{}
    $roots = @("home", "appdata-local", "appdata-roaming", "programdata")

    foreach ($root in $roots) {
        Sweep-StaleFiles -Root (Resolve-TargetRoot $root)

        $sourceDir = Join-Path $WinStorePath $root
        if (-not (Test-Path $sourceDir)) { continue }

        $baseTarget = Resolve-TargetRoot $root
        $files = Get-ChildItem -Path $sourceDir -Recurse -File

        foreach ($file in $files) {
            $relativePath = $file.FullName.Substring($sourceDir.Length + 1)
            $targetPath = Join-Path $baseTarget $relativePath
            $targetDir = Split-Path $targetPath -Parent

            if (-not (Test-Path $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }

            # Backup existing file if not previously managed
            $fileKey = $targetPath.Replace('\', '/')
            if ((Test-Path $targetPath) -and -not $PrevFiles.ContainsKey($fileKey)) {
                $genDir = Join-Path $GenerationsDir $script:NewGeneration "backups"
                if (-not (Test-Path $genDir)) {
                    New-Item -ItemType Directory -Path $genDir -Force | Out-Null
                }
                $backupName = $targetPath.Replace('\', '--').Replace(':', '-')
                Copy-Item $targetPath (Join-Path $genDir $backupName) -Force
            }

            Copy-FileRobust -Source $file.FullName -Destination $targetPath
            $newFiles[$fileKey] = @{ status = "managed" }
            Write-Host "  $relativePath -> $targetPath" -ForegroundColor DarkGray
        }
    }

    return $newFiles
}

# ── Commands ───────────────────────────────────────────────────────────────

function Invoke-Build {
    $storePath = Get-StorePath
    $winPath = ConvertTo-WinPath $storePath
    Write-Host "nix-win: built $storePath" -ForegroundColor Green
    Write-Host "  Windows path: $winPath" -ForegroundColor DarkGray
    return @{ StorePath = $storePath; WinPath = $winPath }
}

function Invoke-Switch {
    $build = Invoke-Build
    $state = Get-State
    $prevFiles = if ($state.files) { $state.files } else { @{} }
    $prevLinks = if ($state.ContainsKey('links') -and $state.links) { $state.links } else { @{} }

    $script:NewGeneration = $state.currentGeneration + 1
    $genDir = Join-Path $GenerationsDir $script:NewGeneration
    New-Item -ItemType Directory -Path $genDir -Force | Out-Null

    # Save store path for this generation
    $build.StorePath | Set-Content (Join-Path $genDir "store-path.txt")
    (Get-Date -Format "o") | Set-Content (Join-Path $genDir "timestamp.txt")

    # Copy manifest
    $manifestSrc = Join-Path $build.WinPath "manifest.json"
    if (Test-Path $manifestSrc) {
        Copy-Item $manifestSrc (Join-Path $genDir "manifest.json")
    }

    Write-Host "`nnix-win: deploying files..." -ForegroundColor Cyan
    $newFiles = Deploy-Files -WinStorePath $build.WinPath -PrevFiles $prevFiles

    Write-Host "`nnix-win: deploying links..." -ForegroundColor Cyan
    $newLinks = Deploy-Links -WinStorePath $build.WinPath -PrevLinks $prevLinks

    Write-Host "`nnix-win: running activation scripts..." -ForegroundColor Cyan
    $env:NIX_WIN_STORE_PATH = $build.WinPath
    $activateScript = Join-Path $build.WinPath "activate.ps1"
    if (Test-Path $activateScript) {
        # Wrap the activation call so a throw doesn't silently skip Save-State
        # with nothing but a small default PS error block. The failure mode
        # we're guarding against: activate.ps1 invokes DSC/WinGet/PowerShell
        # modules, any of which can throw. Before this wrapper, a throw at
        # that depth produced a generic "ERROR: ..." with no framing, the
        # script exited, and state.json stayed at the previous generation
        # with no obvious indication that the generation we just wrote to
        # disk (gen dir + manifest) was never actually activated.
        try {
            & $activateScript
        } catch {
            $err = $_
            Write-Host ""
            Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Red
            Write-Host " nix-win: ACTIVATION FAILED" -ForegroundColor Red
            Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Red
            Write-Host ""
            Write-Host "Generation $script:NewGeneration was NOT saved." -ForegroundColor Red
            Write-Host "Current state remains at generation $($state.currentGeneration)." -ForegroundColor Red
            Write-Host ""
            if ($err.InvocationInfo -and $err.InvocationInfo.PositionMessage) {
                Write-Host "Failed at:" -ForegroundColor Red
                Write-Host $err.InvocationInfo.PositionMessage -ForegroundColor Yellow
                Write-Host ""
            }
            Write-Host "Error:" -ForegroundColor Red
            Write-Host "  $($err.Exception.Message)" -ForegroundColor Yellow
            if ($err.ScriptStackTrace) {
                Write-Host ""
                Write-Host "Stack trace:" -ForegroundColor Red
                Write-Host $err.ScriptStackTrace -ForegroundColor DarkGray
            }
            Write-Host ""
            Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Red
            # Re-throw so the overall script exits non-zero and any wrapping
            # script (CI, scheduled task) sees the failure.
            throw
        }
    }

    # Update state — only reached on successful activation
    $newState = @{
        currentGeneration = $script:NewGeneration
        storePath         = $build.StorePath
        activatedAt       = (Get-Date -Format "o")
        files             = $newFiles
        links             = $newLinks
    }
    Save-State $newState

    Write-Host "`nnix-win: switch to generation $($script:NewGeneration) complete." -ForegroundColor Green
}

function Invoke-Rollback {
    $state = Get-State
    $prevGen = $state.currentGeneration - 1
    if ($prevGen -lt 1) {
        Write-Error "No previous generation to roll back to."
        return
    }
    $genDir = Join-Path $GenerationsDir $prevGen
    $storePathFile = Join-Path $genDir "store-path.txt"
    if (-not (Test-Path $storePathFile)) {
        Write-Error "Generation $prevGen state not found at $genDir"
        return
    }
    Write-Host "nix-win: rolling back to generation $prevGen" -ForegroundColor Yellow
    $storePath = (Get-Content $storePathFile).Trim()
    $FlakeAttr = ""  # Use direct store path
    # Re-activate from previous store path
    $winPath = ConvertTo-WinPath $storePath
    $env:NIX_WIN_STORE_PATH = $winPath
    $activateScript = Join-Path $winPath "activate.ps1"
    if (Test-Path $activateScript) {
        & $activateScript
    }
    Write-Host "nix-win: rolled back to generation $prevGen." -ForegroundColor Green
}

function Invoke-ListGenerations {
    if (-not (Test-Path $GenerationsDir)) {
        Write-Host "No generations found." -ForegroundColor Yellow
        return
    }
    $state = Get-State
    Get-ChildItem $GenerationsDir -Directory | Sort-Object { [int]$_.Name } | ForEach-Object {
        $gen = $_.Name
        $tsFile = Join-Path $_.FullName "timestamp.txt"
        $ts = if (Test-Path $tsFile) { Get-Content $tsFile } else { "unknown" }
        $current = if ($gen -eq $state.currentGeneration) { " *" } else { "" }
        Write-Host "  Generation $gen — $ts$current"
    }
}

function Invoke-GC {
    if (-not (Test-Path $GenerationsDir)) { return }
    $state = Get-State
    $gens = Get-ChildItem $GenerationsDir -Directory | Sort-Object { [int]$_.Name } -Descending
    $toRemove = $gens | Select-Object -Skip $Keep | Where-Object { $_.Name -ne $state.currentGeneration }
    foreach ($gen in $toRemove) {
        Write-Host "  Removing generation $($gen.Name)" -ForegroundColor DarkGray
        Remove-Item $gen.FullName -Recurse -Force
    }
    Write-Host "nix-win: kept $Keep most recent generations." -ForegroundColor Green
}

# ── Main ───────────────────────────────────────────────────────────────────

switch ($Command) {
    "build" { Invoke-Build | Out-Null }
    "switch" { Invoke-Switch }
    "rollback" { Invoke-Rollback }
    "list-generations" { Invoke-ListGenerations }
    "gc" { Invoke-GC }
}
