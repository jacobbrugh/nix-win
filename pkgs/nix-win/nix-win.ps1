#Requires -Version 7.0
<#
.SYNOPSIS
    nix-win — Declarative Windows system configuration via Nix (evaluated in WSL).

.DESCRIPTION
    Builds Windows system configuration using Nix inside WSL, then applies it
    to the Windows host by copying files and running activation scripts.

.PARAMETER Command
    The command to run: build, switch, rollback, list-generations, gc

.PARAMETER Home
    Operate on the per-user (winHome) scope instead of the system scope.
    `nix-win switch -Home` builds winHomeConfigurations."<user>@<host>"
    (falling back to winHomeConfigurations."<user>") and applies it without
    elevation: home files, junctions/symlinks, HKCU environment, and the
    user activation script. System switches embed and apply the current
    user's home scope automatically.

.EXAMPLE
    nix-win switch
    nix-win switch -Home
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
    [Alias("Home")]
    [switch]$HomeScope,

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

$Scope = if ($HomeScope) { "home" } else { "system" }

# Translate a Windows path to a `path:`-prefixed flakeref pointing at the
# equivalent location inside WSL. `wslpath` handles drive paths
# (C:\... -> /mnt/c/...) but mistranslates \\wsl$ UNC paths, so those are
# stripped to their in-distro path directly. Only genuine Windows paths may be
# passed here: `wslpath -a` would corrupt an already-absolute /unix path into
# /mnt/c/unix.
function ConvertTo-WslFlakeRef {
    param([string]$WinPath)
    if ($WinPath -match '^\\\\wsl(?:\$|\.localhost)\\[^\\]+\\(.*)$') {
        return "path:/$($Matches[1] -replace '\\', '/')"
    }
    $norm = $WinPath.Replace('\', '/')
    $wslPath = (wsl.exe -d $WslDistro -- wslpath -a $norm 2>$null).Trim()
    if (-not $wslPath) { throw "Could not translate Windows path to a WSL path: $WinPath" }
    return "path:$wslPath"
}

# Resolve FlakeUri. With no -FlakeUri, use the current directory's flake. A
# Windows drive (C:\...) or UNC (\\wsl$\...) path is translated to its WSL
# location; a flakeref (path:/…, github:…, git+…) or bare /unix path is used
# verbatim.
#
# $script:SourceWinPath records the *Windows-side* source root when the flake
# lives on a drive path, so the build can avoid handing it to the Nix daemon
# across the 9p bridge — see the staging block below. A \\wsl$ UNC path is
# already inside the distro (ext4), and a bare flakeref names something Nix
# fetches itself, so neither is staged.
$script:SourceWinPath = $null
if (-not $FlakeUri) {
    $cwdFlake = Join-Path (Get-Location).Path "flake.nix"
    if (-not (Test-Path $cwdFlake)) {
        throw "No flake.nix found in $((Get-Location).Path). Pass -FlakeUri <Windows path, WSL path, or flakeref> or cd into a directory containing a flake.nix."
    }
    if ((Get-Location).Path -match '^[A-Za-z]:[\\/]') { $script:SourceWinPath = (Get-Location).Path }
    $FlakeUri = ConvertTo-WslFlakeRef (Get-Location).Path
}
elseif ($FlakeUri -match '^[A-Za-z]:[\\/]' -or $FlakeUri -match '^\\\\') {
    if ($FlakeUri -match '^[A-Za-z]:[\\/]') { $script:SourceWinPath = $FlakeUri }
    $FlakeUri = ConvertTo-WslFlakeRef $FlakeUri
}

$StateDir = Join-Path $env:LOCALAPPDATA "nix-win"

# One-time migration from the single-scope v1 layout (state.json +
# generations/<n>) to the scope-split v2 layout (state.system.json +
# generations/system/<n>). Everything v1 tracked was applied by an
# (elevated) system switch, so it lands in the system scope.
$legacyState = Join-Path $StateDir "state.json"
if ((Test-Path $legacyState) -and -not (Test-Path (Join-Path $StateDir "state.system.json"))) {
    Write-Host "nix-win: migrating v1 state to the scope-split layout..." -ForegroundColor Yellow
    Move-Item $legacyState (Join-Path $StateDir "state.system.json")
    $legacyGens = Join-Path $StateDir "generations"
    $sysGens = Join-Path $legacyGens "system"
    if (Test-Path $legacyGens) {
        $numeric = Get-ChildItem $legacyGens -Directory | Where-Object { $_.Name -match '^\d+$' }
        if ($numeric) {
            New-Item -ItemType Directory -Path $sysGens -Force | Out-Null
            foreach ($g in $numeric) { Move-Item $g.FullName (Join-Path $sysGens $g.Name) }
        }
    }
}

$StateFile = Join-Path $StateDir "state.$Scope.json"
$GenerationsDir = Join-Path $StateDir "generations" | Join-Path -ChildPath $Scope

# ── Helpers ────────────────────────────────────────────────────────────────

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Wsl {
    param([string]$Cmd)
    $result = wsl.exe -d $WslDistro -u $WslUser -- bash -c $Cmd 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $Cmd`n$result"
    }
    return $result
}

function Invoke-NixBuild {
    param([string]$Uri)

    # Run the build directly (not through Invoke-Wsl) so nix's stderr — its
    # progress bar / build log — streams live to the host console exactly as it
    # would on the host, instead of being buffered until the build finishes.
    # `--print-out-paths` writes the resolved store path to stdout, which we DO
    # capture here. Leaving stderr unredirected (no `2>&1`) is the whole point:
    # PowerShell captures only stdout into $output and passes the native
    # command's stderr straight through to the console as it arrives.
    #
    # Disable native-exit auto-throw locally so the explicit $LASTEXITCODE check
    # below owns the failure message; pwsh 7.4+ with $ErrorActionPreference='Stop'
    # would otherwise throw a generic "wsl.exe exited with code N" at the
    # assignment. nix's own error has already streamed to the console above, so
    # "See the build log above" is accurate.
    $PSNativeCommandUseErrorActionPreference = $false
    $output = wsl.exe -d $WslDistro -u $WslUser -- bash -c "nix build '$Uri' --no-link --print-out-paths --no-write-lock-file"
    if ($LASTEXITCODE -ne 0) {
        throw "nix build failed (exit $LASTEXITCODE). See the build log above."
    }

    $storePath = ($output | Select-Object -Last 1).Trim()
    if (-not $storePath -or -not $storePath.StartsWith("/nix/store/")) {
        throw "nix build returned invalid store path. Full output:`n$output"
    }

    return $storePath
}

