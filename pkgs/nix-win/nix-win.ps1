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
    [ValidateSet("build", "switch", "rollback", "list-generations", "gc", "update-input")]
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
    [int]$Keep = 5,

    # Build against a LOCAL checkout of a flake input instead of whatever the
    # lock file pins. Repeatable: -InputOverride nix-win=C:\repos\nix-win
    #
    # Each value is `<input>=<location>` — or just `<location>`, which is
    # shorthand for `nix-win=<location>`, the overwhelmingly common case when
    # iterating on nix-win itself.
    #
    # <location> may be a Windows path (C:\repos\nix-win), optionally suffixed
    # with `#<rev-or-ref>`, a \\wsl$ UNC path, a bare WSL path, or any flakeref
    # nix understands (github:owner/repo, git+ssh://…), which is passed through
    # untouched.
    #
    # A Windows path is mirrored onto ext4 and handed to nix as a git+file:
    # ref, so what gets built is that checkout's committed HEAD — exactly what
    # you would get by pushing the commit and bumping the lock, without doing
    # either.
    [Parameter()]
    [Alias("NixWinFlakeOverride", "Override")]
    [string[]]$InputOverride = @(),

    # `update-input`: which input to update. Defaults to nix-win.
    # NOT named $Input — that is an automatic variable holding the pipeline.
    [Parameter()]
    [string]$InputName = "nix-win"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Scope = if ($HomeScope) { "home" } else { "system" }

# All human-facing progress goes here, and this writes to stderr. stdout is
# reserved for data, which is nix's own convention and what lets a caller do
# `$p = nix-win build` and get a store path rather than a store path buried in
# progress lines. `Write-Host` targets the information stream, which renders on
# stdout at the process boundary, so it cannot be used for this.
#
# [Console]::Error.WriteLine takes no -ForegroundColor, so the colour is set
# around the write — and skipped entirely when stderr is redirected, because
# otherwise every captured log would gain ANSI escapes that the information
# stream suppresses today. The parameter name matches the cmdlet it replaces so
# call sites read identically.
#
# [Console]::Error is the process's real fd 2, which is what every caller that
# spawns this CLI as a child process sees — `nix-switch` runs it as
# `pwsh -Command "nix-win switch …"`, and both this progress and the relayed
# build stream land on that process's stderr in order. Note the corollary: a
# PowerShell-level `nix-win … 2>file` from an already-running pwsh does NOT
# capture these lines, because that redirects the PowerShell error stream while
# [Console]::Error stays bound to the original handle. Redirect the process
# (`pwsh -File nix-win.ps1 … 2>file`) when you want them in a file.
function Write-Status {
    param(
        [Parameter(Position = 0)][string]$Message = "",
        [System.ConsoleColor]$ForegroundColor
    )
    $useColor = $PSBoundParameters.ContainsKey('ForegroundColor') -and -not [Console]::IsErrorRedirected
    if ($useColor) {
        $prev = [Console]::ForegroundColor
        [Console]::ForegroundColor = $ForegroundColor
    }
    try { [Console]::Error.WriteLine($Message) }
    finally { if ($useColor) { [Console]::ForegroundColor = $prev } }
}

