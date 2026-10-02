#Requires -Version 7.0
<#
.SYNOPSIS
    nix-win — Declarative Windows system configuration via Nix (evaluated in WSL).

.DESCRIPTION
    Builds Windows system configuration using Nix inside WSL, then applies it
    to the Windows host by copying files and running activation scripts.

.PARAMETER Command
    The command to run: build, switch, rollback, switch-generation,
    list-generations, gc, update-input

    Generations are a Nix profile inside the WSL distro
    (~/.local/state/nix/profiles/nix-win-<scope>), so each one is a GC root
    and stays available to roll back to. `rollback` and `switch-generation`
    re-point the profile and re-activate that generation; nothing is rebuilt.

.PARAMETER Generation
    The generation number for `switch-generation`.

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
    nix-win switch-generation -Generation 12
    nix-win list-generations
    nix-win gc -Keep 5
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet("build", "switch", "rollback", "switch-generation", "list-generations", "gc", "update-input")]
    [string]$Command,

    # `switch-generation`: which profile generation to activate.
    [Parameter()]
    [int]$Generation = 0,

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
# spawns this CLI as a child process sees — a wrapper that runs it as
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
#
# Resolved lazily, by the commands that build (build, switch, update-input).
# rollback, switch-generation, list-generations and gc never touch a flake —
# they act on the profile — so they must work from any directory.
$script:SourceWinPath = $null
$script:FlakeResolved = $false
function Resolve-FlakeUri {
    if ($script:FlakeResolved) { return }
    $script:FlakeResolved = $true
    if (-not $script:FlakeUri) {
        $cwdFlake = Join-Path (Get-Location).Path "flake.nix"
        if (-not (Test-Path $cwdFlake)) {
            throw "No flake.nix found in $((Get-Location).Path). Pass -FlakeUri <Windows path, WSL path, or flakeref> or cd into a directory containing a flake.nix."
        }
        if ((Get-Location).Path -match '^[A-Za-z]:[\\/]') { $script:SourceWinPath = (Get-Location).Path }
        $script:FlakeUri = ConvertTo-WslFlakeRef (Get-Location).Path
    }
    elseif ($script:FlakeUri -match '^[A-Za-z]:[\\/]' -or $script:FlakeUri -match '^\\\\') {
        if ($script:FlakeUri -match '^[A-Za-z]:[\\/]') { $script:SourceWinPath = $script:FlakeUri }
        $script:FlakeUri = ConvertTo-WslFlakeRef $script:FlakeUri
    }
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

# Windows-side data that belongs to one generation and cannot live in the
# store: backups of files nix-win overwrote, and the dsc result document.
# Numbered by the Nix profile's generation number. (The `generations\` tree
# next to it is the pre-profile layout — text records of store paths that
# were never GC roots — and is no longer read or written.)
$GenerationDataRoot = Join-Path $StateDir "generation-data"
$GenerationDataDir = Join-Path $GenerationDataRoot $Scope

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

# A `files` / `links` map out of state, keyed case-insensitively.
#
# State is parsed with `ConvertFrom-Json -AsHashtable`, which yields a
# case-SENSITIVE table, while the keys are NTFS paths. Comparing them
# case-sensitively would make a case-only rename (or a root env var that
# changed casing) look like "this path is no longer deployed" — and the
# removal pass would then delete the file that was just written.
function Get-StateTable {
    param($State, [Parameter(Mandatory)][string]$Name)
    $table = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $State -and $State.ContainsKey($Name) -and $State[$Name]) {
        foreach ($key in @($State[$Name].Keys)) { $table[[string]$key] = $State[$Name][$key] }
    }
    return $table
}

# A state field that an older CLI may not have written.
function Get-StateValue {
    param($State, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -ne $State -and $State.ContainsKey($Name) -and $null -ne $State[$Name]) { return $State[$Name] }
    return $Default
}