function Get-StorePath {
    $hostname = (hostname).ToLower()
    $user = $env:USERNAME.ToLower()

    if ($FlakeAttr) {
        $suffix = if ($HomeScope) { "activationPackage" } else { "config.system.build.toplevel" }
        $uri = "$FlakeUri#$FlakeAttr.$suffix"
        Write-Host "nix-win: building $uri ..." -ForegroundColor Cyan
        return Invoke-NixBuild -Uri $uri
    }

    if ($HomeScope) {
        # Mirror home-manager's attribute resolution: "user@host" first,
        # then bare "user".
        $primary = "winHomeConfigurations.`"$user@$hostname`".activationPackage"
        $fallback = "winHomeConfigurations.`"$user`".activationPackage"
        Write-Host "nix-win: building $FlakeUri#$primary ..." -ForegroundColor Cyan
        try {
            return Invoke-NixBuild -Uri "$FlakeUri#$primary"
        } catch {
            Write-Host "nix-win: '$user@$hostname' not found or failed; trying '$user'..." -ForegroundColor Yellow
            Write-Host "nix-win: building $FlakeUri#$fallback ..." -ForegroundColor Cyan
            return Invoke-NixBuild -Uri "$FlakeUri#$fallback"
        }
    }

    $uri = "$FlakeUri#winConfigurations.$hostname.config.system.build.toplevel"
    Write-Host "nix-win: building $uri ..." -ForegroundColor Cyan
    return Invoke-NixBuild -Uri $uri
}