# Translate a Windows path to its location inside the distro. Runs WITHOUT
# `-u $WslUser` deliberately: wslpath is user-independent, and the default user
# skips the login shell the configured user may carry.
#
# `wslpath -a` would corrupt an already-absolute /unix path into /mnt/c/unix, so
# only genuine Windows paths may be passed here.
function ConvertTo-WslPath {
    param(
        [Parameter(Mandatory)][string]$WinPath,
        [string]$ErrorContext = "Could not translate Windows path to a WSL path"
    )
    $wslPath = (wsl.exe -d $WslDistro -- wslpath -a ($WinPath.Replace('\', '/')) 2>$null).Trim()
    if (-not $wslPath) { throw "${ErrorContext}: $WinPath" }
    return $wslPath
}

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
    return "path:$(ConvertTo-WslPath $WinPath)"
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

# ── CLI-side phase timing ──────────────────────────────────────────────────
# The generated activation script times its own phases; this covers the work
# that happens OUTSIDE it — the WSL build, the file deploy, the link deploy —
# which together were the majority of a switch and showed up as one opaque
# block. Records go to the same spool, in the same nine-key schema, with
# stage = "cli", so they land on the existing dashboard alongside everything
# else.
#
# Deliberately duplicated rather than shared with lib/activation.nix: this is
# a standalone .ps1 shipped to Windows, not generated from the Nix eval, so it
# cannot import from the module tree.
$script:TimingSpool = $null
function Emit-CliTiming {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][double]$DurationMs,
        [int]$ExitCode = 0,
        [string]$Generation = ""
    )
    try {
        if ($null -eq $script:TimingSpool) {
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
                    [System.IO.File]::AppendAllText($probe, "")
                    $script:TimingSpool = $probe
                    break
                } catch { continue }
            }
            if ($null -eq $script:TimingSpool) { $script:TimingSpool = "" }
        }
        if ([string]::IsNullOrEmpty($script:TimingSpool)) { return }
        $now = [DateTimeOffset]::UtcNow
        $record = [ordered]@{
            ts             = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffffffK')
            time_unix_nano = ($now.ToUnixTimeMilliseconds() * 1000000)
            host           = $env:COMPUTERNAME.ToLower()
            generation     = $Generation
            stage          = 'cli'
            step           = $Step
            duration_ms    = [Math]::Round($DurationMs, 3)
            exit_code      = $ExitCode
            source         = 'inline'
        }
        [System.IO.File]::AppendAllText($script:TimingSpool,
            ($record | ConvertTo-Json -Compress -Depth 3) + "`n")
    } catch {
        # Telemetry must never be able to fail a switch.
    }
}

# Run a scriptblock, emit one timing record for it, and return its value.
function Measure-CliPhase {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$Generation = ""
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $Body
        $sw.Stop()
        Emit-CliTiming -Step $Step -DurationMs $sw.Elapsed.TotalMilliseconds -Generation $Generation
        return $result
    } catch {
        $sw.Stop()
        Emit-CliTiming -Step $Step -DurationMs $sw.Elapsed.TotalMilliseconds -ExitCode 1 -Generation $Generation
        throw
    }
}