# ── Generations: a Nix profile inside the distro ───────────────────────────
#
# A generation is a link in a Nix profile, exactly as on NixOS, nix-darwin and
# home-manager: `nix-env -p <profile> --set <path>` records it, the link is a
# GC root, and rollback is `nix-env --rollback` followed by running that
# generation's own activation. Nothing is rebuilt.
#
# The profile lives where home-manager keeps its own
# (~/.local/state/nix/profiles), is owned by the WSL user, and needs no root.
#
# Every command string below is `$`-free with single-quoted absolute paths.
# `wsl.exe -u <user> -- bash -c <cmd>` hands the string to the user's LOGIN
# shell first and only then to bash, so anything either shell would expand is
# expanded twice, or by the wrong one. The one exception is the state-home
# lookup, whose expansion is a constant either shell resolves identically.
$script:NixStateHome = $null
function Get-ProfilePaths {
    param([string]$ForScope = $Scope)
    if (-not $script:NixStateHome) {
        $resolved = ((Invoke-Wsl 'printf %s "${XDG_STATE_HOME:-$HOME/.local/state}"') -join '').Trim()
        if ($resolved -notmatch '^/') { throw "nix-win: cannot resolve the WSL state directory (got '$resolved')." }
        $script:NixStateHome = $resolved
    }
    return @{
        Dir     = "$script:NixStateHome/nix/profiles"
        Profile = "$script:NixStateHome/nix/profiles/nix-win-$ForScope"
        RootDir = "$script:NixStateHome/nix-win/gcroots"
        # The last generation whose activation ran to completion —
        # home-manager's `current-home`. It is a root of its own, outside the
        # profile directory, because after a failed switch the profile already
        # points at the new generation while the machine still runs this one.
        Root    = "$script:NixStateHome/nix-win/gcroots/current-$ForScope"
    }
}