function ConvertTo-WinPath {
    param([string]$WslPath)
    return "\\wsl$\$WslDistro$($WslPath -replace '/', '\')"
}

function Get-State {
    param([string]$Path = $StateFile)
    if (Test-Path $Path) {
        $raw = Get-Content $Path | ConvertFrom-Json -AsHashtable
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
    param($State, [string]$Path = $StateFile)
    if (-not (Test-Path $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    $State | ConvertTo-Json -Depth 10 | Set-Content $Path
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
            # we're done; otherwise replace it. Compare normalized: the
            # manifest declares forward-slash targets while NTFS reports
            # backslash (a strict compare recreated the link every switch);
            # PS 7.0/7.1 surface Target as string[], and some .NET builds
            # report the raw \\?\ / \??\ mount-point form. -eq is already
            # case-insensitive for strings.
            $reported = [string](@($existing.Target)[0])
            $reported = ($reported -replace '^(\\\\\?\\|\\\?\?\\)', '').Replace('/', '\').TrimEnd('\')
            $declared = $Source.Replace('/', '\').TrimEnd('\')
            if ($reported -and $reported -eq $declared) { return }
            Remove-Item -LiteralPath $TargetPath -Force
        } elseif ($Force) {
            Remove-Item -LiteralPath $TargetPath -Force -Recurse
        } else {
            Write-Warning "  skip link: $TargetPath is a real file/dir (set force=true to replace)"
            return
        }
    }

    # "auto" probes the (already-expanded) source: directory → junction
    # (unprivileged), anything else → symlink (needs Developer Mode).
    if ($LinkType -eq "auto") {
        $LinkType = if (Test-Path -LiteralPath $Source -PathType Container) { "junction" } else { "symlink" }
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

    # Home-scope (v2) link entries carry no targetRoot — their paths are
    # home-relative by construction.
    function Get-LinkBase {
        param($Entry)
        if ($Entry.PSObject.Properties['targetRoot'] -and $Entry.targetRoot) {
            return Resolve-TargetRoot $Entry.targetRoot
        }
        return $env:USERPROFILE
    }

    # Index declared keys up front so the removal pass can diff against the
    # previous generation's state before we start mutating anything.
    $newKeys = @{}
    foreach ($entry in $declaredLinks) {
        $base = Get-LinkBase $entry
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
        $base = Get-LinkBase $entry
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
# Deploy-Files hands it the (non-recursive) set of directories that can
# actually hold markers, so orphans don't accumulate across generations
# once their holders exit.
function Sweep-StaleFiles {
    param([string[]]$Directories)
    foreach ($dir in $Directories) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -File -Filter '*.nix-win-stale-*' `
            -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch {}
        }
    }
}

function Deploy-Files {
    param(
        [string]$WinStorePath,
        [hashtable]$PrevFiles,
        [string[]]$Roots = @("home", "appdata-local", "appdata-roaming", "programdata"),
        # Where to back up unmanaged files we're about to overwrite —
        # the invoking scope's generations/<scope>/<gen>/backups. Empty
        # skips backups (rollback re-deploys known-managed trees).
        [string]$BackupDir,
        # Set when this scope's store path is identical to the one the last
        # successful deploy recorded. Every source file is then byte-identical
        # to what we already wrote, which is what makes the skip below sound.
        [switch]$SourceUnchanged
    )

    $newFiles = @{}

    # Enumerate incoming deployments up front: feeds both the stale sweep
    # and the deploy pass. $WinStorePath is a \\wsl$ UNC path, so this walks
    # the 9p bridge — but it reads metadata only (~0.3 s for 159 files),
    # against ~8 s to stream the contents.
    $incoming = foreach ($root in $Roots) {
        $sourceDir = Join-Path $WinStorePath $root
        if (-not (Test-Path $sourceDir)) { continue }
        $baseTarget = Resolve-TargetRoot $root
        foreach ($file in Get-ChildItem -Path $sourceDir -Recurse -File) {
            $relativePath = $file.FullName.Substring($sourceDir.Length + 1)
            [pscustomobject]@{
                Source           = $file.FullName
                RelativePath     = $relativePath
                TargetPath       = Join-Path $baseTarget $relativePath
                Length           = $file.Length
                LastWriteTimeUtc = $file.LastWriteTimeUtc
            }
        }
    }

    # Sweep rename-aside markers (Copy-FileRobust's *.nix-win-stale-*)
    # before deploying. Markers are only ever created NEXT TO a managed
    # file, so the parent dirs of previously-managed plus incoming files
    # bound the search — no full-root recursion (which used to walk all
    # of %USERPROFILE% and friends on every switch). Residual gap: a file
    # removed from config while its holder process lives leaves a marker
    # that exits the swept set once it leaves state.
    $sweepDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $PrevFiles.Keys) {
        $parent = Split-Path $key.Replace('/', '\') -Parent
        if ($parent) { [void]$sweepDirs.Add($parent) }
    }
    foreach ($entry in $incoming) {
        $parent = Split-Path $entry.TargetPath -Parent
        if ($parent) { [void]$sweepDirs.Add($parent) }
    }
    Sweep-StaleFiles -Directories @($sweepDirs)

    $skipped = 0
    foreach ($entry in $incoming) {
        $targetPath = $entry.TargetPath
        $targetDir = Split-Path $targetPath -Parent
        $fileKey = $targetPath.Replace('\', '/')

        # Skip files already deployed from this exact store path and untouched
        # since. Copy-Item preserves the source's timestamp, and nix
        # canonicalises every store file's mtime to 1970-01-01T00:00:01Z, so a
        # target still carrying that stamp at the same length is provably the
        # copy we wrote; anything that rewrote it (a user edit, or CPython
        # regenerating a deployed __pycache__/*.pyc) stamps it with a real
        # time and gets re-copied.
        #
        # The $SourceUnchanged gate is load-bearing and must not be dropped:
        # across DIFFERENT store paths this test is unsound, because that
        # canonical mtime is a constant. Two builds of the same file always
        # compare equal on mtime, so a same-length edit — bumping "1.2.3" to
        # "1.2.4" in a config file is the everyday case — would look identical
        # and never be deployed. Only when the store path is unchanged does
        # "matches its source" actually mean "up to date".
        if ($SourceUnchanged) {
            $existing = [System.IO.FileInfo]::new($targetPath)
            if ($existing.Exists -and
                $existing.Length -eq $entry.Length -and
                $existing.LastWriteTimeUtc -eq $entry.LastWriteTimeUtc) {
                $newFiles[$fileKey] = @{ status = "managed" }
                $skipped++
                continue
            }
        }

        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        # Backup existing file if not previously managed
        if ($BackupDir -and (Test-Path $targetPath) -and -not $PrevFiles.ContainsKey($fileKey)) {
            if (-not (Test-Path $BackupDir)) {
                New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
            }
            $backupName = $targetPath.Replace('\', '--').Replace(':', '-')
            Copy-Item $targetPath (Join-Path $BackupDir $backupName) -Force
        }

        Copy-FileRobust -Source $entry.Source -Destination $targetPath
        $newFiles[$fileKey] = @{ status = "managed" }
        Write-Host "  $($entry.RelativePath) -> $targetPath" -ForegroundColor DarkGray
    }

    # Every file that was actually written is reported above, individually.
    # This only accounts for the ones that needed no work.
    if ($skipped -gt 0) {
        Write-Host "  $skipped file(s) already up to date" -ForegroundColor DarkGray
    }

    return $newFiles
}

# Record a generation on disk: the generation directory plus
# store-path.txt / timestamp.txt / manifest.json. rollback and
# list-generations read these records — a bumped counter without one is
# a generation that can never be rolled back to.
function Write-GenerationRecord {
    param(
        [Parameter(Mandatory)][string]$GenDir,
        [Parameter(Mandatory)][string]$StorePath,
        [string]$ManifestPath
    )
    New-Item -ItemType Directory -Path $GenDir -Force | Out-Null
    $StorePath | Set-Content (Join-Path $GenDir "store-path.txt")
    (Get-Date -Format "o") | Set-Content (Join-Path $GenDir "timestamp.txt")
    if ($ManifestPath -and (Test-Path $ManifestPath)) {
        Copy-Item $ManifestPath (Join-Path $GenDir "manifest.json")
    }
}

# ── Commands ───────────────────────────────────────────────────────────────

# ── Source staging: never let the Nix daemon read the tree over 9p ────────
#
# Handing `nix build` a `path:/mnt/<drive>/...` flakeref makes the daemon copy
# the whole source into the store across the WSL 9p bridge, and that copy is
# the single most expensive thing in a switch: measured on pc1, `nix store
# add-path` takes ~56 s from /mnt/c against ~0.8 s for the identical tree on
# ext4. Evaluation itself is ~0.5 s, so essentially the entire "build" is that
# copy — and it is paid in full even when the result is a byte-identical store
# path.
#
# So the source is fingerprinted on the Windows side, where NTFS reads are
# cheap (~0.7 s for a 2,700-file tree), and:
#   * unchanged fingerprint + the recorded store path still present -> the
#     build is skipped outright;
#   * otherwise the tree is mirrored into an ext4 staging directory with
#     rsync --delete and built from there.
#
# The fingerprint is over file *content*, not size+mtime, so there is no
# mtime-granularity or same-size-same-tick case to reason about; it is
# content-addressed the same way Nix itself is. Paths are folded in too, so
# renames and deletions register. `nix --version` is folded in because a Nix
# upgrade can change the derivation for identical input.
#
# .git and .direnv are excluded. A `path:` flake exposes no git metadata (there
# is no self.rev), so .git cannot affect the result, and it is by far the
# largest part of the tree — 5,502 of the 8,240 files Nix would otherwise copy.
$script:StageExcludes = @('.git', '.direnv')
$script:StageMarker = $null

# Mirror the Windows source into an ext4 staging directory. rsync is the whole
# mechanism here, deliberately: it is exact by construction across the cases a
# hand-rolled comparison gets wrong. This tree carries 46 reparse points —
# `AGENTS.md` -> `CLAUDE.md`, plus `result` and `.pre-commit-config.yaml`
# pointing into /nix/store, which Windows surfaces as reparse points whose
# LinkTarget it cannot read. rsync reproduces all of them as symlinks, handles
# deletions via --delete, and reports whether anything moved via --itemize-changes
# (`-i`): empty stdout means the mirror was already identical.
#
# Returns @{ FlakeRef; Changed; Marker }.
function Sync-SourceToStage {
    param([Parameter(Mandatory)][string]$WinRoot)

    $wslSrc = (wsl.exe -d $WslDistro -- wslpath -a ($WinRoot.Replace('\', '/')) 2>$null).Trim()
    if (-not $wslSrc) { throw "Could not translate source path to a WSL path: $WinRoot" }

    # One stage per source root, keyed by a digest of the path so two checkouts
    # never collide. The marker lives *beside* the stage, not inside it, because
    # --delete would otherwise remove it as extraneous.
    $key = [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($wslSrc))).Substring(0, 16).ToLower()
    $base = (Invoke-Wsl "printf %s `"`$HOME/.cache/nix-win/stage`"") -join ''
    $stage = "$base/$key"
    $marker = "$base/$key.built"

    $excl = ($script:StageExcludes | ForEach-Object { "--exclude '$_'" }) -join ' '
    $out = Invoke-Wsl "mkdir -p '$stage' && rsync -ai --delete $excl '$wslSrc/' '$stage/'"
    $changed = @($out | Where-Object { "$_".Trim() }).Count -gt 0

    return @{ FlakeRef = "path:$stage"; Changed = $changed; Marker = $marker }
}

function Invoke-Build {
    if ($script:SourceWinPath) {
        Write-Host "nix-win: staging source on ext4..." -ForegroundColor Cyan
        $sync = Sync-SourceToStage -WinRoot $script:SourceWinPath
        $script:FlakeUri = $sync.FlakeRef
        $script:StageMarker = $sync.Marker

        # Fast path: nothing in the source moved, and the store path recorded by
        # the last *successful* switch was built from this same staged tree and
        # is still present. Then there is nothing to build. This is what turns a
        # converged switch's ~49 s build phase into ~3.4 s.
        #
        # The marker is what makes this safe against a failed switch: it is
        # written only after activation succeeds, so a run that synced new
        # sources and then died leaves marker != state.storePath and the next
        # run rebuilds instead of wrongly reusing the older path.
        if (-not $sync.Changed) {
            $prev = Get-State
            $PSNativeCommandUseErrorActionPreference = $false
            $built = wsl.exe -d $WslDistro -u $WslUser -- bash -c "cat '$($sync.Marker)' 2>/dev/null" 2>$null
            $built = ($built | Select-Object -First 1)
            if ($built) { $built = "$built".Trim() }
            if ($built -and $prev.storePath -and $built -eq $prev.storePath) {
                wsl.exe -d $WslDistro -u $WslUser -- test -e "$($prev.storePath)" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $winPath = ConvertTo-WinPath $prev.storePath
                    Write-Host "nix-win: source unchanged, reusing $($prev.storePath)" -ForegroundColor Green
                    Write-Host "  Windows path: $winPath" -ForegroundColor DarkGray
                    return @{ StorePath = $prev.storePath; WinPath = $winPath }
                }
                # A garbage collection between switches can remove the path;
                # fall through to a normal build rather than failing.
                Write-Host "nix-win: recorded store path is gone; rebuilding." -ForegroundColor Yellow
            }
        }
    }

    $storePath = Get-StorePath
    $winPath = ConvertTo-WinPath $storePath
    Write-Host "nix-win: built $storePath" -ForegroundColor Green
    Write-Host "  Windows path: $winPath" -ForegroundColor DarkGray
    return @{ StorePath = $storePath; WinPath = $winPath }
}

# Record which store path the current staged tree produced, so the next switch
# can skip the build. Called only after a switch has fully succeeded.
function Set-StageMarker {
    param([Parameter(Mandatory)][string]$StorePath)
    if (-not $script:StageMarker) { return }
    Invoke-Wsl "printf %s '$StorePath' > '$script:StageMarker'" | Out-Null
}

# Apply a winHome activation package (the per-user toplevel): deploy the
# home file tree and links, then run its activation script. Shared by the
# standalone `switch -Home` flow and the system switch's embedded per-user
# pass. Nothing in here requires elevation.
function Invoke-HomeApply {
    param(
        [Parameter(Mandatory)][string]$HomeWinPath,
        [hashtable]$PrevFiles = @{},
        [hashtable]$PrevLinks = @{},
        # Omitted on rollback: re-deploying a known-managed tree backs
        # nothing up.
        [string]$BackupDir,
        # See Deploy-Files: set only when this home scope's store path is
        # unchanged since the last successful deploy.
        [switch]$SourceUnchanged
    )

    Write-Host "`nnix-win: deploying home files..." -ForegroundColor Cyan
    $newFiles = Deploy-Files -WinStorePath $HomeWinPath -PrevFiles $PrevFiles -Roots @("home") `
        -BackupDir $BackupDir -SourceUnchanged:$SourceUnchanged

    Write-Host "`nnix-win: deploying home links..." -ForegroundColor Cyan
    $newLinks = Deploy-Links -WinStorePath $HomeWinPath -PrevLinks $PrevLinks

    Write-Host "`nnix-win: running home activation..." -ForegroundColor Cyan
    $env:NIX_WIN_HOME_STORE_PATH = $HomeWinPath
    $activateScript = Join-Path $HomeWinPath "activate.ps1"
    if (Test-Path $activateScript) {
        # Out-Host, not a bare call: this function RETURNS a hashtable that
        # the caller indexes as .files/.links, so anything activate.ps1 emits
        # on the success stream would be prepended to that return value and
        # turn it into an array. Under Set-StrictMode that surfaces far from
        # the cause, as "The property 'files' cannot be found on this object"
        # at the Save-State call. Activation scripts legitimately print (a
        # komorebic/scoop/winget invocation whose output isn't redirected is
        # enough), so the containment belongs here rather than in every
        # module's activation text.
        & $activateScript | Out-Host
    }

    return @{ files = $newFiles; links = $newLinks }
}

# Standalone per-user switch: no elevation needed, and being elevated is
# actively undesirable (files written by an admin token can pick up ACLs
# the unelevated user then trips over).
function Invoke-HomeSwitch {
    if (Test-IsAdmin) {
        Write-Warning "nix-win: switch -Home is running elevated. Home scope needs no admin; files created now may carry admin ACLs."
    }

    $build = Invoke-Build
    $state = Get-State
    $prevFiles = if ($state.files) { $state.files } else { @{} }
    $prevLinks = if ($state.ContainsKey('links') -and $state.links) { $state.links } else { @{} }

    $script:NewGeneration = $state.currentGeneration + 1
    $genDir = Join-Path $GenerationsDir $script:NewGeneration
    Write-GenerationRecord -GenDir $genDir -StorePath $build.StorePath `
        -ManifestPath (Join-Path $build.WinPath "manifest.json")

    $result = Invoke-HomeApply -HomeWinPath $build.WinPath -PrevFiles $prevFiles -PrevLinks $prevLinks `
        -BackupDir (Join-Path $genDir "backups") `
        -SourceUnchanged:($state.storePath -eq $build.StorePath -and $prevFiles.Count -gt 0)

    Save-State @{
        currentGeneration = $script:NewGeneration
        storePath         = $build.StorePath
        activatedAt       = (Get-Date -Format "o")
        files             = $result.files
        links             = $result.links
    }

    Write-Host "`nnix-win: home switch to generation $($script:NewGeneration) complete." -ForegroundColor Green
}

function Invoke-Switch {
    # The system scope writes ProgramData, HKLM, services, scheduled tasks,
    # and AllUsers PowerShell modules — all of which need an admin token.
    # Fail fast with a real message instead of a cascade of access-denied
    # noise halfway through activation.
    if (-not (Test-IsAdmin)) {
        throw "nix-win: 'switch' (system scope) requires an elevated shell. Use 'nix-win switch -Home' for the no-admin per-user scope."
    }

    $build = Invoke-Build
    $state = Get-State
    $prevFiles = if ($state.files) { $state.files } else { @{} }
    $prevLinks = if ($state.ContainsKey('links') -and $state.links) { $state.links } else { @{} }

    $script:NewGeneration = $state.currentGeneration + 1
    $genDir = Join-Path $GenerationsDir $script:NewGeneration
    Write-GenerationRecord -GenDir $genDir -StorePath $build.StorePath `
        -ManifestPath (Join-Path $build.WinPath "manifest.json")

    Write-Host "`nnix-win: deploying files..." -ForegroundColor Cyan
    $newFiles = Deploy-Files -WinStorePath $build.WinPath -PrevFiles $prevFiles `
        -BackupDir (Join-Path $genDir "backups") `
        -SourceUnchanged:($state.storePath -eq $build.StorePath -and $prevFiles.Count -gt 0)

    Write-Host "`nnix-win: deploying links..." -ForegroundColor Cyan
    $newLinks = Deploy-Links -WinStorePath $build.WinPath -PrevLinks $prevLinks

    Write-Host "`nnix-win: running activation scripts..." -ForegroundColor Cyan
    $env:NIX_WIN_STORE_PATH = $build.WinPath
    # Where activation steps may drop per-generation artifacts (large tool
    # output that belongs on disk rather than in the console log — see the
    # dsc module, which parks its full result JSON here).
    $env:NIX_WIN_GENERATION_DIR = $genDir
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

    # Only now is it true that this staged tree produced a fully applied
    # generation, so only now may the next switch skip its build.
    Set-StageMarker -StorePath $build.StorePath

    # Embedded per-user scope: apply the current user's home activation
    # package if the toplevel carries one (home-manager integration). Runs
    # AFTER the system phases so scoop/winget-installed tools are on PATH
    # for user activation. Other users' packages are skipped — their
    # profiles belong to them; they run `nix-win switch -Home` themselves.
    $userDir = Join-Path $build.WinPath "users" | Join-Path -ChildPath $env:USERNAME.ToLower()
    if (Test-Path -LiteralPath $userDir) {
        Write-Host "`nnix-win: applying embedded home scope for $env:USERNAME..." -ForegroundColor Cyan
        $homeStateFile = Join-Path $StateDir "state.home.json"
        $homeState = Get-State -Path $homeStateFile
        $homePrevFiles = if ($homeState.files) { $homeState.files } else { @{} }
        $homePrevLinks = if ($homeState.ContainsKey('links') -and $homeState.links) { $homeState.links } else { @{} }

        # Record the home generation exactly like a standalone `switch
        # -Home` would — rollback -Home and list-generations -Home read
        # the on-disk record, not the counter in state.home.json. Note
        # the home scope's dirs, NOT this invocation's ($GenerationsDir
        # and $genDir are the system scope's here).
        $homeGen = $homeState.currentGeneration + 1
        $homeGenDir = Join-Path $StateDir "generations" |
            Join-Path -ChildPath "home" | Join-Path -ChildPath $homeGen
        $homeStorePath = "$($build.StorePath)/users/$($env:USERNAME.ToLower())"
        Write-GenerationRecord -GenDir $homeGenDir -StorePath $homeStorePath `
            -ManifestPath (Join-Path $userDir "manifest.json")

        $homeResult = Invoke-HomeApply -HomeWinPath $userDir -PrevFiles $homePrevFiles -PrevLinks $homePrevLinks `
            -BackupDir (Join-Path $homeGenDir "backups") `
            -SourceUnchanged:($homeState.storePath -eq $homeStorePath -and $homePrevFiles.Count -gt 0)

        Save-State -Path $homeStateFile -State @{
            currentGeneration = $homeGen
            storePath         = $homeStorePath
            activatedAt       = (Get-Date -Format "o")
            files             = $homeResult.files
            links             = $homeResult.links
        }
    }

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
    Write-Host "nix-win: rolling back to generation $prevGen ($Scope scope)" -ForegroundColor Yellow
    $storePath = (Get-Content $storePathFile).Trim()
    $winPath = ConvertTo-WinPath $storePath

    if ($HomeScope) {
        # Home rollback re-deploys the previous generation's files and
        # links (not just re-running its activation) so removed files
        # come back. No -BackupDir: re-deploying a known-managed tree
        # backs nothing up.
        $state = Get-State
        $prevFiles = if ($state.files) { $state.files } else { @{} }
        $prevLinks = if ($state.ContainsKey('links') -and $state.links) { $state.links } else { @{} }
        $result = Invoke-HomeApply -HomeWinPath $winPath -PrevFiles $prevFiles -PrevLinks $prevLinks
        Save-State @{
            currentGeneration = $prevGen
            storePath         = $storePath
            activatedAt       = (Get-Date -Format "o")
            files             = $result.files
            links             = $result.links
        }
    } else {
        # Re-activate from previous store path
        $env:NIX_WIN_STORE_PATH = $winPath
        $activateScript = Join-Path $winPath "activate.ps1"
        if (Test-Path $activateScript) {
            & $activateScript
        }
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
    "switch" { if ($HomeScope) { Invoke-HomeSwitch } else { Invoke-Switch } }
    "rollback" { Invoke-Rollback }
    "list-generations" { Invoke-ListGenerations }
    "gc" { Invoke-GC }
}