# One-time migration from the single-scope v1 layout (state.json +
# generations/<n>) to the scope-split v2 layout (state.system.json +
# generations/system/<n>). Everything v1 tracked was applied by an
# (elevated) system switch, so it lands in the system scope.
$legacyState = Join-Path $StateDir "state.json"
if ((Test-Path $legacyState) -and -not (Test-Path (Join-Path $StateDir "state.system.json"))) {
    Write-Status "nix-win: migrating v1 state to the scope-split layout..." -ForegroundColor Yellow
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

# Run a command in WSL and return its output. The two WSL entry points are this
# and Invoke-WslStreaming below; nothing else in this file invokes wsl.exe
# directly, because PowerShell folds a native command's stdout into the
# enclosing function's return value and every bare call site has to get that
# right on its own.
#
# $PSNativeCommandUseErrorActionPreference is pinned off so the explicit
# $LASTEXITCODE check owns the failure message; pwsh 7.4+ with
# $ErrorActionPreference='Stop' would otherwise throw a generic "wsl.exe exited
# with code N" first. The assignment is function-scoped, so it cannot leak.
function Invoke-Wsl {
    param(
        [string]$Cmd,
        # Return the output and leave $LASTEXITCODE to the caller instead of
        # throwing — for probes whose non-zero exit is an expected outcome.
        [switch]$NoThrow
    )
    $PSNativeCommandUseErrorActionPreference = $false
    $result = wsl.exe -d $WslDistro -u $WslUser -- bash -c $Cmd 2>&1
    if (-not $NoThrow -and $LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $Cmd`n$result"
    }
    return $result
}

# Run a command in WSL whose output is for the human, not the pipeline.
#
# Console output MUST be on fd 2 — the caller's command is responsible for
# putting it there. fd 1 is discarded here, which is what makes this safe to
# call from a function that returns data: nothing the command prints can reach
# the enclosing return value. Returns the exit code.
function Invoke-WslStreaming {
    param([Parameter(Mandatory)][string]$Cmd)
    $PSNativeCommandUseErrorActionPreference = $false
    wsl.exe -d $WslDistro -u $WslUser -- bash -c $Cmd | Out-Null
    return $LASTEXITCODE
}

function Invoke-NixBuild {
    param([string]$Uri)

    # Run the build under a pty so nix selects its progress-bar logger and
    # renders exactly as it does on the host. `wsl.exe <command>` never
    # allocates one: measured from a real console, across every invocation shape
    # and with and without PowerShell capturing stdout, the Linux side always
    # sees plain pipes — so nix fell back to its simple logger, which prints
    # nothing whatsoever through evaluation and substitution, and a long build
    # was indistinguishable from a hung one. `script` creates the pty inside
    # Linux, so it does not depend on what wsl.exe hands over, and `script -e`
    # returns the child's exit status for the $LASTEXITCODE check below.
    #
    # A pty merges stdout and stderr into one stream, so `--print-out-paths`
    # cannot stay on stdout — the store path would interleave into the bar. It
    # goes to a file inside WSL instead, which also leaves PowerShell nothing to
    # capture, so all three std handles stay inherited down to the console.
    #
    # --override-input pairs, quoted for the shell that runs them. These must
    # stay ahead of the redirect below.
    $overrides = ""
    if ($script:OverrideArgs.Count -gt 0) {
        $overrides = " " + (($script:OverrideArgs | ForEach-Object { "'$_'" }) -join ' ')
    }

    $outFile = "/tmp/nix-win-outpath.$PID"
    $cmd = "nix build '$Uri' --no-link --print-out-paths --no-write-lock-file$overrides > $outFile"
    # `1>&2` satisfies Invoke-WslStreaming's contract: the progress bar is
    # console output, so it belongs on fd 2. Nothing rides fd 1 here anyway —
    # the store path is redirected to $outFile inside the distro, because a pty
    # merges stdout and stderr and it would otherwise interleave into the bar.
    $buildExit = Invoke-WslStreaming "script -qec `"$cmd`" /dev/null 1>&2"
    if ($buildExit -ne 0) {
        Invoke-Wsl "rm -f '$outFile'" -NoThrow | Out-Null
        throw "nix build failed (exit $buildExit). See the build log above."
    }

    $output = Invoke-Wsl "cat '$outFile'"
    Invoke-Wsl "rm -f '$outFile'" -NoThrow | Out-Null

    $storePath = "$($output | Select-Object -Last 1)".Trim()
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
        Write-Status "nix-win: building $uri ..." -ForegroundColor Cyan
        return Invoke-NixBuild -Uri $uri
    }

    if ($HomeScope) {
        # Mirror home-manager's attribute resolution: "user@host" first,
        # then bare "user".
        $primary = "winHomeConfigurations.`"$user@$hostname`".activationPackage"
        $fallback = "winHomeConfigurations.`"$user`".activationPackage"
        Write-Status "nix-win: building $FlakeUri#$primary ..." -ForegroundColor Cyan
        try {
            return Invoke-NixBuild -Uri "$FlakeUri#$primary"
        } catch {
            Write-Status "nix-win: '$user@$hostname' not found or failed; trying '$user'..." -ForegroundColor Yellow
            Write-Status "nix-win: building $FlakeUri#$fallback ..." -ForegroundColor Cyan
            return Invoke-NixBuild -Uri "$FlakeUri#$fallback"
        }
    }

    $uri = "$FlakeUri#winConfigurations.$hostname.config.system.build.toplevel"
    Write-Status "nix-win: building $uri ..." -ForegroundColor Cyan
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
        # The root of the system drive, for machine-scope files that
        # conventionally live outside %ProgramData% — C:\Scripts and friends.
        # Kept as a named root rather than allowing arbitrary absolute paths so
        # the deploy target stays inside a known, enumerable set.
        "system-drive" { return ($env:SystemDrive + "\") }
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
        Write-Status "  unlink $Path" -ForegroundColor DarkGray
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
    Write-Status "  link $TargetPath -> $Source ($LinkType)" -ForegroundColor DarkGray
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
        Write-Status "  (deferred: $stale still in use)" -ForegroundColor DarkYellow
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
        # Every root Resolve-TargetRoot knows about. A root with no subtree in
        # the store path is skipped, so listing them all costs nothing and
        # means a newly-used root does not need a second edit here.
        [string[]]$Roots = @("home", "appdata-local", "appdata-roaming", "programdata", "system-drive"),
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
    # Target paths this pass actually wrote. Published to activation via
    # NIX_WIN_CHANGED_FILES so a step can restart a daemon only when the
    # config it reads genuinely moved — see Publish-ChangedFiles.
    $script:LastDeployChanged = [System.Collections.Generic.List[string]]::new()

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
        $script:LastDeployChanged.Add($targetPath)
        Write-Status "  $($entry.RelativePath) -> $targetPath" -ForegroundColor DarkGray
    }

    # Every file that was actually written is reported above, individually.
    # This only accounts for the ones that needed no work.
    if ($skipped -gt 0) {
        Write-Status "  $skipped file(s) already up to date" -ForegroundColor DarkGray
    }

    return $newFiles
}

# Publish the set of files the last Deploy-Files pass actually wrote, so
# activation steps can act only on real change. Without this, a step that
# restarts a daemon to pick up its config restarts it on EVERY switch —
# AutoHotkey was killed and relaunched every time, dropping every hotkey
# mid-switch, even when the deployed .ahk was byte-identical.
#
# A path, not the contents, because the list can be long and activation runs
# in a separate process.
function Publish-ChangedFiles {
    param([Parameter(Mandatory)][string]$Scope)
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    $path = Join-Path $StateDir "changed-files.$Scope.json"
    $list = @()
    if ($null -ne $script:LastDeployChanged) { $list = @($script:LastDeployChanged) }
    # The empty case is written literally. Piping an empty array into
    # ConvertTo-Json sends ZERO objects down the pipeline, so it returns $null
    # and Set-Content produces a 0-byte file — and "nothing changed" is
    # precisely the converged switch this whole mechanism exists to make
    # cheap, so that path must not be the fragile one. (Passing @() as
    # -InputObject with -AsArray is no better: it wraps the empty array,
    # yielding [[]].)
    #
    # -AsArray otherwise matters because ConvertTo-Json unwraps a 1-element
    # array to a bare scalar, which would make a single changed file parse
    # back as a string rather than a list.
    $json = if ($list.Count -eq 0) { '[]' } else { [string[]]$list | ConvertTo-Json -AsArray -Compress }
    Set-Content -LiteralPath $path -Value $json -NoNewline
    $env:NIX_WIN_CHANGED_FILES = $path
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
# `__pycache__` is excluded for correctness, not tidiness. The stage is not a
# git repo (`.git` is excluded), so a `path:` flake over it includes UNTRACKED
# files — which a git-based build, i.e. CI, would never see. Python bytecode
# caches sitting in the working tree therefore ended up inside the built
# closure, and since CPython rewrites a .pyc whenever it reimports the module,
# those 18 files drifted and were re-copied on EVERY switch. Excluding them
# both removes that churn and makes the staged build match what CI builds.
$script:StageExcludes = @('.git', '.direnv', '__pycache__')
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

    $wslSrc = ConvertTo-WslPath $WinRoot -ErrorContext "Could not translate source path to a WSL path"

    # One stage per source root, keyed by a digest of the path so two checkouts
    # never collide. The marker lives *beside* the stage, not inside it, because
    # --delete would otherwise remove it as extraneous.
    $key = [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($wslSrc))).Substring(0, 16).ToLower()
    $base = (Invoke-Wsl "printf %s `"`$HOME/.cache/nix-win/stage`"") -join ''
    $stage = "$base/$key"
    # The marker is per (source, override set). A build with an override
    # produces a different store path from one without, so they must not share
    # a marker — otherwise flipping the override off would "reuse" the
    # overridden path and report a no-op.
    $markerKey = if ($script:OverrideKey) { "$key.$($script:OverrideKey)" } else { $key }
    $marker = "$base/$markerKey.built"

    # --delete-excluded, not just --delete: with plain --delete, rsync PROTECTS
    # files on the receiving side that match an --exclude, so anything already
    # in the stage from before a pattern was added survives forever. Adding
    # __pycache__ to the exclude list therefore changed nothing on its own —
    # the stale bytecode stayed in the stage and kept reaching the build.
    $excl = ($script:StageExcludes | ForEach-Object { "--exclude '$_'" }) -join ' '
    $out = Invoke-Wsl "mkdir -p '$stage' && rsync -ai --delete --delete-excluded $excl '$wslSrc/' '$stage/'"
    $changed = @($out | Where-Object { "$_".Trim() }).Count -gt 0

    return @{ FlakeRef = "path:$stage"; Changed = $changed; Marker = $marker }
}

# ── Local flake-input overrides ────────────────────────────────────────────
#
# Iterating on nix-win itself used to mean: commit, push, `nix flake update
# nix-win` in the dotfiles checkout (from inside WSL, by hand), then switch.
# Three steps and a push per attempt, on a repo you are actively debugging.
#
# `-InputOverride` collapses that to one flag pointing at a local checkout.
# The awkward part is the WSL boundary, and it is handled here rather than
# left to the caller:
#
#   * The checkout is a Windows path. Handing nix a `git+file:///mnt/c/...`
#     ref makes the daemon read the repo over the 9p bridge — the same
#     bottleneck the source staging exists to avoid, and worse for a git repo
#     because it walks .git object by object. So the checkout is mirrored onto
#     ext4 first, exactly like the dotfiles source.
#   * .git is deliberately INCLUDED in this mirror (unlike the source stage,
#     which excludes it): the whole point is to resolve the checkout's HEAD
#     commit, which needs git metadata.
#   * The result is a `git+file:` ref, not `path:`, so nix builds the committed
#     HEAD rather than the working tree. That makes an override behave exactly
#     like the push-then-bump-the-lock flow it replaces — a half-saved file
#     cannot silently end up in the build.
$script:OverrideStageExcludes = @('.direnv', 'result')

function Resolve-InputOverride {
    param([Parameter(Mandatory)][string]$Spec)

    # `<input>=<location>`, or bare `<location>` meaning nix-win. Split on the
    # FIRST '=', and only when the left side looks like an input name — a
    # Windows path can contain '=' in principle and must not be mis-split.
    $inputName = 'nix-win'
    $location = $Spec
    if ($Spec -match '^([A-Za-z][A-Za-z0-9_.-]*)=(.+)$') {
        $inputName = $Matches[1]
        $location = $Matches[2]
    }

    # A flakeref nix already understands passes straight through.
    if ($location -match '^[a-z+]+:' -and $location -notmatch '^[A-Za-z]:[\\/]') {
        return @{ Name = $inputName; Ref = $location; Source = $location }
    }

    # Optional `#<rev-or-ref>` suffix. '#' rather than ':' because ':' is
    # already the drive separator in every Windows path.
    $rev = $null
    if ($location -match '^(.*)#([^#]+)$') {
        $location = $Matches[1]
        $rev = $Matches[2]
    }

    # Bare WSL path, or \\wsl$ UNC: already on ext4, no mirror needed.
    $wslSrc = $null
    if ($location -match '^\\\\wsl(?:\$|\.localhost)\\[^\\]+\\(.*)$') {
        $wslSrc = "/$($Matches[1] -replace '\\', '/')"
    } elseif ($location -match '^/') {
        $wslSrc = $location
    }

    if ($null -ne $wslSrc) {
        $ref = "git+file://$wslSrc"
        if ($rev) { $ref = "$ref`?rev=$rev" }
        return @{ Name = $inputName; Ref = $ref; Source = $location }
    }

    # Windows path: must exist, must be a git repo, gets mirrored to ext4.
    if (-not (Test-Path -LiteralPath $location)) {
        throw "-InputOverride: no such path: $location"
    }
    $full = (Resolve-Path -LiteralPath $location).Path
    if (-not (Test-Path -LiteralPath (Join-Path $full '.git'))) {
        throw "-InputOverride: $full is not a git checkout (no .git). An override is built from its committed HEAD, so it has to be one."
    }

    $srcWsl = ConvertTo-WslPath $full -ErrorContext "-InputOverride: could not translate to a WSL path"

    $key = [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($srcWsl))).Substring(0, 16).ToLower()
    $base = (Invoke-Wsl "printf %s `"`$HOME/.cache/nix-win/override`"") -join ''
    $stage = "$base/$key"

    $excl = ($script:OverrideStageExcludes | ForEach-Object { "--exclude '$_'" }) -join ' '
    Write-Status "  mirroring $full -> $stage" -ForegroundColor DarkGray
    Invoke-Wsl "mkdir -p '$stage' && rsync -a --delete $excl '$srcWsl/' '$stage/'" | Out-Null

    # Warn loudly about uncommitted work: it is NOT in the build, and silently
    # building something other than what is on screen is the worst possible
    # behaviour for a debugging aid.
    $dirty = (Invoke-Wsl "git -C '$stage' status --porcelain 2>/dev/null | head -c 400") -join "`n"
    if ("$dirty".Trim()) {
        Write-Status "  WARNING: $full has uncommitted changes; the override builds its committed HEAD, so they are NOT included." -ForegroundColor Yellow
    }

    $head = (Invoke-Wsl "git -C '$stage' rev-parse HEAD 2>/dev/null" | Select-Object -First 1)
    $head = "$head".Trim()
    if (-not $head) { throw "-InputOverride: could not resolve HEAD in $full" }

    $ref = "git+file://$stage"
    if ($rev) {
        $ref = "$ref`?rev=$rev"
        $shown = $rev
    } else {
        # Pin the resolved HEAD explicitly. Without it nix resolves the ref
        # again at build time, so two builds in one session could silently
        # disagree if a commit landed between them.
        $ref = "$ref`?rev=$head"
        $shown = $head.Substring(0, [Math]::Min(12, $head.Length))
    }
    Write-Status "  override $inputName -> $full @ $shown" -ForegroundColor DarkGray
    return @{ Name = $inputName; Ref = $ref; Source = $full }
}