# Parse `readlink <profile>` + `readlink -f <profile>` out of command output.
# The output is 2>&1-merged with whatever nix-env said, so match, never index.
function ConvertFrom-ProfileOutput {
    param($Lines)
    $gen = $null
    $path = $null
    foreach ($line in @($Lines)) {
        $text = "$line".Trim()
        if ($text -match '^nix-win-[a-z]+-(\d+)-link$') { $gen = [int]$Matches[1] }
        elseif ($text -match '^(/nix/store/\S+)$') { $path = $Matches[1] }
    }
    if ($null -eq $gen -or -not $path) {
        throw "nix-win: cannot read the profile state:`n$(@($Lines) -join "`n")"
    }
    return @{ Generation = $gen; StorePath = $path }
}

# Record a store path as the profile's newest generation and return
# @{ Generation; StorePath }. nix-env reuses the newest generation when it
# already points at this path, so re-switching an unchanged configuration
# does not mint a new generation.
function Set-ProfileGeneration {
    param([Parameter(Mandatory)][string]$StorePath)
    $pp = Get-ProfilePaths
    $p = $pp.Profile
    return ConvertFrom-ProfileOutput (Invoke-Wsl "mkdir -p '$($pp.Dir)' && nix-env -p '$p' --set '$StorePath' && readlink '$p' && readlink -f '$p'")
}

# Re-point the profile at its previous generation ($Number = 0) or at a
# specific one, and return @{ Generation; StorePath }.
function Switch-ProfileGeneration {
    param([int]$Number = 0)
    $pp = Get-ProfilePaths
    $p = $pp.Profile
    $how = if ($Number -gt 0) { "--switch-generation $Number" } else { "--rollback" }
    return ConvertFrom-ProfileOutput (Invoke-Wsl "nix-env -p '$p' $how && readlink '$p' && readlink -f '$p'")
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
    # once the holder has exited (e.g. the user restarted the program holding them).
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

# The mtime every file in the Nix store carries. Copy-Item preserves it, so a
# deployed file still bearing it has not been written by anything since
# nix-win copied it (Deploy-Files relies on the same fact to skip unchanged
# files).
$script:StoreStamp = [DateTime]::new(1970, 1, 1, 0, 0, 1, [DateTimeKind]::Utc)

# Delete the files the previous generation deployed and this one does not.
#
# Runs AFTER activation, not before it: by then a removed scheduled task has
# been unregistered and a removed converge script's unset has run, so nothing
# still needs the files. (NixOS stops a removed unit while its old definition
# is still loaded for the same reason.)
#
# A file is deleted only if it still carries the store stamp. One that was
# modified since nix-win deployed it is left in place with a warning — the
# rule home-manager applies to the files it copies rather than links
# ("contents have diverged").
#
# Returns the keys that must stay in state: files that could not be deleted
# yet (in use), so the next switch tries again.
function Remove-StaleFiles {
    param(
        [Parameter(Mandatory)][hashtable]$PrevFiles,
        [Parameter(Mandatory)][hashtable]$NewFiles,
        # Paths the OTHER scope deploys. A file that moved from one scope to
        # the other is still managed and still stamped; it must not be
        # deleted by the scope that gave it up.
        [hashtable]$ProtectedFiles = @{}
    )
    $ci = [System.StringComparer]::OrdinalIgnoreCase
    $keep = [System.Collections.Generic.HashSet[string]]::new($ci)
    foreach ($k in $NewFiles.Keys) { [void]$keep.Add([string]$k) }
    foreach ($k in $ProtectedFiles.Keys) { [void]$keep.Add([string]$k) }

    # Pruning never climbs out of, or removes, a target root. Roots nest
    # (appdata-local is inside home; system-drive is C:\) and a state key
    # does not say which root it came from, so stop at any of them.
    $stop = [System.Collections.Generic.HashSet[string]]::new($ci)
    foreach ($r in 'home', 'appdata-local', 'appdata-roaming', 'programdata', 'system-drive') {
        [void]$stop.Add((Resolve-TargetRoot $r).TrimEnd('\'))
    }

    $carry = @{}
    foreach ($key in @($PrevFiles.Keys)) {
        if ($keep.Contains([string]$key)) { continue }
        $path = ([string]$key).Replace('/', '\')
        $fi = [System.IO.FileInfo]::new($path)
        if ($fi.Exists) {
            if ($fi.LastWriteTimeUtc -ne $script:StoreStamp) {
                Write-Warning "  left in place: $path (no longer managed, but modified since nix-win deployed it)"
                continue
            }
            try {
                # -Force: copies of store files are read-only.
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                Write-Status "  removed $path" -ForegroundColor DarkGray
            } catch {
                Write-Warning "  cannot remove $path yet ($($_.Exception.Message)); will retry on the next switch"
                $carry[[string]$key] = @{ status = "removing" }
                continue
            }
        }

        # Prune directories this left empty.
        $dir = Split-Path $path -Parent
        while ($dir -and -not $stop.Contains($dir.TrimEnd('\'))) {
            $di = [System.IO.DirectoryInfo]::new($dir)
            if ($di.Exists) {
                # Never a junction or symlink: Deploy-Links owns those, and
                # deleting through one would touch its target.
                if ($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { break }
                Sweep-StaleFiles -Directories @($dir)
                # Non-recursive, so it throws unless the directory is truly
                # empty — hidden files included.
                try { [System.IO.Directory]::Delete($dir, $false) } catch { break }
            }
            $dir = Split-Path $dir -Parent
        }
    }
    return $carry
}

# Export the generation being replaced to the activation script, or clear the
# variable when there is none. This is nix-darwin's /run/current-system and
# home-manager's $oldGenPath: activation steps diff the old generation's
# artifacts against their own to find what left the configuration.
#
# Cleared explicitly, because `$env:` assignments outlive this script in the
# calling session and a stale path would be diffed against.
function Set-OldStorePathEnv {
    param([string]$OldStorePath)
    $old = ""
    if ($OldStorePath) {
        $unc = ConvertTo-WinPath $OldStorePath
        if (Test-Path -LiteralPath (Join-Path $unc "manifest.json")) { $old = $unc }
    }
    if ($old) { $env:NIX_WIN_OLD_STORE_PATH = $old }
    else { Remove-Item Env:NIX_WIN_OLD_STORE_PATH -ErrorAction SilentlyContinue }
}

# Save the file map immediately after the copy pass, as previous ∪ new and
# before activation runs. If activation then fails (or the switch is
# interrupted), the files this run copied are still on record, so the next
# successful switch can remove the ones it does not ship.
function Save-FilesWriteAhead {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$PrevFiles,
        [Parameter(Mandatory)][hashtable]$NewFiles
    )
    $state = Get-State -Path $Path
    $union = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $PrevFiles.Keys) { $union[[string]$k] = $PrevFiles[$k] }
    foreach ($k in $NewFiles.Keys) { $union[[string]$k] = $NewFiles[$k] }
    $state["files"] = $union
    Save-State -State $state -Path $Path
}

# ── Commands ───────────────────────────────────────────────────────────────

# ── Source staging: never let the Nix daemon read the tree over 9p ────────
#
# Handing `nix build` a `path:/mnt/<drive>/...` flakeref makes the daemon copy
# the whole source into the store across the WSL 9p bridge, and that copy is
# the single most expensive thing in a switch: measured on a Windows host, `nix store
# add-path` takes ~56 s from /mnt/c against ~0.8 s for the identical tree on
# ext4. Evaluation itself is ~0.5 s, so essentially the entire "build" is that
# copy — and it is paid in full even when the result is a byte-identical store
# path.
#
# So the source is fingerprinted on the Windows side, where NTFS reads are
# cheap (~0.7 s for a few thousand files), and:
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
# largest part of a typical checkout — most of the files Nix would otherwise copy.
# `__pycache__` is excluded for correctness, not tidiness. The stage is not a
# git repo (`.git` is excluded), so a `path:` flake over it includes UNTRACKED
# files — which a git-based build, i.e. CI, would never see. Python bytecode
# caches sitting in the working tree therefore ended up inside the built
# closure, and since CPython rewrites a .pyc whenever it reimports the module,
# those files drifted and were re-copied on EVERY switch. Excluding them
# both removes that churn and makes the staged build match what CI builds.
$script:StageExcludes = @('.git', '.direnv', '__pycache__')
$script:StageMarker = $null

# Mirror the Windows source into an ext4 staging directory. rsync is the whole
# mechanism here, deliberately: it is exact by construction across the cases a
# hand-rolled comparison gets wrong. A checkout can carry reparse points —
# symlinks between tracked files, plus links such as `result`
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

    # A marker describes the tree it was written for. Once the stage moves it
    # is stale, and it has to go NOW rather than when the next switch
    # succeeds: if this switch fails after staging, the retry sees an
    # unchanged stage, and a surviving marker that still equals the recorded
    # store path would make it "reuse" the previous generation and report
    # success without ever building the new source.
    if ($changed) { Invoke-Wsl "rm -f '$marker'" -NoThrow | Out-Null }

    return @{ FlakeRef = "path:$stage"; Changed = $changed; Marker = $marker }
}

# ── Local flake-input overrides ────────────────────────────────────────────
#
# Iterating on nix-win itself used to mean: commit, push, `nix flake update
# nix-win` in the consuming flake's checkout (from inside WSL, by hand), then switch.
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
#     ext4 first, exactly like the configuration source.
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
    # when the configuration source itself did not move. Without this, switching
    # between two nix-win checkouts would reuse the first one's store path and
    # look like a no-op.
    $script:OverrideKey = [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes(($parts -join ';')))).Substring(0, 16).ToLower()
}

