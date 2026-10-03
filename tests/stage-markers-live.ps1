# Tests for the switch fast path's inputs — the source stage's build markers
# and the override key — against a real WSL distro, so they run on Windows only:
#   pwsh -NoProfile -File tests/stage-markers-live.ps1
#
# Everything runs under a scratch $HOME inside WSL, so the real stage and its
# markers are never touched. Functions are lifted out of nix-win.ps1's AST, as
# in tests/cli-functions.ps1.
param(
    [string]$Cli = (Join-Path $PSScriptRoot '..\pkgs\nix-win\nix-win.ps1'),
    [string]$WslDistro = 'NixOS',
    [string]$WslUser = $env:USERNAME
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Failed = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -ceq "$Actual") {
        Write-Host "  ok   $Name"
    } else {
        $script:Failed++
        Write-Host "  FAIL $Name`n         expected: $Expected`n         actual:   $Actual"
    }
}

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Cli).Path, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "nix-win.ps1 does not parse: $($errors[0].Message)" }
$wanted = 'Write-Status', 'ConvertTo-WslPath', 'Sync-SourceToStage', 'Resolve-InputOverride', 'Get-LockedFlakeRef', 'Initialize-InputOverrides'
foreach ($name in $wanted) {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($null -eq $fn) { throw "function $name not found in nix-win.ps1" }
    . ([scriptblock]::Create($fn.Extent.Text))
}
$excl = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:StageExcludes' }, $true)
. ([scriptblock]::Create($excl.Extent.Text))

$scratchHome = "/tmp/nix-win-stage-test-$PID"
# The CLI's Invoke-Wsl, with $HOME pointed at the scratch tree. `wsl.exe -u`
# runs the command line through the user's login shell before bash sees it, and
# that shell expands $HOME inside the double-quoted argument — so exporting a
# different HOME to bash would be too late; the reference is rewritten instead.
function Invoke-Wsl {
    param([string]$Cmd, [switch]$NoThrow)
    $PSNativeCommandUseErrorActionPreference = $false
    $Cmd = $Cmd.Replace('$HOME', $scratchHome)
    $result = wsl.exe -d $WslDistro -u $WslUser -- bash -c $Cmd 2>&1
    if (-not $NoThrow -and $LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $Cmd`n$result"
    }
    return $result
}
function Test-WslFile { param([string]$Path) Invoke-Wsl "test -e '$Path'" -NoThrow | Out-Null; return $LASTEXITCODE -eq 0 }

$winSrc = Join-Path ([System.IO.Path]::GetTempPath()) "nix-win-stage-src-$PID"
try {
    Invoke-Wsl "mkdir -p '$scratchHome'" | Out-Null

    Write-Host "Sync-SourceToStage markers"
    New-Item -ItemType Directory -Path $winSrc -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $winSrc 'a.txt') -Value 'one'

    # The stage key is derived from the source path; recover it from a first sync.
    $script:OverrideKey = ''
    $first = Sync-SourceToStage -WinRoot $winSrc
    $key = ($first.Marker -replace '^.*/', '') -replace '\.built$', ''
    $base = $first.Marker -replace '/[^/]*$', ''
    $markers = @("$base/$key.built", "$base/$key.aaaa.built", "$base/$key.bbbb.built")
    $other = "$base/ffffffffffffffff.aaaa.built"
    function New-Markers { Invoke-Wsl ("for f in " + ((@($markers) + $other | ForEach-Object { "'$_'" }) -join ' ') + "; do printf x > \`$f; done") | Out-Null }

    New-Markers
    Set-Content -LiteralPath (Join-Path $winSrc 'a.txt') -Value 'two'
    $script:OverrideKey = 'aaaa'
    $sync = Sync-SourceToStage -WinRoot $winSrc
    Assert-Equal 'moved stage reports Changed'               $true  $sync.Changed
    Assert-Equal 'marker is this override set''s'            "$base/$key.aaaa.built" $sync.Marker
    Assert-Equal 'no-override marker removed'                $false (Test-WslFile $markers[0])
    Assert-Equal 'this override set''s marker removed'       $false (Test-WslFile $markers[1])
    Assert-Equal 'another override set''s marker removed'    $false (Test-WslFile $markers[2])
    Assert-Equal 'another stage''s marker kept'              $true  (Test-WslFile $other)

    New-Markers
    $sync = Sync-SourceToStage -WinRoot $winSrc
    Assert-Equal 'unmoved stage reports unchanged'           $false $sync.Changed
    Assert-Equal 'unmoved stage keeps every marker'          $true  ((Test-WslFile $markers[0]) -and (Test-WslFile $markers[1]) -and (Test-WslFile $markers[2]))

    Write-Host "Initialize-InputOverrides keys on locked refs"
    $repo = "$scratchHome/flake"
    $git = "git -C '$repo' -c user.name=t -c user.email=t@t"
    Invoke-Wsl "mkdir -p '$repo' && git -C '$repo' init -q && printf '{ outputs = _: { }; }\n' > '$repo/flake.nix' && $git add flake.nix && $git commit -qm one" | Out-Null

    function Get-Key {
        param([string]$Spec)
        $script:OverrideArgs = @(); $script:OverrideKey = ''
        $InputOverride = @($Spec)
        Initialize-InputOverrides
        return $script:OverrideKey
    }
    foreach ($spec in "nix-win=git+file://$repo", $repo) {
        $k1 = Get-Key $spec
        Assert-Equal "[$spec] locked ref carries a rev"      $true ($script:OverrideArgs[2] -match '[?&]rev=[0-9a-f]{40}')
        Assert-Equal "[$spec] key stable across resolutions" $k1 (Get-Key $spec)
        Invoke-Wsl "printf '# %s\n' '$spec' >> '$repo/flake.nix' && $git commit -qam more" | Out-Null
        $k2 = Get-Key $spec
        Assert-Equal "[$spec] key moves with a new commit"   $true ($k1 -ne $k2)
    }
} finally {
    Invoke-Wsl "rm -rf '$scratchHome'" -NoThrow | Out-Null
    Remove-Item -LiteralPath $winSrc -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failed -gt 0) { Write-Host "$script:Failed failed"; exit 1 }
Write-Host "all passed"