# Resolved once, then reused by every nix invocation in this run.
$script:OverrideArgs = @()
$script:OverrideKey = ""

function Initialize-InputOverrides {
    if ($InputOverride.Count -eq 0) { return }
    Write-Status "nix-win: resolving flake input overrides..." -ForegroundColor Cyan
    $parts = @()
    foreach ($spec in $InputOverride) {
        $o = Resolve-InputOverride -Spec $spec
        $script:OverrideArgs += @('--override-input', $o.Name, $o.Ref)
        $parts += "$($o.Name)=$($o.Ref)"
    }
    # Folded into the stage marker so a changed override forces a rebuild even
    # when the dotfiles source itself did not move. Without this, switching
    # between two nix-win checkouts would reuse the first one's store path and
    # look like a no-op.
    $script:OverrideKey = [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes(($parts -join ';')))).Substring(0, 16).ToLower()
}

function Invoke-Build {
    if ($script:SourceWinPath) {
        Write-Status "nix-win: staging source on ext4..." -ForegroundColor Cyan
        # Timed separately from the nix invocation: source staging and
        # eval/realize have completely different cost drivers (9p vs the
        # derivation graph), and reporting them as one number is what made the
        # original "build takes 49 s" impossible to act on.
        $sync = Measure-CliPhase -Step 'build-stage-source' -Body {
            Sync-SourceToStage -WinRoot $script:SourceWinPath
        }
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
            $built = Invoke-Wsl "cat '$($sync.Marker)' 2>/dev/null" -NoThrow
            $built = ($built | Select-Object -First 1)
            if ($built) { $built = "$built".Trim() }
            if ($built -and $prev.storePath -and $built -eq $prev.storePath) {
                Invoke-Wsl "test -e '$($prev.storePath)'" -NoThrow | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $winPath = ConvertTo-WinPath $prev.storePath
                    Write-Status "nix-win: source unchanged, reusing $($prev.storePath)" -ForegroundColor Green
                    Write-Status "  Windows path: $winPath" -ForegroundColor DarkGray
                    return @{ StorePath = $prev.storePath; WinPath = $winPath }
                }
                # A garbage collection between switches can remove the path;
                # fall through to a normal build rather than failing.
                Write-Status "nix-win: recorded store path is gone; rebuilding." -ForegroundColor Yellow
            }
        }
    }

    $storePath = Measure-CliPhase -Step 'build-nix' -Body { Get-StorePath }
    $winPath = ConvertTo-WinPath $storePath
    Write-Status "nix-win: built $storePath" -ForegroundColor Green
    Write-Status "  Windows path: $winPath" -ForegroundColor DarkGray
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

    Write-Status "`nnix-win: deploying home files..." -ForegroundColor Cyan
    $newFiles = Measure-CliPhase -Step 'deploy-home-files' -Body {
        Deploy-Files -WinStorePath $HomeWinPath -PrevFiles $PrevFiles -Roots @("home") `
            -BackupDir $BackupDir -SourceUnchanged:$SourceUnchanged
    }

    Write-Status "`nnix-win: deploying home links..." -ForegroundColor Cyan
    $newLinks = Measure-CliPhase -Step 'deploy-home-links' -Body {
        Deploy-Links -WinStorePath $HomeWinPath -PrevLinks $PrevLinks
    }

    Write-Status "`nnix-win: running home activation..." -ForegroundColor Cyan
    $env:NIX_WIN_HOME_STORE_PATH = $HomeWinPath
    Publish-ChangedFiles -Scope "home"
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

    Write-Status "`nnix-win: home switch to generation $($script:NewGeneration) complete." -ForegroundColor Green
}

