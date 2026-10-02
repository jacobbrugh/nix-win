# End-to-end test of the CLI's profile operations against a real Nix store in
# WSL, so it runs on Windows only:
#   pwsh -NoProfile -File tests/profile-live.ps1 [-WslDistro NixOS] [-WslUser <user>]
#
# It drives a scratch profile, nix-win-selftest, next to the real ones, with
# two throwaway store paths, and removes the profile again afterwards. What
# it proves is the part no unit test can: that the command strings survive
# wsl.exe, the login shell and bash, and that nix-env behaves the way the CLI
# assumes (generation reuse, rollback, GC roots).
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
foreach ($name in 'Invoke-Wsl', 'Get-ProfilePaths', 'ConvertFrom-ProfileOutput', 'Set-ProfileGeneration', 'Switch-ProfileGeneration') {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($null -eq $fn) { throw "function $name not found in nix-win.ps1" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

$Scope = 'selftest'
$script:NixStateHome = $null
$pp = Get-ProfilePaths
$p = $pp.Profile

function New-StorePath {
    param([string]$Content)
    $tmp = "/tmp/nix-win-selftest-$PID-$Content"
    $out = Invoke-Wsl "printf %s '$Content' > '$tmp' && nix-store --add '$tmp' && rm -f '$tmp'"
    foreach ($line in @($out)) { if ("$line".Trim() -match '^/nix/store/\S+$') { return "$line".Trim() } }
    throw "could not add a store path: $out"
}
function Generations {
    $nums = foreach ($line in @(Invoke-Wsl "nix-env -p '$p' --list-generations")) {
        if ("$line" -match '^\s*(\d+)\s') { $Matches[1] }
    }
    return (@($nums) -join ',')
}

try {
    Assert-Equal 'state home resolved to an absolute path' $true ($pp.Dir -match '^/.+/nix/profiles$')

    $a = New-StorePath 'a'
    $b = New-StorePath 'b'

    Write-Host "switch"
    $g = Set-ProfileGeneration -StorePath $a
    Assert-Equal 'first generation is 1'            1 $g.Generation
    Assert-Equal 'it names the store path'          $a $g.StorePath
    $g = Set-ProfileGeneration -StorePath $a
    Assert-Equal 'same path again: no new generation' 1 $g.Generation
    $g = Set-ProfileGeneration -StorePath $b
    Assert-Equal 'new path: generation 2'           2 $g.Generation
    Assert-Equal 'both generations listed'          '1,2' (Generations)

    Write-Host "rollback"
    $g = Switch-ProfileGeneration
    Assert-Equal 'rollback lands on generation 1'   "1|$a" "$($g.Generation)|$($g.StorePath)"
    $g = Set-ProfileGeneration -StorePath $b
    Assert-Equal 'switching forward reuses generation 2' 2 $g.Generation
    $g = Switch-ProfileGeneration -Number 1
    Assert-Equal 'switch-generation 1'              "1|$a" "$($g.Generation)|$($g.StorePath)"
    $threw = $false
    try { [void](Switch-ProfileGeneration) } catch { $threw = $true }
    Assert-Equal 'rollback with nothing older throws' $true $threw
    $threw = $false
    try { [void](Switch-ProfileGeneration -Number 99) } catch { $threw = $true }
    Assert-Equal 'switch-generation to a missing one throws' $true $threw

    Write-Host "GC roots"
    Invoke-Wsl "mkdir -p '$($pp.RootDir)' && nix-store --realise '$b' --add-root '$($pp.Root)'" | Out-Null
    $roots = (Invoke-Wsl "nix-store --query --roots '$b'") -join "`n"
    Assert-Equal 'the profile generation roots its path' $true ($roots -match [regex]::Escape("$p-2-link"))
    Assert-Equal 'the current root roots it too'         $true ($roots -match [regex]::Escape($pp.Root))

    Write-Host "gc"
    [void](Set-ProfileGeneration -StorePath $b)
    Invoke-Wsl "nix-env -p '$p' --delete-generations +1" | Out-Null
    Assert-Equal 'only the current generation remains' '2' (Generations)
} finally {
    Invoke-Wsl "rm -f '$p' '$p-1-link' '$p-2-link' '$($pp.Root)'" -NoThrow | Out-Null
}

if ($script:Failed -gt 0) { Write-Host "$script:Failed test(s) failed"; exit 1 }
Write-Host "all profile-live tests passed"
