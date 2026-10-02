# Unit tests for lib/removal-prelude.ps1. Platform-neutral: run by the
# `removal-logic` flake check under Linux pwsh, and runnable on Windows with
#   pwsh -NoProfile -File tests/removal-logic.ps1 -Prelude lib/removal-prelude.ps1
param([Parameter(Mandatory)][string]$Prelude)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. $Prelude

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

$root = Join-Path ([System.IO.Path]::GetTempPath()) "nix-win-removal-$PID"
if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }

function New-Generation {
    param([string]$Name, [hashtable]$Files)
    $dir = Join-Path $root $Name
    foreach ($rel in $Files.Keys) {
        $path = Join-Path $dir $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, $Files[$rel])
    }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Names {
    param($Items)
    $names = foreach ($item in @($Items)) { if ($null -ne $item) { $item.name } }
    return (@($names) -join ',')
}

try {
    $old = New-Generation 'old' @{
        'things/many.json'   = '[{"name":"a"},{"name":"b"},{"name":"c"}]'
        'things/one.json'    = '[{"name":"x","extra":1}]'
        'things/empty.json'  = '[]'
        'things/blank.json'  = ''
        'things/null.json'   = 'null'
        'things/case.json'   = '[{"name":"Foo"}]'
        'things/nokey.json'  = '[{"other":"z"},{"name":"k"}]'
        'things/dupes.json'  = '[{"name":"d"},{"name":"D"}]'
    }

    Write-Host "Get-NixWinArtifact"
    Assert-Equal 'three elements'   3 @(Get-NixWinArtifact -Root $old -RelPath 'things', 'many.json').Count
    Assert-Equal 'single element'   1 @(Get-NixWinArtifact -Root $old -RelPath 'things', 'one.json').Count
    Assert-Equal 'empty array'      0 @(Get-NixWinArtifact -Root $old -RelPath 'things', 'empty.json').Count
    Assert-Equal 'blank file'       0 @(Get-NixWinArtifact -Root $old -RelPath 'things', 'blank.json').Count
    Assert-Equal 'json null'        0 @(Get-NixWinArtifact -Root $old -RelPath 'things', 'null.json').Count
    Assert-Equal 'missing file'     0 @(Get-NixWinArtifact -Root $old -RelPath 'things', 'absent.json').Count
    Assert-Equal 'empty root'       0 @(Get-NixWinArtifact -Root '' -RelPath 'things', 'many.json').Count

    Write-Host "Get-NixWinRemoved"
    $declaredA = @([pscustomobject]@{ name = 'a' })

    $env:NIX_WIN_OLD_STORE_PATH = $old
    Assert-Equal 'drops what is still declared' 'b,c' (Names (Get-NixWinRemoved -RelPath 'things', 'many.json' -Declared $declaredA))
    Assert-Equal 'nothing declared: all removed' 'a,b,c' (Names (Get-NixWinRemoved -RelPath 'things', 'many.json'))
    Assert-Equal 'single element old'           'x' (Names (Get-NixWinRemoved -RelPath 'things', 'one.json' -Declared $declaredA))
    Assert-Equal 'empty old'                    '' (Names (Get-NixWinRemoved -RelPath 'things', 'empty.json' -Declared $declaredA))
    Assert-Equal 'old artifact missing'         '' (Names (Get-NixWinRemoved -RelPath 'things', 'absent.json' -Declared $declaredA))
    Assert-Equal 'case-insensitive match'       '' (Names (Get-NixWinRemoved -RelPath 'things', 'case.json' -Declared @([pscustomobject]@{ name = 'foo' })))
    Assert-Equal 'entry without the key skipped' 'k' (Names (Get-NixWinRemoved -RelPath 'things', 'nokey.json'))
    Assert-Equal 'duplicates reported once'     'd' (Names (Get-NixWinRemoved -RelPath 'things', 'dupes.json'))
    Assert-Equal 'alternate key'                '1' ((@(Get-NixWinRemoved -RelPath 'things', 'one.json' -Key 'extra') | ForEach-Object { $_.extra }) -join ',')

    Remove-Item Env:NIX_WIN_OLD_STORE_PATH
    Assert-Equal 'old path unset: nothing' '' (Names (Get-NixWinRemoved -RelPath 'things', 'many.json'))
    $env:NIX_WIN_OLD_STORE_PATH = Join-Path $root 'does-not-exist'
    Assert-Equal 'old path gone: nothing'  '' (Names (Get-NixWinRemoved -RelPath 'things', 'many.json'))
    Remove-Item Env:NIX_WIN_OLD_STORE_PATH

    Write-Host "Invoke-NixWinRemoval"
    $script:Removed = 0
    Invoke-NixWinRemoval -Label 'absent item' -Present { $false } -Remove { $script:Removed++ }
    Assert-Equal 'absent: remove not called' 0 $script:Removed
    Invoke-NixWinRemoval -Label 'present item' -Present { $true } -Remove { $script:Removed++ }
    Assert-Equal 'present: remove called' 1 $script:Removed
    Invoke-NixWinRemoval -Label 'noisy test' -Present { 'chatter'; $true } -Remove { $script:Removed++ }
    Assert-Equal 'last emitted value is the verdict' 2 $script:Removed
    Invoke-NixWinRemoval -Label 'failing item' -Present { $true } -Remove { throw 'boom' }
    Assert-Equal 'failure is a warning, not a throw' 1 $script:NixWinRemovalWarnings.Count
    Assert-Equal 'warning names the item' 'failing item: boom' $script:NixWinRemovalWarnings[0]
    Invoke-NixWinRemoval -Label 'failing probe' -Present { throw 'probe' } -Remove { $script:Removed++ }
    Assert-Equal 'failing probe is a warning too' 2 $script:NixWinRemovalWarnings.Count
} finally {
    Remove-Item Env:NIX_WIN_OLD_STORE_PATH -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

if ($script:Failed -gt 0) { Write-Host "$script:Failed test(s) failed"; exit 1 }
Write-Host "all removal-logic tests passed"