function Invoke-Switch {
    # The system scope writes ProgramData, HKLM, services, scheduled tasks,
    # and AllUsers PowerShell modules — all of which need an admin token.
    # Fail fast with a real message instead of a cascade of access-denied
    # noise halfway through activation.
    if (-not (Test-IsAdmin)) {
        throw "nix-win: 'switch' (system scope) requires an elevated shell. Use 'nix-win switch -Home' for the no-admin per-user scope."
    }

    $build = Measure-CliPhase -Step 'build' -Body { Invoke-Build }
    $state = Get-State
    $prevFiles = if ($state.files) { $state.files } else { @{} }
    $prevLinks = if ($state.ContainsKey('links') -and $state.links) { $state.links } else { @{} }

    $script:NewGeneration = $state.currentGeneration + 1
    $genDir = Join-Path $GenerationsDir $script:NewGeneration
    Write-GenerationRecord -GenDir $genDir -StorePath $build.StorePath `
        -ManifestPath (Join-Path $build.WinPath "manifest.json")

    Write-Status "`nnix-win: deploying files..." -ForegroundColor Cyan
    $newFiles = Measure-CliPhase -Step 'deploy-files' -Generation $build.StorePath -Body {
        Deploy-Files -WinStorePath $build.WinPath -PrevFiles $prevFiles `
            -BackupDir (Join-Path $genDir "backups") `
            -SourceUnchanged:($state.storePath -eq $build.StorePath -and $prevFiles.Count -gt 0)
    }

    Write-Status "`nnix-win: deploying links..." -ForegroundColor Cyan
    $newLinks = Measure-CliPhase -Step 'deploy-links' -Generation $build.StorePath -Body {
        Deploy-Links -WinStorePath $build.WinPath -PrevLinks $prevLinks
    }

    Write-Status "`nnix-win: running activation scripts..." -ForegroundColor Cyan
    $env:NIX_WIN_STORE_PATH = $build.WinPath
    # Where activation steps may drop per-generation artifacts (large tool
    # output that belongs on disk rather than in the console log — see the
    # dsc module, which parks its full result JSON here).
    $env:NIX_WIN_GENERATION_DIR = $genDir
    Publish-ChangedFiles -Scope "system"
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
            Write-Status ""
            Write-Status "════════════════════════════════════════════════════════════════════" -ForegroundColor Red
            Write-Status " nix-win: ACTIVATION FAILED" -ForegroundColor Red
            Write-Status "════════════════════════════════════════════════════════════════════" -ForegroundColor Red
            Write-Status ""
            Write-Status "Generation $script:NewGeneration was NOT saved." -ForegroundColor Red
            Write-Status "Current state remains at generation $($state.currentGeneration)." -ForegroundColor Red
            Write-Status ""
            if ($err.InvocationInfo -and $err.InvocationInfo.PositionMessage) {
                Write-Status "Failed at:" -ForegroundColor Red
                Write-Status $err.InvocationInfo.PositionMessage -ForegroundColor Yellow
                Write-Status ""
            }
            Write-Status "Error:" -ForegroundColor Red
            Write-Status "  $($err.Exception.Message)" -ForegroundColor Yellow
            if ($err.ScriptStackTrace) {
                Write-Status ""
                Write-Status "Stack trace:" -ForegroundColor Red
                Write-Status $err.ScriptStackTrace -ForegroundColor DarkGray
            }
            Write-Status ""
            Write-Status "════════════════════════════════════════════════════════════════════" -ForegroundColor Red
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
        Write-Status "`nnix-win: applying embedded home scope for $env:USERNAME..." -ForegroundColor Cyan
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

    Write-Status "`nnix-win: switch to generation $($script:NewGeneration) complete." -ForegroundColor Green
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
    Write-Status "nix-win: rolling back to generation $prevGen ($Scope scope)" -ForegroundColor Yellow
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
    Write-Status "nix-win: rolled back to generation $prevGen." -ForegroundColor Green
}