function Invoke-Build {
    Resolve-FlakeUri
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

# Close out a successfully activated system generation: root it as the
# "current" generation, and record which store path the staged tree produced
# so the next switch can skip the build. One WSL round trip for both.
#
# The current root is what guarantees the NEXT switch can still read this
# generation's artifacts to diff against, whatever happens to the profile in
# between. The marker is written only on the switch path ($script:StageMarker
# is unset for rollback and switch-generation, which build nothing).
function Complete-SystemGeneration {
    param([Parameter(Mandatory)][string]$StorePath)
    $pp = Get-ProfilePaths -ForScope "system"
    $cmd = "mkdir -p '$($pp.RootDir)' && nix-store --realise '$StorePath' --add-root '$($pp.Root)'"
    if ($script:StageMarker) { $cmd += " && printf %s '$StorePath' > '$script:StageMarker'" }
    Invoke-Wsl $cmd | Out-Null
}

# Apply a winHome activation package (the per-user toplevel): deploy the
# home file tree and links, run its activation script, then remove the files
# the previous home generation deployed and this one does not. Shared by the
# standalone `switch -Home` flow and the system activation's embedded per-user
# pass. Nothing in here requires elevation.
function Invoke-HomeApply {
    param(
        [Parameter(Mandatory)][string]$HomeWinPath,
        # The home scope's state file, for the write-ahead file map.
        [Parameter(Mandatory)][string]$StatePath,
        [hashtable]$PrevFiles = @{},
        [hashtable]$PrevLinks = @{},
        [string]$BackupDir,
        # See Deploy-Files: set only when this home scope's store path is
        # unchanged since the last successful deploy.
        [switch]$SourceUnchanged,
        # Paths the system scope deploys; see Remove-StaleFiles.
        [hashtable]$ProtectedFiles = @{}
    )

    Write-Status "`nnix-win: deploying home files..." -ForegroundColor Cyan
    $newFiles = Measure-CliPhase -Step 'deploy-home-files' -Body {
        Deploy-Files -WinStorePath $HomeWinPath -PrevFiles $PrevFiles -Roots @("home") `
            -BackupDir $BackupDir -SourceUnchanged:$SourceUnchanged
    }
    Save-FilesWriteAhead -Path $StatePath -PrevFiles $PrevFiles -NewFiles $newFiles

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

    $carry = Remove-StaleFiles -PrevFiles $PrevFiles -NewFiles $newFiles -ProtectedFiles $ProtectedFiles
    foreach ($k in $carry.Keys) { $newFiles[$k] = $carry[$k] }

    return @{ files = $newFiles; links = $newLinks }
}

# True when the home scope on this machine was last applied as part of a
# system generation (its store path is `<system toplevel>/users/<name>`).
# Such a home scope has no generations of its own: it moves with the system
# generation, the way home-manager-as-a-module does under nix-darwin.
function Test-HomeIsEmbedded {
    $homeState = Get-State -Path (Join-Path $StateDir "state.home.json")
    return ("$(Get-StateValue $homeState 'storePath' '')" -match '/users/[^/]+$')
}

# Activate a standalone winHome generation: the shared body of
# `switch -Home`, `rollback -Home` and `switch-generation -Home`.
function Invoke-HomeActivate {
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][int]$GenerationNumber
    )
    if (Test-IsAdmin) {
        Write-Warning "nix-win: the home scope is being applied elevated. It needs no admin; files created now may carry admin ACLs."
    }
    $winPath = ConvertTo-WinPath $StorePath
    $state = Get-State
    $prevFiles = Get-StateTable $state 'files'
    $prevLinks = Get-StateTable $state 'links'
    $systemFiles = Get-StateTable (Get-State -Path (Join-Path $StateDir "state.system.json")) 'files'

    $result = Invoke-HomeApply -HomeWinPath $winPath -StatePath $StateFile `
        -PrevFiles $prevFiles -PrevLinks $prevLinks `
        -BackupDir (Join-Path (Join-Path $GenerationDataDir $GenerationNumber) "backups") `
        -SourceUnchanged:((Get-StateValue $state 'storePath' '') -eq $StorePath -and $prevFiles.Count -gt 0) `
        -ProtectedFiles $systemFiles

    Save-State @{
        currentGeneration = $GenerationNumber
        storePath         = $StorePath
        activatedAt       = (Get-Date -Format "o")
        files             = $result.files
        links             = $result.links
    }
}

# Standalone per-user switch: no elevation needed, and being elevated is
# actively undesirable (files written by an admin token can pick up ACLs
# the unelevated user then trips over).
function Invoke-HomeSwitch {
    $build = Invoke-Build
    $gen = Set-ProfileGeneration -StorePath $build.StorePath
    Invoke-HomeActivate -StorePath $build.StorePath -GenerationNumber $gen.Generation
    Write-Status "`nnix-win: home switch to generation $($gen.Generation) complete." -ForegroundColor Green
}

# Activate a system generation. The ONE path `switch`, `rollback` and
# `switch-generation` all take — darwin-rebuild's shape: the profile is
# re-pointed first, then the generation it now names is activated.
#
# Order, and why:
#   1. copy files, and save the file map (previous ∪ new) straight away
#   2. deploy links
#   3. export the generation being replaced, for activation to diff against
#   4. run activate.ps1
#   5. remove the files that left the configuration (after activation — see
#      Remove-StaleFiles)
#   6. save state, root the generation, write the build-skip marker
#   7. apply the embedded home scope the same way
function Invoke-Activate {
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][int]$GenerationNumber
    )

    $winPath = ConvertTo-WinPath $StorePath
    if (-not (Test-Path -LiteralPath (Join-Path $winPath "manifest.json"))) {
        throw "nix-win: generation $GenerationNumber ($StorePath) is not readable at $winPath."
    }

    $state = Get-State
    $prevFiles = Get-StateTable $state 'files'
    $prevLinks = Get-StateTable $state 'links'
    $prevStorePath = "$(Get-StateValue $state 'storePath' '')"
    $prevGeneration = Get-StateValue $state 'currentGeneration' 0
    $genDataDir = Join-Path $GenerationDataDir $GenerationNumber

    $homeStateFile = Join-Path $StateDir "state.home.json"
    $homeState = Get-State -Path $homeStateFile
    $homePrevFiles = Get-StateTable $homeState 'files'
    $homePrevLinks = Get-StateTable $homeState 'links'

    Write-Status "`nnix-win: deploying files..." -ForegroundColor Cyan
    $newFiles = Measure-CliPhase -Step 'deploy-files' -Generation $StorePath -Body {
        Deploy-Files -WinStorePath $winPath -PrevFiles $prevFiles `
            -BackupDir (Join-Path $genDataDir "backups") `
            -SourceUnchanged:($prevStorePath -eq $StorePath -and $prevFiles.Count -gt 0)
    }
    Save-FilesWriteAhead -Path $StateFile -PrevFiles $prevFiles -NewFiles $newFiles

    Write-Status "`nnix-win: deploying links..." -ForegroundColor Cyan
    $newLinks = Measure-CliPhase -Step 'deploy-links' -Generation $StorePath -Body {
        Deploy-Links -WinStorePath $winPath -PrevLinks $prevLinks
    }

    Write-Status "`nnix-win: running activation scripts..." -ForegroundColor Cyan
    $env:NIX_WIN_STORE_PATH = $winPath
    Set-OldStorePathEnv -OldStorePath $prevStorePath
    # Where activation steps may drop per-generation artifacts (large tool
    # output that belongs on disk rather than in the console log — see the
    # dsc module, which parks its full result JSON here).
    $env:NIX_WIN_GENERATION_DIR = $genDataDir
    Publish-ChangedFiles -Scope "system"
    $activateScript = Join-Path $winPath "activate.ps1"
    if (Test-Path $activateScript) {
        # Wrap the activation call so a throw doesn't silently skip Save-State
        # with nothing but a small default PS error block. The failure mode
        # we're guarding against: activate.ps1 invokes DSC/WinGet/PowerShell
        # modules, any of which can throw.
        try {
            # Out-Host: this function's success stream must stay empty.
            & $activateScript | Out-Host
        } catch {
            $err = $_
            Write-Status ""
            Write-Status "════════════════════════════════════════════════════════════════════" -ForegroundColor Red
            Write-Status " nix-win: ACTIVATION FAILED" -ForegroundColor Red
            Write-Status "════════════════════════════════════════════════════════════════════" -ForegroundColor Red
            Write-Status ""
            Write-Status "Generation $GenerationNumber was NOT activated." -ForegroundColor Red
            Write-Status "The machine remains at generation $prevGeneration; the profile already names $GenerationNumber." -ForegroundColor Red
            Write-Status "Fix the configuration and switch again, or 'nix-win rollback'." -ForegroundColor Red
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

    # Only reached on successful activation.
    Write-Status "`nnix-win: removing files that left the configuration..." -ForegroundColor Cyan
    $carry = Remove-StaleFiles -PrevFiles $prevFiles -NewFiles $newFiles -ProtectedFiles $homePrevFiles
    foreach ($k in $carry.Keys) { $newFiles[$k] = $carry[$k] }

    Save-State @{
        currentGeneration = $GenerationNumber
        storePath         = $StorePath
        activatedAt       = (Get-Date -Format "o")
        files             = $newFiles
        links             = $newLinks
    }
    Complete-SystemGeneration -StorePath $StorePath

    # Embedded per-user scope: apply the current user's home activation
    # package if the toplevel carries one (home-manager integration). Runs
    # AFTER the system phases so scoop/winget-installed tools are on PATH
    # for user activation. Other users' packages are skipped — their
    # profiles belong to them; they run `nix-win switch -Home` themselves.
    $userName = $env:USERNAME.ToLower()
    $userDir = Join-Path (Join-Path $winPath "users") $userName
    if (Test-Path -LiteralPath $userDir) {
        Write-Status "`nnix-win: applying embedded home scope for $env:USERNAME..." -ForegroundColor Cyan
        $homeStorePath = "$StorePath/users/$userName"

        $homeResult = Invoke-HomeApply -HomeWinPath $userDir -StatePath $homeStateFile `
            -PrevFiles $homePrevFiles -PrevLinks $homePrevLinks `
            -BackupDir (Join-Path $genDataDir "home-backups") `
            -SourceUnchanged:((Get-StateValue $homeState 'storePath' '') -eq $homeStorePath -and $homePrevFiles.Count -gt 0) `
            -ProtectedFiles $newFiles

        # The embedded home scope has no generations of its own; it carries
        # the system generation's number.
        Save-State -Path $homeStateFile -State @{
            currentGeneration = $GenerationNumber
            storePath         = $homeStorePath
            activatedAt       = (Get-Date -Format "o")
            files             = $homeResult.files
            links             = $homeResult.links
        }
    }
}

function Assert-SystemScopeAdmin {
    param([Parameter(Mandatory)][string]$Verb)
    # The system scope writes ProgramData, HKLM, services, scheduled tasks,
    # and AllUsers PowerShell modules — all of which need an admin token.
    # Fail fast with a real message instead of a cascade of access-denied
    # noise halfway through activation.
    if (-not (Test-IsAdmin)) {
        throw "nix-win: '$Verb' (system scope) requires an elevated shell."
    }
}

function Invoke-Switch {
    Assert-SystemScopeAdmin -Verb "switch"
    $build = Measure-CliPhase -Step 'build' -Body { Invoke-Build }
    # The profile moves before activation, as darwin-rebuild and
    # nixos-rebuild do it. If activation then fails, the profile names the
    # new generation while state still names the last one that activated.
    $gen = Set-ProfileGeneration -StorePath $build.StorePath
    Invoke-Activate -StorePath $build.StorePath -GenerationNumber $gen.Generation
    Write-Status "`nnix-win: switch to generation $($gen.Generation) complete." -ForegroundColor Green
}

# rollback / switch-generation: re-point the profile, then activate what it
# now names. Nothing is built; the generation is a GC root, so it is still
# in the store.
function Invoke-ProfileSwitch {
    param([int]$Number = 0)
    $verb = if ($Number -gt 0) { "switch-generation" } else { "rollback" }
    if ($HomeScope) {
        if (Test-HomeIsEmbedded) {
            throw "nix-win: the home scope on this machine is applied as part of the system generation; use '$verb' without -Home."
        }
    } else {
        Assert-SystemScopeAdmin -Verb $verb
    }
    $gen = Switch-ProfileGeneration -Number $Number
    Write-Status "nix-win: activating generation $($gen.Generation) ($Scope scope): $($gen.StorePath)" -ForegroundColor Yellow
    if ($HomeScope) {
        Invoke-HomeActivate -StorePath $gen.StorePath -GenerationNumber $gen.Generation
    } else {
        Invoke-Activate -StorePath $gen.StorePath -GenerationNumber $gen.Generation
    }
    Write-Status "`nnix-win: now at generation $($gen.Generation)." -ForegroundColor Green
}

function Invoke-ListGenerations {
    $pp = Get-ProfilePaths
    $lines = @(Invoke-Wsl "nix-env -p '$($pp.Profile)' --list-generations" -NoThrow)
    $shown = 0
    $active = Get-StateValue (Get-State) 'currentGeneration' 0
    # The listing is this command's data, so it goes to stdout via the success
    # stream — not through Write-Status, which is for progress.
    #
    # nix-env marks the generation the PROFILE points at "(current)". That is
    # not always the one the machine runs: after a failed activation the
    # profile is one ahead. "(active)" marks the generation state recorded as
    # activated.
    foreach ($line in $lines) {
        $text = "$line".TrimEnd()
        if ($text -notmatch '^\s*(\d+)\s') { continue }
        if ([int]$Matches[1] -eq $active) { $text += "   (active)" }
        Write-Output $text
        $shown++
    }
    if ($shown -eq 0) {
        $hint = if ($HomeScope -and (Test-HomeIsEmbedded)) { " The home scope here is applied with the system generation." } else { "" }
        Write-Status "No generations found.$hint" -ForegroundColor Yellow
    }
}

function Invoke-GC {
    if ($Keep -lt 1) { throw "nix-win: -Keep must be at least 1." }
    $pp = Get-ProfilePaths
    $p = $pp.Profile
    # `+N` keeps N generations counting back from the current one, and
    # anything newer than it; the current generation is never deleted.
    $lines = @(Invoke-Wsl "nix-env -p '$p' --delete-generations +$Keep && nix-env -p '$p' --list-generations")
    $alive = @{}
    foreach ($line in $lines) {
        if ("$line" -match '^\s*(\d+)\s') { $alive[[int]$Matches[1]] = $true }
        elseif ("$line".Trim()) { Write-Status "  $("$line".Trim())" -ForegroundColor DarkGray }
    }
    # Drop the Windows-side data of generations that no longer exist. The
    # store paths themselves are freed by a Nix garbage collection in the
    # distro, now that nothing roots them.
    if (Test-Path -LiteralPath $GenerationDataDir) {
        foreach ($dir in (Get-ChildItem -LiteralPath $GenerationDataDir -Directory)) {
            if ($dir.Name -match '^\d+$' -and -not $alive.ContainsKey([int]$dir.Name)) {
                Write-Status "  removing data of generation $($dir.Name)" -ForegroundColor DarkGray
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force
            }
        }
    }
    Write-Status "nix-win: kept the $Keep most recent generations." -ForegroundColor Green
}

# Update one flake input's lock entry in the flake this invocation points at.
#
# Exists so bumping the nix-win pin after pushing does not mean remembering the
# WSL incantation — the nix CLI lives in the distro, the checkout is a Windows
# path, and `nix flake update` has to run against the real checkout (not the
# ext4 mirror) because the point is to WRITE flake.lock where git will see it.
function Invoke-UpdateInput {
    Resolve-FlakeUri
    if (-not $script:SourceWinPath) {
        throw "update-input needs a Windows checkout path; pass -FlakeUri C:\path\to\config (or run from inside it)."
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
    "rollback" { Invoke-ProfileSwitch }
    "switch-generation" {
        if ($Generation -lt 1) { throw "nix-win: switch-generation needs -Generation <number>; see 'nix-win list-generations'." }
        Invoke-ProfileSwitch -Number $Generation
    }
    "list-generations" { Invoke-ListGenerations }
    "gc" { Invoke-GC }
    "update-input" { Invoke-UpdateInput }
}