function Invoke-ListGenerations {
    if (-not (Test-Path $GenerationsDir)) {
        Write-Status "No generations found." -ForegroundColor Yellow
        return
    }
    $state = Get-State
    # The listing is this command's data, so it goes to stdout via the success
    # stream — not through Write-Status, which is for progress.
    Get-ChildItem $GenerationsDir -Directory | Sort-Object { [int]$_.Name } | ForEach-Object {
        $gen = $_.Name
        $tsFile = Join-Path $_.FullName "timestamp.txt"
        $ts = if (Test-Path $tsFile) { Get-Content $tsFile } else { "unknown" }
        $current = if ($gen -eq $state.currentGeneration) { " *" } else { "" }
        Write-Output "  Generation $gen — $ts$current"
    }
}

function Invoke-GC {
    if (-not (Test-Path $GenerationsDir)) { return }
    $state = Get-State
    $gens = Get-ChildItem $GenerationsDir -Directory | Sort-Object { [int]$_.Name } -Descending
    $toRemove = $gens | Select-Object -Skip $Keep | Where-Object { $_.Name -ne $state.currentGeneration }
    foreach ($gen in $toRemove) {
        Write-Status "  Removing generation $($gen.Name)" -ForegroundColor DarkGray
        Remove-Item $gen.FullName -Recurse -Force
    }
    Write-Status "nix-win: kept $Keep most recent generations." -ForegroundColor Green
}

# Update one flake input's lock entry in the flake this invocation points at.
#
# Exists so bumping the nix-win pin after pushing does not mean remembering the
# WSL incantation — the nix CLI lives in the distro, the checkout is a Windows
# path, and `nix flake update` has to run against the real checkout (not the
# ext4 mirror) because the point is to WRITE flake.lock where git will see it.
function Invoke-UpdateInput {
    if (-not $script:SourceWinPath) {
        throw "update-input needs a Windows checkout path; pass -FlakeUri C:\path\to\dotfiles (or run from inside it)."
    }
    $wslPath = ConvertTo-WslPath $script:SourceWinPath -ErrorContext "Could not translate to a WSL path"

    Write-Status "nix-win: updating flake input '$InputName' in $script:SourceWinPath ..." -ForegroundColor Cyan
    # nix writes its progress and errors to stderr, which satisfies
    # Invoke-WslStreaming's fd-2 contract.
    #
    # `nix flake update <input>` is the modern spelling; older nix wants
    # `nix flake lock --update-input <input>`. Try the former, fall back.
    $rc = Invoke-WslStreaming "cd '$wslPath' && nix flake update '$InputName'"
    if ($rc -ne 0) {
        Write-Status "nix-win: retrying with the older --update-input spelling..." -ForegroundColor Yellow
        $rc = Invoke-WslStreaming "cd '$wslPath' && nix flake lock --update-input '$InputName'"
        if ($rc -ne 0) { throw "nix flake update failed (exit $rc)." }
    }
    Write-Status "nix-win: '$InputName' updated. Review the flake.lock diff, then switch." -ForegroundColor Green
}

# ── Main ───────────────────────────────────────────────────────────────────

# Must precede any build: the resolved overrides feed both the nix invocation
# and the stage marker.
if ($Command -in @("build", "switch")) { Initialize-InputOverrides }

switch ($Command) {
    # The store path is this command's data: it goes to stdout, while every
    # progress line went to stderr via Write-Status. `nix-win build > path.txt`
    # therefore leaves just the path in the file.
    "build" { (Invoke-Build).StorePath }
    "switch" { if ($HomeScope) { Invoke-HomeSwitch } else { Invoke-Switch } }
    "rollback" { Invoke-Rollback }
    "list-generations" { Invoke-ListGenerations }
    "gc" { Invoke-GC }
    "update-input" { Invoke-UpdateInput }
}
